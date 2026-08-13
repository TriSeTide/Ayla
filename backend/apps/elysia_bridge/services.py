"""
elysia_bridge.services —— 爱莉桥接核心领域逻辑（供 REST / run_bridge 命令共用）。

职责（步骤文件 §4 / §5）：
- 凭据/会话管理：加载一次性 secret → 换 session → 自动 refresh → 失效恢复；
- 入站 inject：用户给爱莉发消息 → 应用内消息落库 → POST /chat/messages:inject
  （带 sender_id 回显来源，platform="ayla"）；
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
    CommandAccepted,
    ElysiaClient,
    ElysiaHistoryGap,
    ElysiaTransportError,
    ElysiaUnauthenticated,
    EventEnvelope,
    VoiceCallCreated,
    VoiceCallStatus,
    VoiceTranscriptEntry,
    VoiceTranscriptPage,
)
from apps.elysia_bridge.models import ElysiaProfile

logger = logging.getLogger(__name__)

User = get_user_model()

# 平台服务 audience（阶段三 policy.py PLATFORM_SERVICE_AUDIENCE）
PLATFORM_SERVICE_AUDIENCE = "elysium-platform-service"

# 应用侧最小 scope 集（阶段三 ALL_EXPORTED_SCOPES）
# M4-5 §4.5：给同一把 service credential 追加 voice_call:*（operate/read/observe）；
# 不授 admin:*，不授本应用不需要的其他 scope（最小权限原则，阶段三 §9）。
REQUIRED_SCOPES = (
    "chat:write",
    "events:read",
    "events:payload",
    "voice_call:operate",
    "voice_call:read",
    "voice_call:observe",
)
# SSE 订阅事件类型前缀（chat.py _MESSAGE_FACTS；M4-5 追加 voice_call.*）
SSE_EVENT_TYPES = ("chat.message", "voice_call")


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

    def reset_session(self) -> str:
        """清除内存 session 状态，强制用 secret 重新换 session。

        用于 401/credential_revoked 且 refresh 也失败（如 Elysium 重启导致
        旧 refresh_token 失效）的恢复路径；ensure_session 会复用内存 token，
        必须显式重置才能走到 _reissue。
        """
        with self._lock:
            self._state = None
            return self._reissue(stream_id="")


# ---------- 出站路由 ----------

def _extract_sender_id(envelope: EventEnvelope) -> str | None:
    """从出站事件里找应用内 sender_id 回显。

    优先级（步骤文件 §5.2）：
    1. payload.metadata.chat.target_user_id（Elysium 出站事实的标准路径）；
    2. payload.metadata.sender_id / user_id / actor_id（兼容旧投影）；
    3. payload.metadata 里其他嵌套 dict 的同类字段；
    4. correlation_id / causation_id 若形如 `elysia:<user_id>` 之类。
    返回 None 表示无法回显。
    """
    payload = envelope.payload or {}
    metadata = payload.get("metadata")
    if isinstance(metadata, Mapping):
        chat = metadata.get("chat")
        if isinstance(chat, Mapping):
            target_user_id = chat.get("target_user_id")
            if isinstance(target_user_id, str) and target_user_id:
                return target_user_id
        for key in ("sender_id", "user_id", "actor_id"):
            value = metadata.get(key)
            if isinstance(value, str) and value:
                return value
        for value in metadata.values():
            if not isinstance(value, Mapping):
                continue
            for key in ("sender_id", "user_id", "actor_id"):
                raw = value.get(key)
                if isinstance(raw, str) and raw:
                    return raw
    content_ref = payload.get("content_ref")
    if isinstance(content_ref, Mapping):
        for key in ("sender_id", "user_id", "actor_id"):
            raw = content_ref.get(key)
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
        return message
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

        401 恢复：Elysium 重启会清空其内存 session（旧 access/refresh token 全部
        失效），这里捕获 ElysiaUnauthenticated → reset_session（用落盘 secret 强制
        重签）→ 重试一次；仍失败则继续抛出（视图层已有 try/except 记录并保留消息）。
        """
        if not profile.enabled:
            logger.info("elysia profile disabled, skip inject for message %s", message.id)
            return False
        try:
            access_token = self._credentials.ensure_session(
                stream_id=profile.stream_id
            )
            return self._inject_with_token(
                message=message, profile=profile, access_token=access_token
            )
        except ElysiaUnauthenticated:
            logger.warning(
                "elysia inject 401 (stream=%s); reissuing session and retrying once",
                profile.stream_id,
            )
            try:
                access_token = self._credentials.reset_session()
            except Exception:  # noqa: BLE001 - 重签失败不伪装成功
                logger.exception(
                    "elysia session reissue failed for inject (stream=%s)",
                    profile.stream_id,
                )
                raise
            return self._inject_with_token(
                message=message, profile=profile, access_token=access_token
            )

    def _inject_with_token(
        self, *, message: Message, profile: ElysiaProfile, access_token: str
    ) -> bool:
        """携带指定 access_token 执行 inject；仅由 inject_user_message 调用。"""
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


# ---------- 爱莉 Voice Live 桥接（M4-5 §5.2 基线方案） ----------

def _get_bridge() -> tuple[ElysiaClient, ElysiaCredentialManager]:
    """复用 get_injector 的 client/credential（不另建凭据链，M4-5 §0/§2）。"""
    injector = get_injector()
    return injector._client, injector._credentials


def create_elysia_voice_call(profile: ElysiaProfile, mode: str = "auto") -> VoiceCallCreated:
    """创建 Voice Live 通话（一次性、单并发）。

    应用侧以 service credential 调用 → 应用本身就是该通话的 participant/拥有者
    （owner_actor_id = credential 的 actor_id，M4-5 §4.1/§4.5）。
    """
    client, credentials = _get_bridge()
    access_token = credentials.ensure_session(stream_id=profile.stream_id)
    return client.create_voice_call(access_token=access_token, mode=mode)


def get_voice_call_status(profile: ElysiaProfile, call_id: str) -> VoiceCallStatus:
    """查询通话状态与安全指标（resumable 由 VoiceCallStatus 显式给出）。"""
    client, credentials = _get_bridge()
    access_token = credentials.ensure_session(stream_id=profile.stream_id)
    return client.get_voice_call(access_token=access_token, call_id=call_id)


def send_voice_text(profile: ElysiaProfile, call_id: str, text: str) -> CommandAccepted:
    """向实时会话注入文本（真人想对爱莉说的话，M4-5 §5.2 第 4 步）。

    必须带 Idempotency-Key（幂等硬约束）。幂等键由调用方生成（如 `elysia-voice-text-<event_id>`）。
    """
    client, credentials = _get_bridge()
    access_token = credentials.ensure_session(stream_id=profile.stream_id)
    return client.send_voice_call_text(
        access_token=access_token,
        call_id=call_id,
        text=text,
        idempotency_key=f"elysia-voice-text-{_stable_id_hash(call_id + text)}",
    )


def end_voice_call(profile: ElysiaProfile, call_id: str) -> CommandAccepted:
    """结束通话（幂等：重复调用返回同一命令，M4-5 §5.2 第 5 步）。"""
    client, credentials = _get_bridge()
    access_token = credentials.ensure_session(stream_id=profile.stream_id)
    return client.end_voice_call(
        access_token=access_token,
        call_id=call_id,
        idempotency_key=f"elysia-voice-end-{_stable_id_hash(call_id)}",
    )


def voice_call_transcripts(profile: ElysiaProfile, call_id: str) -> VoiceTranscriptPage:
    """授权转写历史（只读；应用侧绝不用它伪造爱莉发言）。"""
    client, credentials = _get_bridge()
    access_token = credentials.ensure_session(stream_id=profile.stream_id)
    return client.get_voice_call_transcripts(
        access_token=access_token, call_id=call_id
    )


# ---------- 爱莉 Voice Live 编排（M4-5 §5.2 基线方案，应用内闭环） ----------
#
# 编排语义：
# - Voice Live 是**一对一**意识实例（`max_concurrent_sessions=1`，开发文档 §11 风险表），
#   同一时刻只允许一个活跃爱莉通话；进程内活跃表做单并发约束，多用户同时要与爱莉
#   语音时复用同一通话（README 已知取舍 §12）。
# - 应用侧以 service credential 创建通话 → 应用本身就是该通话的 participant/拥有者
#   （owner_actor_id = credential 的 actor_id）；爱莉是对话对象，其发言事实由
#   Elysium 侧 final transcript 的 `role="assistant"` 表达，应用侧只投影不生成。
# - 事件源取舍：阶段三 `voice_call.*` SSE 事件流尚未进入 Life Event 账本（events/stream
#   收不到 voice_call 事件，公共契约缺口，见 README）；本期转写投影走
#   `GET /voice-calls/{call_id}/transcripts` **增量轮询**（cursor 分页，幂等键去重），
#   不依赖 SSE 事件流，也不改动 Elysium 侧代码。

_ACTIVE_VOICE_CALLS: dict[str, str] = {}
"""进程内活跃 Voice Live 通话注册（call_id -> profile.stream_id）。

单并发约束：同一时刻只允许一个活跃通话。进程重启后该表清空——但 Elysium 侧
通话状态是权威（`VoiceCallStatus.resumable` 显式给出），Ayla 重启后新通话可再建；
旧通话若仍活跃由 Elysium 侧会话超时/应用侧 poll 时按状态收敛（README 取舍）。
"""


def _register_active_voice_call(profile: ElysiaProfile, call_id: str) -> None:
    _ACTIVE_VOICE_CALLS[call_id] = profile.stream_id


def _unregister_active_voice_call(call_id: str) -> None:
    _ACTIVE_VOICE_CALLS.pop(call_id, None)


def ensure_elysia_voice_call(
    profile: ElysiaProfile, mode: str = "auto"
) -> dict:
    """创建/复用爱莉 Voice Live 通话（单并发，M4-5 §5.2 第 1 步）。

    复用规则：进程内活跃表里的 call_id 仍活跃（状态非 ended/failed）→ 返回已有；
    否则 POST /voice-calls 创建并注册。返回：
    `{"call": VoiceCallStatus, "connection": VoiceCallTicket | None, "reused": bool}`。

    注意：仅"进程内活跃表"不足以判定 Elysium 侧真实状态——复用前先 GET 一次状态
    确认（resumable 由 VoiceCallStatus 显式给出，阶段三 §12.5）。
    """
    for call_id in list(_ACTIVE_VOICE_CALLS):
        if _ACTIVE_VOICE_CALLS[call_id] != profile.stream_id:
            continue
        try:
            status = get_voice_call_status(profile, call_id)
        except Exception:
            logger.exception(
                "voice call %s status check failed; will create new", call_id
            )
            _unregister_active_voice_call(call_id)
            continue
        if status.state not in ("ended", "failed", "suspended"):
            logger.info(
                "reusing active voice call %s (state=%s) for stream %s",
                call_id, status.state, profile.stream_id,
            )
            return {
                "call": status,
                "connection": None,
                "reused": True,
            }
        _unregister_active_voice_call(call_id)

    created = create_elysia_voice_call(profile, mode=mode)
    _register_active_voice_call(profile, created.call.call_id)
    logger.info(
        "created voice call %s (state=%s) for stream %s",
        created.call.call_id, created.call.state, profile.stream_id,
    )
    return {
        "call": created.call,
        "connection": created.connection,
        "reused": False,
    }


def end_elysia_voice_call(profile: ElysiaProfile, call_id: str) -> CommandAccepted:
    """结束爱莉 Voice Live 通话（幂等，M4-5 §5.2 第 5 步）+ 从活跃表移除。"""
    result = end_voice_call(profile, call_id)
    _unregister_active_voice_call(call_id)
    return result


def poll_voice_transcripts(
    profile: ElysiaProfile, call_id: str, *, limit: int = 200
) -> dict:
    """增量投影转写：拉取授权转写历史 → 把 `role="assistant"` 的 final transcript
    投影为语音频道会话里的爱莉消息（幂等 `elysia-voice-<event_id 哈希>`，M4-5 §5.2 第 3 步）。

    事件源取舍（见本段 docstring）：阶段三 `voice_call.*` SSE 事件流未进 Life Event
    账本，本函数以 `GET /voice-calls/{call_id}/transcripts` 轮询为投影主路径；
    从头拉取（cursor=None），投影幂等键去重保证重复调用不重复落库。

    返回：`{"projected": [message_id, ...], "total": 转写条数}`；无会话可路由/
    非 assistant 条目不投影（返回 None 不计数）。
    """
    page = voice_call_transcripts(profile, call_id)
    projected: list[str] = []
    for entry in page.transcripts:
        # 顺序投影，逐条幂等；call_id 用传入参数（与轮询目标一致，可溯源）
        message = project_voice_transcript(
            profile, call_id, entry, event_id=f"voice-poll-{call_id}-{entry.sequence}"
        )
        if message is not None:
            projected.append(str(message.id))
    return {"projected": projected, "total": len(page.transcripts)}


def _voice_conversation(profile: ElysiaProfile) -> Conversation | None:
    """爱莉语音频道绑定的应用内会话。

    倾向「elysia_profile 单例 + 默认语音频道」语义（M4-5 §5.3）：复用 profile 的
    最近私聊会话（与 M4-4 出站降级一致）；无任何会话则返回 None。
    """
    conv = (
        Conversation.objects.filter(members__user=profile.user)
        .order_by("-created_at")
        .first()
    )
    return conv


def project_voice_transcript(
    profile: ElysiaProfile,
    call_id: str,
    entry: VoiceTranscriptEntry,
    *,
    event_id: str,
) -> Message | None:
    """把一条**final transcript** 投影为语音频道会话里的爱莉消息（M4-5 §5.2 第 3 步）。

    主体性铁律（AGENTS.md §4.1 / M4-5 §3.3）：
    - **只投影 `role="assistant"` 的 final transcript**；`role="user"` 或 partial 不落库；
    - 应用侧**绝不生成爱莉的第一人称内容**：没有 final transcript 就没有爱莉发言；
    - 幂等键 `elysia-voice-<event_id>`（同 event_id → 同 key，重复不重复落库）。

    返回落库消息；无法路由会话 / 非 assistant / 无文本 → None。

    注意：同步版用 `_group_send_sync` 广播（async_to_sync），只适用线程上下文
    （REST 视图 / 命令处理器）；事件循环内的广播走异步版 `aproject_voice_transcript`。
    """
    if entry.role != "assistant":
        logger.debug(
            "voice transcript entry %s role=%s skipped (only assistant final projected)",
            entry.sequence,
            entry.role,
        )
        return None
    text = (entry.text or "").strip()
    if not text:
        logger.warning("voice transcript %s has no text; skipped", event_id)
        return None
    conversation = _voice_conversation(profile)
    if conversation is None:
        logger.warning(
            "voice transcript cannot be routed: no conversation for profile %s (call %s)",
            profile.user_id,
            call_id,
        )
        return None

    idempotency_key = f"elysia-voice-{_stable_id_hash(event_id)}"
    try:
        message = chat_services.create_message(
            profile.user,
            conversation,
            content=text,
            msg_type=Message.TYPE_TEXT,
            idempotency_key=idempotency_key,
        )
    except IntegrityError:
        already = chat_services.find_global_by_idempotency_key(idempotency_key)
        if already is None:
            raise
        logger.warning(
            "voice transcript event %s already projected (message %s, conv %s); skipped",
            event_id,
            already.id,
            already.conversation_id,
        )
        return already

    # 广播到会话组（走 M4-2 Chat WS，前端收到 elysia.reply 同款事件）
    event = _voice_reply_event(message, event_id)
    _group_send_sync(message.conversation_id, event)
    return message


def _voice_reply_event(message: Message, event_id: str) -> dict:
    """由已落库的爱莉语音消息构造 elysia.reply 事件（source=voice_call）。

    event_id 取投影调用方传入的 transcript event_id（与幂等键 `elysia-voice-<hash>` 同源），
    供 ChatConsumer.elysia_reply 原样透传（前端可据此去重/溯源）。
    """
    return {
        "type": "elysia.reply",
        "conversation_id": str(message.conversation_id),
        "message_id": str(message.id),
        "sender_id": str(message.sender_id),
        "content": message.content,
        "msg_type": message.type,
        "media": message.media_id,
        "reply_to": str(message.reply_to_id) if message.reply_to_id else None,
        "seq": message.seq,
        "event_id": event_id,
        "ts": message.created_at.isoformat(),
        "source": "voice_call",
    }


async def aproject_voice_transcript(
    profile: ElysiaProfile,
    call_id: str,
    entry: VoiceTranscriptEntry,
    *,
    event_id: str,
) -> Message | None:
    """异步版：供 run_bridge（asyncio 事件循环）与 async 测试使用。

    DB 侧工作（路由+落库）经 database_sync_to_async 卸载到线程池；广播在 async
    上下文直接 await group_send，避免 `_group_send_sync` 的 async_to_sync 在事件
    循环线程跨循环丢消息（与 `aproject_elysia_reply` 同语义）。
    """
    message = await database_sync_to_async(_project_voice_into_message)(
        profile, call_id, entry, event_id=event_id
    )
    if message is not None:
        event = _voice_reply_event(message, event_id)
        await _group_send_async(message.conversation_id, event)
    return message


def _project_voice_into_message(
    profile: ElysiaProfile,
    call_id: str,
    entry: VoiceTranscriptEntry,
    *,
    event_id: str,
) -> Message | None:
    """投影核心（同步）：路由 + 幂等落库，返回消息；不做广播（由调用方负责）。"""
    if entry.role != "assistant":
        logger.debug(
            "voice transcript entry %s role=%s skipped (only assistant final projected)",
            entry.sequence,
            entry.role,
        )
        return None
    text = (entry.text or "").strip()
    if not text:
        logger.warning("voice transcript %s has no text; skipped", event_id)
        return None
    conversation = _voice_conversation(profile)
    if conversation is None:
        logger.warning(
            "voice transcript cannot be routed: no conversation for profile %s (call %s)",
            profile.user_id,
            call_id,
        )
        return None

    idempotency_key = f"elysia-voice-{_stable_id_hash(event_id)}"
    try:
        return chat_services.create_message(
            profile.user,
            conversation,
            content=text,
            msg_type=Message.TYPE_TEXT,
            idempotency_key=idempotency_key,
        )
    except IntegrityError:
        already = chat_services.find_global_by_idempotency_key(idempotency_key)
        if already is None:
            raise
        logger.warning(
            "voice transcript event %s already projected (message %s, conv %s); skipped",
            event_id,
            already.id,
            already.conversation_id,
        )
        return already


# ---------- SSE 订阅循环（run_bridge 命令 / 测试共用） ----------

def _chat_direction(envelope: EventEnvelope) -> str | None:
    """读取标准 chat 事实的方向字段（Elysium `metadata.chat.direction`）。

    direction ∈ {received, requested, delivered}：
    - received：入站消息（Ayla 后端已自行落库，桥接不得再投影）；
    - requested：发送请求（预发送通知，不是交付事实，投影会与 delivered 重复）；
    - delivered：最终交付事实（爱莉回复经本通道出站成功，投影为应用内消息）。
    """
    payload = envelope.payload
    if not isinstance(payload, Mapping):
        return None
    metadata = payload.get("metadata")
    if not isinstance(metadata, Mapping):
        return None
    chat = metadata.get("chat")
    if not isinstance(chat, Mapping):
        return None
    direction = chat.get("direction")
    return str(direction) if direction else None


async def _handle_envelope(
    profile: ElysiaProfile, envelope: EventEnvelope
) -> Message | None:
    """单条出站事件处理：stream 匹配 → 事件类型分派 → 投影落库 + 广播。

    过滤职责：
    1. stream_id 属于本 profile 才投影；不匹配直接忽略（多爱莉/多平台
       情况下各 profile 各订各的，事件过滤由 client 侧 event_type/stream_id
       参数与这里双保险）；
    2. voice_call.* 事件走 `_handle_voice_event`（transcript.final → 爱莉发言投影；
       其余只记录不投影）；
    3. chat.message 事件只投影 `direction=delivered`（最终交付事实），
       received（入站已由 Ayla 后端落库）与 requested（发送请求，非交付）
       一律跳过，避免把用户消息投影成爱莉回复、或一条回复投影两次。
    """
    if envelope.stream_id and envelope.stream_id != profile.stream_id:
        logger.debug(
            "skip event %s for stream %s (profile=%s)",
            envelope.event_id,
            envelope.stream_id,
            profile.stream_id,
        )
        return None
    if envelope.event_type.startswith("voice_call."):
        return await _handle_voice_event(profile, envelope)
    if envelope.is_chat_message:
        direction = _chat_direction(envelope)
        if direction != "delivered":
            logger.debug(
                "skip chat event %s direction=%s (only delivered facts projected)",
                envelope.event_id,
                direction,
            )
            return None
    return await aproject_elysia_reply(profile, envelope)


# ---------- voice_call 事件分派（M4-5 §5.2 第 2/3 步） ----------

def _transcript_from_event_payload(
    payload: Mapping[str, Any] | None,
) -> VoiceTranscriptEntry | None:
    """从 voice_call.transcript.final 事件 payload 解析 VoiceTranscriptEntry。

    兼容两种 payload 形态（以 Elysium 侧 voice_call 领域 payload 为准，解析失败
    安全忽略——**绝不伪造**）：
    - payload["transcript"] = {sequence, role, text, provider_event_id, ...}
    - payload 顶层直接是 transcript 字段（sequence/role/text/...）
    缺 role 与 text 关键字段 → None。
    """
    if not isinstance(payload, Mapping):
        return None
    raw = payload.get("transcript")
    if not isinstance(raw, Mapping):
        raw = payload
    if not raw.get("role") and not raw.get("text"):
        return None
    return VoiceTranscriptEntry.from_mapping(raw)


def _voice_call_id_from_event(
    payload: Mapping[str, Any] | None, fallback: str
) -> str:
    """提取 call_id：payload["call_id"] 优先，缺失用事件 id 兜底（保持可溯源）。"""
    if isinstance(payload, Mapping) and payload.get("call_id"):
        return str(payload["call_id"])
    transcript = payload.get("transcript") if isinstance(payload, Mapping) else None
    if isinstance(transcript, Mapping) and transcript.get("call_id"):
        return str(transcript["call_id"])
    return fallback


async def _handle_voice_event(
    profile: ElysiaProfile, envelope: EventEnvelope
) -> Message | None:
    """voice_call.* 事件分派：

    - `voice_call.transcript.final` → 解析 transcript → 投影爱莉发言
      （`aproject_voice_transcript` 只投影 role=assistant，幂等 `elysia-voice-<event_id>`）；
    - 其余 voice_call.* 事件（state_changed/provider_state_changed/...）→ debug 日志
      保持可观测，不投影（爱莉技术状态不落库为发言，阶段三 §12.3）。
    """
    if envelope.event_type == "voice_call.transcript.final":
        entry = _transcript_from_event_payload(envelope.payload)
        if entry is None:
            logger.debug(
                "voice_call.transcript.final %s has no parseable transcript; skipped",
                envelope.event_id,
            )
            return None
        call_id = _voice_call_id_from_event(envelope.payload, envelope.event_id)
        return await aproject_voice_transcript(
            profile, call_id, entry, event_id=envelope.event_id
        )
    logger.debug(
        "voice_call event %s (%s) observed for stream %s; not projected",
        envelope.event_id,
        envelope.event_type,
        envelope.stream_id,
    )
    return None


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
                    # refresh 失败（如 Elysium 重启后旧 refresh_token 失效）：
                    # 必须用落盘 secret 强制重签，否则 ensure_session 会继续
                    # 复用内存里的失效 token，陷入 401 重试循环。
                    logger.warning(
                        "elysia session refresh failed; reissuing from secret"
                    )
                    try:
                        await database_sync_to_async(credentials.reset_session)()
                    except Exception:
                        logger.exception(
                            "elysia session reissue from secret failed"
                        )
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
    "aproject_voice_transcript",
    "create_elysia_voice_call",
    "end_elysia_voice_call",
    "end_voice_call",
    "ensure_elysia_voice_call",
    "get_injector",
    "get_voice_call_status",
    "on_user_message_to_elysia",
    "poll_voice_transcripts",
    "project_elysia_reply",
    "project_voice_transcript",
    "run_bridge_loop",
    "send_voice_text",
    "voice_call_transcripts",
]
