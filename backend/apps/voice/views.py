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

from apps.common.visibility import Visibility, can_join, can_view, visible_queryset
from apps.media.models import MediaObject
from apps.media.services import can_access_media
from apps.media.serializers import MediaObjectSerializer

from . import livekit, services
from .models import VoiceChannel, VoiceChannelMember, VoiceChatMessage
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
    """GET /api/v1/voice/channels/ —— 频道列表（含人数；?scope=group:<id> 群内过滤）；POST —— 建频道。"""

    permission_classes = [IsAuthenticated]

    def get(self, request):
        from django.db.models import Q

        qs = visible_queryset(VoiceChannel, request.user)

        # 群内过滤：scope=group:<id> 匹配 group_id 或 allowed_groups 包含该群
        scope = request.query_params.get("scope", "").strip()
        if scope.startswith("group:"):
            raw_gid = scope.split(":", 1)[1]
            try:
                gid = int(raw_gid)
            except (TypeError, ValueError):
                return Response(
                    {"detail": "group id 无效"}, status=status.HTTP_400_BAD_REQUEST
                )
            qs = qs.filter(Q(group_id=gid) | Q(allowed_groups__id=gid)).distinct()

        channels = list(qs)
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
        allowed_group_ids = request.data.get("allowed_group_ids")
        # visibility=group 且无单群归属时，必须提供群白名单；否则房间对所有人不可见
        # （owner 自己可见，但无任何成员可进入，属误建）。
        if (
            visibility == Visibility.GROUP
            and group is None
            and not allowed_group_ids
        ):
            return Response(
                {"detail": "指定群可见必须至少选择一个群"},
                status=status.HTTP_400_BAD_REQUEST,
            )
        try:
            ch = services.create_channel(
                request.user, name, group=group, visibility=visibility,
                allowed_group_ids=allowed_group_ids,
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

    def delete(self, request, channel_id):
        ch = _get_channel_or_404(channel_id)
        if ch is None:
            return _not_found()
        if not services.can_manage_channel(ch, request.user):
            return _forbidden("仅房主可删除")
        ch.delete()
        return Response({"deleted": True})

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
        update_fields = ["name"]
        if "visibility" in request.data:
            value = request.data.get("visibility")
            if value not in {"public", "friends", "group"}:
                return Response({"detail": "visibility 无效"}, status=status.HTTP_400_BAD_REQUEST)
            if value == Visibility.GROUP:
                # 与创建一致：group 可见但无单群归属时，必须有群白名单，
                # 否则改完房间对所有人不可见（owner 自己可见，无人可进入）。
                target_ids = (
                    request.data.get("allowed_group_ids")
                    if "allowed_group_ids" in request.data
                    else list(ch.allowed_groups.values_list("id", flat=True))
                )
                if ch.group_id is None and not target_ids:
                    return Response(
                        {"detail": "指定群可见必须至少选择一个群"},
                        status=status.HTTP_400_BAD_REQUEST,
                    )
            ch.visibility = value
            update_fields.append("visibility")
        if "allowed_group_ids" in request.data:
            try:
                from apps.common.visibility import set_allowed_groups
                set_allowed_groups(ch, request.data.get("allowed_group_ids"))
            except ValueError as exc:
                return Response({"detail": str(exc)}, status=status.HTTP_400_BAD_REQUEST)
        ch.save(update_fields=update_fields)
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
        try:
            token = livekit.issue_token(request.user, ch.room_name)
        except livekit.LiveKitNotConfigured:
            # token 不可签（未配置）显式失败，不伪造媒体凭据，也不落成员活动态
            logger.warning("join without LiveKit config, channel=%s", ch.id)
            return Response(
                {"detail": "LiveKit 未配置，无法加入语音频道"},
                status=status.HTTP_503_SERVICE_UNAVAILABLE,
            )
        services.join_channel(ch, request.user)
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
        try:
            services.leave_channel(ch, request.user)
        except PermissionError as exc:
            return _forbidden(str(exc))
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


class ChannelChatMessagesView(APIView):
    """GET/POST /voice/channels/<id>/messages/ —— 语音房独立聊天。"""

    permission_classes = [IsAuthenticated]

    def _channel(self, request, channel_id):
        ch = _get_channel_or_404(channel_id)
        if ch is None:
            return None, _not_found()
        if not can_view(request.user, ch):
            return None, _forbidden("无权查看该语音频道")
        return ch, None

    @staticmethod
    def _payload(message):
        return {
            "id": str(message.id),
            "channel_id": str(message.channel_id),
            "sender": {
                "user_id": str(message.sender_id),
                "nickname": message.sender.nickname or message.sender.username,
                "avatar": message.sender.avatar or "",
            },
            "content": message.content,
            "media_id": message.media_id,
            "media": (
                MediaObjectSerializer(
                    MediaObject.objects.filter(media_id=message.media_id).first()
                ).data
                if message.media_id
                and MediaObject.objects.filter(media_id=message.media_id).exists()
                else None
            ),
            "created_at": message.created_at.isoformat(),
        }

    def get(self, request, channel_id):
        ch, error = self._channel(request, channel_id)
        if error:
            return error
        try:
            limit = max(1, min(int(request.query_params.get("limit", 100)), 200))
        except (TypeError, ValueError):
            limit = 100
        rows = list(
            VoiceChatMessage.objects.filter(channel=ch)
            .select_related("sender")
            .order_by("-created_at", "-id")[:limit]
        )
        rows.reverse()
        return Response([self._payload(row) for row in rows])

    def post(self, request, channel_id):
        ch, error = self._channel(request, channel_id)
        if error:
            return error
        if not services.user_in_channel(ch, request.user):
            return _forbidden("加入语音房后才能发消息")
        content = (request.data.get("content") or "").strip()
        media_id = (request.data.get("media_id") or "").strip() or None
        if not content and not media_id:
            return Response({"detail": "消息内容不能为空"}, status=status.HTTP_400_BAD_REQUEST)
        if len(content) > 2000:
            return Response({"detail": "消息内容不能超过 2000 字"}, status=status.HTTP_400_BAD_REQUEST)
        media = None
        if media_id:
            media = MediaObject.objects.filter(media_id=media_id).first()
            if media is None:
                return Response({"detail": "media_not_found"}, status=status.HTTP_400_BAD_REQUEST)
            if media.status != MediaObject.STATUS_READY:
                return Response({"detail": "media_not_ready"}, status=status.HTTP_400_BAD_REQUEST)
            if media.kind != MediaObject.KIND_IMAGE:
                return Response({"detail": "media_type_mismatch"}, status=status.HTTP_400_BAD_REQUEST)
            if not can_access_media(request.user, media):
                return _forbidden("media_access_denied")
        message = VoiceChatMessage.objects.create(
            channel=ch,
            sender=request.user,
            content=content or "图片",
            media_id=media_id,
        )
        return Response(self._payload(message), status=status.HTTP_201_CREATED)


class ChannelMemberActionView(APIView):
    """房主踢人/转让房主。"""

    permission_classes = [IsAuthenticated]

    def post(self, request, channel_id, user_id):
        ch = _get_channel_or_404(channel_id)
        if ch is None:
            return _not_found()
        action = request.data.get("action")
        try:
            if action == "kick":
                services.kick_member(ch, request.user, user_id)
            elif action == "transfer":
                services.transfer_channel_owner(ch, request.user, user_id)
            else:
                return Response({"detail": "action 无效"}, status=status.HTTP_400_BAD_REQUEST)
        except PermissionError as exc:
            return _forbidden(str(exc))
        except ValueError as exc:
            return Response({"detail": str(exc)}, status=status.HTTP_400_BAD_REQUEST)
        except (LookupError, VoiceChannelMember.DoesNotExist):
            return _not_found("成员不存在")
        return Response(VoiceChannelSerializer(ch).data)


class ChannelDeleteView(APIView):
    permission_classes = [IsAuthenticated]

    def delete(self, request, channel_id):
        ch = _get_channel_or_404(channel_id)
        if ch is None:
            return _not_found()
        if not services.can_manage_channel(ch, request.user):
            return _forbidden("仅房主可删除")
        ch.delete()
        return Response({"deleted": True})


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
