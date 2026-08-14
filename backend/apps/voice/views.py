"""
语音频道视图 —— 频道 REST（挂 /api/v1/voice/，M4-5 §6）。

权限语义（复用 M4-2 约定，S1 扩展可见性）：
- 列表/详情/成员列表：按 `apps/common/visibility.py` 过滤与校验（非可见 → 403）；
- 加入频道走 can_join（当前与 can_view 同语义）；非成员操作/非 owner 改名称 → 403；
  不存在的频道 → 404；
- 频道默认开放加入（类似 Discord 语音频道）；私有/邀请制留待后续。
"""
import logging

from django.conf import settings
from django.contrib.auth import get_user_model
from django.db.models import Count
from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.common.visibility import can_join, can_view, visible_queryset

from . import livekit, services
from .models import VoiceChannel, VoiceChannelMember
from .serializers import VoiceChannelMemberSerializer, VoiceChannelSerializer

logger = logging.getLogger(__name__)

User = get_user_model()


def _get_channel_or_404(channel_id):
    try:
        return VoiceChannel.objects.get(pk=channel_id)
    except (VoiceChannel.DoesNotExist, ValueError, TypeError):
        return None


def _get_group_or_400(group_id):
    """解析创建参数里的群归属：必须是存在的群聊会话；非法值返回 (None, error) 或 (obj, None)。"""
    from apps.chat.models import Conversation

    if group_id in (None, "", "null"):
        return None, None
    conv = Conversation.objects.filter(pk=group_id).first()
    if conv is None:
        return None, "群不存在"
    if conv.type != Conversation.TYPE_GROUP:
        return None, "群归属必须是群聊会话"
    return conv, None


def _forbidden(msg="无权访问"):
    return Response({"detail": msg}, status=status.HTTP_403_FORBIDDEN)


def _not_found(msg="频道不存在"):
    return Response({"detail": msg}, status=status.HTTP_404_NOT_FOUND)


class ChannelListView(APIView):
    """GET /api/v1/voice/channels/ —— 频道列表（含人数）；POST —— 建频道。"""

    permission_classes = [IsAuthenticated]

    def get(self, request):
        channels = list(visible_queryset(VoiceChannel, request.user))
        # 附成员数
        counts = {
            c["channel_id"]: c["n"]
            for c in VoiceChannelMember.objects.values("channel_id").annotate(
                n=Count("id")
            )
        }
        payload = []
        for ch in channels:
            s = VoiceChannelSerializer(ch).data
            s["member_count"] = counts.get(ch.id, 0)
            s["mine"] = services.user_in_channel(ch, request.user)
            payload.append(s)
        return Response(payload)

    def post(self, request):
        name = (request.data.get("name") or "").strip()
        if not name:
            return Response(
                {"detail": "name 不能为空"}, status=status.HTTP_400_BAD_REQUEST
            )
        group, group_err = _get_group_or_400(request.data.get("group"))
        if group_err:
            return Response({"detail": group_err}, status=status.HTTP_400_BAD_REQUEST)
        visibility = request.data.get("visibility") or None
        try:
            ch = services.create_channel(
                request.user, name, group=group, visibility=visibility
            )
        except ValueError as exc:
            return Response({"detail": str(exc)}, status=status.HTTP_400_BAD_REQUEST)
        return Response(
            VoiceChannelSerializer(ch).data, status=status.HTTP_201_CREATED
        )


class ChannelDetailView(APIView):
    """GET/PATCH /api/v1/voice/channels/<id>/ —— 频道详情 / 改名称（仅 owner）。"""

    permission_classes = [IsAuthenticated]

    def get(self, request, channel_id):
        ch = _get_channel_or_404(channel_id)
        if ch is None:
            return _not_found()
        if not can_view(request.user, ch):
            return _forbidden("无权查看该语音频道")
        data = VoiceChannelSerializer(ch).data
        data["member_count"] = ch.members.count()
        data["mine"] = services.user_in_channel(ch, request.user)
        return Response(data)

    def patch(self, request, channel_id):
        ch = _get_channel_or_404(channel_id)
        if ch is None:
            return _not_found()
        if not services.can_manage_channel(ch, request.user):
            return _forbidden("仅频道创建者可改名称")
        name = (request.data.get("name") or "").strip()
        if not name:
            return Response(
                {"detail": "name 不能为空"}, status=status.HTTP_400_BAD_REQUEST
            )
        ch.name = name
        ch.save(update_fields=["name"])
        return Response(VoiceChannelSerializer(ch).data)


class ChannelJoinView(APIView):
    """POST /api/v1/voice/channels/<id>/join/ —— 加入（拿 LiveKit token）+ 落成员表 + 广播。"""

    permission_classes = [IsAuthenticated]

    def post(self, request, channel_id):
        ch = _get_channel_or_404(channel_id)
        if ch is None:
            return _not_found()
        if not can_join(request.user, ch):
            return _forbidden("无权加入该语音频道")
        member = services.join_channel(ch, request.user)
        try:
            token = livekit.issue_token(request.user, ch.room_name)
        except livekit.LiveKitNotConfigured:
            # token 不可签（未配置）显式失败，不伪造媒体凭据
            logger.warning("join without LiveKit config, channel=%s", ch.id)
            return Response(
                {"detail": "LiveKit 未配置，无法加入语音频道"},
                status=status.HTTP_503_SERVICE_UNAVAILABLE,
            )
        return Response(
            {
                "channel_id": str(ch.id),
                "room_name": ch.room_name,
                "token": token,
                "ws_url": settings.LIVEKIT_WS_URL,
                "ttl": settings.LIVEKIT_TOKEN_TTL_SECONDS,
                "joined": True,
            },
            status=status.HTTP_200_OK,
        )


class ChannelLeaveView(APIView):
    """POST /api/v1/voice/channels/<id>/leave/ —— 离开 + 广播 voice.state left。"""

    permission_classes = [IsAuthenticated]

    def post(self, request, channel_id):
        ch = _get_channel_or_404(channel_id)
        if ch is None:
            return _not_found()
        services.leave_channel(ch, request.user)
        return Response({"left": True})


class ChannelHeartbeatView(APIView):
    """POST /api/v1/voice/channels/<id>/heartbeat/ —— presence 心跳刷新 last_seen_at。"""

    permission_classes = [IsAuthenticated]

    def post(self, request, channel_id):
        ch = _get_channel_or_404(channel_id)
        if ch is None:
            return _not_found()
        try:
            services.heartbeat_channel(ch, request.user)
        except PermissionError:
            return _forbidden("非频道成员不可心跳")
        return Response({"ok": True})


class ChannelMembersView(APIView):
    """GET /api/v1/voice/channels/<id>/members/ —— 当前成员列表。"""

    permission_classes = [IsAuthenticated]

    def get(self, request, channel_id):
        ch = _get_channel_or_404(channel_id)
        if ch is None:
            return _not_found()
        if not can_view(request.user, ch):
            return _forbidden("无权查看该语音频道")
        members = VoiceChannelMember.objects.filter(channel=ch).select_related("user")
        return Response(
            VoiceChannelMemberSerializer(members, many=True).data,
            status=status.HTTP_200_OK,
        )
