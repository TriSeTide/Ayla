"""elysia_bridge DRF 序列化器 —— 爱莉 profile 管理（应用内 REST）。

字段收敛（REQUIREMENTS.zh.md §13.4 / D-2）：D-2 起 profile 只承载应用侧身份映射
`user` / `enabled` / `display_name` / `created_at`。`stream_id` / `platform` /
`chat_type` 三个字段随旧 SSE 桥接删除：

- `stream_id`：旧桥接用它给 Elysium 侧挑聊天流（inject + SSE 过滤）。新通道由
  WS 连接上的 JWT 认定身份，帧里直接带 `conversation_id`，不再有「stream」这层
  投影，故字段与 `generate_elysia_stream_id()` 一并删除；
- `platform` / `chat_type`：旧 inject 帧的附带字段，无任何读取方（DEVELOPMENT §3）。

主体性约束（AGENTS.md §4.1）：这里只管理应用侧映射与开关，display_name 仅用于
UI，绝不写回 Elysium 主体文件；本序列化不涉及爱莉第一人称内容的生成或改写。
"""
from django.contrib.auth import get_user_model
from rest_framework import serializers

from apps.accounts.serializers import UserPublicSerializer

from .models import ElysiaProfile

User = get_user_model()


class ElysiaProfileSerializer(serializers.ModelSerializer):
    """爱莉 profile 读写序列化。

    - user_id 只写（POST 绑定爱莉应用内 User；绑定后不可改，避免身份漂移）；
    - 读时附带 user 详情便于前端展示。
    """

    user = UserPublicSerializer(read_only=True)
    user_id = serializers.CharField(write_only=True)

    class Meta:
        model = ElysiaProfile
        fields = [
            "id",
            "user",
            "user_id",
            "enabled",
            "display_name",
            "created_at",
        ]
        read_only_fields = ["id", "created_at"]

    def validate_user_id(self, value: str) -> str:
        if not User.objects.filter(pk=value).exists():
            raise serializers.ValidationError("绑定的用户不存在")
        return value
