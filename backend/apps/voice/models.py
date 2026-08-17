"""
语音频道域模型（M4-5，严格按开发文档第 4 节 + 注明补充字段）。

- VoiceChannel：真人语音频道（Discord 风格）。`room_name` 唯一，LiveKit Room 名；
- VoiceChannelMember：频道成员（**补充表**，开发文档 §4 只有频道表，
  但需求 FR-13「用户可加入/离开」FR-16「断线恢复」需要持久化"谁在哪个频道"）。

补充表/字段的理由（写进 README 已知取舍）：
- `last_seen_at`（补充字段）：presence 心跳刷新，用于超时判定"是否还在频道"，
  配合 `voice.state` 广播（技术状态，不是爱莉/用户的情绪判断，见阶段三 §12.3）。

权限语义（复用 M4-2 约定）：
- `channel.owner` 只是"创建者"语义；真正权限判断是"是否在 `members` 里"（沿用 `user_can_access` 风格）。
- 频道默认开放加入（类似 Discord 语音频道）；私有/邀请制留待后续。
"""
from django.conf import settings
from django.db import models

from apps.common.visibility import Visibility


class VoiceChannel(models.Model):
    """语音频道。"""

    id = models.AutoField(primary_key=True)
    name = models.CharField("频道名", max_length=128)
    room_name = models.CharField(
        "LiveKit Room 名", max_length=128, unique=True
    )
    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        related_name="owned_voice_channels",
        on_delete=models.CASCADE,
    )
    # S1（聚合主页）：可见性 + 群归属。约束：visibility=group 时 group 必填；
    # group 非空时默认 visibility=group（services 层落值，见 apps/voice/services.py）。
    visibility = models.CharField(
        "可见性", max_length=16, choices=Visibility.choices, default=Visibility.PUBLIC
    )
    group = models.ForeignKey(
        "chat.Conversation",
        related_name="voice_channels",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        limit_choices_to={"type": "group"},
    )
    created_at = models.DateTimeField("创建时间", auto_now_add=True)

    class Meta:
        db_table = "voice_channels"
        verbose_name = "语音频道"
        verbose_name_plural = "语音频道"
        ordering = ["id"]

    def __str__(self) -> str:
        return f"{self.name} ({self.room_name})"


class VoiceChannelMember(models.Model):
    """频道成员（补充表：持久化"谁在哪个频道"，FR-13/FR-16）。"""

    id = models.AutoField(primary_key=True)
    channel = models.ForeignKey(
        VoiceChannel, related_name="members", on_delete=models.CASCADE
    )
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        related_name="voice_memberships",
        on_delete=models.CASCADE,
    )
    joined_at = models.DateTimeField("最近加入时间", auto_now_add=True)
    # 补充字段：presence 心跳刷新，断线判定依据
    last_seen_at = models.DateTimeField("最近活跃", auto_now=True)

    class Meta:
        db_table = "voice_channel_members"
        unique_together = (("channel", "user"),)
        verbose_name = "频道成员"
        verbose_name_plural = "频道成员"

    def __str__(self) -> str:
        return f"vc{self.channel_id}:{self.user_id}"


class VoiceChatMessage(models.Model):
    """语音房独立文字消息，不复用群聊 Message。"""

    id = models.AutoField(primary_key=True)
    channel = models.ForeignKey(
        VoiceChannel, related_name="chat_messages", on_delete=models.CASCADE
    )
    sender = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        related_name="voice_chat_messages",
        on_delete=models.CASCADE,
    )
    content = models.CharField("消息内容", max_length=2000, blank=True, default="")
    media_id = models.CharField("媒体引用", max_length=64, null=True, blank=True)
    created_at = models.DateTimeField("发送时间", auto_now_add=True, db_index=True)

    class Meta:
        db_table = "voice_chat_messages"
        ordering = ["created_at", "id"]

    def __str__(self) -> str:
        return f"voice{self.channel_id}:{self.id}"
