"""
用户域模型（FR-1~FR-4）。

- User：AbstractUser 扩展（文档 7.1 要求），加入昵称/头像/签名/在线状态字段；
  id 使用 uuid hex 字符串，符合应用内 WS 消息帧的字符串 id 协议；
- Friendship：好友关系，status 区分 pending/accepted/blocked；
- FriendRequest：好友申请流，带申请消息与处理状态。

在线状态（auto/away/dnd/invisible）是运行事实而非关系信念，
Redis 中维护实时值，数据库 status 字段仅作为离线后的持久化期望（见 presence.py）。
auto（自动）表示对外显示跟随实时在线状态；presence 实时值仍只区分 online/invisible。
"""
import uuid

from django.conf import settings
from django.contrib.auth.models import AbstractUser
from django.db import models


def _gen_uuid() -> str:
    return uuid.uuid4().hex


class User(AbstractUser):
    """应用内用户（含爱莉的应用内身份，见 elysia_bridge 里程碑）。"""

    id = models.CharField(
        primary_key=True, default=_gen_uuid, max_length=32, editable=False
    )
    email = models.EmailField("邮箱", unique=True, null=True, blank=True)

    nickname = models.CharField("昵称", max_length=64, blank=True, default="")
    avatar = models.CharField("头像", max_length=512, blank=True, default="")
    signature = models.CharField("个性签名", max_length=256, blank=True, default="")

    # 离线时的持久化期望状态；实时在线状态以 Redis 为准
    # auto（自动）：对外显示跟随实时在线；旧 online 值已并入 auto（数据迁移见 0004）
    STATUS_AUTO = "auto"
    STATUS_AWAY = "away"
    STATUS_DND = "dnd"
    STATUS_INVISIBLE = "invisible"
    STATUS_CHOICES = [
        (STATUS_AUTO, "自动"),
        (STATUS_AWAY, "离开"),
        (STATUS_DND, "勿扰"),
        (STATUS_INVISIBLE, "隐身"),
    ]
    status = models.CharField(
        "状态", max_length=16, choices=STATUS_CHOICES, default=STATUS_AUTO
    )

    last_active_at = models.DateTimeField("最后活跃", null=True, blank=True)

    # 媒体活动事实：用于跨页面恢复入口；由 voice/live 生命周期服务维护。
    is_in_voice = models.BooleanField("正在语音房", default=False)
    voice_room_id = models.PositiveIntegerField("语音房 ID", null=True, blank=True)
    is_live = models.BooleanField("正在开播", default=False)
    live_room_id = models.PositiveIntegerField("直播间 ID", null=True, blank=True)

    # 内容可见性：是否向他人展示我的内容（发帖/直播间/桌游）。
    # 默认关闭（隐私优先）；开启后他人个人页才会显示「他的内容」卡片，收藏永不对外。
    show_content = models.BooleanField("向他人展示内容", default=False)

    class Meta:
        db_table = "users"
        verbose_name = "用户"
        verbose_name_plural = "用户"
        ordering = ["-date_joined"]

    def __str__(self) -> str:
        return self.nickname or self.username


class Friendship(models.Model):
    """好友关系（双向已确认）。"""

    id = models.AutoField(primary_key=True)
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL, related_name="friendships", on_delete=models.CASCADE
    )
    friend = models.ForeignKey(
        settings.AUTH_USER_MODEL, related_name="friended_by", on_delete=models.CASCADE
    )
    STATUS_PENDING = "pending"
    STATUS_ACCEPTED = "accepted"
    STATUS_BLOCKED = "blocked"
    STATUS_CHOICES = [
        (STATUS_PENDING, "待确认"),
        (STATUS_ACCEPTED, "已确认"),
        (STATUS_BLOCKED, "已屏蔽"),
    ]
    status = models.CharField(
        "状态", max_length=16, choices=STATUS_CHOICES, default=STATUS_ACCEPTED
    )
    created_at = models.DateTimeField("创建时间", auto_now_add=True)
    updated_at = models.DateTimeField("更新时间", auto_now=True)

    class Meta:
        db_table = "friendships"
        unique_together = (("user", "friend"),)
        verbose_name = "好友关系"
        verbose_name_plural = "好友关系"

    def __str__(self) -> str:
        return f"{self.user_id}->{self.friend_id}:{self.status}"


class FriendRequest(models.Model):
    """好友申请。"""

    id = models.AutoField(primary_key=True)
    from_user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        related_name="friend_requests_sent",
        on_delete=models.CASCADE,
    )
    to_user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        related_name="friend_requests_received",
        on_delete=models.CASCADE,
    )
    message = models.CharField("申请消息", max_length=256, blank=True, default="")
    STATUS_PENDING = "pending"
    STATUS_ACCEPTED = "accepted"
    STATUS_REJECTED = "rejected"
    STATUS_CHOICES = [
        (STATUS_PENDING, "待处理"),
        (STATUS_ACCEPTED, "已同意"),
        (STATUS_REJECTED, "已拒绝"),
    ]
    status = models.CharField(
        "状态", max_length=16, choices=STATUS_CHOICES, default=STATUS_PENDING
    )
    created_at = models.DateTimeField("创建时间", auto_now_add=True)
    handled_at = models.DateTimeField("处理时间", null=True, blank=True)

    class Meta:
        db_table = "friend_requests"
        verbose_name = "好友申请"
        verbose_name_plural = "好友申请"

    def __str__(self) -> str:
        return f"{self.from_user_id}->{self.to_user_id}:{self.status}"
