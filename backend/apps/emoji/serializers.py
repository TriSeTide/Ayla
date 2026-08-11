"""
表情包序列化（M4-3，步骤文件 5.5）。
"""
from rest_framework import serializers

from apps.media.models import MediaObject
from apps.media.serializers import MediaObjectSerializer

from .models import EmojiItem, EmojiPack


class EmojiItemSerializer(serializers.ModelSerializer):
    """表情项：引用媒体的 descriptor（用于列表展示）。"""

    id = serializers.CharField(read_only=True)
    media = serializers.SerializerMethodField()

    class Meta:
        model = EmojiItem
        fields = ["id", "media", "tag", "created_at"]

    def get_media(self, obj):
        media = obj.media
        if media is None:
            return None
        return MediaObjectSerializer(media).data


class EmojiPackSerializer(serializers.ModelSerializer):
    """表情包：含包内表情项列表。"""

    id = serializers.CharField(read_only=True)
    owner_id = serializers.CharField(read_only=True, source="owner.id", allow_null=True)
    items = EmojiItemSerializer(many=True, read_only=True)
    item_count = serializers.SerializerMethodField()

    class Meta:
        model = EmojiPack
        fields = ["id", "owner_id", "name", "is_system", "item_count", "items", "created_at"]
        read_only_fields = fields

    def get_item_count(self, obj) -> int:
        return obj.items.count()


class EmojiPackBriefSerializer(serializers.ModelSerializer):
    """表情包精简（列表用，不带 items 全量）。"""

    id = serializers.CharField(read_only=True)
    owner_id = serializers.CharField(read_only=True, source="owner.id", allow_null=True)
    item_count = serializers.SerializerMethodField()

    class Meta:
        model = EmojiPack
        fields = ["id", "owner_id", "name", "is_system", "item_count", "created_at"]

    def get_item_count(self, obj) -> int:
        return obj.items.count()


class EmojiSearchResultSerializer(serializers.Serializer):
    """表情检索结果（pack + item 列表；排序只影响可达性，不自动改变事实状态）。"""

    pack_id = serializers.CharField()
    pack_name = serializers.CharField()
    is_system = serializers.BooleanField()
    hits = EmojiItemSerializer(many=True, read_only=True)
