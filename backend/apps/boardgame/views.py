"""
桌游 REST 视图（挂 /api/v1/boardgame/，S4 开发文档 §1.4）。

- GET/POST /rooms/：房间列表（可见性过滤，可选 ?mine=1 我在局）/ 创建；
- GET/DELETE /rooms/<id>/：详情 / 删除（DELETE 仅 owner）；
- POST /rooms/<id>:join/：加入（幂等）；
- POST /rooms/<id>:leave/：离开（仅成员）。

玩法引擎、WS 对局通道非本期目标（进入房间后前端为占位界面）。
"""
from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.common.visibility import can_join, can_view, visible_queryset

from . import services
from .models import GameRoom
from .serializers import GameRoomMemberSerializer, GameRoomSerializer


def _get_room_or_404(room_id):
    try:
        return (
            GameRoom.objects.select_related("owner", "group")
            .prefetch_related("members__user")
            .get(pk=room_id)
        )
    except (GameRoom.DoesNotExist, ValueError, TypeError):
        return None


def _forbidden(msg="无权访问"):
    return Response({"detail": msg}, status=status.HTTP_403_FORBIDDEN)


def _not_found(msg="不存在"):
    return Response({"detail": msg}, status=status.HTTP_404_NOT_FOUND)


def _bad_request(msg):
    return Response({"detail": msg}, status=status.HTTP_400_BAD_REQUEST)


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


class RoomListView(APIView):
    """GET /rooms/（可见性过滤 + 可选 ?mine=1；?scope=group:<id> 群内过滤）/ POST /rooms/（创建）。"""

    permission_classes = [IsAuthenticated]

    def get(self, request):
        from django.db.models import Q

        qs = (
            visible_queryset(GameRoom, request.user)
            .select_related("owner", "group")
            .prefetch_related("members__user")
        )

        # 群内过滤：scope=group:<id> 匹配 group_id 或 allowed_groups 包含该群
        scope = request.query_params.get("scope", "").strip()
        if scope.startswith("group:"):
            raw_gid = scope.split(":", 1)[1]
            try:
                gid = int(raw_gid)
            except (TypeError, ValueError):
                return _bad_request("group id 无效")
            qs = qs.filter(Q(group_id=gid) | Q(allowed_groups__id=gid)).distinct()

        # F10「正在玩的桌游」数据源：我在局的房间（成员视角，叠加可见性过滤）
        if request.query_params.get("mine") == "1":
            qs = qs.filter(members__user=request.user).distinct()
        data = GameRoomSerializer(qs, many=True, context={"request": request}).data
        return Response(data)

    def post(self, request):
        name = (request.data.get("name") or "").strip()
        if not name:
            return _bad_request("name 不能为空")
        group, group_err = _get_group_or_400(request.data.get("group"))
        if group_err:
            return _bad_request(group_err)
        try:
            room = services.create_room(
                request.user,
                name,
                group=group,
                visibility=request.data.get("visibility"),
                game_type=request.data.get("game_type"),
                allowed_group_ids=request.data.get("allowed_group_ids"),
            )
        except ValueError as exc:
            return _bad_request(str(exc))
        
        # 推送桌游房创建事件
        if room.group:
            services.broadcast_room_created_to_group(room, room.group)
        
        # 处理 allowed_groups：推送给所有白名单群
        if room.allowed_groups.exists():
            for allowed_group in room.allowed_groups.all():
                services.broadcast_room_created_to_group(room, allowed_group)
        
        # 推送给创建者本人
        services.broadcast_room_created_to_user(room, request.user)
        
        return Response(
            GameRoomSerializer(room, context={"request": request}).data,
            status=status.HTTP_201_CREATED,
        )


class RoomDetailView(APIView):
    """GET/DELETE /rooms/<id>/ —— 详情 / 删除（DELETE 仅 owner）。"""

    permission_classes = [IsAuthenticated]

    def get(self, request, room_id):
        room = _get_room_or_404(room_id)
        if room is None:
            return _not_found("房间不存在")
        if not can_view(request.user, room):
            return _forbidden("无权查看该房间")
        return Response(GameRoomSerializer(room, context={"request": request}).data)

    def delete(self, request, room_id):
        room = _get_room_or_404(room_id)
        if room is None:
            return _not_found("房间不存在")
        if room.owner_id != request.user.id:
            return _forbidden("仅房主可删除")
        
        # 删除前保存必要信息用于推送
        saved_room_id = room.id
        group_id = room.group_id
        owner_id = room.owner_id
        
        # 收集 allowed_groups 的 id 列表
        allowed_group_ids = list(room.allowed_groups.values_list("id", flat=True))
        
        # 删除房间
        room.delete()
        
        # 推送删除事件给群成员
        if group_id:
            services.broadcast_room_deleted(saved_room_id, group_id, owner_id)
        else:
            # 无归属群时仍推送给房主
            services.broadcast_room_deleted(saved_room_id, None, owner_id)
        
        # 推送给所有白名单群
        for gid in allowed_group_ids:
            services.broadcast_room_deleted(saved_room_id, gid, None)
        
        return Response({"deleted": True})


class RoomJoinView(APIView):
    """POST /rooms/<id>:join/ —— 加入房间（幂等：已是成员返回 200 + 原成员）。"""

    permission_classes = [IsAuthenticated]

    def post(self, request, room_id):
        room = _get_room_or_404(room_id)
        if room is None:
            return _not_found("房间不存在")
        if not can_join(request.user, room):
            return _forbidden("无权加入该房间")
        member, created = services.join_room(room, request.user)
        return Response(
            GameRoomMemberSerializer(member, context={"request": request}).data,
            status=status.HTTP_201_CREATED if created else status.HTTP_200_OK,
        )


class RoomMemberActionView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, room_id, user_id):
        room = _get_room_or_404(room_id)
        if room is None:
            return _not_found("房间不存在")
        try:
            if request.data.get("action") == "kick":
                services.kick_member(room, request.user, user_id)
            elif request.data.get("action") == "transfer":
                services.transfer_room_owner(room, request.user, user_id)
            else:
                return _bad_request("action 无效")
        except PermissionError as exc:
            return _forbidden(str(exc))
        except ValueError as exc:
            return _bad_request(str(exc))
        except LookupError as exc:
            return _not_found(str(exc))
        # action 变更了 owner（转让）或成员集合（踢人）。序列化依赖 select_related
        # "owner" 与 prefetch_related "members" 的缓存：转让只改 owner_id 不更新 owner
        # 缓存、踢人删除成员后 prefetch 缓存仍是旧集合，直接复用 room 会返回旧房主 /
        # 已被踢成员。这里重新拉取一次权威实例，确保响应反映变更后的真实状态。
        room = _get_room_or_404(room_id)
        return Response(GameRoomSerializer(room, context={"request": request}).data)


class RoomLeaveView(APIView):
    """POST /rooms/<id>:leave/ —— 离开房间（仅成员；非成员 400）。"""

    permission_classes = [IsAuthenticated]

    def post(self, request, room_id):
        room = _get_room_or_404(room_id)
        if room is None:
            return _not_found("房间不存在")
        try:
            left = services.leave_room(room, request.user)
        except ValueError as exc:
            return _bad_request(str(exc))
        if not left:
            return _bad_request("不在该房间中")
        return Response({"left": True})
