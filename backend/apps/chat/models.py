"""
聊天域模型（M4-2，严格按开发文档第 4 节落库）。

- Conversation：会话（PRIVATE/GROUP），`announcement` 为补加字段（README 已注明）；
- ConversationMember：会话成员（role: member/admin/owner；muted 禁言）；
- Message：消息（文本/图片/语音/文件/表情/系统），`idempotency_key` 唯一（幂等契约核心），
  `seq` 为会话内单调递增序号（补发与分页游标），`(conversation, seq)` 唯一兜底并发；
- MessageRead：已读回执，`(message, user)` 唯一。

硬约束继承 AGENTS.md：
- 幂等是工程硬约束，`idempotency_key` 唯一约束必须实现；
- 私聊"同两人只能有一个会话"在 services 层做幂等查找（见 get_or_create_conversation），
  不在 DB 层硬约束，因为 PRIVATE 会话在 DB 层无法用 members 表达唯一性。
"""
from django.conf import settings
from django.db import models


class Conversation(models.Model):
    """会话（私聊/群聊）。"""

    TYPE_PRIVATE = "private"
    TYPE_GROUP = "group"
    TYPE_CHOICES = [
        (TYPE_PRIVATE, "私聊"),
        (TYPE_GROUP, "群聊"),
    ]

    id = models.AutoField(primary_key=True)
    type = models.CharField("类型", max_length=16, choices=TYPE_CHOICES)
    title = models.CharField("标题", max_length=128, blank=True, default="")
    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        related_name="owned_conversations",
        on_delete=models.CASCADE,
        null=True,
        blank=True,
    )
    # 补加字段（开发文档 Conversation 表无此字段，见步骤文件 3.1/10 节注明）
    announcement = models.TextField("群公告", blank=True, default="")
    created_at = models.DateTimeField("创建时间", auto_now_add=True)

    class Meta:
        db_table = "conversations"
        verbose_name = "会话"
        verbose_name_plural = "会话"
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"{self.type}:{self.title or self.id}"


class ConversationMember(models.Model):
    """会话成员。"""

    ROLE_MEMBER = "member"
    ROLE_ADMIN = "admin"
    ROLE_OWNER = "owner"
    ROLE_CHOICES = [
        (ROLE_MEMBER, "成员"),
        (ROLE_ADMIN, "管理员"),
        (ROLE_OWNER, "群主"),
    ]

    id = models.AutoField(primary_key=True)
    conversation = models.ForeignKey(
        Conversation, related_name="members", on_delete=models.CASCADE
    )
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL, related_name="chat_memberships", on_delete=models.CASCADE
    )
    role = models.CharField("角色", max_length=16, choices=ROLE_CHOICES, default=ROLE_MEMBER)
    muted = models.BooleanField("禁言", default=False)
    joined_at = models.DateTimeField("加入时间", auto_now_add=True)

    class Meta:
        db_table = "conversation_members"
        unique_together = (("conversation", "user"),)
        verbose_name = "会话成员"
        verbose_name_plural = "会话成员"

    def __str__(self) -> str:
        return f"conv{self.conversation_id}:{self.user_id}:{self.role}"


class Message(models.Model):
    """消息。"""

    TYPE_TEXT = "text"
    TYPE_IMAGE = "image"
    TYPE_VOICE = "voice"
    TYPE_FILE = "file"
    TYPE_EMOJI = "emoji"
    TYPE_SYSTEM = "system"
    TYPE_CHOICES = [
        (TYPE_TEXT, "文本"),
        (TYPE_IMAGE, "图片"),
        (TYPE_VOICE, "语音"),
        (TYPE_FILE, "文件"),
        (TYPE_EMOJI, "表情"),
        (TYPE_SYSTEM, "系统"),
    ]

    STATUS_SENT = "sent"
    STATUS_DELIVERED = "delivered"
    STATUS_READ = "read"
    STATUS_RECALLED = "recalled"
    STATUS_CHOICES = [
        (STATUS_SENT, "已发送"),
        (STATUS_DELIVERED, "已送达"),
        (STATUS_READ, "已读"),
        (STATUS_RECALLED, "已撤回"),
    ]

    id = models.AutoField(primary_key=True)
    conversation = models.ForeignKey(
        Conversation, related_name="messages", on_delete=models.CASCADE, db_index=True
    )
    sender = models.ForeignKey(
        settings.AUTH_USER_MODEL, related_name="chat_messages", on_delete=models.CASCADE
    )
    type = models.CharField("类型", max_length=16, choices=TYPE_CHOICES, default=TYPE_TEXT)
    content = models.TextField("内容", blank=True, default="")
    media_id = models.CharField("媒体引用", max_length=64, null=True, blank=True)
    reply_to = models.ForeignKey(
        "self",
        related_name="replies",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
    )
    status = models.CharField("状态", max_length=16, choices=STATUS_CHOICES, default=STATUS_SENT)
    idempotency_key = models.CharField("幂等键", max_length=64, unique=True)
    seq = models.PositiveBigIntegerField("会话内序号")
    created_at = models.DateTimeField("创建时间", auto_now_add=True)
    recalled_at = models.DateTimeField("撤回时间", null=True, blank=True)

    class Meta:
        db_table = "messages"
        # (conversation, seq) 唯一：并发写同一会话的兜底
        constraints = [
            models.UniqueConstraint(
                fields=["conversation", "seq"], name="uniq_conv_seq"
            )
        ]
        verbose_name = "消息"
        verbose_name_plural = "消息"
        ordering = ["seq"]

    def __str__(self) -> str:
        return f"conv{self.conversation_id}:{self.seq}"


class MessageRead(models.Model):
    """已读回执（读到哪条 = 已读回执发到该条）。"""

    id = models.AutoField(primary_key=True)
    message = models.ForeignKey(Message, related_name="reads", on_delete=models.CASCADE)
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL, related_name="chat_reads", on_delete=models.CASCADE
    )
    read_at = models.DateTimeField("阅读时间", auto_now_add=True)

    class Meta:
        db_table = "message_reads"
        unique_together = (("message", "user"),)
        verbose_name = "已读回执"
        verbose_name_plural = "已读回执"

    def __str__(self) -> str:
        return f"msg{self.message_id}:{self.user_id}"
