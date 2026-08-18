"""
直播 REST 视图（挂 /api/v1/live/，M4-6 §5）。

权限语义（复用 M4-2/M4-5 约定，S1 扩展可见性）：
- 越权（非 owner :start/:stop/删除）→ 403；不存在的频道 → 404；
- 列表/详情/弹幕/状态：按 `apps/common/visibility.py` 过滤与校验
  （public 全登录用户 / friends 好友 / group 群员，非可见 → 403）；
- 弹幕发送 = 进入互动，走 can_join（当前与 can_view 同语义）；
- 观众可看直播与弹幕，但拿不到推流指纹（stream_key 仅 owner）；
- 直播中（乐观标记 live）禁止删除，先 :stop（400）。

状态真实性（AGENTS.md §8）：`:start`/`:stop` 只更新乐观标记；
`GET /channels/{id}/status/` 以 SRS HTTP API 实时判定为准，SRS 不可用返回 degraded，
禁止把查询失败伪装成"未在播"。
"""
import logging

from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.common.visibility import can_join, can_view, visible_queryset
from apps.media.models import MediaObject
from apps.media.services import can_access_media, parse_avatar_media_id

from . import services
from .models import Danmaku, LiveChannel
from .serializers import LiveChannelSerializer
from .services import DANMAKU_HISTORY_MAX

logger = logging.getLogger(__name__)


def _get_channel_or_404(channel_id):
    try:
        return LiveChannel.objects.get(pk=channel_id)
    except (LiveChannel.DoesNotExist, ValueError, TypeError):
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


def _not_found(msg="直播间不存在"):
    return Response({"detail": msg}, status=status.HTTP_404_NOT_FOUND)


def _bad_request(msg):
    return Response({"detail": msg}, status=status.HTTP_400_BAD_REQUEST)


def _validate_cover(user, value: str) -> str | None:
    """封面只允许引用当前用户可访问的已完成图片媒体。"""
    value = (value or "").strip()
    if not value:
        return None
    media_id = parse_avatar_media_id(value)
    if media_id is None:
        return "cover 必须是有效的媒体地址"
    media = MediaObject.objects.filter(media_id=media_id, status=MediaObject.STATUS_READY).first()
    if media is None:
        return "封面媒体不存在或尚未准备好"
    if media.kind != MediaObject.KIND_IMAGE:
        return "封面必须是图片"
    if not can_access_media(user, media):
        return "无权使用该媒体作为封面"
    return None


def _channel_serializer(ch, request):
    return LiveChannelSerializer(ch, context={"request": request}).data


class ChannelListView(APIView):
    """GET/POST /api/v1/live/channels/ —— 频道列表（含乐观 status；?only_live=1 过滤）/ 创建。"""

    permission_classes = [IsAuthenticated]

    def get(self, request):
        qs = visible_queryset(LiveChannel, request.user)
        if request.query_params.get("only_live") == "1":
            qs = qs.filter(status="live")
        payload = [_channel_serializer(ch, request) for ch in qs]
        return Response(payload)

    def post(self, request):
        title = (request.data.get("title") or "").strip()
        if not title:
            return _bad_request("title 不能为空")
        group, group_err = _get_group_or_400(request.data.get("group"))
        if group_err:
            return _bad_request(group_err)
        visibility = request.data.get("visibility") or None
        description = request.data.get("description") or ""
        cover = request.data.get("cover") or ""
        cover_error = _validate_cover(request.user, cover)
        if cover_error:
            return _bad_request(cover_error)
        try:
            ch = services.create_channel(
                request.user,
                title,
                group=group,
                visibility=visibility,
                description=description,
                cover=cover,
            )
        except ValueError as exc:
            return _bad_request(str(exc))
        # 创建响应即回显 stream_key/推流地址（创建者即 owner，供复制进 OBS）
        return Response(
            _channel_serializer(ch, request), status=status.HTTP_201_CREATED
        )


class ChannelDetailView(APIView):
    """GET/PATCH/DELETE 频道详情；PATCH 仅 owner 可修改资料。"""

    permission_classes = [IsAuthenticated]

    def get(self, request, channel_id):
        ch = _get_channel_or_404(channel_id)
        if ch is None:
            return _not_found()
        if not can_view(request.user, ch):
            return _forbidden("无权查看该直播间")
        return Response(_channel_serializer(ch, request))

    def patch(self, request, channel_id):
        ch = _get_channel_or_404(channel_id)
        if ch is None:
            return _not_found()
        if not services.can_manage_channel(ch, request.user):
            return _forbidden("仅频道 owner 可修改资料")

        update_fields = []
        if "title" in request.data:
            title = (request.data.get("title") or "").strip()
            if not title:
                return _bad_request("title 不能为空")
            if len(title) > 128:
                return _bad_request("title 不能超过 128 字")
            ch.title = title
            update_fields.append("title")
        if "description" in request.data:
            description = (request.data.get("description") or "").strip()
            if len(description) > 2000:
                return _bad_request("description 不能超过 2000 字")
            ch.description = description
            update_fields.append("description")
        if "cover" in request.data:
            cover = request.data.get("cover") or ""
            cover_error = _validate_cover(request.user, cover)
            if cover_error:
                return _bad_request(cover_error)
            ch.cover = cover.strip()
            update_fields.append("cover")
        if update_fields:
            ch.save(update_fields=update_fields)
        return Response(_channel_serializer(ch, request))

    def delete(self, request, channel_id):
        ch = _get_channel_or_404(channel_id)
        if ch is None:
            return _not_found()
        if not services.can_manage_channel(ch, request.user):
            return _forbidden("仅频道 owner 可删除")
        if ch.status == "live":
            return _bad_request("直播中禁止删除，请先 :stop")
        ch.delete()
        return Response({"deleted": True}, status=status.HTTP_200_OK)


class ChannelStartView(APIView):
    """POST /api/v1/live/channels/<id>:start/ —— 开播（乐观标记，不校验 SRS 真实流）。"""

    permission_classes = [IsAuthenticated]

    def post(self, request, channel_id):
        ch = _get_channel_or_404(channel_id)
        if ch is None:
            return _not_found()
        if not services.can_manage_channel(ch, request.user):
            return _forbidden("仅频道 owner 可开播")
        try:
            services.start_channel(ch)
        except ValueError as exc:
            return _bad_request(str(exc))
        return Response(_channel_serializer(ch, request))


class ChannelStopView(APIView):
    """POST /api/v1/live/channels/<id>:stop/ —— 下播（乐观标记）。"""

    permission_classes = [IsAuthenticated]

    def post(self, request, channel_id):
        ch = _get_channel_or_404(channel_id)
        if ch is None:
            return _not_found()
        if not services.can_manage_channel(ch, request.user):
            return _forbidden("仅频道 owner 可下播")
        services.stop_channel(ch)
        return Response(_channel_serializer(ch, request))


class ChannelStatusView(APIView):
    """GET /api/v1/live/channels/<id>/status/ —— SRS 实时判定（在播/未在播/degraded）。"""

    permission_classes = [IsAuthenticated]

    def get(self, request, channel_id):
        ch = _get_channel_or_404(channel_id)
        if ch is None:
            return _not_found()
        if not can_view(request.user, ch):
            return _forbidden("无权查看该直播间")
        # 实时判定在 services 内完成；SRS 查询失败 → degraded（不伪装"未在播"）
        return Response(services.resolve_live_status(ch))


class DanmakuListView(APIView):
    """GET/POST /api/v1/live/channels/<id>/danmaku/ —— 弹幕历史 / 发弹幕（落库+广播）。"""

    permission_classes = [IsAuthenticated]

    def get(self, request, channel_id):
        ch = _get_channel_or_404(channel_id)
        if ch is None:
            return _not_found()
        if not can_view(request.user, ch):
            return _forbidden("无权查看该直播间")
        raw_limit = request.query_params.get("limit")
        try:
            limit = int(raw_limit) if raw_limit else None
        except (TypeError, ValueError):
            limit = None
        rows = services.danmaku_history(ch, limit)
        return Response(
            [
                {
                    "id": str(dm.id),
                    "sender": services._sender_descriptor(dm.sender),
                    "content": dm.content,
                    "media_id": dm.media_id,
                    "media": services._media_descriptor(dm.media_id),
                    "created_at": dm.created_at.isoformat(),
                }
                for dm in rows
            ]
        )

    def post(self, request, channel_id):
        ch = _get_channel_or_404(channel_id)
        if ch is None:
            return _not_found()
        if not can_join(request.user, ch):
            return _forbidden("无权进入该直播间")
        content = request.data.get("content")
        media_id = request.data.get("media_id")
        try:
            dm = services.create_danmaku(ch, request.user, content, media_id)
        except PermissionError as exc:
            return _forbidden(str(exc))
        except ValueError as exc:
            return _bad_request(str(exc))
        # 落库与广播分离：落库已完成，广播走 channels group（同步包装版）
        services.broadcast_danmaku(dm)
        return Response(
            {
                "id": str(dm.id),
                "channel_id": str(dm.channel_id),
                "sender": services._sender_descriptor(dm.sender),
                "content": dm.content,
                "media_id": dm.media_id,
                "media": services._media_descriptor(dm.media_id),
                "created_at": dm.created_at.isoformat(),
            },
            status=status.HTTP_201_CREATED,
        )
