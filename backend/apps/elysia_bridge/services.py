"""
elysia_bridge.services —— 爱莉桥接领域逻辑。

旧爱莉桥接（SSE 出站投影 / service credential / messages:inject / Voice Live
编排）已按 REQUIREMENTS.zh.md §13 整体删除（协议已不存在）。本模块保留通道契约
仍然需要的部分：

- 领域异常 BridgeError / ProfileNotConfigured（views.py 模块级 import）；
- broadcast_elysia_profile_updated：爱莉 profile 变更广播；
- **D-3 通道投递**（REQUIREMENTS.zh.md §7/§9/§10）：入站 outbox 登记、帧构造、
  ack 推进、补投查询与「有新消息」的在线通知。WS 连接与帧收发在 consumers.py。

主体性铁律（AGENTS.md §4.1）：爱莉消息内容只能来自她自己的意识实例，
应用侧代码绝不生成爱莉的第一人称内容。本模块只做传输结构投影——
不按关键词分类、不改写正文、不因「像闲聊」就不入账。
"""
from __future__ import annotations

import hashlib
import logging

from django.db import transaction
from django.utils import timezone

logger = logging.getLogger(__name__)

# 协议版本（REQUIREMENTS.zh.md §7：所有帧带 v，当前 1）
PROTOCOL_VERSION = 1

# 单帧上限 1 MiB（§10）：超帧直接断连并记一行。
MAX_FRAME_BYTES = 1024 * 1024
# 单条文本上限 32 KiB（§10）：入站超限标 failed，出站回 error。
MAX_TEXT_BYTES = 32 * 1024
# 重投上限（§9）：超过则置 dead，保留现场等人工处置，不静默丢弃。
MAX_DELIVERY_ATTEMPTS = 10
# 一次补投最多取多少行（避免一次连接把内存打满）
PUSH_BATCH_SIZE = 50
# 每个 profile 一个 channel group：用于「有新消息了，在线 consumer 去推」。
CHANNEL_GROUP_PREFIX = "ayla_bridge_"


class BridgeError(Exception):
    """桥接领域错误。"""


class ProfileNotConfigured(BridgeError):
    """尚未配置爱莉 profile（保留为通道领域错误，新入站/探测链路复用）。"""


# ---------- 2026-10-25 补齐：爱莉 profile 变更广播 ----------
#
# 背景（用户规则：符合常理的热更新都要有）：爱莉的头像 / 昵称 / 启用状态变化后，
# 所有显示她的地方（会话列表的爱莉入口、私聊顶栏、语音面板、主页爱莉卡）都应更新。
# 此前只有 REST，改完要刷新才看到。


def broadcast_elysia_profile_updated(profile) -> None:
    """爱莉 profile 变更 → 广播给**所有在线用户**（presence 组，全站可见的事实）。

    投递面刻意收窄：只带公开展示字段（绑定 user_id / 启用位），
    不带凭据等运维信息。
    """
    from channels.layers import get_channel_layer

    if get_channel_layer() is None:
        return
    try:
        from asgiref.sync import async_to_sync

        async_to_sync(get_channel_layer().group_send)(
            "presence",
            {
                "type": "elysia.profile.updated",
                "user_id": str(profile.user_id) if profile.user_id else None,
                "enabled": bool(getattr(profile, "enabled", False)),
            },
        )
    except Exception:  # noqa: BLE001 - 广播失败不阻断保存
        import logging

        logging.getLogger(__name__).exception("elysia.profile.updated broadcast failed")


# ---------- D-3：入站 outbox 登记与帧构造（REQUIREMENTS.zh.md §7/§9） ----------
#
# 本段只做「传输结构」投影：把一条已落库的 Message 变成 DSH 能消费的 inbound 帧。
# 不做任何认知判断（不按关键词分类、不改写正文、不丢未知部分）。


def _text_bytes(text: str) -> int:
    """按 UTF-8 字节数计长（§10 的 32 KiB 是字节上限，不是字符数）。"""
    return len((text or "").encode("utf-8"))


def _sender_name(message) -> str:
    """发送者显示名（nickname || username）；仅用于 UI，不承载任何主体语义。"""
    sender = getattr(message, "sender", None)
    if sender is None:
        return ""
    return getattr(sender, "nickname", "") or getattr(sender, "username", "") or ""


def _mention_display_name(segment) -> str:
    """@ 段的显示名（与 chat.serializers 的预览规则一致：昵称 → 用户名 → 未知用户）。"""
    user_id = segment.get("user_id")
    if not user_id:
        return "未知用户"
    from django.contrib.auth import get_user_model

    user = get_user_model().objects.filter(pk=user_id).first()
    if user is None:
        return "未知用户"
    return getattr(user, "nickname", "") or user.username or "未知用户"


def _conversation_type(conversation) -> str:
    """Ayla 会话类型 → 帧里的 conversation_type（private / group）。"""
    return str(conversation.type)


def build_inbound_parts(message) -> list[dict]:
    """把一条消息投影成帧的 `parts`（§7.1：保持平台原顺序，只接受 text/image）。

    未知类型（voice/file/video/emoji/share/poke/system）**不在这里丢弃**：
    它们在 `unsupported_parts()` 里被识别，整条消息标 failed，而不是只投文字
    ——丢部分等于伪造她收全了（§7.1）。
    """
    parts: list[dict] = []
    if message.type == "mixed" and message.segments:
        for seg in message.segments:
            seg_type = seg.get("type")
            if seg_type == "text":
                parts.append({"type": "text", "text": seg.get("text", "")})
            elif seg_type == "image":
                parts.append({"type": "image", "media_id": seg.get("media_id")})
            elif seg_type == "mention":
                # @ 段在应用 UI 里就显示成 "@昵称"（serializer 的预览同一规则）。
                # 这里同样展开成文本段，而不是丢掉：丢掉等于让 DSH 看不见她
                # 被谁 @ 了，属于「只投递了未声明的节选」。
                parts.append({"type": "text", "text": f"@{_mention_display_name(seg)}"})
            else:
                # 未知段类型：保留占位，交由 unsupported_parts() 判定整条不可投递。
                parts.append({"type": seg_type})
    elif message.type == "text":
        parts.append({"type": "text", "text": message.content or ""})
    elif message.type == "image":
        parts.append({"type": "image", "media_id": message.media_id})
    else:
        parts.append({"type": message.type})
    return parts


# §7.1 明确支持的 part 类型；其余类型整条不可投递。
SUPPORTED_PART_TYPES = frozenset({"text", "image"})


def unsupported_parts(message) -> list[str]:
    """返回该消息里不可投递的 part 类型（空列表 = 整条可投递）。"""
    return [
        str(part.get("type"))
        for part in build_inbound_parts(message)
        if part.get("type") not in SUPPORTED_PART_TYPES
    ]


def build_inbound_message(message) -> dict:
    """帧里的 `message` 对象（§7.1 字段名必须与需求一致）。"""
    return {
        "id": str(message.id),
        "conversation_id": str(message.conversation_id),
        "conversation_type": _conversation_type(message.conversation),
        "sender_id": str(message.sender_id),
        "sender_name": _sender_name(message),
        "sent_at": message.created_at.isoformat(),
        "parts": build_inbound_parts(message),
    }


def build_inbound_frame(outbox_row) -> dict:
    """一条 outbox 行 → `inbound` 帧（§7.1）。"""
    return {
        "v": PROTOCOL_VERSION,
        "type": "inbound",
        "seq": outbox_row.seq,
        "message": build_inbound_message(outbox_row.message),
    }


def enqueue_for_delivery(message) -> object | None:
    """把一条**用户发给爱莉**的消息登记进通道 outbox（D-3，同事务）。

    返回 outbox 行；不属于爱莉通道的消息返回 None（不登记、不报错）。

    判定只有两条，都不是认知裁决：
    1. 该会话里有启用的 ElysiaProfile（对端是爱莉）；
    2. 发送者不是爱莉本人（她自己说的话不是给她的输入）。

    超过 32 KiB 或含不可投递 part 的消息仍**登记**，但直接置 `failed` 并记录原因：
    §9 要求「失败必须显式报告」，不能因为投不出去就假装它没发生过。
    """
    from .models import AylaInboundOutbox, enqueue_inbound

    profile = profile_for_message(message)
    if profile is None:
        return None
    if message.sender_id == profile.user_id:
        return None
    if message.type in ("poke", "system"):
        # 轻互动/系统消息不是给她的输入（与旧 on_user_message_to_elysia 语义一致）。
        return None

    existing = AylaInboundOutbox.objects.filter(message_id=message.id).first()
    if existing is not None:
        # 幂等重放（同 idempotency_key 的消息被再次投递）：已登记过就返回原行，
        # 不重复取号、不撞 message 的 OneToOne 唯一约束。
        return existing

    with transaction.atomic():
        row = enqueue_inbound(message)
        reason = _undeliverable_reason(message)
        if reason:
            row.status = AylaInboundOutbox.STATUS_FAILED
            row.last_error = reason
            row.save(update_fields=["status", "last_error", "updated_at"])
            logger.warning(
                "ayla inbound message %s not deliverable: %s", message.id, reason
            )
    return row


def _undeliverable_reason(message) -> str:
    """该消息为什么不可投递（空串 = 可投递）。§7.1 / §10 的硬约束。"""
    unsupported = unsupported_parts(message)
    if unsupported:
        return f"unsupported parts: {','.join(unsupported)}"
    text = "".join(
        part.get("text", "")
        for part in build_inbound_parts(message)
        if part.get("type") == "text"
    )
    if _text_bytes(text) > MAX_TEXT_BYTES:
        return f"text too large: {_text_bytes(text)} bytes > {MAX_TEXT_BYTES}"
    return ""


def profile_for_message(message):
    """该消息所属会话里的启用 ElysiaProfile（没有则 None）。

    私聊：对端是爱莉；群聊：任一成员是爱莉（与旧实现同语义）。
    """
    from .models import ElysiaProfile

    member_ids = list(
        message.conversation.members.values_list("user_id", flat=True)
    )
    return (
        ElysiaProfile.objects.select_related("user")
        .filter(user_id__in=member_ids, enabled=True)
        .first()
    )


def pending_after(seq: int, limit: int = PUSH_BATCH_SIZE) -> list:
    """`resume` 用：seq > 给定值、仍 pending 的行，按 seq 升序（§7.3）。"""
    from .models import AylaInboundOutbox

    return list(
        AylaInboundOutbox.objects.filter(
            status=AylaInboundOutbox.STATUS_PENDING, seq__gt=seq
        )
        .select_related("message", "message__sender", "message__conversation")
        .order_by("seq")[:limit]
    )


def pending_count() -> int:
    """待投递条数（health 用，不泄露正文）。"""
    from .models import AylaInboundOutbox

    return AylaInboundOutbox.objects.filter(
        status=AylaInboundOutbox.STATUS_PENDING
    ).count()


def mark_acked(seq: int) -> int:
    """`ack{seq}`：把 seq ≤ N 的 pending 置 delivered，返回推进条数（§7.2）。"""
    from .models import AylaInboundOutbox

    updated = AylaInboundOutbox.objects.filter(
        status=AylaInboundOutbox.STATUS_PENDING, seq__lte=seq
    ).update(status=AylaInboundOutbox.STATUS_DELIVERED, updated_at=timezone.now())
    if updated:
        logger.info("ayla bridge ack: %s inbound row(s) <= seq %s delivered", updated, seq)
    return updated


def note_delivery_attempt(rows) -> None:
    """重投计数：attempts +1，超过上限置 dead（保留现场，§9）。

    只有 `resume`（重连后重投）会调用它；在线首推不算重投，否则 DSH 稍慢 ack
    就会把刚发出的新消息误判成 dead。
    """
    from .models import AylaInboundOutbox

    if not rows:
        return
    # 逐行更新：需要按 attempts 判定 dead，批量 update 无法表达该条件。
    for row in rows:
        attempts = (row.attempts or 0) + 1
        fields = ["attempts", "updated_at"]
        row.attempts = attempts
        if attempts >= MAX_DELIVERY_ATTEMPTS:
            row.status = AylaInboundOutbox.STATUS_DEAD
            row.last_error = (
                row.last_error or f"delivery not acked after {attempts} attempts"
            )
            fields += ["status", "last_error"]
            logger.error(
                "ayla inbound seq %s marked dead after %s attempts (message %s)",
                row.seq,
                attempts,
                row.message_id,
            )
        row.save(update_fields=fields)


def outbox_group_name(profile_id) -> str:
    """该 profile 的通道 group（在线 consumer 加入它接收「有新消息」通知）。"""
    return f"{CHANNEL_GROUP_PREFIX}{profile_id}"


def notify_inbound_ready(profile_id, seq: int) -> None:
    """通知在线 consumer「有新入站待推」（不携带正文，正文由 consumer 自己读库）。

    在**同步**上下文（REST 视图）里调用；广播失败只记日志，绝不阻塞消息落库。
    """
    from channels.layers import get_channel_layer

    layer = get_channel_layer()
    if layer is None:
        return
    try:
        from asgiref.sync import async_to_sync

        async_to_sync(layer.group_send)(
            outbox_group_name(profile_id),
            {"type": "ayla.inbound.ready", "seq": seq},
        )
    except Exception:  # noqa: BLE001 - 通知失败由下一次 resume/重连兜底
        logger.exception("ayla inbound ready notify failed (profile=%s)", profile_id)


def idempotency_key_for_client_message(client_message_id: str) -> str:
    """`reply` 的幂等键：`"ayla-" + sha256(id)[:24]`（§9，≤64 字符）。"""
    digest = hashlib.sha256((client_message_id or "").encode("utf-8")).hexdigest()
    return f"ayla-{digest[:24]}"


# ---------- 用户规则一 + 二：新账号默认已是爱莉的好友，并默认有一条私聊会话 ----------
#
# 用户（TriSeTide）定的三条规则（2026-11-11）：
#   1. 所有账号默认有爱莉的好友；
#   2. 消息列表默认有爱莉的聊天会话；
#   3. ElyH 连上 Ayla 时爱莉在线（见 accounts.presence 的 ElyH 段）。
#
# 这里刻意**不引入任何「爱莉专属入口」**：爱莉就是一个普通 user（username=elysia，
# ElysiaProfile 绑定），注册后按普通好友 + 普通私聊处理，前端照常渲染。
#
# 为什么放在 elysia_bridge 而不是 accounts：目标（爱莉身份）由 ElysiaProfile 定义，
# 该模型的 owner 是本 app；accounts 只调用，不反向依赖桥接模型的语义。


def elysia_user():
    """返回启用的爱莉应用内 User；没有绑定 / profile 被禁用 / user 失效 → None。

    只认 `ElysiaProfile(enabled=True)` 绑定的 user，不按 username 猜——
    账号可以被改名，用户名不是身份契约。
    """
    from .models import ElysiaProfile

    profile = (
        ElysiaProfile.objects.select_related("user")
        .filter(enabled=True, user__is_active=True)
        .order_by("id")
        .first()
    )
    return profile.user if profile is not None else None


def ensure_elysia_relationship(user) -> bool:
    """让 user 与爱莉互为好友，并确保存在一条私聊会话。幂等。

    返回 True 表示本次已确保（含"本来就有"），False 表示**未处理**（爱莉
    profile 缺失/禁用，或 user 本身无效）。这两类是预期内的降级：只记一行
    warning 日志，不抛异常。

    但**数据库错误不被吞**：`update_or_create` / `get_or_create_conversation`
    的真实失败会向上抛，由调用方决定——`RegisterView` 用 try/except 兜住
    （账号已经建好了，关系补齐失败不该把 201 变成 500）。吞掉 DB 错误会让
    "以为补齐了、其实没有"变成静默数据缺陷（AGENTS.md §8）。

    幂等实现（全部是可安全重复的写法）：
    - Friendship 用 `update_or_create`，DB 层 `unique_together(user, friend)`
      兜底并发；status 统一 accepted（双向各一条，与 FriendRequestActionView
      accept 的写入形状一致）；
    - 会话复用 `chat.services.get_or_create_conversation`——**不在此重写建会话逻辑**
      （私聊"同两人只有一个会话"的幂等规则只允许有一份实现）。
    """
    if user is None or not getattr(user, "pk", None):
        logger.warning("ensure_elysia_relationship skipped: invalid user")
        return False
    elysia = elysia_user()
    if elysia is None:
        # 静默跳过 + 一行日志：测试库/新部署里爱莉可能还没建，注册不能因此失败。
        logger.warning(
            "ensure_elysia_relationship skipped for user=%s: no enabled elysia profile",
            getattr(user, "pk", None),
        )
        return False
    if str(elysia.pk) == str(user.pk):
        # 爱莉自己不需要和自己做朋友。
        return False

    from apps.accounts.models import Friendship
    from apps.chat import services as chat_services

    for owner, friend in ((user, elysia), (elysia, user)):
        Friendship.objects.update_or_create(
            user=owner,
            friend=friend,
            defaults={"status": Friendship.STATUS_ACCEPTED},
        )
    chat_services.get_or_create_conversation(user, elysia)
    return True


__all__ = [
    "ensure_elysia_relationship",
    "elysia_user",
    "BridgeError",
    "ProfileNotConfigured",
    "broadcast_elysia_profile_updated",
    "PROTOCOL_VERSION",
    "MAX_FRAME_BYTES",
    "MAX_TEXT_BYTES",
    "MAX_DELIVERY_ATTEMPTS",
    "PUSH_BATCH_SIZE",
    "SUPPORTED_PART_TYPES",
    "build_inbound_frame",
    "build_inbound_message",
    "build_inbound_parts",
    "unsupported_parts",
    "enqueue_for_delivery",
    "profile_for_message",
    "pending_after",
    "pending_count",
    "mark_acked",
    "note_delivery_attempt",
    "outbox_group_name",
    "notify_inbound_ready",
    "idempotency_key_for_client_message",
]
