"""
elysia_client —— 阶段三 Elysium HTTP 客户端（REST + SSE 长连接）。

职责边界（阶段三决策 2 / 步骤文件 §4）：
- 本客户端只负责「应用后端 ↔ 阶段三 /api/v1」的协议封装：凭据获取、
  session 换发与 refresh、inject 入站、命令端点（send/reply）、SSE 出站订阅；
- 所有返回结构都按阶段三真实 schema 解析（EventEnvelope / ChatCommandAccepted /
  SessionResponse / AdminCredentialSecret），不臆造字段；
- SSE 是**只读观察通道**（GET /events/stream），不在这里发消息；真实发送走命令端点；
- 幂等硬约束：命令请求必须带 Idempotency-Key（调用方生成，客户端原样透传）。

凭据/会话生命周期（auth_store.py + runtime.py 真实契约）：
1. 管理员在 Elysium 侧以 `admin:credential` 创建 service credential（platform_service role、
   scope 含 chat:write / events:read、resource_grants 含 stream:<stream_id>）；
   secret 只在创建时返回一次，应用侧必须安全落盘（本机配置，不提交仓库）。
2. `POST /auth/sessions`（grant_type=service_credential）换 access/refresh；
3. access 过期前自动 refresh（refresh 是轮换式，旧 token 立即失效）；
4. 撤销/轮换：捕获 401/credential_revoked 后调用方走恢复流程（重新用 secret 换 session）。

本文件不依赖 Django，便于独立单测（mock httpx）。
"""
from __future__ import annotations

import json
import logging
from dataclasses import dataclass, field
from typing import Any, AsyncIterator, Mapping, Sequence

import httpx

logger = logging.getLogger(__name__)

# 阶段三常量（与源码核对）
DEFAULT_TIMEOUT = httpx.Timeout(30.0, connect=10.0)
SSE_READ_TIMEOUT = httpx.Timeout(60.0, connect=10.0)
# 事件类型前缀过滤（chat.py _MESSAGE_FACTS：chat.message.* / text 旧通道）
CHAT_EVENT_PREFIXES = ("chat.message.", "text")

# 错误码语义（阶段三 runtime.py / events.py）
ERR_UNAUTHENTICATED = "unauthenticated"
ERR_CREDENTIAL_REVOKED = "credential_revoked"
ERR_SESSION_REVOKED = "session_revoked"
ERR_HISTORY_GAP = "history_gap"


class ElysiaClientError(Exception):
    """Elysium 客户端协议/传输错误。"""


class ElysiaUnauthenticated(ElysiaClientError):
    """401 未认证：session 或 credential 已失效，调用方应走恢复流程。"""


class ElysiaTransportError(ElysiaClientError):
    """网络/超时/服务端 5xx 等可重试错误。"""


class ElysiaHistoryGap(ElysiaClientError):
    """SSE 历史缺口错误帧，携带 recovery cursor。"""

    def __init__(self, message: str, *, recovery_cursor: str | None = None) -> None:
        super().__init__(message)
        self.recovery_cursor = recovery_cursor


@dataclass(frozen=True, slots=True)
class EventEnvelope:
    """阶段三 EventEnvelope 的只读投影（仅保留本应用关心的字段）。

    cursor：SSE 帧级 `id:` 字段（服务端 durable cursor）。它属于连接层而非事件体，
    由 stream_sse 在 yield 时注入；断线重连用 `cursor` 作为 Last-Event-ID/cursor。
    """

    event_id: str
    sequence: int
    event_type: str
    stream_id: str | None
    channel: str
    reply_target_type: str | None
    reply_target_id: str | None
    actor_type: str
    actor_id: str
    correlation_id: str | None
    causation_id: str | None
    payload: dict[str, Any] | None = None
    cursor: str | None = None
    raw: Mapping[str, Any] = field(default_factory=dict, repr=False)

    @classmethod
    def from_mapping(cls, data: Mapping[str, Any]) -> "EventEnvelope":
        actor = data.get("actor") or {}
        reply_target = data.get("reply_target")
        return cls(
            event_id=str(data.get("event_id") or ""),
            sequence=int(data.get("sequence") or 0),
            event_type=str(data.get("event_type") or ""),
            stream_id=data.get("stream_id") or None,
            channel=str(data.get("channel") or ""),
            reply_target_type=(reply_target or {}).get("type") if reply_target else None,
            reply_target_id=(reply_target or {}).get("id") if reply_target else None,
            actor_type=str(actor.get("type") or ""),
            actor_id=str(actor.get("id") or ""),
            correlation_id=data.get("correlation_id") or None,
            causation_id=data.get("causation_id") or None,
            payload=data.get("payload") if isinstance(data.get("payload"), dict) else None,
            raw=dict(data),
        )

    @property
    def is_chat_message(self) -> bool:
        return self.event_type.startswith(CHAT_EVENT_PREFIXES)


@dataclass(frozen=True, slots=True)
class CommandAccepted:
    """阶段三 ChatCommandAccepted 的只读投影。"""

    command_id: str
    status: str
    accepted: bool = True

    @classmethod
    def from_mapping(cls, data: Mapping[str, Any]) -> "CommandAccepted":
        command = data.get("command") or {}
        return cls(
            command_id=str(command.get("command_id") or ""),
            status=str(command.get("status") or ""),
            accepted=bool(data.get("accepted", True)),
        )


@dataclass(frozen=True, slots=True)
class SessionTokens:
    """session token 对 + 过期信息。"""

    access_token: str
    refresh_token: str
    expires_at: str | None = None
    refresh_expires_at: str | None = None

    @classmethod
    def from_mapping(cls, data: Mapping[str, Any]) -> "SessionTokens":
        return cls(
            access_token=str(data.get("access_token") or ""),
            refresh_token=str(data.get("refresh_token") or ""),
            expires_at=data.get("expires_at"),
            refresh_expires_at=data.get("refresh_expires_at"),
        )


@dataclass(frozen=True, slots=True)
class VoiceCallStatus:
    """阶段三 VoiceCallStatus 的只读投影（M4-5 §4.1）。"""

    call_id: str
    episode_id: str | None = None
    state: str = ""
    mode: str = ""
    provider: str = ""
    created_at: str | None = None
    updated_at: str | None = None
    resumable: bool = False
    connected: bool = False
    input_audio_bytes: int = 0
    output_audio_bytes: int = 0
    interruptions: int = 0
    failure_reason: str | None = None

    @classmethod
    def from_mapping(cls, data: Mapping[str, Any]) -> "VoiceCallStatus":
        return cls(
            call_id=str(data.get("call_id") or ""),
            episode_id=data.get("episode_id"),
            state=str(data.get("state") or ""),
            mode=str(data.get("mode") or ""),
            provider=str(data.get("provider") or ""),
            created_at=data.get("created_at"),
            updated_at=data.get("updated_at"),
            resumable=bool(data.get("resumable", False)),
            connected=bool(data.get("connected", False)),
            input_audio_bytes=int(data.get("input_audio_bytes") or 0),
            output_audio_bytes=int(data.get("output_audio_bytes") or 0),
            interruptions=int(data.get("interruptions") or 0),
            failure_reason=data.get("failure_reason"),
        )


@dataclass(frozen=True, slots=True)
class VoiceCallTicket:
    """阶段三 WSTicketResponse 的只读投影（短时、单次、绑定 scope/origin）。"""

    ticket: str
    url: str = ""
    expires_at: str | None = None
    resource: str = ""
    subprotocol: str = ""

    @classmethod
    def from_mapping(cls, data: Mapping[str, Any]) -> "VoiceCallTicket":
        return cls(
            ticket=str(data.get("ticket") or ""),
            url=str(data.get("url") or ""),
            expires_at=data.get("expires_at"),
            resource=str(data.get("resource") or ""),
            subprotocol=str(data.get("subprotocol") or ""),
        )


@dataclass(frozen=True, slots=True)
class VoiceCallCreated:
    """POST /voice-calls 响应：call + 一次性 participant ticket。"""

    call: VoiceCallStatus
    connection: VoiceCallTicket

    @classmethod
    def from_mapping(cls, data: Mapping[str, Any]) -> "VoiceCallCreated":
        return cls(
            call=VoiceCallStatus.from_mapping(data.get("call") or {}),
            connection=VoiceCallTicket.from_mapping(data.get("connection") or {}),
        )


@dataclass(frozen=True, slots=True)
class VoiceTranscriptEntry:
    """单条转写（role: user/assistant）。"""

    sequence: int = 0
    occurred_at: str | None = None
    role: str = ""
    text: str = ""
    provider_event_id: str | None = None
    visibility: str = ""

    @classmethod
    def from_mapping(cls, data: Mapping[str, Any]) -> "VoiceTranscriptEntry":
        return cls(
            sequence=int(data.get("sequence") or 0),
            occurred_at=data.get("occurred_at"),
            role=str(data.get("role") or ""),
            text=str(data.get("text") or ""),
            provider_event_id=data.get("provider_event_id"),
            visibility=str(data.get("visibility") or ""),
        )


@dataclass(frozen=True, slots=True)
class VoiceTranscriptPage:
    """阶段三 VoiceTranscriptPage 的只读投影。"""

    transcripts: tuple[VoiceTranscriptEntry, ...] = ()
    next_cursor: str | None = None
    has_more: bool = False

    @classmethod
    def from_mapping(cls, data: Mapping[str, Any]) -> "VoiceTranscriptPage":
        return cls(
            transcripts=tuple(
                VoiceTranscriptEntry.from_mapping(t)
                for t in (data.get("transcripts") or [])
            ),
            next_cursor=data.get("next_cursor"),
            has_more=bool(data.get("has_more", False)),
        )


def _extract_error(response: httpx.Response) -> ElysiaClientError:
    """把阶段三错误响应映射为客户端异常（保留 code/status/recovery）。"""
    try:
        body = response.json()
    except ValueError:
        body = {}
    error = body.get("error") or {}
    code = str(error.get("code") or "")
    message = str(error.get("message") or response.text[:200])
    status = response.status_code
    if status == 401 or code in {
        ERR_UNAUTHENTICATED,
        ERR_CREDENTIAL_REVOKED,
        ERR_SESSION_REVOKED,
    }:
        return ElysiaUnauthenticated(message)
    recovery = error.get("recovery") or {}
    recovery_cursor = (
        recovery.get("cursor") if isinstance(recovery, Mapping) else None
    )
    if code == ERR_HISTORY_GAP:
        return ElysiaHistoryGap(message, recovery_cursor=recovery_cursor)
    if 500 <= status < 600:
        return ElysiaTransportError(f"Elysium server error {status}: {message}")
    detail = f"[{code}] {message}" if code else message
    return ElysiaClientError(f"Elysium API error {status}: {detail}")


class ElysiaClient:
    """对阶段三 /api/v1 的 HTTP 客户端。

    线程模型：方法都是同步 def（httpx 同步调用），由调用方决定放在线程/事件循环外。
    测试通过注入 transport / 自建 httpx.Client 来 mock。
    """

    def __init__(
        self,
        *,
        base_url: str,
        client: httpx.Client | None = None,
        async_client: httpx.AsyncClient | None = None,
        timeout: httpx.Timeout = DEFAULT_TIMEOUT,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._client = client or httpx.Client(base_url=self._base_url, timeout=timeout)
        self._async_client = async_client
        self._timeout = timeout

    # ---------- 会话 ----------

    def close(self) -> None:
        self._client.close()
        if self._async_client is not None:
            self._async_client.close()

    def __enter__(self) -> "ElysiaClient":
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()

    def _headers(self, access_token: str | None = None) -> dict[str, str]:
        headers: dict[str, str] = {"Accept": "application/json"}
        if access_token:
            headers["Authorization"] = f"Bearer {access_token}"
        return headers

    def _send(
        self, method: str, url: str, **kwargs: Any
    ) -> httpx.Response:
        """同步请求分发：把网络层错误统一封装为 ElysiaTransportError。

        Elysium 不可达（连接被拒/超时/DNS）或连接中途断开时，httpx 抛
        `httpx.HTTPError` 子类（如 ConnectError）。这里统一映射为
        `ElysiaTransportError`，让调用方（run_bridge_loop 等）能按
        "上游不可达、可重试"处理，而不是让裸传输异常冒泡刷完整 traceback
        （Elysium 未运行时 Ayla 应能独立启动）。
        """
        try:
            return self._client.request(method, url, **kwargs)
        except httpx.HTTPError as exc:
            raise ElysiaTransportError(
                f"Elysium unreachable: {type(exc).__name__}: {exc}"
            ) from exc

    def _handle(self, response: httpx.Response) -> Mapping[str, Any]:
        if response.is_success or response.status_code == 202:
            try:
                return response.json()
            except ValueError:
                return {}
        raise _extract_error(response)

    # ---------- 凭据 / 会话 ----------

    def create_credential(
        self,
        *,
        access_token: str,
        actor_id: str,
        scopes: Sequence[str],
        resource_grants: Sequence[str] = (),
    ) -> tuple[str, str]:
        """POST /admin/credentials —— 返回 (credential_id, secret)。

        secret 只在创建时返回一次，调用方必须立刻安全落盘。
        """
        body: dict[str, Any] = {
            "actor_id": actor_id,
            "scopes": list(scopes),
        }
        if resource_grants:
            body["resource_grants"] = list(resource_grants)
        response = self._send(
            "POST",
            "/api/v1/admin/credentials",
            json=body,
            headers=self._headers(access_token),
        )
        data = self._handle(response)
        credential = data.get("credential") or {}
        return str(credential.get("credential_id") or ""), str(data.get("secret") or "")

    def issue_session(self, *, service_credential: str, audience: str) -> SessionTokens:
        """POST /auth/sessions（grant_type=service_credential）。"""
        response = self._send(
            "POST",
            "/api/v1/auth/sessions",
            json={
                "grant_type": "service_credential",
                "service_credential": service_credential,
                "audience": audience,
            },
            headers=self._headers(),
        )
        return SessionTokens.from_mapping(self._handle(response))

    def refresh_session(self, *, refresh_token: str) -> SessionTokens:
        """POST /auth/sessions/current:refresh —— refresh 是轮换式。"""
        response = self._send(
            "POST",
            "/api/v1/auth/sessions/current:refresh",
            json={"refresh_token": refresh_token},
            headers=self._headers(),
        )
        return SessionTokens.from_mapping(self._handle(response))

    def revoke_credential(self, *, access_token: str, credential_id: str) -> bool:
        """DELETE /admin/credentials/{id} —— 撤销凭据（旧 session 立即失效）。"""
        response = self._send(
            "DELETE",
            f"/api/v1/admin/credentials/{credential_id}",
            headers=self._headers(access_token),
        )
        data = self._handle(response)
        return bool(data.get("revoked", False))

    # ---------- 入站：inject ----------

    def inject_message(
        self,
        *,
        access_token: str,
        stream_id: str,
        content: str,
        sender_name: str | None = None,
        sender_id: str | None = None,
        sender_cardname: str | None = None,
        chat_type: str = "private",
        platform: str = "ayla",
    ) -> Mapping[str, Any]:
        """POST /chat/messages:inject —— 同步端点，无 Idempotency-Key。

        返回 InboundMessageInjectResult：{message_id, stream_id, accepted}。
        platform 默认 `ayla`（Elysium接入Ayla平台模块.md §1.1/§2.2，显式传 platform
        走 Elysium 侧 InboundInjector 快速路径，不扫描账本投影）。
        """
        body: dict[str, Any] = {
            "stream_id": stream_id,
            "content": content,
            "chat_type": chat_type,
            "platform": platform,
        }
        if sender_name:
            body["sender_name"] = sender_name
        if sender_id:
            body["sender_id"] = sender_id
        if sender_cardname:
            body["sender_cardname"] = sender_cardname
        response = self._send(
            "POST",
            "/api/v1/chat/messages:inject",
            json=body,
            headers=self._headers(access_token),
        )
        return self._handle(response)

    # ---------- 出站：命令端点（真实发送链路，本期以 SSE 投影为主） ----------

    def send_chat_message(
        self,
        *,
        access_token: str,
        stream_id: str,
        parts: Sequence[Mapping[str, Any]],
        idempotency_key: str,
        reply_to: str | None = None,
    ) -> CommandAccepted:
        """POST /chat/messages:send —— 必须带 Idempotency-Key，返回 202。"""
        body: dict[str, Any] = {
            "stream_id": stream_id,
            "parts": list(parts),
        }
        if reply_to:
            body["reply_to"] = reply_to
        response = self._send(
            "POST",
            "/api/v1/chat/messages:send",
            json=body,
            headers={
                **self._headers(access_token),
                "Idempotency-Key": idempotency_key,
            },
        )
        return CommandAccepted.from_mapping(self._handle(response))

    def reply_chat_message(
        self,
        *,
        access_token: str,
        message_id: str,
        parts: Sequence[Mapping[str, Any]],
        idempotency_key: str,
    ) -> CommandAccepted:
        """POST /chat/messages/{id}:reply —— 必须带 Idempotency-Key，返回 202。"""
        response = self._send(
            "POST",
            f"/api/v1/chat/messages/{message_id}:reply",
            json={"parts": list(parts)},
            headers={
                **self._headers(access_token),
                "Idempotency-Key": idempotency_key,
            },
        )
        return CommandAccepted.from_mapping(self._handle(response))

    # ---------- 语音通话（M4-5 §4.1 控制面 REST，全部需 Bearer） ----------

    def create_voice_call(
        self,
        *,
        access_token: str,
        mode: str = "auto",
    ) -> VoiceCallCreated:
        """POST /voice-calls —— 创建通话 + 一次性 participant ticket。

        应用侧以 service credential 调用，应用本身就是该通话的参与者/拥有者
        （owner_actor_id = credential 的 actor_id）。
        """
        response = self._send(
            "POST",
            "/api/v1/voice-calls",
            json={"mode": mode},
            headers=self._headers(access_token),
        )
        return VoiceCallCreated.from_mapping(self._handle(response))

    def get_voice_call(
        self,
        *,
        access_token: str,
        call_id: str,
    ) -> VoiceCallStatus:
        """GET /voice-calls/{call_id} —— 通话状态与安全指标。"""
        response = self._send(
            "GET",
            f"/api/v1/voice-calls/{call_id}",
            headers=self._headers(access_token),
        )
        return VoiceCallStatus.from_mapping(self._handle(response))

    def _voice_call_command(
        self,
        *,
        access_token: str,
        call_id: str,
        action: str,
        idempotency_key: str,
        body: Mapping[str, Any] | None = None,
    ) -> CommandAccepted:
        """POST /voice-calls/{call_id}:<action> —— 命令必须带 Idempotency-Key。"""
        response = self._send(
            "POST",
            f"/api/v1/voice-calls/{call_id}:{action}",
            json=dict(body or {}),
            headers={
                **self._headers(access_token),
                "Idempotency-Key": idempotency_key,
            },
        )
        return CommandAccepted.from_mapping(self._handle(response))

    def resume_voice_call(
        self, *, access_token: str, call_id: str, idempotency_key: str
    ) -> CommandAccepted:
        """POST :resume —— 恢复可恢复通话。"""
        return self._voice_call_command(
            access_token=access_token, call_id=call_id, action="resume",
            idempotency_key=idempotency_key,
        )

    def interrupt_voice_call(
        self,
        *,
        access_token: str,
        call_id: str,
        idempotency_key: str,
        played_audio_ms: int = 0,
    ) -> CommandAccepted:
        """POST :interrupt —— 清空播放并中断当前回复。"""
        return self._voice_call_command(
            access_token=access_token, call_id=call_id, action="interrupt",
            idempotency_key=idempotency_key,
            body={"played_audio_ms": played_audio_ms},
        )

    def end_voice_call(
        self, *, access_token: str, call_id: str, idempotency_key: str
    ) -> CommandAccepted:
        """POST :end —— 结束通话（幂等：重复调用返回同一命令）。"""
        return self._voice_call_command(
            access_token=access_token, call_id=call_id, action="end",
            idempotency_key=idempotency_key,
        )

    def send_voice_call_text(
        self,
        *,
        access_token: str,
        call_id: str,
        text: str,
        idempotency_key: str,
    ) -> CommandAccepted:
        """POST /voice-calls/{call_id}/text —— 向实时会话注入文本（1~8000 字符，拒绝纯空白）。"""
        if not text or not text.strip() or not (1 <= len(text) <= 8000):
            raise ValueError("voice call text must be 1~8000 chars and not blank")
        response = self._send(
            "POST",
            f"/api/v1/voice-calls/{call_id}/text",
            json={"text": text},
            headers={
                **self._headers(access_token),
                "Idempotency-Key": idempotency_key,
            },
        )
        return CommandAccepted.from_mapping(self._handle(response))

    def get_voice_call_transcripts(
        self,
        *,
        access_token: str,
        call_id: str,
        cursor: str | None = None,
        limit: int | None = None,
    ) -> VoiceTranscriptPage:
        """GET /voice-calls/{call_id}/transcripts —— 授权转写历史。"""
        params: dict[str, str] = {}
        if cursor:
            params["cursor"] = cursor
        if limit is not None:
            params["limit"] = str(limit)
        response = self._send(
            "GET",
            f"/api/v1/voice-calls/{call_id}/transcripts",
            params=params,
            headers=self._headers(access_token),
        )
        return VoiceTranscriptPage.from_mapping(self._handle(response))

    def issue_voice_call_ticket(
        self,
        *,
        access_token: str,
        call_id: str,
        role: str,
        origin: str = "",
    ) -> VoiceCallTicket:
        """POST /voice-calls/{call_id}/tickets —— 生成短时、单次、绑定 scope 的 WS ticket。

        role: participant（voice_call:operate）/ observer（voice_call:observe）。
        """
        if role not in ("participant", "observer"):
            raise ValueError("voice call ticket role must be participant|observer")
        response = self._send(
            "POST",
            f"/api/v1/voice-calls/{call_id}/tickets",
            json={"role": role, "origin": origin},
            headers=self._headers(access_token),
        )
        return VoiceCallTicket.from_mapping(self._handle(response))

    # ---------- SSE 出站订阅（只读观察通道） ----------

    async def stream_sse(
        self,
        *,
        access_token: str,
        event_types: Sequence[str] = ("chat.message",),
        stream_id: str | None = None,
        include_payload: bool = True,
        projection: str = "full",
        last_event_id: str | None = None,
        cursor: str | None = None,
    ) -> AsyncIterator[EventEnvelope]:
        """GET /events/stream —— 持续 SSE 订阅（异步迭代器）。

        - 心跳帧（`:` 开头的注释行）与空行被静默跳过，不推进业务 cursor；
        - `id:` 是服务端 cursor，客户端用它断线重连（Last-Event-ID）；
        - `event: error` 结构化错误帧：history_gap 时抛 ElysiaHistoryGap（带
          recovery.cursor），其余按错误码映射；
        - `event: life_event` 时 yield EventEnvelope。

        注意：本方法内部用独立 AsyncClient 打开连接，调用方负责在遍历
        退出/异常时关闭它（见 finally）。
        """
        params: dict[str, Any] = {
            "include_payload": "true" if include_payload else "false",
        }
        if projection:
            params["projection"] = projection
        for etype in event_types:
            params.setdefault("event_type", []).append(etype)
        if stream_id:
            params["stream_id"] = stream_id
        if cursor:
            params["cursor"] = cursor

        headers = self._headers(access_token)
        if last_event_id:
            headers["Last-Event-ID"] = last_event_id

        # 用流式 AsyncClient 保持长连接；读超时拉长避免误判心跳为断线
        stream_client = self._async_client or httpx.AsyncClient(
            base_url=self._base_url, timeout=SSE_READ_TIMEOUT, follow_redirects=False
        )
        try:
            async with stream_client.stream(
                "GET",
                "/api/v1/events/stream",
                params=params,
                headers=headers,
            ) as response:
                if not response.is_success:
                    raise _extract_error(response)
                async for frame in _aiter_sse_frames(response):
                    event = frame.get("event")
                    data_raw = frame.get("data")
                    if data_raw is None:
                        continue  # 心跳 `:` 或空行
                    try:
                        data = json.loads(data_raw)
                    except ValueError:
                        logger.warning("invalid SSE data frame: %.200s", data_raw)
                        continue
                    if event == "error":
                        error = data.get("error") or {}
                        code = str(error.get("code") or "")
                        if code == ERR_HISTORY_GAP:
                            recovery = error.get("recovery") or {}
                            raise ElysiaHistoryGap(
                                str(error.get("message") or "history gap"),
                                recovery_cursor=(
                                    recovery.get("cursor")
                                    if isinstance(recovery, Mapping)
                                    else None
                                ),
                            )
                        raise ElysiaClientError(
                            (
                                "SSE error frame: "
                                f"{code}: {error.get('message', '')}"
                            )
                        )
                    if event in ("life_event", None):
                        envelope = EventEnvelope.from_mapping(data)
                        cursor = frame.get("id")
                        if cursor:
                            object.__setattr__(envelope, "cursor", str(cursor))
                        yield envelope
        except httpx.HTTPError as exc:
            # 连接建立或读取中途断网（Elysium 不可达/重启窗口）：统一映射为
            # ElysiaTransportError，交给 run_bridge_loop 的有界退避重连。
            raise ElysiaTransportError(
                f"Elysium SSE stream unreachable: {type(exc).__name__}: {exc}"
            ) from exc
        finally:
            await stream_client.aclose()


async def _aiter_sse_frames(
    response: httpx.Response,
) -> AsyncIterator[Mapping[str, Any]]:
    """异步解析 SSE 帧：按空行切分，返回 {event, id, data} 字典。

    规范：事件由空行分隔；字段是 `key: value` 或 `key`（data 可多行累加）；
    `:` 开头的行是注释（心跳），忽略。
    """
    current: dict[str, Any] = {"event": None, "id": None, "data": None}
    data_lines: list[str] = []

    async for raw_line in response.aiter_lines():
        if raw_line == "":
            if current.get("data") is not None or current.get("event") is not None:
                yield current
            current = {"event": None, "id": None, "data": None}
            data_lines = []
            continue
        if raw_line.startswith(":"):
            continue  # 心跳注释
        if ":" in raw_line:
            field, _, value = raw_line.partition(":")
            value = value.lstrip(" ")
        else:
            field = raw_line
            value = ""
        field = field.strip()
        if field == "event":
            current["event"] = value
        elif field == "id":
            current["id"] = value
        elif field == "data":
            data_lines.append(value)
            current["data"] = "\n".join(data_lines)
        # 其它字段（retry 等）忽略



__all__ = [
    "CHAT_EVENT_PREFIXES",
    "CommandAccepted",
    "DEFAULT_TIMEOUT",
    "ERR_HISTORY_GAP",
    "EventEnvelope",
    "ElysiaClient",
    "ElysiaClientError",
    "ElysiaHistoryGap",
    "ElysiaTransportError",
    "ElysiaUnauthenticated",
    "SessionTokens",
    "VoiceCallCreated",
    "VoiceCallStatus",
    "VoiceCallTicket",
    "VoiceTranscriptEntry",
    "VoiceTranscriptPage",
]
