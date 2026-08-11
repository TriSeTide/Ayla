"""
elysia_bridge.services —— 爱莉桥接核心领域逻辑（供 REST / run_bridge 命令共用）。

职责（步骤文件 §4 / §5）：
- 凭据/会话管理：加载一次性 secret → 换 session → 自动 refresh → 失效恢复；
- 入站 inject：用户给爱莉发消息 → 应用内消息落库 → POST /chat/messages:inject
  （带 sender_id 回显来源，platform="elysia-app"）；
- 出站投影：SSE 收到 chat.message.* 且 stream 匹配 → 定位应用内会话 →
  幂等落库（key=elysia-<event_id>）→ 广播 elysia.reply；
- 出站路由：从 reply_target/correlation/payload 找回显 sender_id，匹配不到
  降级到 profile 默认会话 + warning（不静默丢弃）。

主体性铁律（AGENTS.md §4.1）：爱莉消息内容只来自出站事件投影，应用侧代码
绝不生成爱莉的第一人称内容。本模块只做「事件 → 应用内消息」的投影与转发，
不构造爱莉的发言文本。
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping, Sequence

from asgiref.sync import async_to_sync
from channels.db import database_sync_to_async
from channels.exceptions import ChannelFull
from channels.layers import get_channel_layer
from django.contrib.auth import get_user_model
from django.db import IntegrityError
from django.utils import timezone

from apps.chat import services as chat_services
from apps.chat.models import Conversation, Message
from apps.elysia_bridge.elysia_client import (
    ElysiaClient,
    ElysiaHistoryGap,
    ElysiaTransportError,
    ElysiaUnauthenticated,
    EventEnvelope,
)
from apps.elysia_bridge.models import ElysiaProfile

logger = logging.getLogger(__name__)

User = get_user_model()

# 平台服务 audience（阶段三 policy.py PLATFORM_SERVICE_AUDIENCE）
PLATFORM_SERVICE_AUDIENCE = "elysium-platform-service"

# 应用侧最小 scope 集（阶段三 ALL_EXPORTED_SCOPES）
REQUIRED_SCOPES = ("chat:write", "events:read")
# SSE 订阅事件类型前缀（chat.py _MESSAGE_FACTS）
SSE_EVENT_TYPES = ("chat.message",)


class BridgeError(Exception):
    """桥接领域错误。"""


class ProfileNotConfigured(BridgeError):
    """尚未配置爱莉 profile。"""


# ---------- 凭据 / 会话管理 ----------

@dataclass
class CredentialState:
    """运行期凭据状态（内存，不落库明文）。"""

    credential_id: str
    service_secret: str  # 一次性 secret；创建后立刻落盘本机配置
    access_token: str = ""
    refresh_token: str = ""
    audience: str = PLATFORM_SERVICE_AUDIENCE


class ElysiaCredentialManager:
    """凭据/session 生命周期管理。

    存储策略（步骤文件 §4.4 / §10）：secret 一次性落盘到本机配置文件
    （Git 忽略，不提交仓库）；access/refresh token 只保存在内存，重启后
    用 secret 重新换 session。
    """

    def __init__(
        self,
        *,
        client: ElysiaClient,
        secret_path: str | Path | None = None,
        actor_id: str = "elysia-app",
    ) -> None:
        self._client = client
        self._secret_path = Path(secret_path) if secret_path else None
        self._actor_id = actor_id
        self._state: CredentialState | None = None
        self._lock = threading.RLock()

    # ---------- 存储 ----------

    def _load_secret(self) -> str | None:
        if self._secret_path is None or not self._secret_path.exists():
            return None
        try:
            data = json.loads(self._secret_path.read_text(encoding="utf-8"))
            return str(data.get("service_secret") or "")
        except (OSError, ValueError):
            logger.exception("failed to read elysia credential file")
            return None

    def save_secret(self, *, credential_id: str, service_secret: str) -> None:
        """一次性 secret 立刻落盘（本机配置）。"""
        if self._secret_path is None:
            raise BridgeError("credential secret path not configured")
        self._secret_path.parent.mkdir(parents=True, exist_ok=True)
        # 0600：只有本机用户可读
        self._secret_path.write_text(
            json.dumps(
                {"credential_id": credential_id, "service_secret": service_secret},
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        try:
            os.chmod(self._secret_path, 0o600)
        except OSError:
            pass  # Windows 无 POSIX 权限；尽力而为

    # ---------- 会话 ----------

    def ensure_session(self, *, stream_id: str) -> str:
        """确保存在有效 access token，返回它；必要时重新换 session。

        优先用内存 token；refresh 失败/凭据撤销 → 用落盘 secret 重新换 session
        （恢复流程，对应 401/credential_revoked）。
        """
        with self._lock:
            if self._state is not None and self._state.access_token:
                return self._state.access_token
            return self._reissue(stream_id=stream_id)

    def _reissue(self, *, stream_id: str) -> str:
        secret = self._load_secret() if self._state is None else self._state.service_secret
        if not secret:
            raise ProfileNotConfigured(
                "未找到 Elysium service credential；请先初始化凭据"
            )
        tokens = self._client.issue_session(
            service_credential=secret,
            audience=PLATFORM_SERVICE_AUDIENCE,
        )
        if self._state is None:
            self._state = CredentialState(
                credential_id=self._load_credential_id(),
                service_secret=secret,
            )
        self._state.access_token = tokens.access_token
        self._state.refresh_token = tokens.refresh_token
        return tokens.access_token

    def _load_credential_id(self) -> str:
        if self._secret_path is not None and self._secret_path.exists():
            try:
                data = json.loads(self._secret_path.read_text(encoding="utf-8"))
                return str(data.get("credential_id") or "")
            except (OSError, ValueError):
                pass
        return ""

    def refresh(self) -> str:
        """在 access 过期前主动 refresh（轮换 token 对）。"""
        with self._lock:
            if self._state is None or not self._state.refresh_token:
                raise ProfileNotConfigured("no refresh token to refresh")
            tokens = self._client.refresh_session(
                refresh_token=self._state.refresh_token
            )
            self._state.access_token = tokens.access_token
            self._state.refresh_token = tokens.refresh_token
            return tokens.access_token


# ---------- 出站路由 ----------

def _extract_sender_id(envelope: EventEnvelope) -> str | None:
    """从出站事件里找应用内 sender_id 回显。

    优先级（步骤文件 §5.2）：
    1. payload.metadata.sender_id；
    2. payload.metadata 里嵌套 dict 的 sender_id；
    3. correlation_id / causation_id 若形如 `elysia:<user_id>` 之类。
    返回 None 表示无法回显。
    """
    payload = envelope.payload or {}
    metadata = payload.get("metadata")
    if isinstance(metadata, Mapping):
        for key in ("sender_id", "user_id", "actor_id"):
            value = metadata.get(key)
            if isinstance(value, str) and value:
                return value
    # 嵌套 dict 兜底
    for value in (payload.get("metadata"), payload.get("content_ref")):
        if isinstance(value, Mapping):
            for key in ("sender_id", "user_id", "actor_id"):
                raw = value.get(key)
                if isinstance(raw, str) and raw:
                    return raw
    # correlation / causation 回显（形如 `elysia:<user_id>` / 纯数字应用内 user id）
    for cid in (envelope.correlation_id, envelope.causation_id):
        if not cid:
            continue
        if cid.startswith("elysia:"):
            return cid.split(":", 1)[1]
        if cid.isdigit():
            return cid
    return None


def _resolve_conversation_for_envelope(
    profile: ElysiaProfile, envelope: EventEnvelope
) -> Conversation | None:
    """把出站事件路由到应用内 conversation。

    - 优先 payload 回显的 sender_id → 找该用户与爱莉的私聊会话；
    - 匹配不到 → 降级：返回爱莉 profile 绑定的 user 的「默认会话」
      （若只有一个用户与爱莉私聊过则取它；否则 None，调用方记 warning）。
    """
    sender_id = _extract_sender_id(envelope)
    if sender_id:
        try:
            user = User.objects.get(pk=sender_id)
        except (User.DoesNotExist, ValueError):
            user = None
        if user is not None and user.id != profile.user_id:
            conv = chat_services.get_or_create_conversation(user, profile.user)
            if conv is not None:
                return conv
    # 降级：profile.user 参与的私聊会话里，取最近的一个（不静默丢弃，记 warning）
    fallback = (
        Conversation.objects.filter(
            type=Conversation.TYPE_PRIVATE, members__user=profile.user
        )
        .distinct()
        .order_by("-created_at")
        .first()
    )
    if fallback is not None:
        logger.warning(
            "elysia reply %s (stream=%s) has no resolvable sender, "
            "falling back to most recent private conversation %s",
            envelope.event_id,
            envelope.stream_id,
            fallback.id,
        )
    return fallback


def _reply_event(message: Message, envelope: EventEnvelope) -> dict[str, Any]:
    """构造 elysia.reply 广播事件（M4-2 协议命名）。"""
    return {
        "type": "elysia.reply",
        "conversation_id": str(message.conversation_id),
        "message_id": str(message.id),
        "sender_id": message.sender_id,
        "content": message.content,
        "msg_type": message.type,
        "seq": message.seq,
        "event_id": envelope.event_id,
        "ts": message.created_at.isoformat(),
    }


def project_elysia_reply(profile: ElysiaProfile, envelope: EventEnvelope) -> Message | None:
    """把出站事件投影为应用内消息（幂等）并广播 elysia.reply（同步版）。

    幂等键：`elysia-<event_id>`（SSE 重放不重复落库）。
    返回落库/已存在的消息；无法定位会话时返回 None（调用方记 warning）。
    """
    message = _project_into_message(profile, envelope)
    if message is not None:
        _group_send_sync(message.conversation_id, _reply_event(message, envelope))
    return message


async def aproject_elysia_reply(
    profile: ElysiaProfile, envelope: EventEnvelope
) -> Message | None:
    """异步版：供 run_bridge（asyncio 事件循环）与 async 测试使用。

    DB 侧工作（路由+落库）经 database_sync_to_async 卸载到线程池，避免在
    事件循环线程做 ORM；广播在 async 上下文直接 await group_send，与 M4-2
    abroadcast_* 同语义（InMemory layer 跨事件循环会丢消息，因此同步版
    async_to_sync 广播不能用于 async 测试/后台循环）。
    """
    message = await database_sync_to_async(_project_into_message)(profile, envelope)
    if message is not None:
        event = _reply_event(message, envelope)
        await _group_send_async(message.conversation_id, event)
    return message


def _project_into_message(
    profile: ElysiaProfile, envelope: EventEnvelope
) -> Message | None:
    """投影核心（同步）：路由 + 幂等落库，返回消息；无法路由/无内容返回 None。"""
    conversation = _resolve_conversation_for_envelope(profile, envelope)
    if conversation is None:
        logger.warning(
            "elysia reply cannot be routed: no conversation for event %s (stream=%s)",
            envelope.event_id,
            envelope.stream_id,
        )
        return None

    content = _extract_content(envelope)
    if not content:
        logger.warning(
            "elysia reply event %s has no text payload; skipped",
            envelope.event_id,
        )
        return None

    # 幂等键唯一约束 max_length=64（MySQL 超长会 1406 Data too long）。
    # Elysium event_id 长达 69 字符，`elysia-` 前缀 + 原文必超 64；用哈希截断
    # 保持同 event_id → 同 key 的幂等语义，且不超列宽。
    idempotency_key = f"elysia-{_stable_id_hash(envelope.event_id)}"
    try:
        message = chat_services.create_message(
            profile.user,
            conversation,
            content=content,
            msg_type=Message.TYPE_TEXT,
            idempotency_key=idempotency_key,
        )
    except IntegrityError:
        # 幂等兜底：idempotency_key 是 DB 全局唯一，但 find_by_idempotency_key 按
        # (conversation, key) 查。bridge 重放历史事件时，同 event_id 曾被路由到
        # 其它会话（旧 key 已在库），当前会话查不到 → 插入撞全局唯一约束。
        # 按全局 key 找已存在的投影：同 key 已存在 = 已投影过，跳过（不重复落库，
        # 不广播），符合 M4-2/4-4 幂等契约。找不到则原样抛（保留失败可观测）。
        already = chat_services.find_global_by_idempotency_key(idempotency_key)
        if already is None:
            raise
        logger.warning(
            "elysia reply event %s already projected (message %s, conv %s); skipped",
            envelope.event_id,
            already.id,
            already.conversation_id,
        )
        return already


def _group_send_sync(conversation_id, event: dict) -> None:
    """向会话组广播，捕获 ChannelFull 不抛断（与 chat.services 一致）。"""
    layer = get_channel_layer()
    if layer is None:
        return
    try:
        async_to_sync(layer.group_send)(f"chat_conv_{conversation_id}", event)
    except ChannelFull:
        logger.warning("channel full, dropping elysia.reply for conv %s", conversation_id)
    except Exception:
        logger.exception("group_send elysia.reply failed for conv %s", conversation_id)


async def _group_send_async(conversation_id, event: dict) -> None:
    """异步向会话组广播（run_bridge / async 测试用），捕获 ChannelFull 不抛断。"""
    layer = get_channel_layer()
    if layer is None:
        return
    try:
        await layer.group_send(f"chat_conv_{conversation_id}", event)
    except ChannelFull:
        logger.warning("channel full, dropping elysia.reply for conv %s", conversation_id)
    except Exception:
        logger.exception("group_send elysia.reply failed for conv %s", conversation_id)


def _stable_id_hash(value: str, length: int = 24) -> str:
    """从事件 id 派生稳定短哈希（幂等键用，同 id → 同哈希）。"""
    import hashlib

    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:length]


def _extract_content(envelope: EventEnvelope) -> str:
    """从事件 payload 提取文本内容。

    payload 结构（阶段三 _payload()）：{content, content_ref, priority, salience, metadata}。
    只取 payload["content"]；没有则返回空串（不伪造内容）。
    """
    payload = envelope.payload
    if not isinstance(payload, Mapping):
        return ""
    content = payload.get("content")
    if isinstance(content, str):
        return content.strip()
    return ""


# ---------- 入站 inject ----------

def on_user_message_to_elysia(*, message: Message, conversation: Conversation) -> bool:
    """用户给爱莉发消息后的桥接入口（在应用内消息落库后调用）。

    判断：该会话是否包含爱莉 profile 绑定的 user；是则 inject 到 Elysium
    （带 sender_id 回显 + sender_name），触发爱莉思考。
    返回是否已 inject（False = 非爱莉会话 / profile 未启用 / 发送者就是爱莉）。
    """
    profile = _profile_for_conversation(conversation)
    if profile is None or not profile.enabled:
        return False
    if message.sender_id == profile.user_id:
        return False  # 爱莉自己发的，不入站

    injector = get_injector()
    return injector.inject_user_message(message=message, profile=profile)


def _profile_for_conversation(conversation: Conversation) -> ElysiaProfile | None:
    """找该会话里的爱莉 profile（会话另一方是爱莉 user）。"""
    for member in conversation.members.select_related("user"):
        try:
            return member.user.elysia_profile
        except ElysiaProfile.DoesNotExist:
            continue
    return None


# ---------- 入站 injector ----------

class InboundInjector:
    """用户 → 爱莉 的入站桥接（inject 到 Elysium 主链）。"""

    def __init__(self, *, client: ElysiaClient, credentials: ElysiaCredentialManager) -> None:
        self._client = client
        self._credentials = credentials

    def inject_user_message(self, *, message: Message, profile: ElysiaProfile) -> bool:
        """把一条应用内用户消息 inject 到 Elysium。

        幂等：inject 同步端点无 Idempotency-Key；但应用内同一消息只应 inject 一次。
        这里由调用方保证（chat 视图落库后只调一次）。
        """
        if not profile.enabled:
            logger.info("elysia profile disabled, skip inject for message %s", message.id)
            return False
        access_token = self._credentials.ensure_session(stream_id=profile.stream_id)
        result = self._client.inject_message(
            access_token=access_token,
            stream_id=profile.stream_id,
            content=message.content,
            sender_name=message.sender.nickname or message.sender.username,
            sender_id=str(message.sender_id),
            chat_type=profile.chat_type,
            platform=profile.platform,
        )
        accepted = bool(result.get("accepted", False))
        if not accepted:
            logger.warning(
                "elysia inject rejected for message %s (stream=%s): %s",
                message.id,
                profile.stream_id,
                result,
            )
        return accepted

    def smoke(self, *, profile: ElysiaProfile) -> dict[str, Any]:
        """连接冒烟：确保有有效 session，返回会话状态（不真正 inject）。"""
        access_token = self._credentials.ensure_session(stream_id=profile.stream_id)
        return {
            "authenticated": bool(access_token),
            "stream_id": profile.stream_id,
        }


_injector: InboundInjector | None = None
_injector_lock = threading.Lock()


def get_injector() -> InboundInjector:
    """获取全局 InboundInjector 单例（按 settings 配置懒初始化）。"""
    global _injector
    if _injector is None:
        with _injector_lock:
            if _injector is None:
                from django.conf import settings

                base_url = getattr(settings, "ELYSIA_BASE_URL", "").rstrip("/")
                if not base_url:
                    raise ProfileNotConfigured("ELYSIA_BASE_URL 未配置")
                secret_path = getattr(settings, "ELYSIA_CREDENTIAL_FILE", None)
                client = ElysiaClient(base_url=base_url)
                credentials = ElysiaCredentialManager(
                    client=client, secret_path=secret_path
                )
                _injector = InboundInjector(client=client, credentials=credentials)
    return _injector


# ---------- SSE 订阅循环（run_bridge 命令 / 测试共用） ----------

async def _handle_envelope(
    profile: ElysiaProfile, envelope: EventEnvelope
) -> Message | None:
    """单条出站事件处理：stream 匹配 → 投影落库 + 广播。

    过滤职责：stream_id 属于本 profile 才投影；不匹配直接忽略（多爱莉/多平台
    情况下各 profile 各订各的，事件过滤由 client 侧 event_type/stream_id 参数
    与这里双保险）。
    """
    if envelope.stream_id and envelope.stream_id != profile.stream_id:
        logger.debug(
            "skip event %s for stream %s (profile=%s)",
            envelope.event_id,
            envelope.stream_id,
            profile.stream_id,
        )
        return None
    return await aproject_elysia_reply(profile, envelope)


async def run_bridge_loop(
    *,
    profile: ElysiaProfile,
    client: ElysiaClient,
    credentials: ElysiaCredentialManager,
    event_types: Sequence[str] = SSE_EVENT_TYPES,
    reconnect_seconds: float = 3.0,
    max_backoff_seconds: float = 30.0,
    stop_event: asyncio.Event | None = None,
    on_event: Any = None,
) -> None:
    """SSE 订阅主循环：持续拉事件 → 投影 → 断线重连（有界退避）。

    - 用最近一次事件 cursor 做重连（Last-Event-ID / cursor），心跳不推进 cursor；
    - `history_gap` 错误帧 → 按 recovery.cursor 重连（禁止跳到尾部伪装连续）；
    - 401/credential_revoked → 走凭据恢复（ensure_session 内部用 secret 重换）；
    - stop_event 置位时优雅退出（关连接），供 SIGTERM/SIGINT 与测试使用；
    - on_event：可选回调，每个事件处理后被调用（测试注入停止信号等）。
    """
    loop = asyncio.get_running_loop()
    stop = stop_event or asyncio.Event()
    last_cursor: str | None = None
    backoff = reconnect_seconds

    while not stop.is_set():
        try:
            access_token = await database_sync_to_async(
                credentials.ensure_session
            )(stream_id=profile.stream_id)
        except ProfileNotConfigured as exc:
            logger.error("elysia bridge cannot start: %s", exc)
            raise
        except ElysiaUnauthenticated:
            logger.warning(
                "elysia session invalid at startup; will retry after %ss", backoff
            )
        else:
            try:
                async for envelope in client.stream_sse(
                    access_token=access_token,
                    event_types=list(event_types),
                    stream_id=profile.stream_id,
                    include_payload=True,
                    projection="full",
                    cursor=last_cursor,
                    last_event_id=last_cursor,
                ):
                    if stop.is_set():
                        break
                    try:
                        await _handle_envelope(profile, envelope)
                    except Exception:
                        logger.exception(
                            "elysia event projection failed for %s", envelope.event_id
                        )
                    if envelope.cursor:
                        last_cursor = envelope.cursor
                        backoff = reconnect_seconds  # 有进展即重置退避
                    if on_event is not None:
                        await on_event(envelope)
                # 流正常结束（服务端关闭/断线）：若已请求停止则退出，否则走重连
                if stop.is_set():
                    break
            except ElysiaHistoryGap as exc:
                # 历史缺口：只能按 recovery cursor 重连，禁止跳到尾部
                logger.warning(
                    "elysia SSE history gap, resuming from recovery cursor=%s",
                    exc.recovery_cursor,
                )
                if exc.recovery_cursor:
                    last_cursor = exc.recovery_cursor
                await _sleep_or_stop(loop, backoff, stop)
                backoff = min(backoff * 2, max_backoff_seconds)
                continue
            except ElysiaUnauthenticated:
                logger.warning(
                    "elysia SSE unauthenticated; refreshing session and retrying"
                )
                try:
                    await database_sync_to_async(credentials.refresh)()
                except Exception:
                    logger.exception("elysia session refresh failed")
                await _sleep_or_stop(loop, backoff, stop)
                backoff = min(backoff * 2, max_backoff_seconds)
                continue
            except ElysiaTransportError as exc:
                logger.warning("elysia SSE transport error: %s", exc)
                await _sleep_or_stop(loop, backoff, stop)
                backoff = min(backoff * 2, max_backoff_seconds)
                continue
            except Exception:
                logger.exception("elysia SSE loop error")
                await _sleep_or_stop(loop, backoff, stop)
                backoff = min(backoff * 2, max_backoff_seconds)
                continue
        if stop.is_set():
            break
        await _sleep_or_stop(loop, backoff, stop)
        backoff = min(backoff * 2, max_backoff_seconds)


async def _sleep_or_stop(
    loop: asyncio.AbstractEventLoop, seconds: float, stop: asyncio.Event
) -> None:
    """可取消睡眠：stop 置位立即返回。"""
    try:
        await asyncio.wait_for(stop.wait(), timeout=seconds)
    except asyncio.TimeoutError:
        return



__all__ = [
    "BridgeError",
    "CredentialState",
    "ElysiaCredentialManager",
    "InboundInjector",
    "PLATFORM_SERVICE_AUDIENCE",
    "ProfileNotConfigured",
    "REQUIRED_SCOPES",
    "SSE_EVENT_TYPES",
    "aproject_elysia_reply",
    "get_injector",
    "on_user_message_to_elysia",
    "project_elysia_reply",
    "run_bridge_loop",
]
