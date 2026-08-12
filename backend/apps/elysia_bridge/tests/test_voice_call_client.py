"""
爱莉 Voice Live 控制面契约测试（M4-5 §4.1 控制面 REST）—— 全部 mock httpx。

覆盖：
- 创建通话：POST /voice-calls 带 mode，解析 VoiceCallCreated（call + 一次性 participant ticket）；
- 查状态：GET /voice-calls/{id} → VoiceCallStatus（resumable 显式给出，不猜）；
- 命令端点（resume/interrupt/end/text）全部必须带 Idempotency-Key，解析 CommandAccepted；
  interrupt 带 played_audio_ms；text 校验 1~8000 字符（越界直接抛 ValueError，不触网）；
- 转写：GET /voice-calls/{id}/transcripts 带 cursor/limit，解析 VoiceTranscriptPage
  （entry 含 role/sequence/text/visibility）；
- ticket：POST /voice-calls/{id}/tickets，role 仅 participant|observer（非法直接抛）；
- 错误映射：404（call 不存在）/ 403（无 operate scope）→ ElysiaClientError 带 code；
  401 → ElysiaUnauthenticated；5xx → ElysiaTransportError。

全部走同步 httpx.MockTransport，不依赖真实 Elysium（与 test_elysia_client.py 同模式）。
"""
import json

import httpx
import pytest

from apps.elysia_bridge.elysia_client import (
    CommandAccepted,
    ElysiaClient,
    ElysiaClientError,
    ElysiaTransportError,
    ElysiaUnauthenticated,
    VoiceCallCreated,
    VoiceCallStatus,
    VoiceCallTicket,
    VoiceTranscriptPage,
)

BASE = "http://elysium.test"


class MockTransport(httpx.MockTransport):
    """记录请求便于断言，按 (method, path) 分派 handler。"""

    def __init__(self, handlers: dict[tuple[str, str], httpx.Response | Exception]):
        super().__init__(self._handler)
        self.handlers = handlers
        self.requests: list[httpx.Request] = []

    def _handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        key = (request.method, request.url.path)
        handler = self.handlers.get(key)
        if handler is None:
            raise AssertionError(f"unexpected request: {request.method} {request.url.path}")
        if isinstance(handler, Exception):
            raise handler
        return handler


def _client(transport: httpx.MockTransport) -> ElysiaClient:
    """包装已构造的 MockTransport：调用方以 ``transport = MockTransport({...})``
    构造后传入，这里直接复用实例（不要再包一层 MockTransport，否则把实例
    当 handlers dict 用，``.get`` 必然 AttributeError）。"""
    return ElysiaClient(
        base_url=BASE,
        client=httpx.Client(transport=transport, base_url=BASE),
    )


def _json_response(status: int, payload: dict, request=None) -> httpx.Response:
    return httpx.Response(
        status, json=payload, request=request or httpx.Request("GET", BASE)
    )


# ---------- 创建 / 查状态 ----------

def _created_payload(call_id="call_abc", mode="auto"):
    return {
        "call": {
            "call_id": call_id,
            "episode_id": "epi_1",
            "state": "connecting",
            "mode": mode,
            "provider": "mimo",
            "created_at": "2026-08-11T08:00:00Z",
            "updated_at": "2026-08-11T08:00:01Z",
            "resumable": True,
            "connected": False,
            "input_audio_bytes": 0,
            "output_audio_bytes": 0,
            "interruptions": 0,
            "failure_reason": None,
        },
        "connection": {
            "ticket": "ws-ticket-1",
            "url": "wss://elysium.test/api/v1/voice-calls/call_abc/ws",
            "expires_at": "2026-08-11T08:00:30Z",
            "resource": "voice-call:call_abc",
            "subprotocol": "elysium.voice-call.participant.v1",
        },
    }


def test_create_voice_call_returns_created_with_ticket():
    transport = MockTransport(
        {("POST", "/api/v1/voice-calls"): _json_response(201, _created_payload())}
    )
    client = ElysiaClient(
        base_url=BASE, client=httpx.Client(transport=transport, base_url=BASE)
    )
    created = client.create_voice_call(access_token="access-1", mode="auto")

    assert isinstance(created, VoiceCallCreated)
    assert isinstance(created.call, VoiceCallStatus)
    assert isinstance(created.connection, VoiceCallTicket)
    assert created.call.call_id == "call_abc"
    assert created.call.mode == "auto"
    assert created.call.resumable is True
    assert created.connection.ticket == "ws-ticket-1"
    assert created.connection.subprotocol == "elysium.voice-call.participant.v1"

    req = transport.requests[0]
    assert req.headers["Authorization"] == "Bearer access-1"
    assert json.loads(req.content)["mode"] == "auto"
    # 创建无 Idempotency-Key（资源创建端点，非命令）
    assert "Idempotency-Key" not in req.headers


def test_get_voice_call_status_parses_security_metrics():
    transport = MockTransport(
        {
            ("GET", "/api/v1/voice-calls/call_abc"): _json_response(
                200,
                {
                    "call_id": "call_abc",
                    "state": "active",
                    "mode": "auto",
                    "provider": "mimo",
                    "resumable": False,
                    "connected": True,
                    "input_audio_bytes": 1280,
                    "output_audio_bytes": 40960,
                    "interruptions": 2,
                    "failure_reason": None,
                },
            )
        }
    )
    client = _client(transport)
    status = client.get_voice_call(access_token="access-1", call_id="call_abc")

    assert isinstance(status, VoiceCallStatus)
    assert status.call_id == "call_abc"
    assert status.state == "active"
    assert status.connected is True
    assert status.resumable is False
    assert status.input_audio_bytes == 1280
    assert status.interruptions == 2
    assert transport.requests[0].url.path == "/api/v1/voice-calls/call_abc"


# ---------- 命令端点 ----------

def test_resume_voice_call_carries_idempotency_key():
    transport = MockTransport(
        {
            ("POST", "/api/v1/voice-calls/call_abc:resume"): _json_response(
                202, {"command": {"command_id": "cmd_resume_1", "status": "accepted"}}
            )
        }
    )
    client = _client(transport)
    accepted = client.resume_voice_call(
        access_token="access-1", call_id="call_abc", idempotency_key="elysia-voice-resume-k1"
    )
    assert isinstance(accepted, CommandAccepted)
    assert accepted.command_id == "cmd_resume_1"
    req = transport.requests[0]
    assert req.headers["Idempotency-Key"] == "elysia-voice-resume-k1"


def test_interrupt_voice_call_sends_played_audio_ms():
    transport = MockTransport(
        {
            ("POST", "/api/v1/voice-calls/call_abc:interrupt"): _json_response(
                202, {"command": {"command_id": "cmd_int_1", "status": "accepted"}}
            )
        }
    )
    client = _client(transport)
    accepted = client.interrupt_voice_call(
        access_token="access-1",
        call_id="call_abc",
        idempotency_key="elysia-voice-interrupt-k2",
        played_audio_ms=500,
    )
    assert accepted.command_id == "cmd_int_1"
    req = transport.requests[0]
    assert req.headers["Idempotency-Key"] == "elysia-voice-interrupt-k2"
    assert json.loads(req.content)["played_audio_ms"] == 500


def test_end_voice_call_carries_idempotency_key():
    transport = MockTransport(
        {
            ("POST", "/api/v1/voice-calls/call_abc:end"): _json_response(
                202, {"command": {"command_id": "cmd_end_1", "status": "accepted"}}
            )
        }
    )
    client = _client(transport)
    accepted = client.end_voice_call(
        access_token="access-1", call_id="call_abc", idempotency_key="elysia-voice-end-k3"
    )
    assert accepted.command_id == "cmd_end_1"
    assert transport.requests[0].headers["Idempotency-Key"] == "elysia-voice-end-k3"


def test_send_voice_call_text_validates_length_before_network():
    """文本 1~8000 字符硬校验：越界直接抛 ValueError，不触网。"""
    transport = MockTransport(
        {
            ("POST", "/api/v1/voice-calls/call_abc/text"): _json_response(
                202, {"command": {"command_id": "cmd_text_1", "status": "accepted"}}
            )
        }
    )
    client = _client(transport)

    with pytest.raises(ValueError):
        client.send_voice_call_text(
            access_token="access-1", call_id="call_abc", text="", idempotency_key="k"
        )
    with pytest.raises(ValueError):
        client.send_voice_call_text(
            access_token="access-1", call_id="call_abc", text="x" * 8001, idempotency_key="k"
        )
    assert transport.requests == []  # 未发出任何请求

    accepted = client.send_voice_call_text(
        access_token="access-1",
        call_id="call_abc",
        text="你好，爱莉",
        idempotency_key="elysia-voice-text-k4",
    )
    assert accepted.command_id == "cmd_text_1"
    req = transport.requests[0]
    assert req.headers["Idempotency-Key"] == "elysia-voice-text-k4"
    assert json.loads(req.content)["text"] == "你好，爱莉"


def test_send_voice_call_text_rejects_whitespace_only():
    transport = MockTransport({})
    client = _client(transport)
    with pytest.raises(ValueError):
        client.send_voice_call_text(
            access_token="access-1", call_id="call_abc", text="   ", idempotency_key="k"
        )
    assert transport.requests == []


# ---------- 转写 ----------

def _transcript_entry(*, sequence=1, role="assistant", text="爱莉的语音回复", visibility="private"):
    return {
        "sequence": sequence,
        "occurred_at": "2026-08-11T08:01:00Z",
        "role": role,
        "text": text,
        "provider_event_id": "prov_1",
        "visibility": visibility,
    }


def test_get_voice_call_transcripts_parses_page():
    transport = MockTransport(
        {
            ("GET", "/api/v1/voice-calls/call_abc/transcripts"): _json_response(
                200,
                {
                    "transcripts": [
                        _transcript_entry(sequence=1, role="user", text="你好爱莉"),
                        _transcript_entry(sequence=2, role="assistant", text="我在呢"),
                    ],
                    "next_cursor": "cursor-next-1",
                    "has_more": True,
                },
            )
        }
    )
    client = _client(transport)
    page = client.get_voice_call_transcripts(
        access_token="access-1", call_id="call_abc"
    )

    assert isinstance(page, VoiceTranscriptPage)
    assert page.has_more is True
    assert page.next_cursor == "cursor-next-1"
    assert len(page.transcripts) == 2
    assert page.transcripts[0].role == "user"
    assert page.transcripts[0].text == "你好爱莉"
    assert page.transcripts[1].role == "assistant"
    assert page.transcripts[1].sequence == 2
    assert page.transcripts[1].visibility == "private"

    req = transport.requests[0]
    # 无 cursor/limit 时不带分页参数
    assert "cursor" not in req.url.params
    assert "limit" not in req.url.params


def test_get_voice_call_transcripts_passes_cursor_and_limit():
    transport = MockTransport(
        {
            ("GET", "/api/v1/voice-calls/call_abc/transcripts"): _json_response(
                200, {"transcripts": [], "next_cursor": None, "has_more": False}
            )
        }
    )
    client = _client(transport)
    client.get_voice_call_transcripts(
        access_token="access-1", call_id="call_abc", cursor="cursor-5", limit=20
    )
    req = transport.requests[0]
    assert req.url.params.get("cursor") == "cursor-5"
    assert req.url.params.get("limit") == "20"


# ---------- ticket ----------

def test_issue_voice_call_ticket_participant():
    transport = MockTransport(
        {
            ("POST", "/api/v1/voice-calls/call_abc/tickets"): _json_response(
                200,
                {
                    "ticket": "ws-ticket-p",
                    "url": "wss://elysium.test/api/v1/voice-calls/call_abc/ws",
                    "expires_at": "2026-08-11T08:02:00Z",
                    "resource": "voice-call:call_abc",
                    "subprotocol": "elysium.voice-call.participant.v1",
                },
            )
        }
    )
    client = _client(transport)
    ticket = client.issue_voice_call_ticket(
        access_token="access-1", call_id="call_abc", role="participant", origin="https://app.example"
    )
    assert isinstance(ticket, VoiceCallTicket)
    assert ticket.ticket == "ws-ticket-p"
    body = json.loads(transport.requests[0].content)
    assert body["role"] == "participant"
    assert body["origin"] == "https://app.example"


def test_issue_voice_call_ticket_rejects_invalid_role():
    transport = MockTransport({})
    client = _client(transport)
    with pytest.raises(ValueError):
        client.issue_voice_call_ticket(
            access_token="access-1", call_id="call_abc", role="admin"
        )
    assert transport.requests == []


# ---------- 错误映射 ----------

def test_voice_call_404_maps_to_client_error_with_code():
    transport = MockTransport(
        {
            ("GET", "/api/v1/voice-calls/nope"): _json_response(
                404, {"error": {"code": "voice_call_not_found", "message": "通话不存在"}}
            )
        }
    )
    client = _client(transport)
    with pytest.raises(ElysiaClientError) as exc:
        client.get_voice_call(access_token="access-1", call_id="nope")
    assert "voice_call_not_found" in str(exc.value)


def test_voice_call_403_maps_to_client_error_with_scope_code():
    transport = MockTransport(
        {
            ("POST", "/api/v1/voice-calls/call_abc:end"): _json_response(
                403, {"error": {"code": "insufficient_scope", "message": "缺少 voice_call:operate"}}
            )
        }
    )
    client = _client(transport)
    with pytest.raises(ElysiaClientError) as exc:
        client.end_voice_call(
            access_token="access-1", call_id="call_abc", idempotency_key="k"
        )
    assert "insufficient_scope" in str(exc.value)


def test_voice_call_401_maps_to_unauthenticated():
    transport = MockTransport(
        {
            ("GET", "/api/v1/voice-calls/call_abc"): _json_response(
                401, {"error": {"code": "session_revoked", "message": "会话已失效"}}
            )
        }
    )
    client = _client(transport)
    with pytest.raises(ElysiaUnauthenticated):
        client.get_voice_call(access_token="expired", call_id="call_abc")


def test_voice_call_5xx_maps_to_transport_error():
    transport = MockTransport(
        {
            ("POST", "/api/v1/voice-calls"): _json_response(
                503, {"error": {"code": "voice_live_unavailable", "message": "语音服务不可用"}}
            )
        }
    )
    client = _client(transport)
    with pytest.raises(ElysiaTransportError):
        client.create_voice_call(access_token="access-1")
