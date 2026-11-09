"""
爱莉桥接领域模型。

- `ElysiaProfile`：爱莉在应用内的身份映射（应用级单例）。D-2 起只保留
  `user` / `enabled` / `display_name` / `created_at`；`stream_id` / `platform` /
  `chat_type` 随旧 SSE 桥接一起删除（REQUIREMENTS.zh.md §13.4）——通道身份改由
  WS 连接上的 JWT 认定，不再需要「Elysium 侧 stream」这一层投影。

- `AylaChannelSequence`：通道序号分配器（每个通道一行，`SELECT ... FOR UPDATE`
  加锁取号）。**序号不复用 `Message.id`**：`Message.id` 是全站消息自增主键，
  与「投递给 DSH 的通道序号」语义不同，且不能保证在本通道内连续。

- `AylaInboundOutbox`：一条用户消息待投递给 DSH 的入站 outbox 行。
  与 `Message` 必须在**同一事务**内写入；DSH 收到并 ack 后才置 `delivered`。

为什么序号需要独立序列表（实测依据，非偏好）：

MySQL 8.0 / REPEATABLE READ 下，用 `SELECT MAX(seq) FROM outbox FOR UPDATE`
（或 `ORDER BY seq DESC LIMIT 1 FOR UPDATE`）取号**不能串行化**：

- 表尾是不存在的 gap，多个事务可以同时持有该 gap 的 X 锁；
- 随后各自 INSERT 相同的 `max+1`，要么 `IntegrityError 1062`，
  要么互相等插入意向锁形成 `Deadlock 1213`；
- 本机实测（4 并发）：方案 A/B 均 1 成功 3 死锁；C 变体 1 成功 3 重复键。

改为「专用序号行 + `SELECT ... FOR UPDATE`」后实测 8/16 并发全部成功，
序号连续无空洞、最大等待 0.042s。故 `next_seq()` 走 `AylaChannelSequence`。

主体性约束（AGENTS.md §4.1）：应用侧 messages 表里爱莉作为发送者的消息，
sender 一律指向 `ElysiaProfile` 绑定的应用内 User；内容只能来自她自己的意识
实例经通道投递，应用侧代码绝不生成爱莉的第一人称内容。`display_name`
只用于应用 UI。
"""
from __future__ import annotations

from django.conf import settings
from django.db import models, transaction


class ElysiaProfile(models.Model):
    """爱莉在应用内的唯一身份映射（应用级单例）。"""

    id = models.AutoField(primary_key=True)
    user = models.OneToOneField(
        settings.AUTH_USER_MODEL,
        related_name="elysia_profile",
        on_delete=models.CASCADE,
        verbose_name="爱莉应用内用户",
    )
    enabled = models.BooleanField("启用", default=True)
    display_name = models.CharField("展示名", max_length=128, blank=True, default="")
    created_at = models.DateTimeField("创建时间", auto_now_add=True)

    class Meta:
        db_table = "elysia_profiles"
        verbose_name = "爱莉桥接档案"
        verbose_name_plural = "爱莉桥接档案"

    def __str__(self) -> str:
        return f"ElysiaProfile(user={self.user_id})"


class AylaChannelSequence(models.Model):
    """通道序号分配器：一行一个通道，取号时对该行加行锁。

    行锁必须加在**已存在且唯一**的行上，才能让并发事务真正串行；
    若对聚合结果（`MAX(seq)`）或表尾 gap 加锁，MySQL 允许并发持有，
    取号会重复或死锁（见模块 docstring 的实测记录）。
    """

    # 入站（用户消息 → DSH）通道。出站序号将来若需要，另起一行，互不影响。
    NAME_INBOUND = "ayla_inbound"

    id = models.AutoField(primary_key=True)
    name = models.CharField("通道", max_length=32, unique=True)
    last_seq = models.BigIntegerField("已分配序号", default=0)
    updated_at = models.DateTimeField("更新时间", auto_now=True)

    class Meta:
        db_table = "ayla_channel_sequences"
        verbose_name = "通道序号"
        verbose_name_plural = "通道序号"

    def __str__(self) -> str:
        return f"AylaChannelSequence({self.name}={self.last_seq})"


def next_seq(name: str = AylaChannelSequence.NAME_INBOUND) -> int:
    """在当前事务内取下一个通道序号（max+1，行锁串行化）。

    必须在与 outbox 写入相同的 `transaction.atomic()` 内调用：提交前持有该
    通道行的 X 锁，其他取号事务排队等待，因此序号单调递增且不重复。
    `atomic()` 在已处于事务中时只是 savepoint，不会提前释放行锁。

    不用 `Message.id` 当序号的理由：它是全站消息主键，跨会话交错，
    不能满足「本通道内单调、可 resume」的契约（REQUIREMENTS.zh.md §7.1）。
    """
    with transaction.atomic():
        # 首次运行时补建序号行（unique 约束保证并发安全）；
        # get_or_create 的写入也会在该事务内提交，与取号同生共死。
        AylaChannelSequence.objects.get_or_create(
            name=name, defaults={"last_seq": 0}
        )
        row = AylaChannelSequence.objects.select_for_update().get(name=name)
        row.last_seq = row.last_seq + 1
        row.save(update_fields=["last_seq", "updated_at"])
        return row.last_seq


class AylaInboundOutbox(models.Model):
    """一条用户消息待投递给 DSH 通道（与 Message 同事务写入）。

    生命周期：`pending` →（DSH ack）`delivered`；
    可重试失败留在 `pending` 并累加 `attempts` / 置 `next_attempt_at`；
    超过重投上限 → `dead`（保留现场，人工处置，不静默丢弃）；
    `failed` 表示该条**不可投递**（如超出单条 32 KiB、缺少 seq），不重试。
    """

    STATUS_PENDING = "pending"
    STATUS_DELIVERED = "delivered"
    STATUS_FAILED = "failed"
    STATUS_DEAD = "dead"
    STATUS_CHOICES = [
        (STATUS_PENDING, "待投递"),
        (STATUS_DELIVERED, "已确认"),
        (STATUS_FAILED, "不可投递"),
        (STATUS_DEAD, "重投耗尽"),
    ]

    id = models.AutoField(primary_key=True)
    # db_constraint=False：服务器默认引擎可能是 MyISAM（不支持 FK 约束），
    # 建表时内联 FK 会被静默忽略；约束由迁移 0004 在表转为 InnoDB 后手动添加
    # （与 chat.0001 的 group_subgroups 同一手法）。ORM 级级联不受影响。
    message = models.OneToOneField(
        "chat.Message",
        related_name="ayla_outbox",
        on_delete=models.CASCADE,
        db_constraint=False,
        verbose_name="消息",
    )
    seq = models.BigIntegerField("通道序号", unique=True)
    status = models.CharField(
        "状态", max_length=16, choices=STATUS_CHOICES, default=STATUS_PENDING
    )
    attempts = models.IntegerField("已尝试次数", default=0)
    next_attempt_at = models.DateTimeField("下次重试时间", null=True, blank=True)
    last_error = models.TextField("最近错误", blank=True, default="")
    created_at = models.DateTimeField("创建时间", auto_now_add=True)
    updated_at = models.DateTimeField("更新时间", auto_now=True)

    class Meta:
        db_table = "ayla_inbound_outbox"
        # 补投按 (status, seq) 升序扫描；resume 从 seq+1 起重投 pending。
        indexes = [
            models.Index(fields=["status", "seq"], name="ayla_outbox_status_seq"),
        ]
        verbose_name = "入站 outbox"
        verbose_name_plural = "入站 outbox"

    def __str__(self) -> str:
        return f"AylaInboundOutbox(seq={self.seq}, status={self.status})"


def enqueue_inbound(message) -> AylaInboundOutbox:
    """把一条消息登记为待投递（取号 + 落 outbox，同一事务）。

    这里显式包 `transaction.atomic()`，原因不只是「方便调用方」：

    - 取号依赖行锁，行锁只在事务提交前有效。若在 autocommit 下取号，`next_seq()`
      自己的 atomic 会立刻提交，序号锁当场释放，而 outbox 行还没写——中间崩溃就会
      留下一个**已分配但无对应消息**的序号；
    - 包起来之后，即使调用方在 autocommit 下调用，序号与 outbox 行也同生共死；
      调用方已有更外层事务时（推荐写法：与 `Message` 落库同一个 `atomic()`），
      本函数的 atomic 退化为 savepoint，不会提前释放行锁。

    幂等提示：`message` 是 OneToOne，重复登记会触发唯一约束而不是静默覆盖
    —— 重复入站应由调用方按 `idempotency_key` 去重（chat.services 已有该语义）。
    """
    with transaction.atomic():
        return AylaInboundOutbox.objects.create(
            message=message,
            seq=next_seq(),
            status=AylaInboundOutbox.STATUS_PENDING,
        )
