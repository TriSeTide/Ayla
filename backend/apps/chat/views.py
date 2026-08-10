"""
chat 视图 —— 私聊/群聊/消息/已读/撤回/群管理 REST。

路径挂 /api/v1/chat/（见 urls.py）。权限语义：
- 越权（非成员）→ 403；不存在的会话/消息 → 404；
- 禁言成员发消息 → 403；
- 群管理（加/踢/禁言/改公告/改角色）仅群主/管理员。
"""
from django.contrib.auth import get_user_model
from django.db.models import Q
from django.utils import timezone
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from . import services
from .models import Conversation, ConversationMember, Message, MessageRead
from .serializers import (
    ConversationListSerializer,
    ConversationSerializer,
    CreateMessageSerializer,
    MessageSerializer,
)

User = get_user_model()


def _get_conv_or_404(conv_id):
    try:
        return Conversation.objects.get(pk=conv_id)
    except (Conversation.DoesNotExist, ValueError):
        return None


def _get_msg_or_404(conv, mid):
    try:
        return Message.objects.get(pk=mid, conversation=conv)
    except (Message.DoesNotExist, ValueError):
        return None


def _forbidden(msg="无权访问"):
    return Response({"detail": msg}, status=status.HTTP_403_FORBIDDEN)


def _not_found(msg="不存在"):
    return Response({"detail": msg}, status=status.HTTP_404_NOT_FOUND)


# ---------- 会话 ----------

class ConversationListView(APIView):
    """GET /conversations/ —— 当前用户会话列表（含未读数、对方信息/群标题）。"""

    def get(self, request):
        qs = (
            Conversation.objects.filter(members__user=request.user)
            .distinct()
            .prefetch_related("members__user")
        )
        data = ConversationListSerializer(
            qs, many=True, context={"request": request}
        ).data
        return Response(data)


class PrivateConversationView(APIView):
    """POST /conversations/private/ —— 开启/获取私聊会话 body {user_id}。"""

    def post(self, request):
        user_id = request.data.get("user_id")
        if not user_id:
            return Response(
                {"detail": "缺少 user_id"}, status=status.HTTP_400_BAD_REQUEST
            )
        try:
            peer = User.objects.get(pk=user_id)
        except User.DoesNotExist:
            return _not_found("目标用户不存在")
        if peer.id == request.user.id:
            return Response(
                {"detail": "不能与自己私聊"}, status=status.HTTP_400_BAD_REQUEST
            )
        conv = services.get_or_create_conversation(request.user, peer)
        data = ConversationSerializer(conv, context={"request": request}).data
        return Response(data)


class GroupCreateView(APIView):
    """POST /conversations/ —— 建群 {title, member_ids[]}（owner=当前用户）。"""

    def post(self, request):
        title = (request.data.get("title") or "").strip()
        if not title:
            return Response(
                {"detail": "群名必填"}, status=status.HTTP_400_BAD_REQUEST
            )
        member_ids = request.data.get("member_ids") or []
        if not isinstance(member_ids, list):
            return Response(
                {"detail": "member_ids 必须是数组"}, status=status.HTTP_400_BAD_REQUEST
            )
        # 去重且排除自己
        member_ids = [str(m) for m in member_ids if str(m) != str(request.user.id)]
        if len(member_ids) > 200:
            return Response(
                {"detail": "成员数超限"}, status=status.HTTP_400_BAD_REQUEST
            )
        users = list(User.objects.filter(pk__in=member_ids))
        conv = Conversation.objects.create(
            type=Conversation.TYPE_GROUP,
            title=title,
            owner=request.user,
            announcement=request.data.get("announcement", ""),
        )
        ConversationMember.objects.create(
            conversation=conv, user=request.user, role=ConversationMember.ROLE_OWNER
        )
        for u in users:
            ConversationMember.objects.create(conversation=conv, user=u)
        data = ConversationSerializer(conv, context={"request": request}).data
        return Response(data, status=status.HTTP_201_CREATED)


class ConversationDetailView(APIView):
    """GET /conversations/<id>/ —— 会话详情（成员列表 + 我的角色）。
    PATCH —— 改群标题/公告（群管理员）。"""

    def get(self, request, conv_id):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        if not services.user_can_access(request.user, conv):
            return _forbidden()
        return Response(ConversationSerializer(conv, context={"request": request}).data)

    def patch(self, request, conv_id):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        if not services.user_can_access(request.user, conv):
            return _forbidden()
        if not services.can_manage_group(request.user, conv):
            return _forbidden("仅群主/管理员可修改")
        title = request.data.get("title")
        announcement = request.data.get("announcement")
        if title is not None:
            conv.title = str(title).strip()
        if announcement is not None:
            conv.announcement = str(announcement)
        conv.save(update_fields=["title", "announcement"])
        return Response(ConversationSerializer(conv, context={"request": request}).data)


# ---------- 消息 ----------

class MessageView(APIView):
    """GET /conversations/<id>/messages/?before_seq=&limit= —— 历史分页（按 seq 倒序）。
    POST /conversations/<id>/messages/ —— 发消息。

    幂等语义：同 idempotency_key + 同 conversation 重复 POST 返回 200 + 原消息；
    同 key 内容不同返回 409。
    """

    def get(self, request, conv_id):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        if not services.user_can_access(request.user, conv):
            return _forbidden()
        qs = conv.messages.all()
        before_seq = request.query_params.get("before_seq")
        if before_seq:
            try:
                qs = qs.filter(seq__lt=int(before_seq))
            except ValueError:
                return Response(
                    {"detail": "before_seq 必须是整数"},
                    status=status.HTTP_400_BAD_REQUEST,
                )
        try:
            limit = int(request.query_params.get("limit", 50))
        except ValueError:
            limit = 50
        limit = max(1, min(limit, 200))
        msgs = list(qs.order_by("-seq")[:limit][::-1])
        return Response(MessageSerializer(msgs, many=True).data)

    def post(self, request, conv_id):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        if not services.user_can_access(request.user, conv):
            return _forbidden()
        if services.is_muted(request.user, conv):
            return _forbidden("你已被禁言")

        ser = CreateMessageSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        data = ser.validated_data

        # 引用目标校验（必须在本会话）
        reply_to = None
        if data.get("reply_to"):
            reply_to = _get_msg_or_404(conv, data["reply_to"])
            if reply_to is None:
                return _not_found("引用消息不存在")

        key = data.get("idempotency_key")
        # idempotency_key 全局唯一：先做全局预检（幂等契约核心）
        if key:
            existing = Message.objects.filter(idempotency_key=key).first()
            if existing is not None:
                if existing.conversation_id != conv.id:
                    return Response(
                        {"detail": "idempotency_key 冲突：已被其他会话使用"},
                        status=status.HTTP_409_CONFLICT,
                    )
                # 同 key 内容不同 → 409 冲突
                if (
                    existing.content != (data.get("content") or "")
                    or existing.type != data.get("type")
                ):
                    return Response(
                        {"detail": "idempotency_key 冲突：内容不一致"},
                        status=status.HTTP_409_CONFLICT,
                    )
                return Response(
                    MessageSerializer(existing).data, status=status.HTTP_200_OK
                )

        msg = services.create_message(
            request.user,
            conv,
            content=data.get("content") or "",
            msg_type=data.get("type"),
            reply_to=reply_to,
            idempotency_key=key,
            media_id=data.get("media_id"),
        )
        # 只有真正落库后才广播
        services.broadcast_message_new(msg)
        return Response(MessageSerializer(msg).data, status=status.HTTP_201_CREATED)


class MessageReadView(APIView):
    """POST /conversations/<id>/messages/<mid>/read/ —— 标已读。"""

    def post(self, request, conv_id, mid):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        if not services.user_can_access(request.user, conv):
            return _forbidden()
        msg = _get_msg_or_404(conv, mid)
        if msg is None:
            return _not_found("消息不存在")
        services.mark_read(request.user, msg)
        return Response({"detail": "已读"})


class MessageRecallView(APIView):
    """POST /conversations/<id>/messages/<mid>/recall/ —— 撤回（限时，仅发送者）。"""

    def post(self, request, conv_id, mid):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        if not services.user_can_access(request.user, conv):
            return _forbidden()
        msg = _get_msg_or_404(conv, mid)
        if msg is None:
            return _not_found("消息不存在")
        try:
            services.recall_message(request.user, msg)
        except PermissionError:
            return _forbidden("只有发送者本人可以撤回")
        except TimeoutError:
            return Response(
                {"detail": "超过撤回时限"}, status=status.HTTP_400_BAD_REQUEST
            )
        services.broadcast_recall(conv.id, msg.id, msg.seq)
        return Response(MessageSerializer(msg).data)


class TypingView(APIView):
    """POST /conversations/<id>/typing/ —— 声明正在输入（触发 typing 广播）。"""

    def post(self, request, conv_id):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        if not services.user_can_access(request.user, conv):
            return _forbidden()
        services.broadcast_typing(
            conv.id, request.user.id, bool(request.data.get("is_typing", True))
        )
        return Response({"detail": "ok"})


# ---------- 群管理 ----------

class MemberAddView(APIView):
    """POST /conversations/<id>/members/ —— 加人 body {user_ids[]}（群管理员）。"""

    def post(self, request, conv_id):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        if conv.type != Conversation.TYPE_GROUP:
            return _forbidden("仅群聊支持加人")
        if not services.can_manage_group(request.user, conv):
            return _forbidden("仅群主/管理员可加人")
        user_ids = request.data.get("user_ids") or []
        if not isinstance(user_ids, list):
            return Response(
                {"detail": "user_ids 必须是数组"}, status=status.HTTP_400_BAD_REQUEST
            )
        added = 0
        for uid in user_ids:
            try:
                u = User.objects.get(pk=str(uid))
            except (User.DoesNotExist, ValueError):
                continue
            _, created = ConversationMember.objects.get_or_create(
                conversation=conv, user=u, defaults={"role": ConversationMember.ROLE_MEMBER}
            )
            if created:
                added += 1
        conv.refresh_from_db()
        return Response(ConversationSerializer(conv, context={"request": request}).data)


class MemberRemoveView(APIView):
    """DELETE /conversations/<id>/members/<user_id>/ —— 踢人（群管理员；群主不能踢自己）。"""

    def delete(self, request, conv_id, user_id):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        if conv.type != Conversation.TYPE_GROUP:
            return _forbidden("仅群聊支持踢人")
        if not services.can_manage_group(request.user, conv):
            return _forbidden("仅群主/管理员可踢人")
        if str(user_id) == str(request.user.id):
            return _forbidden("不能踢自己")
        try:
            member = ConversationMember.objects.get(
                conversation=conv, user_id=user_id
            )
        except ConversationMember.DoesNotExist:
            return _not_found("成员不存在")
        # 群主不能踢管理员/群主
        if member.role in (ConversationMember.ROLE_OWNER, ConversationMember.ROLE_ADMIN):
            if not services.user_role_in(request.user, conv) == ConversationMember.ROLE_OWNER:
                return _forbidden("不能移除管理员/群主")
        member.delete()
        return Response(status=status.HTTP_204_NO_CONTENT)


class MemberMuteView(APIView):
    """POST /conversations/<id>/members/<user_id>/mute/ —— 禁言/解除 {muted: bool}。"""

    def post(self, request, conv_id, user_id):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        if conv.type != Conversation.TYPE_GROUP:
            return _forbidden("仅群聊支持禁言")
        if not services.can_manage_group(request.user, conv):
            return _forbidden("仅群主/管理员可禁言")
        if str(user_id) == str(request.user.id):
            return _forbidden("不能禁言自己")
        try:
            member = ConversationMember.objects.get(conversation=conv, user_id=user_id)
        except ConversationMember.DoesNotExist:
            return _not_found("成员不存在")
        muted = bool(request.data.get("muted", True))
        member.muted = muted
        member.save(update_fields=["muted"])
        return Response({"detail": "已禁言" if muted else "已解除禁言", "muted": muted})
