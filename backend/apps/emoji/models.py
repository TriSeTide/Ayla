"""
表情包模型（M4-3，严格按开发文档第 4 节表情包 + 步骤文件 3.3 落库）。

- EmojiPack：表情包（is_system 系统包 owner 可为空）；
- EmojiItem：包内表情项。

唯一约束（步骤文件 3.4）：
- EmojiPack.unique(owner, name)：系统包 owner 为 NULL，NULL 唯一语义在 SQLite/MySQL 不同，
  因此在 services 做幂等（get_or_create_system_pack / get_or_create 个人包），DB 层不加会误导的约束；
- EmojiItem.unique(pack, media)：硬约束（DB 层），同一包内重复收藏必须被 DB 拒绝。

任务 03（群内表情包）：EmojiPack 增加 group FK 与 allow_member_upload 开关——
群表情包 = group 非空、owner 为空、is_system=False 的包，对群内所有成员可见；
上传权限默认仅群主/管理员，群主可在群详情页开启 allow_member_upload 允许普通成员上传。
"""
from django.conf import settings
from django.db import models


class EmojiPack(models.Model):
    """表情包。

    三种形态（互斥，由 services 保证）：
    - 个人包：owner 非空，group 为空；
    - 系统包：owner 为空，group 为空，is_system=True；
    - 群表情包：group 非空（任务 03），owner 为空，is_system=False；
      `allow_member_upload` 为群主设置的"是否允许普通群成员上传"开关（默认 False）。
    """

    id = models.AutoField(primary_key=True)
    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        related_name="emoji_packs",
        on_delete=models.CASCADE,
        null=True,
        blank=True,
    )
    # 群表情包关联的群（任务 03）；个人包/系统包为空
    group = models.ForeignKey(
        "chat.Conversation",
        related_name="emoji_packs",
        on_delete=models.CASCADE,
        null=True,
        blank=True,
    )
    name = models.CharField("名称", max_length=64)
    is_system = models.BooleanField("系统包", default=False)
    # 群表情包：是否允许普通群成员上传（仅群主可改，默认 False）
    allow_member_upload = models.BooleanField("允许普通成员上传", default=False)
    created_at = models.DateTimeField("创建时间", auto_now_add=True)

    class Meta:
        db_table = "emoji_packs"
        verbose_name = "表情包"
        verbose_name_plural = "表情包"

    def __str__(self) -> str:
        return f"{self.name} (system={self.is_system})"


class EmojiItem(models.Model):
    """表情项。"""

    id = models.AutoField(primary_key=True)
    pack = models.ForeignKey(
        EmojiPack, related_name="items", on_delete=models.CASCADE, db_index=True
    )
    media = models.ForeignKey(
        "media.MediaObject",
        related_name="emoji_items",
        on_delete=models.CASCADE,
        db_index=True,
    )
    tag = models.CharField("标签", max_length=64, blank=True, default="")
    created_at = models.DateTimeField("创建时间", auto_now_add=True)

    class Meta:
        db_table = "emoji_items"
        constraints = [
            models.UniqueConstraint(
                fields=["pack", "media"], name="uniq_emoji_pack_media"
            )
        ]
        verbose_name = "表情项"
        verbose_name_plural = "表情项"

    def __str__(self) -> str:
        return f"pack{self.pack_id}:media{self.media_id}"
