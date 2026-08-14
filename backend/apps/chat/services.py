"""
聊天领域服务 —— REST 视图与 ChatConsumer 复用的核心逻辑。

设计（步骤文件第 4 节）：
- 会话成员权限判断（user_can_access / user_role_in / can_manage_group）；
- 私聊幂等创建（get_or_create_conversation，含双向两条成员记录）；
- 消息幂等落库（create_message，事务内算 seq，`(conversation, seq)` 唯一兜底）；
- 撤回（限时）、已读（幂等写入 + 广播）、会话 seq 查询；
- 广播统一从这里发出，group_send 捕获 ChannelFull，慢消费者不阻塞其他成员。

硬约束（AGENTS.md）：
- 幂等是工程硬约束：同 idempotency_key 已存在则返回既有消息（不重复落库），
  不同内容由调用方（视图层）报 409；
- 禁止把失败伪造成成功投递：只有真正落库并广播后才算发出。
"""
import logging

from asgiref.sync import async_to_sync
from channels.exceptions import ChannelFull
from django.conf import settings
from django.db import IntegrityError, transaction
from django.db.models import Max, Q
from django.utils import timezone

from .models import (
    Conversation,
    ConversationMember,
    GroupInvite,
    GroupJoinRequest,
    Message,
    MessageRead,
)

logger = logging.getLogger(__name__)


# ---------- 会话 ----------

def get_or_create_conversation(a_user, b_user) -> Conversation:
    """私聊幂等：找两人共有的 PRIVATE 会话，没有则建（含两条成员记录）。

    注意：members 是双向两条记录（A-B 会话要建 (conv, A) 和 (conv, B) 两条），
    权限判断按"是否在 members 里"而不是按 owner。
    """
    # 找同时含 a 与 b 的 PRIVATE 会话（members 反向查询；"同时含"用两次存在性判断）
    conv = (
        Conversation.objects.filter(type=Conversation.TYPE_PRIVATE)
        .filter(members__user=a_user)
        .filter(members__user=b_user)
        .distinct()
        .first()
    )
    if conv:
        return conv

    with transaction.atomic():
        conv = Conversation.objects.create(
            type=Conversation.TYPE_PRIVATE, title="", owner=a_user
        )
        ConversationMember.objects.create(
            conversation=conv, user=a_user, role=ConversationMember.ROLE_OWNER
        )
        ConversationMember.objects.create(
            conversation=conv, user=b_user, role=ConversationMember.ROLE_MEMBER
        )
    return conv


def user_role_in(user, conversation) -> str | None:
    """返回 member/admin/owner 或 None（不在会话）。"""
    try:
        return ConversationMember.objects.get(
            conversation=conversation, user=user
        ).role
    except ConversationMember.DoesNotExist:
        return None


def user_can_access(user, conversation) -> bool:
    """会话成员/群管理员权限判断；越权在视图层返回 403。"""
    return ConversationMember.objects.filter(
        conversation=conversation, user=user
    ).exists()


def can_manage_group(user, conversation) -> bool:
    """群管理员/群主才可：加踢人/禁言/改公告/改成员角色。"""
    if conversation.type != Conversation.TYPE_GROUP:
        return False
    role = user_role_in(user, conversation)
    return role in (ConversationMember.ROLE_ADMIN, ConversationMember.ROLE_OWNER)


def is_muted(user, conversation) -> bool:
    """会话成员是否被禁言（仅群聊有意义；私聊不禁言）。"""
    try:
        member = ConversationMember.objects.get(conversation=conversation, user=user)
    except ConversationMember.DoesNotExist:
        return False
    return member.muted


# ---------- 消息 ----------

def conversation_seq(conversation) -> int:
    """当前会话最大 seq（无消息返回 0）。"""
    return (
        conversation.messages.aggregate(m=Max("seq"))["m"]
        or 0
    )


def find_by_idempotency_key(conversation, key) -> Message | None:
    return Message.objects.filter(conversation=conversation, idempotency_key=key).first()


def find_global_by_idempotency_key(key) -> Message | None:
    """按全局唯一幂等键查消息（不限定会话）。

    idempotency_key 在 DB 层是全局唯一。`find_by_idempotency_key` 按
    (conversation, key) 查，桥接重放历史事件时同 key 可能已被路由到其它会话，
    此时需按全局 key 判定"已投影过"（幂等跳过），见 elysia_bridge 投影兜底。
    """
    return Message.objects.filter(idempotency_key=key).first()


def create_message(
    user,
    conversation,
    *,
    content="",
    msg_type=Message.TYPE_TEXT,
    reply_to=None,
    idempotency_key=None,
    media_id=None,
    seq=None,
) -> Message:
    """幂等创建消息。

    - 同 idempotency_key 已存在则返回既有消息（不重复落库）；
    - 否则在事务内算 seq 并落库；
    - 调用方负责广播（本函数不做广播，保证 REST 与 WS 落库后再各自广播）。
    """
    key = idempotency_key
    if key is None:
        key = _new_key()

    existing = find_by_idempotency_key(conversation, key)
    if existing is not None:
        return existing

    try:
        with transaction.atomic():
            # 未显式指定 seq 时在事务内算 max+1
            if seq is None:
                seq = conversation_seq(conversation) + 1
            msg = Message.objects.create(
                conversation=conversation,
                sender=user,
                type=msg_type,
                content=content,
                media_id=media_id,
                reply_to=reply_to,
                idempotency_key=key,
                seq=seq,
            )
    except IntegrityError:
        # (conversation, seq) 并发冲突：重试一次；仍冲突则抛给调用方（记录 README 已知取舍）
        logger.warning("message seq conflict, retrying once", exc_info=True)
        if seq is None:
            with transaction.atomic():
                seq = conversation_seq(conversation) + 1
                msg = Message.objects.create(
                    conversation=conversation,
                    sender=user,
                    type=msg_type,
                    content=content,
                    media_id=media_id,
                    reply_to=reply_to,
                    idempotency_key=key,
                    seq=seq,
                )
        else:
            raise
    return msg


def _new_key() -> str:
    import uuid

    return uuid.uuid4().hex


def recall_message(user, message) -> Message:
    """撤回：仅发送者本人、且 created_at 在限时窗口内。

    成功置 recalled + recalled_at。越权/超时抛 ValueError，由视图层映射为 403/400。
    """
    if message.sender_id != user.id:
        raise PermissionError("只有发送者本人可以撤回")
    if message.status == Message.STATUS_RECALLED:
        return message  # 幂等：已撤回直接返回
    window = getattr(settings, "MESSAGE_RECALL_SECONDS", 120)
    if (timezone.now() - message.created_at).total_seconds() > window:
        raise TimeoutError("超过撤回时限")
    message.status = Message.STATUS_RECALLED
    message.recalled_at = timezone.now()
    message.save(update_fields=["status", "recalled_at"])
    return message


def mark_read(user, message) -> None:
    """幂等写入 MessageRead；若该消息 sender != user 且用户已读，广播 message.read。"""
    _mark_read_record(user, message)
    if message.sender_id != user.id:
        broadcast_read(message, user)


# ---------- 广播（统一从这里发出，捕获 ChannelFull） ----------
#
# 设计：async 核心（_abroadcast_*）+ 同步包装（broadcast_*）。
# - REST 视图在同步线程里跑，用 async_to_sync 包装的同步版；
# - WS consumer / 异步测试直接 await async 版，避免 async_to_sync 跨事件循环
#   （InMemory channel layer 跨循环会丢事件）。

def _group_send_sync(conversation_id, event: dict) -> None:
    """同步向会话组广播，捕获 ChannelFull 不抛断（慢消费者不阻塞其他成员）。"""
    from channels.layers import get_channel_layer

    layer = get_channel_layer()
    if layer is None:
        return
    try:
        async_to_sync(layer.group_send)(f"chat_conv_{conversation_id}", event)
    except ChannelFull:
        logger.warning("channel full, dropping event for conv %s", conversation_id)
    except Exception:
        logger.exception("group_send failed for conv %s", conversation_id)


async def _group_send_async(conversation_id, event: dict) -> None:
    """异步向会话组广播，捕获 ChannelFull 不抛断。"""
    from channels.layers import get_channel_layer

    layer = get_channel_layer()
    if layer is None:
        return
    try:
        await layer.group_send(f"chat_conv_{conversation_id}", event)
    except ChannelFull:
        logger.warning("channel full, dropping event for conv %s", conversation_id)
    except Exception:
        logger.exception("group_send failed for conv %s", conversation_id)


def _message_new_event(message: Message) -> dict:
    # M4-3：media 从字符串 media_id 升级为 descriptor 对象（无引用为 null）
    return {
        "type": "chat.message.new",
        "conversation_id": str(message.conversation_id),
        "message_id": str(message.id),
        "sender_id": message.sender_id,
        "content": message.content,
        "msg_type": message.type,
        "media": _media_descriptor(message.media_id),
        "reply_to": str(message.reply_to_id) if message.reply_to_id else None,
        "seq": message.seq,
        "ts": message.created_at.isoformat(),
    }


def _media_descriptor(media_id: str | None):
    """媒体 descriptor：media_id 引用 MediaObject 则返回 descriptor，否则 None。"""
    if not media_id:
        return None
    from apps.media.models import MediaObject
    from apps.media.serializers import MediaObjectSerializer

    media = MediaObject.objects.filter(media_id=media_id).first()
    if media is None:
        return None
    return MediaObjectSerializer(media).data


def broadcast_message_new(message: Message) -> None:
    """message.new（同步版，REST 视图用）。"""
    _group_send_sync(message.conversation_id, _message_new_event(message))


async def abroadcast_message_new(message: Message) -> None:
    """message.new（异步版，WS/测试用）。"""
    await _group_send_async(message.conversation_id, _message_new_event(message))


def broadcast_recall(conversation_id, message_id: int, seq: int) -> None:
    """message.recall（同步版）。"""
    _group_send_sync(
        conversation_id,
        {
            "type": "chat.message.recall",
            "conversation_id": str(conversation_id),
            "message_id": str(message_id),
            "seq": seq,
        },
    )


async def abroadcast_recall(conversation_id, message_id: int, seq: int) -> None:
    """message.recall（异步版）。"""
    await _group_send_async(
        conversation_id,
        {
            "type": "chat.message.recall",
            "conversation_id": str(conversation_id),
            "message_id": str(message_id),
            "seq": seq,
        },
    )


def broadcast_read(message: Message, user) -> None:
    """message.read（同步版）：私聊里给"对方发的消息"标已读时广播。"""
    _group_send_sync(
        message.conversation_id,
        {
            "type": "chat.message.read",
            "conversation_id": str(message.conversation_id),
            "message_id": str(message.id),
            "user_id": user.id,
            "seq": message.seq,
        },
    )


async def abroadcast_read(message: Message, user) -> None:
    """message.read（异步版）。"""
    await _group_send_async(
        message.conversation_id,
        {
            "type": "chat.message.read",
            "conversation_id": str(message.conversation_id),
            "message_id": str(message.id),
            "user_id": user.id,
            "seq": message.seq,
        },
    )


def broadcast_typing(conversation_id, user_id: str, is_typing: bool) -> None:
    """typing（同步版）。"""
    _group_send_sync(
        conversation_id,
        {
            "type": "chat.typing",
            "conversation_id": str(conversation_id),
            "user_id": user_id,
            "is_typing": is_typing,
        },
    )


async def abroadcast_typing(conversation_id, user_id: str, is_typing: bool) -> None:
    """typing（异步版）。"""
    await _group_send_async(
        conversation_id,
        {
            "type": "chat.typing",
            "conversation_id": str(conversation_id),
            "user_id": user_id,
            "is_typing": is_typing,
        },
    )


# ---------- 同步辅助（供 WS Consumer 使用） ----------

def _mark_read_record(user, message) -> None:
    MessageRead.objects.get_or_create(message=message, user=user)


def member_user_ids(conversation) -> list:
    """会话全部成员 user.id 列表（用于建群/加人/踢人后的批量处理）。"""
    return list(
        ConversationMember.objects.filter(conversation=conversation).values_list(
            "user_id", flat=True
        )
    )


# ---------- 群动态 highlights（S6） ----------

def conversation_highlights(conv, limit: int = 5) -> list:
    """返回该群的最近动态封面列表（按 created_at 降序取前 limit 条，默认 5）。

    聚合三类动态：
    - live：LiveChannel(status=live)，无封面；
    - post：有配图的帖子，取首图（order 最小）缩略图作封面；
    - game：GameRoom(status=playing)，无封面。

    元素结构：
    {"type", "title", "cover_url", "target_url", "created_at"}

    无动态返回 []。cover_url 为 None 表示该类型无封面字段；
    post 无图被 exclude(images=None) 排除在外。
    """
    from apps.live.models import LiveChannel
    from apps.posts.models import Post
    from apps.boardgame.models import GameRoom

    highlights = []

    # live
    for ch in LiveChannel.objects.filter(group=conv, status="live"):
        highlights.append(
            {
                "type": "live",
                "title": ch.title,
                "cover_url": None,
                "target_url": f"/live/{ch.id}",
                "created_at": ch.created_at.isoformat(),
            }
        )

    # post：只取有图的帖子，首图缩略图作封面
    posts = (
        Post.objects.filter(group=conv)
        .exclude(images=None)
        .prefetch_related("images__media")
    )
    for p in posts:
        first_image = None
        for img in p.images.all():
            first_image = img
            break
        cover_url = None
        if first_image is not None and first_image.media_id is not None:
            cover_url = f"/api/v1/media/{first_image.media.media_id}/thumbnail"
        highlights.append(
            {
                "type": "post",
                "title": p.title or (p.body or "")[:30],
                "cover_url": cover_url,
                "target_url": f"/posts/{p.id}",
                "created_at": p.created_at.isoformat(),
            }
        )

    # game
    for g in GameRoom.objects.filter(group=conv, status="playing"):
        highlights.append(
            {
                "type": "game",
                "title": g.name,
                "cover_url": None,
                "target_url": f"/games/{g.id}",
                "created_at": g.created_at.isoformat(),
            }
        )

    highlights.sort(key=lambda h: h["created_at"], reverse=True)
    return highlights[:limit]


# ---------- 群申请 / 邀请（S2，开发文档 §1.2） ----------
#
# 幂等语义：pending 查重由 services 做（DB 不设部分唯一索引，MySQL 不支持），
# 与私聊会话幂等（services 层 get_or_create_conversation）同一模式。
# 事务与广播分离：accept/reject 只做状态 + 成员写入，广播由视图层在成功后调用。

def create_join_request(applicant, conversation, message="") -> tuple:
    """申请入群（幂等）：存在 pending 申请则复用，否则创建。

    返回 (GroupJoinRequest, created: bool)。
    """
    existing = GroupJoinRequest.objects.filter(
        conversation=conversation,
        applicant=applicant,
        status=GroupJoinRequest.STATUS_PENDING,
    ).first()
    if existing is not None:
        return existing, False
    return (
        GroupJoinRequest.objects.create(
            conversation=conversation,
            applicant=applicant,
            message=(message or "")[:256],
        ),
        True,
    )


def accept_join_request(req: GroupJoinRequest, handled_by) -> GroupJoinRequest:
    """审批通过：事务内更新状态并创建成员（get_or_create 幂等）。"""
    with transaction.atomic():
        req.status = GroupJoinRequest.STATUS_ACCEPTED
        req.handled_by = handled_by
        req.handled_at = timezone.now()
        req.save(update_fields=["status", "handled_by", "handled_at"])
        ConversationMember.objects.get_or_create(
            conversation=req.conversation,
            user=req.applicant,
            defaults={"role": ConversationMember.ROLE_MEMBER},
        )
    return req


def reject_join_request(req: GroupJoinRequest, handled_by) -> GroupJoinRequest:
    """审批拒绝：仅更新状态，不建成员。"""
    req.status = GroupJoinRequest.STATUS_REJECTED
    req.handled_by = handled_by
    req.handled_at = timezone.now()
    req.save(update_fields=["status", "handled_by", "handled_at"])
    return req


def create_group_invite(inviter, conversation, invitee) -> tuple:
    """群成员邀请入群（幂等）：同 (conversation, inviter, invitee) pending 复用。

    返回 (GroupInvite, created: bool)。
    """
    existing = GroupInvite.objects.filter(
        conversation=conversation,
        inviter=inviter,
        invitee=invitee,
        status=GroupInvite.STATUS_PENDING,
    ).first()
    if existing is not None:
        return existing, False
    return (
        GroupInvite.objects.create(
            conversation=conversation, inviter=inviter, invitee=invitee
        ),
        True,
    )


def accept_group_invite(inv: GroupInvite, handled_by) -> GroupInvite:
    """接受邀请：事务内更新状态并创建成员（get_or_create 幂等）。"""
    with transaction.atomic():
        inv.status = GroupInvite.STATUS_ACCEPTED
        inv.handled_at = timezone.now()
        inv.save(update_fields=["status", "handled_at"])
        ConversationMember.objects.get_or_create(
            conversation=inv.conversation,
            user=inv.invitee,
            defaults={"role": ConversationMember.ROLE_MEMBER},
        )
    return inv


def reject_group_invite(inv: GroupInvite, handled_by) -> GroupInvite:
    """拒绝邀请：仅更新状态，不建成员。"""
    inv.status = GroupInvite.STATUS_REJECTED
    inv.handled_at = timezone.now()
    inv.save(update_fields=["status", "handled_at"])
    return inv


# ---------- 用户级广播（S2：申请处理 / 新邀请通知） ----------
#
# 申请人/被邀请人未必是会话成员（订阅不到 chat_conv_* 组），所以走
# `chat_user_<user_id>` 用户级组。ChatConsumer connect 时加入该组（见 consumers.py）。

def _user_group_send_sync(user_id, event: dict) -> None:
    """同步向用户级组广播，捕获 ChannelFull 不抛断。"""
    from channels.layers import get_channel_layer

    layer = get_channel_layer()
    if layer is None:
        return
    try:
        async_to_sync(layer.group_send)(f"chat_user_{user_id}", event)
    except ChannelFull:
        logger.warning("channel full, dropping user event for user %s", user_id)
    except Exception:
        logger.exception("user group_send failed for user %s", user_id)


async def _user_group_send_async(user_id, event: dict) -> None:
    """异步向用户级组广播，捕获 ChannelFull 不抛断。"""
    from channels.layers import get_channel_layer

    layer = get_channel_layer()
    if layer is None:
        return
    try:
        await layer.group_send(f"chat_user_{user_id}", event)
    except ChannelFull:
        logger.warning("channel full, dropping user event for user %s", user_id)
    except Exception:
        logger.exception("user group_send failed for user %s", user_id)


def broadcast_group_request_resolved(
    user_id,
    *,
    request_id,
    conversation_id,
    conversation_title,
    status,
    handled_by_id,
    handled_at,
) -> None:
    """申请被处理 → 推给申请人（同步版）。"""
    _user_group_send_sync(
        user_id,
        {
            "type": "group.request.resolved",
            "request_id": str(request_id),
            "conversation_id": str(conversation_id),
            "conversation_title": conversation_title,
            "status": status,
            "handled_by_id": str(handled_by_id),
            "handled_at": handled_at.isoformat() if handled_at else None,
        },
    )


async def abroadcast_group_request_resolved(
    user_id,
    *,
    request_id,
    conversation_id,
    conversation_title,
    status,
    handled_by_id,
    handled_at,
) -> None:
    """申请被处理 → 推给申请人（异步版，WS/测试用）。"""
    await _user_group_send_async(
        user_id,
        {
            "type": "group.request.resolved",
            "request_id": str(request_id),
            "conversation_id": str(conversation_id),
            "conversation_title": conversation_title,
            "status": status,
            "handled_by_id": str(handled_by_id),
            "handled_at": handled_at.isoformat() if handled_at else None,
        },
    )


def broadcast_group_invite_new(
    user_id,
    *,
    invite_id,
    conversation_id,
    conversation_title,
    inviter_id,
    inviter_name,
    created_at,
) -> None:
    """新邀请 → 推给被邀请人（同步版）。"""
    _user_group_send_sync(
        user_id,
        {
            "type": "group.invite.new",
            "invite_id": str(invite_id),
            "conversation_id": str(conversation_id),
            "conversation_title": conversation_title,
            "inviter_id": str(inviter_id),
            "inviter_name": inviter_name,
            "created_at": created_at.isoformat() if created_at else None,
        },
    )


async def abroadcast_group_invite_new(
    user_id,
    *,
    invite_id,
    conversation_id,
    conversation_title,
    inviter_id,
    inviter_name,
    created_at,
) -> None:
    """新邀请 → 推给被邀请人（异步版，WS/测试用）。"""
    await _user_group_send_async(
        user_id,
        {
            "type": "group.invite.new",
            "invite_id": str(invite_id),
            "conversation_id": str(conversation_id),
            "conversation_title": conversation_title,
            "inviter_id": str(inviter_id),
            "inviter_name": inviter_name,
            "created_at": created_at.isoformat() if created_at else None,
        },
    )
