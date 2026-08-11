"""语音频道序列化（M4-5 §6）：频道 + 成员 descriptor。"""
from rest_framework import serializers

from .models import VoiceChannel, VoiceChannelMember


class VoiceChannelSerializer(serializers.ModelSerializer):
    """频道 descriptor：含人数、创建者 id；不暴露 storage 等内部字段。"""

    member_count = serializers.IntegerField(read_only=True, default=0)
    owner_id = serializers.CharField(source="owner.id", read_only=True)

    class Meta:
        model = VoiceChannel
        fields = ["id", "name", "room_name", "owner_id", "member_count", "created_at"]
        read_only_fields = ["id", "room_name", "owner_id", "member_count", "created_at"]


class VoiceChannelMemberSerializer(serializers.ModelSerializer):
    """成员 descriptor（含 user_id、最近活跃时间）。"""

    user_id = serializers.CharField(source="user.id", read_only=True)

    class Meta:
        model = VoiceChannelMember
        fields = ["id", "user_id", "joined_at", "last_seen_at"]
        read_only_fields = fields
