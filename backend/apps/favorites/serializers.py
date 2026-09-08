"""
收藏序列化（S6）。

FavoriteSerializer 输出 id/user_id/target_type/target_id/created_at，
并附带可选 `target` 安全卡片 dict（消息仍为原摘要）：
- 目标仍存在且当前用户可访问 → 返回公开卡片字段；
- 目标已被删除 → `target` 为 null，收藏记录本身仍返回（不报错）。
"""
from rest_framework import serializers

from .models import Favorite
from .target_cards import build_target_cards, target_key


class FavoriteListSerializer(serializers.ListSerializer):
    """Share one permission-filtered target batch across the current page."""

    def to_representation(self, data):
        rows = list(data)
        self.context["favorite_target_cards"] = build_target_cards(
            rows, self.context.get("request"),
        )
        return super().to_representation(rows)


class FavoriteSerializer(serializers.ModelSerializer):
    """收藏记录对外序列化（含本次权限过滤后的 target 卡片）。"""

    id = serializers.IntegerField(read_only=True)
    user_id = serializers.CharField(read_only=True)
    target_type = serializers.CharField(read_only=True)
    target_id = serializers.CharField(read_only=True)
    target = serializers.SerializerMethodField()

    class Meta:
        model = Favorite
        fields = ["id", "user_id", "target_type", "target_id", "target", "created_at"]
        read_only_fields = fields
        list_serializer_class = FavoriteListSerializer

    def get_target(self, obj) -> dict | None:
        request = self.context.get("request")
        user = getattr(request, "user", None)
        if user is None or not user.is_authenticated:
            return None
        cards = self.context.get("favorite_target_cards")
        if cards is None:
            cards = build_target_cards([obj], request)
        return cards.get(target_key(obj.target_type, obj.target_id))
