"""
桌游域模型（S4，开发文档 §1.4）—— 仅房间框架，玩法引擎/WS 对局通道非本期目标。

- GameRoom：桌游室。字段名用 `owner`（复用 apps/common/visibility.py 的可见性 helper，
  与 live/voice/post 同构）；`game_type`/`status` 为占位字段（默认 boardgame / waiting），
  玩法本体后续实现；
- GameRoomMember：房间成员（room/user/seat），`(room, user)` 唯一（join 幂等 DB 兜底），
  `seat` 是占位座位号（join 时按当前成员数顺序分配，后续对局引擎接管）。

权限语义（工程约束，AGENTS.md §2.2）：
- 列表/详情/join 按可见性过滤（public 全登录 / friends 好友 / group 群员，不可见 → 403）；
- DELETE 仅 owner；
- leave 仅成员。
"""
from django.conf import settings
from django.db import models

from apps.common.visibility import Visibility


class GameRoom(models.Model):
    """桌游室。"""

    STATUS_WAITING = "waiting"
    STATUS_PLAYING = "playing"
    STATUS_ENDED = "ended"
    STATUS_CHOICES = [
        (STATUS_WAITING, "等待中"),
        (STATUS_PLAYING, "对局中"),
        (STATUS_ENDED, "已结束"),
    ]

    id = models.AutoField(primary_key=True)
    name = models.CharField("房间名", max_length=128)
    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        related_name="game_rooms",
        on_delete=models.CASCADE,
    )
    # 群归属：可空；非空时默认 visibility=group（services 层落值，见 apps/boardgame/services.py）。
    group = models.ForeignKey(
        "chat.Conversation",
        related_name="game_rooms",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        limit_choices_to={"type": "group"},
    )
    visibility = models.CharField(
        "可见性", max_length=16, choices=Visibility.choices, default=Visibility.PUBLIC
    )
    allowed_groups = models.ManyToManyField(
        "chat.Conversation", related_name="visible_game_rooms", blank=True,
        limit_choices_to={"type": "group"},
    )
    # 占位字段：玩法本体后续实现，本期固定默认值
    game_type = models.CharField("游戏类型", max_length=64, default="boardgame")
    status = models.CharField(
        "状态", max_length=16, choices=STATUS_CHOICES, default=STATUS_WAITING
    )
    created_at = models.DateTimeField("创建时间", auto_now_add=True, db_index=True)

    class Meta:
        db_table = "game_rooms"
        verbose_name = "桌游室"
        verbose_name_plural = "桌游室"
        ordering = ["-created_at"]
        indexes = [
            models.Index(fields=["owner"], name="game_rooms_owner_idx"),
            models.Index(fields=["group"], name="game_rooms_group_idx"),
            models.Index(fields=["status"], name="game_rooms_status_idx"),
        ]

    def __str__(self) -> str:
        return f"room{self.id}:{self.name}"


class GameRoomMember(models.Model):
    """房间成员（seat 为占位座位号）。"""

    id = models.AutoField(primary_key=True)
    room = models.ForeignKey(GameRoom, related_name="members", on_delete=models.CASCADE)
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        related_name="game_memberships",
        on_delete=models.CASCADE,
    )
    seat = models.PositiveIntegerField("座位号", default=0)
    joined_at = models.DateTimeField("加入时间", auto_now_add=True)

    class Meta:
        db_table = "game_room_members"
        unique_together = (("room", "user"),)
        verbose_name = "房间成员"
        verbose_name_plural = "房间成员"
        ordering = ["seat", "id"]

    def __str__(self) -> str:
        return f"room{self.room_id}:{self.user_id}:seat{self.seat}"
