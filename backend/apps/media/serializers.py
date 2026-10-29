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
    # 过期状态投影（2026-10-29）：客户端据此**在不发请求的情况下**判断
    # 「该媒体是否已过期 / 原对象是否已删」，从而：
    #  · 已完全过期 → 直接渲染占位，不白跑一次 :sign（省往返，也避免误显示"加载失败"）；
    #  · 阶段 1（原图/视频本体已删）→ 直接按缩略图/海报渲染 + 「原图已过期」角标。
    # 只读布尔投影，不暴露 storage_path 与时间戳细节。
    original_expired = serializers.SerializerMethodField()
    expired = serializers.SerializerMethodField()

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
            "original_expired",
            "expired",
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

    def get_original_expired(self, obj) -> bool:
        """原对象是否已删（图片阶段 1 / 视频阶段 1）。"""
        return obj.original_expired_at is not None

    def get_expired(self, obj) -> bool:
        """是否已完全过期（所有对象已删）。"""
        return obj.expired_at is not None
