"""elysia_bridge DRF 序列化器 —— 爱莉 profile 管理（应用内 REST）。

主体性约束（AGENTS.md §4.1）：这里只管理应用侧映射（user/stream_id/enabled/
display_name/chat_type/platform），display_name 仅用于 UI，绝不写回 Elysium
主体文件；本序列化不涉及爱莉第一人称内容的生成或改写。

stream_id 契约（Elysium接入Ayla平台模块.md §5.2）：
- POST 未显式提供时，用 `generate_elysia_stream_id(user_id)` 自动生成
  （SHA-256 `ayla_<uid>_private`，与 Elysium 侧同算法，避开历史飞书流）；
- 显式提供则保留（管理员已知 stream_id 时可注入既有流）。
"""
from django.contrib.auth import get_user_model
from rest_framework import serializers

from apps.accounts.serializers import UserPublicSerializer

from .models import ElysiaProfile, generate_elysia_stream_id

User = get_user_model()


class ElysiaProfileSerializer(serializers.ModelSerializer):
    """爱莉 profile 读写序列化。

    - user_id 只写（POST 绑定爱莉应用内 User；绑定后不可改，避免身份漂移）；
    - stream_id 创建后不可改（inject/SSE 过滤都依赖它，改它等于换爱莉实例）；
    - 读时附带 user 详情便于前端展示。
    """

    user = UserPublicSerializer(read_only=True)
    user_id = serializers.CharField(write_only=True)
    # stream_id 可选：POST 未提供时由 create() 自动生成 ayla 独立流（文档 §5.2）
    stream_id = serializers.CharField(
        required=False, allow_blank=True, allow_null=True
    )

    class Meta:
        model = ElysiaProfile
        fields = [
            "id",
            "user",
            "user_id",
            "stream_id",
            "platform",
            "enabled",
            "display_name",
            "chat_type",
            "created_at",
        ]
        read_only_fields = ["id", "created_at"]

    def validate_user_id(self, value: str) -> str:
        if not User.objects.filter(pk=value).exists():
            raise serializers.ValidationError("绑定的用户不存在")
        return value

    def validate_stream_id(self, value: str) -> str:
        value = (value or "").strip()
        if not value:
            # POST 未提供 → 由 create() 用 user_id 自动生成 ayla 流
            return value
        return value

    def create(self, validated_data):
        stream_id = (validated_data.get("stream_id") or "").strip()
        if not stream_id:
            user_id = validated_data["user_id"]
            stream_id = generate_elysia_stream_id(str(user_id))
            validated_data["stream_id"] = stream_id
        return super().create(validated_data)
