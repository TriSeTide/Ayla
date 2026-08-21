"""语音频道序列化（M4-5 §6）：频道 + 成员 descriptor。"""
from rest_framework import serializers

from .models import VoiceChannel, VoiceChannelMember


class VoiceChannelSerializer(serializers.ModelSerializer):
    """频道 descriptor：含人数、创建者 id；不暴露 storage 等内部字段。"""

    member_count = serializers.IntegerField(read_only=True, default=0)
    owner_id = serializers.CharField(source="owner.id", read_only=True)
    # 创建者显示名（nickname 为空回退 username；null=未知）——群"新内容"事件描述用
    owner_nickname = serializers.SerializerMethodField()
    # S1：可见性 + 群归属（group=群 id 字符串；group_name=群标题，无群为 null）
    visibility = serializers.CharField(read_only=True)
    group = serializers.CharField(source="group_id", read_only=True, default=None)
    group_name = serializers.CharField(source="group.title", read_only=True, default=None)
    allowed_group_ids = serializers.SerializerMethodField()
    allowed_group_names = serializers.SerializerMethodField()

    def get_owner_nickname(self, obj):
        owner = getattr(obj, "owner", None)
        if owner is None:
            return None
        return getattr(owner, "nickname", "") or owner.username or ""

    def get_allowed_group_ids(self, obj):
        return [str(group_id) for group_id in obj.allowed_groups.values_list("id", flat=True)]

    def get_allowed_group_names(self, obj):
        """返回所有可见群的名称列表，用于显示多个群标签"""
        return list(obj.allowed_groups.values_list("title", flat=True))

    class Meta:
        model = VoiceChannel
        fields = [
            "id",
            "name",
            "room_name",
            "visibility",
            "group",
            "group_name",
            "allowed_group_ids",
            "allowed_group_names",
            "owner_id",
            "owner_nickname",
            "member_count",
            "created_at",
        ]
        read_only_fields = [
            "id",
            "room_name",
            "visibility",
            "group",
            "group_name",
            "allowed_group_ids",
            "owner_id",
            "owner_nickname",
            "member_count",
            "created_at",
        ]


class VoiceChannelMemberSerializer(serializers.ModelSerializer):
    """成员 descriptor（含 user_id、最近活跃时间）。"""

    user_id = serializers.CharField(source="user.id", read_only=True)

    class Meta:
        model = VoiceChannelMember
        fields = ["id", "user_id", "joined_at", "last_seen_at"]
        read_only_fields = fields
