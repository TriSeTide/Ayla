"""
chat 视图 —— 私聊/群聊/消息/已读/撤回/群管理 REST。

路径挂 /api/v1/chat/（见 urls.py）。权限语义：
- 越权（非成员）→ 403；不存在的会话/消息 → 404；
- 禁言成员发消息 → 403；
- 群管理（加/踢/禁言/改公告/改角色）仅群主/管理员。
"""
import logging

from django.contrib.auth import get_user_model
from django.db.models import Q
from django.utils import timezone
from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from . import services
from .models import (
    Conversation,
    ConversationMember,
    GroupInvite,
    GroupJoinRequest,
    GroupMemberLeaveNotice,
    GroupSubGroup,
    Message,
    MessageRead,
)
from .serializers import (
    ConversationListSerializer,
    ConversationSerializer,
    CreateMessageSerializer,
    GroupActionSerializer,
    GroupInviteSerializer,
    GroupJoinRequestSerializer,
    GroupMemberLeaveNoticeSerializer,
    MessageSerializer,
    SubGroupSerializer,
)

logger = logging.getLogger(__name__)

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


def _bad_request(msg):
    return Response({"detail": msg}, status=status.HTTP_400_BAD_REQUEST)


# ---------- 会话 ----------

class ConversationListView(APIView):
    """GET /conversations/ —— 当前用户会话列表（含未读数、对方信息/群标题）。

    每个用户只看到自己"未隐藏"（hidden=False）的会话；被其"删除"（隐藏）的会话
    不出现在本人列表，但收到新消息时由 services.create_message 自动取消隐藏。
    """

    def get(self, request):
        # 当前用户"已隐藏"的会话 id（每个用户各自视图）
        hidden_ids = ConversationMember.objects.filter(
            user=request.user, hidden=True
        ).values_list("conversation_id", flat=True)
        qs = (
            Conversation.objects.filter(members__user=request.user)
            .exclude(id__in=hidden_ids)
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
    """POST /conversations/group/ —— 建群 {title, member_ids[]}（owner=当前用户）。"""

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
        # 新群初创默认一个子群「默认组」（即群聊本体，不可删除）
        GroupSubGroup.objects.create(
            conversation=conv, name="默认组", is_default=True
        )
        ConversationMember.objects.create(
            conversation=conv, user=request.user, role=ConversationMember.ROLE_OWNER
        )
        for u in users:
            ConversationMember.objects.create(conversation=conv, user=u)
        
        # 推送群创建事件给所有成员（包括创建者）
        all_member_ids = [request.user.id] + [u.id for u in users]
        services.broadcast_group_created(conv, all_member_ids)
        
        data = ConversationSerializer(conv, context={"request": request}).data
        return Response(data, status=status.HTTP_201_CREATED)


# ---------- 群聊子群 ----------

class SubGroupListView(APIView):
    """GET/POST /conversations/<id>/subgroups/ —— 子群列表 / 创建（仅群主/管理员）。"""

    def get(self, request, conv_id):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        if not services.user_can_access(request.user, conv):
            return _forbidden()
        if conv.type != Conversation.TYPE_GROUP:
            return _bad_request("仅群聊有子群")
        return Response(
            SubGroupSerializer(
                conv.subgroups.all(), many=True, context={"request": request}
            ).data
        )

    def post(self, request, conv_id):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        if not services.user_can_access(request.user, conv):
            return _forbidden()
        if conv.type != Conversation.TYPE_GROUP:
            return _bad_request("仅群聊有子群")
        if not services.can_manage_group(request.user, conv):
            return _forbidden("仅群主/管理员可管理子群")
        name = (request.data.get("name") or "").strip()
        if not name:
            return _bad_request("子群名必填")
        if len(name) > 64:
            return _bad_request("子群名不能超过 64 字")
        if conv.subgroups.filter(name=name).exists():
            return _bad_request("已存在同名子群")
        sg = services.create_subgroup(conv, name)
        services.broadcast_subgroup_created(sg)
        return Response(
            SubGroupSerializer(sg, context={"request": request}).data,
            status=status.HTTP_201_CREATED,
        )


class SubGroupDetailView(APIView):
    """PATCH/DELETE /conversations/<id>/subgroups/<sid>/ —— 改名 / 删除（仅群主/管理员）。"""

    def _get_subgroup(self, request, conv_id, sid):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return None, _not_found("会话不存在")
        if not services.user_can_access(request.user, conv):
            return None, _forbidden()
        if conv.type != Conversation.TYPE_GROUP:
            return None, _bad_request("仅群聊有子群")
        try:
            sg = conv.subgroups.get(pk=sid)
        except (GroupSubGroup.DoesNotExist, ValueError):
            return None, _not_found("子群不存在")
        return sg, None

    def patch(self, request, conv_id, sid):
        sg, err = self._get_subgroup(request, conv_id, sid)
        if err is not None:
            return err
        if not services.can_manage_group(request.user, sg.conversation):
            return _forbidden("仅群主/管理员可管理子群")
        name = request.data.get("name")
        muted = request.data.get("muted")
        if name is not None:
            name = str(name).strip()
            if not name:
                return _bad_request("子群名必填")
            if len(name) > 64:
                return _bad_request("子群名不能超过 64 字")
            if sg.conversation.subgroups.filter(name=name).exclude(pk=sg.pk).exists():
                return _bad_request("已存在同名子群")
            sg.name = name
        if muted is not None:
            if not isinstance(muted, bool):
                return _bad_request("muted 必须是布尔值")
            sg.muted = muted
        update_fields = []
        if name is not None:
            update_fields.append("name")
        if muted is not None:
            update_fields.append("muted")
        if update_fields:
            sg.save(update_fields=update_fields)
        services.broadcast_subgroup_updated(sg)
        return Response(SubGroupSerializer(sg, context={"request": request}).data)

    def delete(self, request, conv_id, sid):
        sg, err = self._get_subgroup(request, conv_id, sid)
        if err is not None:
            return err
        if not services.can_manage_group(request.user, sg.conversation):
            return _forbidden("仅群主/管理员可管理子群")
        if sg.is_default:
            return _bad_request("默认组不可删除")
        conversation_id = sg.conversation_id
        subgroup_id = sg.id
        services.delete_subgroup(sg)
        services.broadcast_subgroup_deleted(conversation_id, subgroup_id)
        return Response({"detail": "子群已删除"})


class SubGroupReadView(APIView):
    """POST /conversations/<id>/subgroups/<sid>/read/ —— 把该子群标已读（本人）。"""

    def post(self, request, conv_id, sid):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        if not services.user_can_access(request.user, conv):
            return _forbidden()
        try:
            sg = conv.subgroups.get(pk=sid)
        except (GroupSubGroup.DoesNotExist, ValueError):
            return _not_found("子群不存在")
        marked = services.mark_subgroup_read(request.user, sg)
        services.broadcast_subgroup_read(sg, request.user, marked)
        return Response({"marked": marked})


class ConversationDetailView(APIView):
    """GET /conversations/<id>/ —— 会话详情（成员列表 + 我的角色）。
    PATCH —— 改群标题/公告/头像（群管理员）。"""

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
        join_policy = request.data.get("join_policy")
        avatar = request.data.get("avatar")
        if title is not None:
            conv.title = str(title).strip()
        if announcement is not None:
            conv.announcement = str(announcement)
        if join_policy is not None:
            if join_policy not in {Conversation.JOIN_PUBLIC, Conversation.JOIN_APPLICATION}:
                return Response({"detail": "join_policy 无效"}, status=status.HTTP_400_BAD_REQUEST)
            conv.join_policy = join_policy
        if avatar is not None:
            avatar = str(avatar).strip()
            # 头像必须是媒体 content URL 且当前用户有访问权（图片）
            from apps.media.services import validate_avatar_url

            error = validate_avatar_url(request.user, avatar)
            if error:
                return Response({"detail": error}, status=status.HTTP_400_BAD_REQUEST)
            conv.avatar = avatar
        update_fields = []
        if title is not None:
            update_fields.append("title")
        if announcement is not None:
            update_fields.append("announcement")
        if join_policy is not None:
            update_fields.append("join_policy")
        if avatar is not None:
            update_fields.append("avatar")
        if update_fields:
            conv.save(update_fields=update_fields)
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
        # 子群过滤：subgroup_id 缺省 = 全部消息（旧客户端兼容）；
        # 默认组额外包含 subgroup 为 null 的旧消息（子群功能上线前的群聊本体）。
        subgroup_id = request.query_params.get("subgroup_id")
        if subgroup_id:
            try:
                subgroup_id = int(subgroup_id)
            except ValueError:
                return Response(
                    {"detail": "subgroup_id 必须是整数"},
                    status=status.HTTP_400_BAD_REQUEST,
                )
            subgroup = conv.subgroups.filter(id=subgroup_id).first()
            if subgroup is None:
                return _not_found("子群不存在")
            if subgroup.is_default:
                qs = qs.filter(Q(subgroup=subgroup) | Q(subgroup__isnull=True))
            else:
                qs = qs.filter(subgroup=subgroup)
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
        return Response(MessageSerializer(msgs, many=True, context={"request": request}).data)

    def post(self, request, conv_id):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        if not services.user_can_access(request.user, conv):
            return _forbidden()
        # Bug #2：私聊发消息要求双方仍是好友（爱莉对端放行，见 services）
        if conv.type == Conversation.TYPE_PRIVATE:
            peer = (
                conv.members.exclude(user=request.user).select_related("user").first()
            )
            if peer is None or not services.can_send_private_message(
                request.user, peer.user
            ):
                return _forbidden("对方已不是你的好友，无法发送消息")
        if services.is_muted(request.user, conv):
            return _forbidden("你已被禁言")

        # 子群禁言：开启时仅群主/管理员可发言（普通成员 403）；
        # 不传 subgroup_id 时按默认组判定（旧客户端语义）。
        if conv.type == Conversation.TYPE_GROUP:
            subgroup_id = request.data.get("subgroup_id")
            sg = None
            if subgroup_id is not None:
                sg = conv.subgroups.filter(id=subgroup_id).first()
            else:
                sg = conv.subgroups.filter(is_default=True).first()
            if sg is not None and sg.muted and not services.can_manage_group(request.user, conv):
                return _forbidden("该子群已禁言，仅群主/管理员可发言")

        ser = CreateMessageSerializer(
            data=request.data, context={"request": request, "conversation": conv}
        )
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
                    or existing.segments != (data.get("segments") or None)
                ):
                    return Response(
                        {"detail": "idempotency_key 冲突：内容不一致"},
                        status=status.HTTP_409_CONFLICT,
                    )
                return Response(
                    MessageSerializer(existing, context={"request": request}).data,
                    status=status.HTTP_200_OK,
                )

        # 子群归属：serializer 已校验存在性；群聊不传时归默认组（None = 旧消息语义）
        subgroup = None
        if data.get("subgroup_id") is not None:
            subgroup = conv.subgroups.filter(id=data["subgroup_id"]).first()
            if subgroup is None:
                return _not_found("子群不存在")

        msg = services.create_message(
            request.user,
            conv,
            content=data.get("content") or "",
            msg_type=data.get("type"),
            reply_to=reply_to,
            idempotency_key=key,
            media_id=data.get("media_id"),
            segments=data.get("segments"),
            subgroup=subgroup,
        )
        # 戳一戳：独立广播帧（不进未读/已读/红点链路），也不 inject 爱莉主链
        # （轻互动不是聊天内容，不进入 Elysium 意识通道）。
        if data.get("type") == Message.TYPE_POKE:
            services.broadcast_message_poke(msg)
            return Response(
                MessageSerializer(msg, context={"request": request}).data,
                status=status.HTTP_201_CREATED,
            )
        # 只有真正落库后才广播
        services.broadcast_message_new(msg)
        # 爱莉桥接：若该会话对端是爱莉，把用户消息 inject 到 Elysium 主链
        # （失败不阻塞/不回滚用户消息；仅告警，由桥接重试或人工处理）
        try:
            from apps.elysia_bridge.services import on_user_message_to_elysia

            on_user_message_to_elysia(message=msg, conversation=conv)
        except Exception:
            logger.exception("elysia bridge inject failed for message %s", msg.id)
        return Response(
            MessageSerializer(msg, context={"request": request}).data,
            status=status.HTTP_201_CREATED,
        )


class ConversationReadView(APIView):
    """POST /conversations/<id>/read/ —— 将会话当前消息全部标已读。"""

    def post(self, request, conv_id):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        if not services.user_can_access(request.user, conv):
            return _forbidden()
        through_seq = request.data.get("through_seq")
        exclude_message_ids = request.data.get("exclude_message_ids") or []
        preserve_special = bool(request.data.get("preserve_special", False))
        if through_seq is not None:
            try:
                through_seq = int(through_seq)
            except (TypeError, ValueError):
                return _bad_request("through_seq 必须是整数")
        if not isinstance(exclude_message_ids, list):
            return _bad_request("exclude_message_ids 必须是数组")
        services.mark_conversation_read(
            request.user,
            conv,
            through_seq=through_seq,
            exclude_message_ids=exclude_message_ids,
            preserve_special=preserve_special,
        )
        return Response({"detail": "已读"})


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
        exact = bool(request.data.get("exact", False))
        services.mark_read(request.user, msg, through=not exact)
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
        return Response(MessageSerializer(msg, context={"request": request}).data)


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
                # 通知新成员群加入成功
                services.broadcast_group_joined(conv, u.id)
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


class MemberRoleView(APIView):
    """PATCH /conversations/<id>/members/<user_id>/role/ —— 任命/撤销管理员。"""

    def patch(self, request, conv_id, user_id):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        if conv.type != Conversation.TYPE_GROUP:
            return _forbidden("仅群聊支持角色管理")
        if services.user_role_in(request.user, conv) != ConversationMember.ROLE_OWNER:
            return _forbidden("仅群主可管理管理员")
        try:
            member = ConversationMember.objects.get(conversation=conv, user_id=user_id)
        except ConversationMember.DoesNotExist:
            return _not_found("成员不存在")
        if member.role == ConversationMember.ROLE_OWNER:
            return _forbidden("不能修改群主角色")
        role = request.data.get("role")
        if role not in {ConversationMember.ROLE_MEMBER, ConversationMember.ROLE_ADMIN}:
            return Response({"detail": "role 无效"}, status=status.HTTP_400_BAD_REQUEST)
        member.role = role
        member.save(update_fields=["role"])
        conv.refresh_from_db()
        return Response(ConversationSerializer(conv, context={"request": request}).data)


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


class GroupOwnerTransferView(APIView):
    """POST /conversations/<id>/transfer-owner/ —— 群主转让。"""

    def post(self, request, conv_id):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        if conv.type != Conversation.TYPE_GROUP:
            return _forbidden("仅群聊支持转让")
        target_id = request.data.get("user_id")
        try:
            services.transfer_group_owner(conv, request.user, target_id)
        except ConversationMember.DoesNotExist:
            return _not_found("目标成员不存在")
        except (PermissionError, ValueError) as exc:
            return _forbidden(str(exc))
        return Response(ConversationSerializer(conv, context={"request": request}).data)


class GroupLeaveView(APIView):
    """POST /conversations/<id>/leave/ —— 成员退出群聊。"""

    def post(self, request, conv_id):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        try:
            services.leave_group(conv, request.user)
        except ValueError as exc:
            return _bad_request(str(exc))
        return Response({"left": True})


class GroupMemberLeaveNoticeListView(APIView):
    """GET /chat/leave-notices/；POST /chat/leave-notices/<id>/read/。"""

    def get(self, request):
        notices = GroupMemberLeaveNotice.objects.filter(recipient=request.user, read_at__isnull=True).select_related("conversation")[:50]
        return Response(GroupMemberLeaveNoticeSerializer(notices, many=True).data)


class GroupMemberLeaveNoticeReadView(APIView):
    def post(self, request, notice_id):
        notice = GroupMemberLeaveNotice.objects.filter(id=notice_id, recipient=request.user).first()
        if notice is None:
            return _not_found("退群通知不存在")
        notice.read_at = timezone.now()
        notice.save(update_fields=["read_at"])
        return Response({"read": True})


class GroupDissolveView(APIView):
    """DELETE /conversations/<id>/dissolve/ —— 群主解散群聊。"""

    def delete(self, request, conv_id):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        try:
            services.dissolve_group(conv, request.user)
        except PermissionError as exc:
            return _forbidden(str(exc))
        return Response({"deleted": True})


class ConversationPinView(APIView):
    """POST /conversations/<id>/pin/ —— 置顶/取消置顶会话（本人视图）body {pinned: bool}。"""

    permission_classes = [IsAuthenticated]

    def post(self, request, conv_id):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        if not services.user_can_access(request.user, conv):
            return _forbidden()
        pinned = bool(request.data.get("pinned", True))
        try:
            is_pinned = services.toggle_pin(request.user, conv, pinned)
        except PermissionError as exc:
            return _forbidden(str(exc))
        return Response({"pinned": is_pinned, "detail": "已置顶" if is_pinned else "已取消置顶"})


class ConversationHideView(APIView):
    """POST /conversations/<id>/hide/ —— 从本人列表隐藏/删除会话（软删除，不删消息）。

    被隐藏的会话不再出现在本人列表；对方再发消息或本人重新发起会话时自动取消隐藏。
    """

    permission_classes = [IsAuthenticated]

    def post(self, request, conv_id):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        if not services.user_can_access(request.user, conv):
            return _forbidden()
        services.hide_conversation(request.user, conv)
        return Response({"detail": "会话已隐藏", "hidden": True})


# ---------- 群申请 / 邀请（S2，开发文档 §1.2） ----------
#
# 权限矩阵：
# - 申请入群：任何登录用户（当前群无可见性字段，"公开/好友"群区分后置，
#   见开发步骤 §7 已知取舍）；已是成员 → 400；pending 幂等复用；
# - 审批申请：仅 owner/admin；
# - 邀请：仅群成员（可邀请任意登录用户，需求 R-G9 "搜索用户 → 邀请"）；
# - 处理邀请：仅被邀请人本人。
# WS 通知：审批后推申请人 group.request.resolved；新邀请推被邀请人 group.invite.new。

class GroupJoinRequestView(APIView):
    """GET /conversations/<id>/join-requests/ —— owner/admin 查看待审批申请。
    POST /conversations/<id>/join-requests/ —— 申请入群 {message}（幂等）。"""

    def get(self, request, conv_id):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        if conv.type != Conversation.TYPE_GROUP:
            return _forbidden("仅群聊支持入群申请")
        if not services.can_manage_group(request.user, conv):
            return _forbidden("仅群主/管理员可查看申请")
        qs = GroupJoinRequest.objects.filter(
            conversation=conv, status=GroupJoinRequest.STATUS_PENDING
        ).select_related("applicant")
        return Response(
            GroupJoinRequestSerializer(qs, many=True, context={"request": request}).data
        )

    def post(self, request, conv_id):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        if conv.type != Conversation.TYPE_GROUP:
            return _forbidden("仅群聊支持申请加入")
        if services.user_can_access(request.user, conv):
            return Response(
                {"detail": "你已在群中"}, status=status.HTTP_400_BAD_REQUEST
            )
        if conv.join_policy == Conversation.JOIN_PUBLIC:
            ConversationMember.objects.get_or_create(
                conversation=conv,
                user=request.user,
                defaults={"role": ConversationMember.ROLE_MEMBER},
            )
            # 公开群直接加入后，通知前端更新群列表
            services.broadcast_group_joined(conv, request.user.id)
            return Response({"status": "accepted", "conversation_id": str(conv.id)}, status=status.HTTP_201_CREATED)
        req, created = services.create_join_request(
            request.user, conv, request.data.get("message") or ""
        )
        if created:
            recipients = ConversationMember.objects.filter(
                conversation=conv,
                role__in=[ConversationMember.ROLE_OWNER, ConversationMember.ROLE_ADMIN],
            ).values_list("user_id", flat=True)
            applicant_name = getattr(request.user, "nickname", "") or request.user.username
            for recipient_id in recipients:
                services.broadcast_group_request_new(
                    recipient_id,
                    request_id=req.id,
                    conversation_id=conv.id,
                    conversation_title=conv.title,
                    applicant_id=request.user.id,
                    applicant_name=applicant_name,
                )
        return Response(
            GroupJoinRequestSerializer(req, context={"request": request}).data,
            status=status.HTTP_201_CREATED if created else status.HTTP_200_OK,
        )


class GroupJoinRequestActionView(APIView):
    """POST /join-requests/<id>/action/ —— owner/admin 审批 {action}（accept 事务内建成员）。"""

    def post(self, request, request_id):
        try:
            req = GroupJoinRequest.objects.select_related(
                "conversation", "applicant"
            ).get(pk=request_id, status=GroupJoinRequest.STATUS_PENDING)
        except GroupJoinRequest.DoesNotExist:
            return _not_found("申请不存在或已处理")
        if not services.can_manage_group(request.user, req.conversation):
            return _forbidden("仅群主/管理员可审批")
        ser = GroupActionSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        action = ser.validated_data["action"]
        if action == "accept":
            services.accept_join_request(req, request.user)
            # 通知新成员群加入成功
            services.broadcast_group_joined(req.conversation, req.applicant_id)
        else:
            services.reject_join_request(req, request.user)
        # 审批成功后通知申请人（用户级广播，事务外）
        services.broadcast_group_request_resolved(
            req.applicant_id,
            request_id=req.id,
            conversation_id=req.conversation_id,
            conversation_title=req.conversation.title,
            status=req.status,
            handled_by_id=request.user.id,
            handled_at=req.handled_at,
        )
        return Response(
            GroupJoinRequestSerializer(req, context={"request": request}).data
        )


class GroupInviteView(APIView):
    """POST /conversations/<id>/invites/ —— 群成员邀请入群 {invitee_id}（幂等）。"""

    def post(self, request, conv_id):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        if conv.type != Conversation.TYPE_GROUP:
            return _forbidden("仅群聊支持邀请")
        if not services.user_can_access(request.user, conv):
            return _forbidden("仅群成员可邀请")
        invitee_id = request.data.get("invitee_id")
        if not invitee_id:
            return Response(
                {"detail": "缺少 invitee_id"}, status=status.HTTP_400_BAD_REQUEST
            )
        try:
            invitee = User.objects.get(pk=str(invitee_id))
        except (User.DoesNotExist, ValueError):
            return _not_found("目标用户不存在")
        if invitee.id == request.user.id:
            return Response(
                {"detail": "不能邀请自己"}, status=status.HTTP_400_BAD_REQUEST
            )
        if services.user_can_access(invitee, conv):
            return Response(
                {"detail": "对方已在群中"}, status=status.HTTP_400_BAD_REQUEST
            )
        inv, created = services.create_group_invite(request.user, conv, invitee)
        if created:
            # 新邀请通知被邀请人（用户级广播）
            services.broadcast_group_invite_new(
                invitee.id,
                invite_id=inv.id,
                conversation_id=conv.id,
                conversation_title=conv.title,
                inviter_id=request.user.id,
                inviter_name=request.user.nickname or request.user.username,
                created_at=inv.created_at,
            )
        return Response(
            GroupInviteSerializer(inv, context={"request": request}).data,
            status=status.HTTP_201_CREATED if created else status.HTTP_200_OK,
        )


class MyInvitesView(APIView):
    """GET /me/invites/ —— 我收到的待处理邀请。"""

    def get(self, request):
        qs = GroupInvite.objects.filter(
            invitee=request.user, status=GroupInvite.STATUS_PENDING
        ).select_related("conversation", "inviter")
        return Response(
            GroupInviteSerializer(qs, many=True, context={"request": request}).data
        )


class GroupInviteActionView(APIView):
    """POST /invites/<id>/action/ —— 被邀请人处理 {action}（accept 事务内建成员）。"""

    def post(self, request, invite_id):
        try:
            inv = GroupInvite.objects.select_related("conversation", "inviter").get(
                pk=invite_id, status=GroupInvite.STATUS_PENDING
            )
        except GroupInvite.DoesNotExist:
            return _not_found("邀请不存在或已处理")
        if inv.invitee_id != request.user.id:
            return _forbidden("仅被邀请人可处理")
        ser = GroupActionSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        action = ser.validated_data["action"]
        if action == "accept":
            services.accept_group_invite(inv, request.user)
            # 通知新成员群加入成功
            services.broadcast_group_joined(inv.conversation, request.user.id)
        else:
            services.reject_group_invite(inv, request.user)
        return Response(
            GroupInviteSerializer(inv, context={"request": request}).data
        )


# ---------- 群动态 highlights（S6） ----------

class ConversationHighlightsView(APIView):
    """GET /conversations/<conv_id>/highlights/ —— 单群最近动态封面列表。

    校验：会话存在（404）、是群聊（非群 403）、当前用户是成员（否则 403）。
    """

    permission_classes = [IsAuthenticated]

    def get(self, request, conv_id):
        conv = _get_conv_or_404(conv_id)
        if conv is None:
            return _not_found("会话不存在")
        if conv.type != Conversation.TYPE_GROUP:
            return _forbidden("仅群聊支持动态 highlights")
        if not services.user_can_access(request.user, conv):
            return _forbidden()
        return Response(services.conversation_highlights(conv))


class ConversationHighlightsBatchView(APIView):
    """GET /conversations/highlights/?ids=1,2,3 —— 批量群动态封面。

    ids 为逗号分隔整数列表（必填，缺失或空 → 400）。
    只返回当前用户是成员的群；不存在的 id / 非成员群 / 非群聊不出现在结果里。
    返回 dict：{str(conv.id): highlights}。
    """

    permission_classes = [IsAuthenticated]

    def get(self, request):
        raw_ids = request.query_params.get("ids")
        if not raw_ids or not raw_ids.strip():
            return Response(
                {"detail": "缺少 ids 参数"}, status=status.HTTP_400_BAD_REQUEST
            )
        try:
            conv_ids = [int(x) for x in raw_ids.split(",") if x.strip()]
        except ValueError:
            return Response(
                {"detail": "ids 必须是逗号分隔的整数"}, status=status.HTTP_400_BAD_REQUEST
            )
        if not conv_ids:
            return Response(
                {"detail": "缺少 ids 参数"}, status=status.HTTP_400_BAD_REQUEST
            )

        convs = Conversation.objects.filter(
            pk__in=conv_ids, type=Conversation.TYPE_GROUP, members__user=request.user
        ).distinct()
        result = {
            str(conv.id): services.conversation_highlights(conv) for conv in convs
        }
        return Response(result)
