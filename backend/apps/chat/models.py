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
    # 群头像：媒体 content URL（/api/v1/media/{id}/content），空串表示未设置（仅群聊使用）
    avatar = models.CharField("群头像", max_length=512, blank=True, default="")
    JOIN_PUBLIC = "public"
    JOIN_APPLICATION = "application"
    JOIN_POLICY_CHOICES = [
        (JOIN_PUBLIC, "公开加入"),
        (JOIN_APPLICATION, "申请加入"),
    ]
    join_policy = models.CharField(
        "加入方式", max_length=20, choices=JOIN_POLICY_CHOICES, default=JOIN_APPLICATION
    )
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
    # 用户各自的会话视图偏好（每个成员独立，不共享）：
    # - is_pinned：该成员在会话列表中置顶该会话；
    # - hidden：该成员"删除"会话（仅从本人列表隐藏，不删消息；对方再发消息会自动取消隐藏）。
    is_pinned = models.BooleanField("置顶", default=False)
    hidden = models.BooleanField("隐藏", default=False)
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
    TYPE_VIDEO = "video"
    TYPE_MIXED = "mixed"
    TYPE_SYSTEM = "system"
    TYPE_POKE = "poke"
    TYPE_CHOICES = [
        (TYPE_TEXT, "文本"),
        (TYPE_IMAGE, "图片"),
        (TYPE_VOICE, "语音"),
        (TYPE_FILE, "文件"),
        (TYPE_EMOJI, "表情"),
        (TYPE_VIDEO, "视频"),
        (TYPE_MIXED, "图文混排"),
        (TYPE_SYSTEM, "系统"),
        (TYPE_POKE, "戳一戳"),
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
    # 图文混排段（type=mixed）：有序数组，每段
    #   {"type": "text", "text": "..."} 或 {"type": "image"|"video", "media_id": "..."}
    # content 冗余保存全部 text 段拼接（旧逻辑/搜索/预览兼容）；单媒体消息（image/voice/
    # video/file/emoji）不使用 segments（保持旧格式 media_id + type）。
    segments = models.JSONField("图文段", null=True, blank=True, default=None)
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


class GroupJoinRequest(models.Model):
    """入群申请（B1，开发文档 §1.2）。

    幂等语义与私聊会话一致（services 层做，不依赖 DB 部分唯一索引——
    MySQL 不支持 partial unique index，`(conversation, applicant, pending)`
    唯一性由 services 的 pending 查重保证，见 services.create_join_request）。
    """

    STATUS_PENDING = "pending"
    STATUS_ACCEPTED = "accepted"
    STATUS_REJECTED = "rejected"
    STATUS_CHOICES = [
        (STATUS_PENDING, "待处理"),
        (STATUS_ACCEPTED, "已同意"),
        (STATUS_REJECTED, "已拒绝"),
    ]

    id = models.AutoField(primary_key=True)
    conversation = models.ForeignKey(
        Conversation, related_name="join_requests", on_delete=models.CASCADE
    )
    applicant = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        related_name="group_join_requests",
        on_delete=models.CASCADE,
    )
    message = models.CharField("申请消息", max_length=256, blank=True, default="")
    status = models.CharField(
        "状态", max_length=16, choices=STATUS_CHOICES, default=STATUS_PENDING
    )
    handled_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        related_name="handled_group_join_requests",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
    )
    handled_at = models.DateTimeField("处理时间", null=True, blank=True)
    created_at = models.DateTimeField("申请时间", auto_now_add=True)

    class Meta:
        db_table = "group_join_requests"
        verbose_name = "入群申请"
        verbose_name_plural = "入群申请"
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"conv{self.conversation_id}:{self.applicant_id}:{self.status}"


class GroupMemberLeaveNotice(models.Model):
    """持久化退群通知，避免接收者不在线时丢失。"""
    recipient = models.ForeignKey(settings.AUTH_USER_MODEL, related_name="group_leave_notices", on_delete=models.CASCADE)
    conversation = models.ForeignKey(Conversation, related_name="member_leave_notices", on_delete=models.CASCADE)
    member_name = models.CharField(max_length=150)
    read_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "group_member_leave_notices"
        ordering = ["-created_at"]


class GroupInvite(models.Model):
    """入群邀请（B1，开发文档 §1.2）。

    幂等：同 (conversation, inviter, invitee) 的 pending 邀请由 services 查重
    （不设 DB 部分唯一索引，理由同 GroupJoinRequest）。
    """

    STATUS_PENDING = "pending"
    STATUS_ACCEPTED = "accepted"
    STATUS_REJECTED = "rejected"
    STATUS_CHOICES = [
        (STATUS_PENDING, "待处理"),
        (STATUS_ACCEPTED, "已同意"),
        (STATUS_REJECTED, "已拒绝"),
    ]

    id = models.AutoField(primary_key=True)
    conversation = models.ForeignKey(
        Conversation, related_name="invites", on_delete=models.CASCADE
    )
    inviter = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        related_name="group_invites_sent",
        on_delete=models.CASCADE,
    )
    invitee = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        related_name="group_invites_received",
        on_delete=models.CASCADE,
    )
    status = models.CharField(
        "状态", max_length=16, choices=STATUS_CHOICES, default=STATUS_PENDING
    )
    handled_at = models.DateTimeField("处理时间", null=True, blank=True)
    created_at = models.DateTimeField("邀请时间", auto_now_add=True)

    class Meta:
        db_table = "group_invites"
        verbose_name = "入群邀请"
        verbose_name_plural = "入群邀请"
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"conv{self.conversation_id}:{self.invitee_id}:{self.status}"
