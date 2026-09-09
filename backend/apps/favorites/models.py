"""
收藏域模型（S6，收藏 + 群动态 highlights）。

Favorite：用户对任意可见目标（帖子/消息/直播间/语音房/桌游室）的收藏。
- `target_id` 用 CharField：User.id 是 uuid 字符串，而 live/voice/post/boardgame
  的 id 是 AutoField 整数；统一存字符串，查询时在 services 层转成对应类型。
- `(user, target_type, target_id)` 唯一：收藏幂等由 DB 兜底（MySQL 唯一约束）。

群（group）不再支持收藏：TARGET_CHOICES 不含群，新收藏被校验拒绝；存量群收藏
记录保留在 DB（不可变历史），由列表接口显式排除不再展示。
"""
from django.conf import settings
from django.db import models


class Favorite(models.Model):
    """收藏记录。"""

    TARGET_POST = "post"
    TARGET_MESSAGE = "message"
    TARGET_LIVE = "live"
    TARGET_VOICE = "voice"
    TARGET_GAME = "game"
    # 存量群收藏排除标记（列表接口 exclude 用；不进入 TARGET_CHOICES，新收藏被拒）
    TARGET_GROUP = "group"
    TARGET_CHOICES = [
        (TARGET_POST, "帖子"),
        (TARGET_MESSAGE, "消息"),
        (TARGET_LIVE, "直播间"),
        (TARGET_VOICE, "语音房"),
        (TARGET_GAME, "桌游室"),
    ]

    id = models.AutoField(primary_key=True)
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        related_name="favorites",
        on_delete=models.CASCADE,
    )
    target_type = models.CharField("目标类型", max_length=16, choices=TARGET_CHOICES)
    target_id = models.CharField("目标ID", max_length=64)
    created_at = models.DateTimeField("收藏时间", auto_now_add=True)

    class Meta:
        db_table = "favorites"
        unique_together = (("user", "target_type", "target_id"),)
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"{self.user_id}:{self.target_type}:{self.target_id}"
