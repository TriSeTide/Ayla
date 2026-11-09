"""
Ayla 通道 WebSocket Consumer（D-3，REQUIREMENTS.zh.md §6/§7/§10）。

连接：`/ws/elysia-bridge/?token=<access_jwt>`（DSH 主动拨入，Ayla 不开新认证方式）。
JWT 解析**复用** `apps/accounts/consumers.py` 的 `_jwt_user_from_scope`，不复制实现。

鉴权两段：
1. JWT 无效 → close(4401)（沿用既有 WS 约定）；
2. 该 user 不是某个 `enabled=True` 的 ElysiaProfile.user → close(4403)
   （不是爱莉账号不得占用通道，§6）。

协议（§7，JSON 文本帧，全部带 `v` 与 `type`）：

| 入站（DSH → Ayla） | 处理 |
|---|---|
| `ping` | 回 `pong`（服务端不做主动超时，心跳由 DSH 负责，§7.3） |
| `resume{seq}` | 从 `seq+1` 起重投 pending 的 outbox 行，按 seq 升序 |
| `ack{seq}` | 把 `seq ≤ N` 的 pending 置 `delivered` |
| `reply{...}` | 校验会话 + 类型 → 幂等落库 → 广播一次 → 回 `sent` |

| 出站（Ayla → DSH） | 含义 |
|---|---|
| `inbound{seq,message}` | 一条用户消息（§7.1） |
| `sent{client_message_id,message_id,seq}` | reply 已落库（§7.2） |
| `error{client_message_id,code,detail}` | reply 被拒（§7.2） |
| `pong` | 心跳应答 |

单实例语义（§10）：同一 profile 只允许一条活跃连接，新连接顶替旧连接并**记一行日志**。
做法是每个 profile 一个 channel group，连接时 group_send 一个 `ayla.bridge.replaced`
事件让旧连接自己关闭——多 daphne 进程下同样成立（组在 channel layer 里，不在进程内）。

硬约束：本 consumer 不在事件循环线程做阻塞 ORM——所有 DB 访问都经
`database_sync_to_async` 卸载到线程池；广播一律 `await layer.group_send`，
不用 `async_to_sync`（InMemory layer 跨事件循环会丢事件）。
"""
import logging

from channels.db import database_sync_to_async
from channels.generic.websocket import AsyncJsonWebsocketConsumer

from apps.accounts.consumers import _jwt_user_from_scope
from apps.chat.models import Conversation, Message

from . import services

logger = logging.getLogger(__name__)


# ---------- 同步辅助（全部在 database_sync_to_async 线程池里执行） ----------


def _profile_for_user(user):
    """该 user 绑定的**启用** ElysiaProfile（没有则 None）。"""
    from .models import ElysiaProfile

    return (
        ElysiaProfile.objects.select_related("user")
        .filter(user_id=user.id, enabled=True)
        .first()
    )


def _conversation_for_reply(profile, conversation_id):
    """解析 reply 的会话；不存在/成员不含爱莉 → (None, code)。"""
    from apps.chat.models import ConversationMember

    try:
        conv = Conversation.objects.filter(pk=int(conversation_id)).first()
    except (TypeError, ValueError):
        return None, "conversation_not_found"
    if conv is None:
        return None, "conversation_not_found"
    if not ConversationMember.objects.filter(
        conversation=conv, user_id=profile.user_id
    ).exists():
        # 与「不存在」区分开：她自己不在这个会话里，不能代她发话。
        return None, "conversation_not_a_member"
    return conv, ""


def _conversation_type(conv) -> str:
    return str(conv.type)


def _store_reply(
    *, profile, conv, content: str, client_message_id: str, reply_to=None
) -> tuple[Message, bool]:
    """reply 落库（幂等），返回 (消息, 是否本次新建)。

    幂等键按 §9：`"ayla-" + sha256(client_message_id)[:24]`。
    同 client_message_id 第二次到达 → 命中既有消息，**不重复广播**。
    """
    from django.db import IntegrityError

    from apps.chat import services as chat_services

    key = services.idempotency_key_for_client_message(client_message_id)
    existing = chat_services.find_global_by_idempotency_key(key)
    if existing is not None:
        return existing, False
    try:
        message = chat_services.create_message(
            profile.user,
            conv,
            content=content,
            msg_type=Message.TYPE_TEXT,
            reply_to=reply_to,
            idempotency_key=key,
        )
    except IntegrityError:
        # 并发重放：同 client_message_id 的两个 reply 同时到达，后到者撞幂等键
        # 唯一约束。按全局 key 再查一次——已落库就当作「已存在」，不重复广播。
        existing = chat_services.find_global_by_idempotency_key(key)
        if existing is None:
            raise
        return existing, False
    return message, True


def _resolve_reply_target(conv, reply_to):
    """reply_to 必须是本会话内的消息 id（十进制字符串），否则 None。"""
    if reply_to in (None, ""):
        return None
    try:
        return conv.messages.filter(pk=int(reply_to)).first()
    except (TypeError, ValueError):
        return None


async def _group_member_count(layer, group) -> int:
    """异步数一个 group 的活跃成员（RedisChannelLayer 路径）。"""
    import time

    key = layer._group_key(group)  # noqa: SLF001 - 只读探测，无公开 API
    connection = layer.connection(layer.consistent_hash(group))
    cutoff = time.time() - int(getattr(layer, "group_expiry", 86400))
    return int(await connection.zcount(key, cutoff, "+inf"))


def _active_connections(profile_id) -> int:
    """该 profile 的通道当前活跃连接数（health / 探测端点用）。

    通道 group 的成员 = 在线 consumer（连接时 group_add，断开时 group_discard），
    所以「组成员数」就是活跃连接数：

    - InMemoryChannelLayer（测试）：`groups` dict 的成员数；
    - RedisChannelLayer（生产）：`asgi:group:<name>` ZSET 里未过期的成员数
      （score = 加入时间，超过 `group_expiry` 即失效）。

    探测失败返回 0（不猜、不 500）：health 的语义是「现在有没有连接」，
    拿不到证据就不能说「有」。
    """
    from asgiref.sync import async_to_sync
    from channels.layers import get_channel_layer

    layer = get_channel_layer()
    group = services.outbox_group_name(profile_id)
    if layer is None:
        return 0
    try:
        groups = getattr(layer, "groups", None)  # InMemoryChannelLayer
        if isinstance(groups, dict):
            return len(groups.get(group, {}) or {})
        return async_to_sync(_group_member_count)(layer, group)
    except Exception:  # noqa: BLE001 - 探测失败按「无连接」处理，不 500
        logger.warning("ayla bridge active connection probe failed", exc_info=True)
        return 0


class AylaBridgeConsumer(AsyncJsonWebsocketConsumer):
    """Ayla 通道（DSH ↔ Ayla 后端）单条 WS。"""

    async def connect(self):
        self.profile = None
        self.group_name = None
        self.user = await database_sync_to_async(_jwt_user_from_scope)(self.scope)
        if self.user is None:
            await self.close(code=4401)  # 未认证
            return

        self.profile = await database_sync_to_async(_profile_for_user)(self.user)
        if self.profile is None:
            logger.warning(
                "ayla bridge rejected: user %s is not an enabled elysia profile",
                self.user.id,
            )
            await self.close(code=4403)  # 不是爱莉账号
            return

        self.group_name = services.outbox_group_name(self.profile.id)
        # 本条连接上已推过的 seq（避免在线推送重复帧；resume 不受此限制）
        self.pushed_seqs = set()
        await self.accept()
        # 先加入组，再顶替旧连接：保证旧连接即使正在收帧也会先被通知关闭。
        await self.channel_layer.group_add(self.group_name, self.channel_name)
        await self.channel_layer.group_send(
            self.group_name,
            {"type": "ayla.bridge.replaced", "by": self.channel_name},
        )
        logger.info(
            "ayla bridge connected: profile=%s user=%s channel=%s",
            self.profile.id,
            self.user.id,
            self.channel_name,
        )

    async def disconnect(self, code):
        if getattr(self, "group_name", None):
            await self.channel_layer.group_discard(
                self.group_name, self.channel_name
            )
            logger.info(
                "ayla bridge disconnected: profile=%s channel=%s code=%s",
                getattr(getattr(self, "profile", None), "id", None),
                self.channel_name,
                code,
            )

    # ---------- 入站帧（DSH → Ayla） ----------

    async def receive(self, text_data=None, bytes_data=None, **kwargs):
        """单帧上限 1 MiB（§10）：超帧直接断连并记一行，不解析、不投递。"""
        if text_data is not None and len(text_data.encode("utf-8")) > services.MAX_FRAME_BYTES:
            logger.error(
                "ayla bridge frame too large: profile=%s channel=%s > %s bytes; closing",
                getattr(getattr(self, "profile", None), "id", None),
                self.channel_name,
                services.MAX_FRAME_BYTES,
            )
            await self.close(code=4413)
            return
        if bytes_data is not None:
            # 协议是 JSON 文本帧；二进制帧不是本协议的一部分。
            await self._send_error(None, "bad_frame", "仅接受 JSON 文本帧")
            return
        await super().receive(text_data=text_data, bytes_data=bytes_data, **kwargs)

    async def receive_json(self, content, **kwargs):
        if not isinstance(content, dict):
            await self._send_error(None, "bad_frame", "帧必须是 JSON 对象")
            return
        if content.get("v") != services.PROTOCOL_VERSION:
            await self._send_error(
                content.get("client_message_id"),
                "unsupported_version",
                f"仅支持 v={services.PROTOCOL_VERSION}",
            )
            return
        frame_type = content.get("type")
        if frame_type == "ping":
            await self.send_json({"v": services.PROTOCOL_VERSION, "type": "pong"})
        elif frame_type == "resume":
            await self._handle_resume(content)
        elif frame_type == "ack":
            await self._handle_ack(content)
        elif frame_type == "reply":
            await self._handle_reply(content)
        else:
            await self._send_error(
                content.get("client_message_id"),
                "unknown_type",
                f"未知帧类型 {frame_type}",
            )

    async def _handle_resume(self, content):
        """`resume{seq}`：从 seq+1 起重投 pending，按 seq 升序（§7.3）。"""
        seq = _as_int(content.get("seq"), default=None)
        if seq is None:
            await self._send_error(None, "bad_frame", "resume 需要整数 seq")
            return
        # resume 是「重投」：每推一次算一次投递尝试，超过上限置 dead（§9）。
        pushed = await self._drain_pending(seq, count_attempt=True, skip_pushed=False)
        logger.info(
            "ayla bridge resume: profile=%s from seq>%s, %s row(s) replayed",
            self.profile.id,
            seq,
            pushed,
        )

    async def _handle_ack(self, content):
        """`ack{seq}`：seq ≤ N 的 pending 置 delivered（§7.2）。"""
        seq = _as_int(content.get("seq"), default=None)
        if seq is None:
            await self._send_error(None, "bad_frame", "ack 需要整数 seq")
            return
        await database_sync_to_async(services.mark_acked)(seq)

    async def _handle_reply(self, content):
        """`reply{...}`：校验 → 幂等落库 → 广播一次 → 回 `sent`（§7.2/§9）。"""
        client_message_id = str(content.get("client_message_id") or "")
        if not client_message_id:
            await self._send_error(
                None, "bad_frame", "reply 需要 client_message_id"
            )
            return

        conv, code = await database_sync_to_async(_conversation_for_reply)(
            self.profile, content.get("conversation_id")
        )
        if conv is None:
            await self._send_error(client_message_id, code, "会话不存在或爱莉不在该会话")
            return

        # 类型必须与真实类型一致，否则拒绝且**不落库**（§7.2：防止把私聊回复发进群）。
        expected_type = str(content.get("conversation_type") or "")
        if expected_type != _conversation_type(conv):
            await self._send_error(
                client_message_id,
                "conversation_type_mismatch",
                f"会话 {conv.id} 的真实类型是 {conv.type}，帧里是 {expected_type}",
            )
            return

        text = content.get("content")
        if not isinstance(text, str) or not text.strip():
            await self._send_error(client_message_id, "bad_frame", "content 必须是非空字符串")
            return
        if len(text.encode("utf-8")) > services.MAX_TEXT_BYTES:
            await self._send_error(
                client_message_id,
                "content_too_large",
                f"单条文本上限 {services.MAX_TEXT_BYTES} 字节",
            )
            return

        reply_to = await database_sync_to_async(_resolve_reply_target)(
            conv, content.get("reply_to")
        )
        message, created = await database_sync_to_async(_store_reply)(
            profile=self.profile,
            conv=conv,
            content=text,
            client_message_id=client_message_id,
            reply_to=reply_to,
        )
        if created:
            # 广播**一次**：幂等重放（同 client_message_id）不再广播。
            # 不把 message.status 改成 delivered：`sent` 回执只证明 DSH 收到了帧，
            # 不证明会话成员读到了消息——不能把传输事实伪造成送达事实。
            await self._broadcast_message_new(message)
        else:
            logger.info(
                "ayla bridge reply %s already stored as message %s; not rebroadcast",
                client_message_id,
                message.id,
            )
        await self.send_json(
            {
                "v": services.PROTOCOL_VERSION,
                "type": "sent",
                "client_message_id": client_message_id,
                "message_id": str(message.id),
                "seq": message.seq,
            }
        )

    # ---------- 组事件 ----------

    async def ayla_inbound_ready(self, event):
        """有新入站待推（REST 落库后经 group 通知）：读出 pending 并推给 DSH。

        通知本身不带正文（health/日志都不该泄露消息内容），consumer 自己读库。
        读的是「全部 pending」而不是只读 event.seq 那一条：DSH 可能因为上一条
        还没 ack 而漏推，按 seq 升序补齐才是正确语义（§9 断开期间堆积、重连补投）。
        """
        # 只推本条连接上还没推过的行：同一条 pending 在 ack 前重复到达时，
        # 不该把同一帧重复塞给 DSH（去重键在 DSH 侧，但重复帧会掩盖真实积压）。
        # 在线推送不是「重投」：不计投递尝试，避免 DSH 稍慢 ack 时把新消息误判 dead。
        await self._drain_pending(0, count_attempt=False, skip_pushed=True)

    async def ayla_bridge_replaced(self, event):
        """同 profile 的新连接顶替本连接（§10）：关掉旧的，并记一行日志。"""
        if event.get("by") == self.channel_name:
            return
        logger.warning(
            "ayla bridge connection replaced: profile=%s old_channel=%s new_channel=%s",
            getattr(getattr(self, "profile", None), "id", None),
            self.channel_name,
            event.get("by"),
        )
        await self.close(code=4409)

    # ---------- 内部 ----------

    async def _drain_pending(self, from_seq: int, *, count_attempt: bool, skip_pushed: bool) -> int:
        """按 seq 升序把 pending 全部推完（分批，避免一次把内存打满）。

        返回实际推送条数。分页游标用「本批最大 seq」而不是 offset：中途有新消息
        插入时不会漏读（offset 会因新行前移而跳过一条）。
        """
        cursor = from_seq
        pushed = 0
        while True:
            rows = await database_sync_to_async(services.pending_after)(cursor)
            rows = [row for row in rows if row.seq > cursor]
            if not rows:
                return pushed
            cursor = rows[-1].seq
            batch = (
                [row for row in rows if row.seq not in self.pushed_seqs]
                if skip_pushed
                else rows
            )
            await self._push_rows(batch, count_attempt=count_attempt)
            pushed += len(batch)
            if len(rows) < services.PUSH_BATCH_SIZE:
                return pushed

    async def _push_rows(self, rows, *, count_attempt: bool):
        """把一批 outbox 行推成 inbound 帧（按 seq 升序）。

        `count_attempt=True`（resume 重投）时才累加 attempts：只有「重连后再次
        投递」才算重投；在线首推不算，否则 DSH 稍慢 ack 就会把新消息误判 dead。
        """
        if not rows:
            return
        for row in rows:
            frame = await database_sync_to_async(services.build_inbound_frame)(row)
            await self.send_json(frame)
            self.pushed_seqs.add(row.seq)
        if count_attempt:
            await database_sync_to_async(services.note_delivery_attempt)(rows)

    async def _broadcast_message_new(self, message):
        """把爱莉的出站消息广播给会话成员（与 REST 落库后同一条链路，只发一次）。"""
        from apps.chat import services as chat_services

        await database_sync_to_async(chat_services.broadcast_message_new)(message)

    async def _send_error(self, client_message_id, code, detail):
        await self.send_json(
            {
                "v": services.PROTOCOL_VERSION,
                "type": "error",
                "client_message_id": client_message_id,
                "code": code,
                "detail": detail,
            }
        )


def _as_int(value, default=None):
    """宽松整数解析：只接受整数（不接受 "12abc" 这类半解析结果）。"""
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


__all__ = ["AylaBridgeConsumer"]