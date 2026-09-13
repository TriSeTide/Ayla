"""直播频道序列化（M4-6 §5.1）：descriptor 含推流/播放地址；stream_key 仅 owner 可见。"""
from rest_framework import serializers

from . import viewers
from .models import LiveChannel
from .services import build_flv_url, build_hls_url, build_rtmp_url


class LiveChannelSerializer(serializers.ModelSerializer):
    """频道 descriptor。

    - `stream_key` / `rtmp_url`：**仅 owner 可见**（他人为 null）——推流握手指纹最小权限，
      创建响应（创建者即 owner）回显一次，绝不外泄给观众；
    - `hls_url` / `flv_url`：全员可见（播放地址）；
    - `status`：应用侧乐观标记（:start/:stop 更新）；真实在播以 `/status` 实时判定为准；
    - `viewer_count`：当前在看人数（弹幕 WS 连接数，运行事实）；presence 存储不可用时
      为 `null`——**不能把读不到伪装成 0 人在看**，前端据此隐藏人数。
    """

    owner_id = serializers.CharField(source="owner.id", read_only=True)
    is_owner = serializers.SerializerMethodField()
    # 列表/详情直接带主播昵称（大厅卡片显示；避免前端经 users/search 懒拉未命中 → "未知主播"）
    owner_nickname = serializers.SerializerMethodField()
    stream_key = serializers.SerializerMethodField()
    rtmp_url = serializers.SerializerMethodField()
    hls_url = serializers.SerializerMethodField()
    flv_url = serializers.SerializerMethodField()
    viewer_count = serializers.SerializerMethodField()
    # S1：可见性 + 群归属（group=群 id 字符串；group_name=群标题，无群为 null）
    visibility = serializers.CharField(read_only=True)
    group = serializers.CharField(source="group_id", read_only=True, default=None)
    group_name = serializers.CharField(source="group.title", read_only=True, default=None)
    allowed_group_ids = serializers.SerializerMethodField()
    allowed_group_names = serializers.SerializerMethodField()

    def get_allowed_group_ids(self, obj):
        return [str(group_id) for group_id in obj.allowed_groups.values_list("id", flat=True)]

    def get_allowed_group_names(self, obj):
        """返回所有可见群的名称列表，用于显示多个群标签"""
        return list(obj.allowed_groups.values_list("title", flat=True))

    class Meta:
        model = LiveChannel
        fields = [
            "id",
            "title",
            "description",
            "cover",
            "status",
            "visibility",
            "group",
            "group_name",
            "allowed_group_ids",
            "allowed_group_names",
            "owner_id",
            "owner_nickname",
            "is_owner",
            "stream_key",
            "rtmp_url",
            "hls_url",
            "flv_url",
            "viewer_count",
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

    def get_owner_nickname(self, obj: LiveChannel) -> str:
        """主播展示名（nickname 为空时回退 username），供大厅卡片直接展示。"""
        return obj.owner.nickname or obj.owner.username

    def get_viewer_count(self, obj: LiveChannel) -> int | None:
        """在读人数；列表视图会预取整页人数（`context["viewer_counts"]`）避免逐行往返。

        预取缺失（单条详情 / 序列化器外部复用）时按需读一次；两种情况都可能返回 None
        （presence 存储不可用），调用方必须区分「0 人在看」与「读不到」。
        """
        counts = self.context.get("viewer_counts")
        if counts is not None:
            return counts.get(obj.id)
        return viewers.viewer_count(obj.id)

    def get_stream_key(self, obj: LiveChannel) -> str | None:
        # 仅 owner 可见；无 request 上下文（如系统侧序列化）一律 null（安全默认）
        return obj.stream_key if self.get_is_owner(obj) else None

    def get_rtmp_url(self, obj: LiveChannel) -> str | None:
        return build_rtmp_url(obj) if self.get_is_owner(obj) else None

    def get_hls_url(self, obj: LiveChannel) -> str:
        return build_hls_url(obj)

    def get_flv_url(self, obj: LiveChannel) -> str:
        return build_flv_url(obj)
