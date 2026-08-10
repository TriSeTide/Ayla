"""
爱莉桥接领域模型（M4-4，严格按开发文档 §4 + 步骤文件 §3.1 落库）。

ElysiaProfile：爱莉在应用内的身份映射（应用级单例）。
- user       → 爱莉在应用内的真实 User（可被搜索/私聊/@/加群，FR-26），唯一；
- stream_id  → 爱莉在 Elysium 侧接收该应用消息的聊天流，inject 与 SSE 过滤都用它，唯一；
- platform   → 注入时 platform 字段（本应用即 "elysia-app"，显式覆盖账本投影）；
- enabled    → 关闭时桥接跳过（不 inject / 不投影出站）。

补充字段（步骤文件 §3.1 注明，不改变开发文档 §4 核心字段）：
- display_name：应用内展示名，只用于 UI，绝不写回 Elysium 主体文件；
- chat_type   ：阶段三 messages:inject 的可选字段（private|group），接口驱动补充；
- created_at  ：便于管理排查。

主体性约束（AGENTS.md §4.1）：应用侧 messages 表里爱莉作为发送者的消息，
sender 一律指向本 profile 绑定的应用内 User；内容只能来自 Elysium 出站事件投影，
应用侧代码绝不生成爱莉的第一人称内容。display_name 只用于应用 UI。
"""
from django.conf import settings
from django.db import models


class ElysiaProfile(models.Model):
    """爱莉在应用内的唯一身份映射（应用级单例）。"""

    PLATFORM_DEFAULT = "elysia-app"
    CHAT_TYPE_PRIVATE = "private"
    CHAT_TYPE_GROUP = "group"
    CHAT_TYPE_CHOICES = [
        (CHAT_TYPE_PRIVATE, "私聊"),
        (CHAT_TYPE_GROUP, "群聊"),
    ]

    id = models.AutoField(primary_key=True)
    user = models.OneToOneField(
        settings.AUTH_USER_MODEL,
        related_name="elysia_profile",
        on_delete=models.CASCADE,
        verbose_name="爱莉应用内用户",
    )
    stream_id = models.CharField(
        "Elysium stream_id", max_length=240, unique=True
    )
    platform = models.CharField(
        "平台标识", max_length=64, default=PLATFORM_DEFAULT
    )
    enabled = models.BooleanField("启用", default=True)
    # 补充字段
    display_name = models.CharField("展示名", max_length=128, blank=True, default="")
    chat_type = models.CharField(
        "聊天类型", max_length=16, choices=CHAT_TYPE_CHOICES, default=CHAT_TYPE_PRIVATE
    )
    created_at = models.DateTimeField("创建时间", auto_now_add=True)

    class Meta:
        db_table = "elysia_profiles"
        verbose_name = "爱莉桥接档案"
        verbose_name_plural = "爱莉桥接档案"

    def __str__(self) -> str:
        return f"ElysiaProfile(user={self.user_id}, stream={self.stream_id})"
