"""直播频道序列化（M4-6 §5.1）：descriptor 含推流/播放地址；stream_key 仅 owner 可见。"""
from rest_framework import serializers

from .models import LiveChannel
from .services import build_flv_url, build_hls_url, build_rtmp_url


class LiveChannelSerializer(serializers.ModelSerializer):
    """频道 descriptor。

    - `stream_key` / `rtmp_url`：**仅 owner 可见**（他人为 null）——推流握手指纹最小权限，
      创建响应（创建者即 owner）回显一次，绝不外泄给观众；
    - `hls_url` / `flv_url`：全员可见（播放地址）；
    - `status`：应用侧乐观标记（:start/:stop 更新）；真实在播以 `/status` 实时判定为准。
    """

    owner_id = serializers.CharField(source="owner.id", read_only=True)
    is_owner = serializers.SerializerMethodField()
    stream_key = serializers.SerializerMethodField()
    rtmp_url = serializers.SerializerMethodField()
    hls_url = serializers.SerializerMethodField()
    flv_url = serializers.SerializerMethodField()

    class Meta:
        model = LiveChannel
        fields = [
            "id",
            "title",
            "status",
            "owner_id",
            "is_owner",
            "stream_key",
            "rtmp_url",
            "hls_url",
            "flv_url",
            "started_at",
            "ended_at",
            "created_at",
        ]
        read_only_fields = fields

    def _requester(self):
        return self.context.get("request").user if self.context.get("request") else None

    def get_is_owner(self, obj: LiveChannel) -> bool:
        user = self._requester()
        return bool(user and user.is_authenticated and user.id == obj.owner_id)

    def get_stream_key(self, obj: LiveChannel) -> str | None:
        # 仅 owner 可见；无 request 上下文（如系统侧序列化）一律 null（安全默认）
        return obj.stream_key if self.get_is_owner(obj) else None

    def get_rtmp_url(self, obj: LiveChannel) -> str | None:
        return build_rtmp_url(obj) if self.get_is_owner(obj) else None

    def get_hls_url(self, obj: LiveChannel) -> str:
        return build_hls_url(obj)

    def get_flv_url(self, obj: LiveChannel) -> str:
        return build_flv_url(obj)
