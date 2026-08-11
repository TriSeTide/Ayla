"""
媒体序列化（M4-3，步骤文件 5.1 descriptor）。

descriptor 只含媒体标识、派生元数据与应用内派生资源路径；
不暴露 storage_path、宿主机路径或任何签名 URL（阶段三 §10 安全）。
"""
from rest_framework import serializers

from .models import MediaObject


class MediaObjectSerializer(serializers.ModelSerializer):
    """媒体 descriptor（对外统一形态）。"""

    media_id = serializers.CharField(read_only=True)
    kind = serializers.CharField(read_only=True)
    mime_type = serializers.CharField(read_only=True)
    size = serializers.IntegerField(read_only=True)
    status = serializers.CharField(read_only=True)
    width = serializers.IntegerField(read_only=True)
    height = serializers.IntegerField(read_only=True)
    duration = serializers.FloatField(read_only=True)
    thumbnail = serializers.SerializerMethodField()
    waveform = serializers.SerializerMethodField()
    created_at = serializers.DateTimeField(read_only=True)

    class Meta:
        model = MediaObject
        fields = [
            "media_id",
            "kind",
            "mime_type",
            "size",
            "status",
            "width",
            "height",
            "duration",
            "thumbnail",
            "waveform",
            "created_at",
        ]
        read_only_fields = fields

    def _request(self):
        return self.context.get("request")

    def get_thumbnail(self, obj) -> str | None:
        if not obj.has_thumbnail:
            return None
        return f"/api/v1/media/{obj.media_id}/thumbnail"

    def get_waveform(self, obj) -> str | None:
        if not obj.has_waveform:
            return None
        return f"/api/v1/media/{obj.media_id}/waveform"
