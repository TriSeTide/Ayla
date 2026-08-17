"""
收藏序列化（S6）。

FavoriteSerializer 输出 id/user_id/target_type/target_id/created_at，
并附带可选 `target` 摘要 dict（前端直接展示收藏卡片）：
- 目标仍存在且当前用户可访问 → 返回摘要；
- 目标已被删除 → `target` 为 null，收藏记录本身仍返回（不报错）。
"""
from rest_framework import serializers

from .models import Favorite


def _target_summary(target_type: str, target) -> dict | None:
    """按 target_type 生成目标摘要 dict；目标不存在返回 None。"""
    if target is None:
        return None
    if target_type == Favorite.TARGET_POST:
        return {
            "id": str(target.id),
            "title": target.title or (target.body or "")[:30],
            "body": (target.body or "")[:120],
        }
    if target_type == Favorite.TARGET_MESSAGE:
        return {
            "id": str(target.id),
            "conversation_id": str(target.conversation_id),
            "type": target.type,
            "content": (target.content or "")[:120],
            "created_at": target.created_at.isoformat(),
        }
    if target_type == Favorite.TARGET_LIVE:
        return {"id": str(target.id), "title": target.title}
    if target_type == Favorite.TARGET_VOICE:
        return {"id": str(target.id), "name": target.name}
    if target_type == Favorite.TARGET_GAME:
        return {"id": str(target.id), "name": target.name}
    if target_type == Favorite.TARGET_GROUP:
        return {"id": str(target.id), "title": target.title}
    return None


class FavoriteSerializer(serializers.ModelSerializer):
    """收藏记录对外序列化（含 target 摘要）。"""

    id = serializers.IntegerField(read_only=True)
    user_id = serializers.CharField(read_only=True)
    target_type = serializers.CharField(read_only=True)
    target_id = serializers.CharField(read_only=True)
    target = serializers.SerializerMethodField()

    class Meta:
        model = Favorite
        fields = ["id", "user_id", "target_type", "target_id", "target", "created_at"]
        read_only_fields = fields

    def get_target(self, obj) -> dict | None:
        request = self.context.get("request")
        user = getattr(request, "user", None)
        if user is None or not user.is_authenticated:
            return None
        from .services import load_target

        target = load_target(obj.target_type, obj.target_id)
        if obj.target_type == Favorite.TARGET_MESSAGE and target is not None:
            from apps.chat.models import ConversationMember

            if not ConversationMember.objects.filter(
                conversation_id=target.conversation_id, user=user
            ).exists():
                return None
        return _target_summary(obj.target_type, target)
