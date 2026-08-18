"""
直播域模型（M4-6，开发文档 §4 直播域未给表结构，按需求 FR-17/18 补充定义，补充字段显式标注）。

- LiveChannel：应用内直播频道。`stream_key` 是推流握手指纹（`secrets.token_hex(24)`，唯一索引），
  RTMP 流名 `live/{stream_key}`；`status` 是**乐观标记**（:start/:stop 更新），
  "是否在播"以 SRS HTTP API 实时判定为准（apps/live/srs.py），禁止把乐观标记伪装成真实直播状态；
- Danmaku：弹幕。落库 + WS 广播分离（复用 M4-5 voice.state 模式）；不建 FTS/不设敏感词过滤
  （弹幕过滤属 Elysium 侧审核能力，应用只落库广播，不代判内容意义，AGENTS.md §2）。

补充字段理由（写进 README 已知取舍）：开发文档直播域未定表结构，
`stream_key`/`status`/`started_at`/`ended_at` 是直播频道的最小必要组成（推流指纹 + 生命周期）；
核心语义（owner/title）与 FR-17 对齐。
"""
from django.conf import settings
from django.db import models

from apps.common.visibility import Visibility


class LiveChannel(models.Model):
    """直播频道。"""

    STATUS_CHOICES = (
        ("idle", "idle"),
        ("live", "live"),
        ("ended", "ended"),
    )

    id = models.AutoField(primary_key=True)
    title = models.CharField("直播间标题", max_length=128)
    description = models.TextField("直播间介绍", blank=True, default="")
    # 内部媒体 content URL；空串表示使用默认占位封面。
    cover = models.CharField("直播间封面", max_length=512, blank=True, default="")
    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        related_name="live_channels",
        on_delete=models.CASCADE,
    )
    # S1（聚合主页）：可见性 + 群归属。约束：visibility=group 时 group 必填；
    # group 非空时默认 visibility=group（services 层落值，见 apps/live/services.py）。
    visibility = models.CharField(
        "可见性", max_length=16, choices=Visibility.choices, default=Visibility.PUBLIC
    )
    group = models.ForeignKey(
        "chat.Conversation",
        related_name="live_channels",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        limit_choices_to={"type": "group"},
    )
    allowed_groups = models.ManyToManyField(
        "chat.Conversation", related_name="visible_live_channels", blank=True,
        limit_choices_to={"type": "group"},
    )
    # 补充（安全）：secrets.token_hex(24) = 48 字符，唯一索引；推流握手指纹，仅 owner 可见
    stream_key = models.CharField("推流指纹", max_length=64, unique=True)
    # 乐观标记：真实在播以 SRS 查询为准（srs.is_streaming）
    status = models.CharField(
        "状态", max_length=16, choices=STATUS_CHOICES, default="idle"
    )
    started_at = models.DateTimeField("最近开播时间", null=True, blank=True)
    ended_at = models.DateTimeField("最近下播时间", null=True, blank=True)
    created_at = models.DateTimeField("创建时间", auto_now_add=True)

    class Meta:
        db_table = "live_channels"
        verbose_name = "直播频道"
        verbose_name_plural = "直播频道"
        ordering = ["-created_at"]
        indexes = [
            models.Index(fields=["owner"], name="live_channels_owner_idx"),
            models.Index(fields=["status"], name="live_channels_status_idx"),
            models.Index(fields=["created_at"], name="live_channels_created_idx"),
        ]

    def __str__(self) -> str:
        return f"{self.title} ({self.status})"


class Danmaku(models.Model):
    """弹幕（落库 + WS 广播；内容原样，应用不代判意义）。"""

    id = models.AutoField(primary_key=True)
    channel = models.ForeignKey(
        LiveChannel, related_name="danmaku", on_delete=models.CASCADE
    )
    sender = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        related_name="danmaku",
        on_delete=models.CASCADE,
    )
    content = models.CharField("弹幕文本", max_length=200)
    media_id = models.CharField("媒体引用", max_length=64, null=True, blank=True)
    created_at = models.DateTimeField("发送时间", auto_now_add=True)

    class Meta:
        db_table = "live_danmaku"
        verbose_name = "弹幕"
        verbose_name_plural = "弹幕"
        ordering = ["-created_at"]
        indexes = [
            # 新进房间拉最近 N 条
            models.Index(
                fields=["channel", "created_at"], name="live_danmaku_chan_created_idx"
            ),
        ]

    def __str__(self) -> str:
        return f"dm{self.id}:{self.content[:20]}"
