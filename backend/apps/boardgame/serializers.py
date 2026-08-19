"""
桌游序列化（S4，开发文档 §1.4）。

- GameRoomSerializer：房间对外序列化（owner/owner_id + members[] + member_count + is_member + is_owner）；
- GameRoomMemberSerializer：成员（user 用 UserPublicSerializer + seat）。

创建入参用视图内手工校验（name/group/visibility，复用 live/voice/posts 模式），
不引入独立输入 serializer，保持最小。
"""
from rest_framework import serializers

from apps.accounts.serializers import UserPublicSerializer

from .models import GameRoom, GameRoomMember


class GameRoomMemberSerializer(serializers.ModelSerializer):
    """房间成员：user 完整公开信息 + seat。"""

    id = serializers.IntegerField(read_only=True)
    user = serializers.SerializerMethodField()
    user_id = serializers.CharField(read_only=True)
    seat = serializers.IntegerField(read_only=True)

    class Meta:
        model = GameRoomMember
        fields = ["id", "user", "user_id", "seat", "joined_at"]
        read_only_fields = fields

    def get_user(self, obj):
        return UserPublicSerializer(obj.user, context=self.context).data


class GameRoomSerializer(serializers.ModelSerializer):
    """房间对外序列化：owner/owner_id + 成员列表 + 成员数 + 我是否在局。"""

    id = serializers.IntegerField(read_only=True)
    owner = serializers.SerializerMethodField()
    owner_id = serializers.CharField(read_only=True)
    visibility = serializers.CharField(read_only=True)
    group = serializers.CharField(source="group_id", read_only=True, default=None)
    group_name = serializers.CharField(source="group.title", read_only=True, default=None)
    members = GameRoomMemberSerializer(many=True, read_only=True)
    member_count = serializers.SerializerMethodField()
    is_owner = serializers.SerializerMethodField()
    is_member = serializers.SerializerMethodField()
    allowed_group_ids = serializers.SerializerMethodField()
    allowed_group_names = serializers.SerializerMethodField()

    def get_allowed_group_ids(self, obj):
        return [str(group_id) for group_id in obj.allowed_groups.values_list("id", flat=True)]

    def get_allowed_group_names(self, obj):
        """返回所有可见群的名称列表，用于显示多个群标签"""
        return list(obj.allowed_groups.values_list("title", flat=True))

    class Meta:
        model = GameRoom
        fields = [
            "id",
            "name",
            "owner",
            "owner_id",
            "visibility",
            "group",
            "group_name",
            "allowed_group_ids",
            "allowed_group_names",
            "game_type",
            "status",
            "members",
            "member_count",
            "is_owner",
            "is_member",
            "created_at",
        ]
        read_only_fields = fields

    def _requester(self):
        return self.context.get("request").user if self.context.get("request") else None

    def _members(self, obj):
        if (
            hasattr(obj, "_prefetched_objects_cache")
            and "members" in obj._prefetched_objects_cache
        ):
            return obj._prefetched_objects_cache["members"]
        return obj.members.all()

    def get_owner(self, obj):
        return UserPublicSerializer(obj.owner, context=self.context).data

    def get_member_count(self, obj) -> int:
        return len(self._members(obj))

    def get_is_owner(self, obj) -> bool:
        user = self._requester()
        return bool(user and user.is_authenticated and user.id == obj.owner_id)

    def get_is_member(self, obj) -> bool:
        user = self._requester()
        if not user or not user.is_authenticated:
            return False
        return any(m.user_id == user.id for m in self._members(obj))
