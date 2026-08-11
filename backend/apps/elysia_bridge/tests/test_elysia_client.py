"""
elysia_client 契约测试（8.1 清单第 2 项）—— 全部 mock httpx，不依赖真实 Elysium。

覆盖（对应步骤文件 §4.4 凭据流程 + §4.1/§4.2/§4.3 接口契约）：
- 凭据：create_credential 返回 (credential_id, secret)，secret 只在创建时返回一次；
- 换 session：issue_session 用 service_credential grant 换 access/refresh；
- refresh：refresh_session 轮换 token 对；
- 撤销：revoke_credential 返回 revoked，401/credential_revoked 映射为 ElysiaUnauthenticated；
- inject：合法请求体（含 platform/chat_type）+ 202 返回 message_id/stream_id/accepted；
- 命令端点：send/reply 带 Idempotency-Key，解析 CommandAccepted；
- SSE：信封解析（life_event + id cursor）、payload 授权、心跳不推进 cursor、
  history_gap 错误帧抛 ElysiaHistoryGap（带 recovery cursor）、断线（401）映射。
"""
import json

import httpx
import pytest

from apps.elysia_bridge import elysia_client
from apps.elysia_bridge.elysia_client import (
    CommandAccepted,
    EventEnvelope,
    ElysiaClient,
    ElysiaHistoryGap,
    ElysiaUnauthenticated,
    SessionTokens,
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


def _client(handlers) -> ElysiaClient:
    return ElysiaClient(
        base_url=BASE,
        client=httpx.Client(transport=MockTransport(handlers), base_url=BASE),
    )


def _json_response(status: int, payload: dict) -> httpx.Response:
    return httpx.Response(status, json=payload, request=httpx.Request("GET", BASE))


# ---------- 凭据 / 会话 ----------

def test_create_credential_returns_secret_once():
    transport = MockTransport(
        {
            ("POST", "/api/v1/admin/credentials"): _json_response(
                201,
                {
                    "credential": {
                        "credential_id": "cred_abc",
                        "actor_id": "elysia-app",
                        "audience": "elysium-platform-service",
                        "role": "platform_service",
                        "scopes": ["chat:write", "events:read"],
                        "resource_grants": ["stream:elysia-1"],
                    },
                    "secret": "elysium_one_time_secret_xyz",
                },
            )
        }
    )
    client = ElysiaClient(base_url=BASE, client=httpx.Client(transport=transport, base_url=BASE))
    cid, secret = client.create_credential(
        access_token="admin-token",
        actor_id="elysia-app",
        scopes=["chat:write", "events:read"],
        resource_grants=["stream:elysia-1"],
    )
    assert cid == "cred_abc"
    assert secret == "elysium_one_time_secret_xyz"
    # 请求带管理员 token 与最小 scope 集
    req = transport.requests[0]
    assert req.headers["Authorization"] == "Bearer admin-token"
    body = json.loads(req.content)
    assert body["scopes"] == ["chat:write", "events:read"]
    assert body["resource_grants"] == ["stream:elysia-1"]
    assert body["actor_id"] == "elysia-app"


def test_issue_session_uses_service_credential_grant():
    transport = MockTransport(
        {
            ("POST", "/api/v1/auth/sessions"): _json_response(
                200,
                {
                    "access_token": "access-1",
                    "refresh_token": "refresh-1",
                    "identity": {"actor_id": "elysia-app"},
                },
            )
        }
    )
    client = ElysiaClient(base_url=BASE, client=httpx.Client(transport=transport, base_url=BASE))
    tokens = client.issue_session(service_credential="elysium_secret", audience="elysium-platform-service")
    assert isinstance(tokens, SessionTokens)
    assert tokens.access_token == "access-1"
    assert tokens.refresh_token == "refresh-1"
    body = json.loads(transport.requests[0].content)
    assert body["grant_type"] == "service_credential"
    assert body["service_credential"] == "elysium_secret"
    assert body["audience"] == "elysium-platform-service"


def test_refresh_session_rotates_tokens():
    transport = MockTransport(
        {
            ("POST", "/api/v1/auth/sessions/current:refresh"): _json_response(
                200,
                {"access_token": "access-2", "refresh_token": "refresh-2"},
            )
        }
    )
    client = ElysiaClient(base_url=BASE, client=httpx.Client(transport=transport, base_url=BASE))
    tokens = client.refresh_session(refresh_token="refresh-1")
    assert tokens.access_token == "access-2"
    assert tokens.refresh_token == "refresh-2"
    assert json.loads(transport.requests[0].content)["refresh_token"] == "refresh-1"


def test_revoke_credential():
    transport = MockTransport(
        {("DELETE", "/api/v1/admin/credentials/cred_abc"): _json_response(200, {"revoked": True})}
    )
    client = ElysiaClient(base_url=BASE, client=httpx.Client(transport=transport, base_url=BASE))
    assert client.revoke_credential(access_token="admin-token", credential_id="cred_abc") is True


def test_401_maps_to_unauthenticated():
    transport = MockTransport(
        {
            ("POST", "/api/v1/auth/sessions/current:refresh"): _json_response(
                401, {"error": {"code": "credential_revoked", "message": "凭据已撤销"}}
            )
        }
    )
    client = ElysiaClient(base_url=BASE, client=httpx.Client(transport=transport, base_url=BASE))
    with pytest.raises(ElysiaUnauthenticated):
        client.refresh_session(refresh_token="refresh-1")


# ---------- 入站 inject ----------

def test_inject_message_ok():
    transport = MockTransport(
        {
            ("POST", "/api/v1/chat/messages:inject"): _json_response(
                202, {"message_id": "inject_abc", "stream_id": "elysia-1", "accepted": True}
            )
        }
    )
    client = ElysiaClient(base_url=BASE, client=httpx.Client(transport=transport, base_url=BASE))
    result = client.inject_message(
        access_token="access-1",
        stream_id="elysia-1",
        content="你好，爱莉",
        sender_name="汐汐",
        sender_id="user-42",
        chat_type="private",
        platform="ayla",
    )
    assert result["accepted"] is True
    assert result["message_id"] == "inject_abc"
    body = json.loads(transport.requests[0].content)
    assert body["stream_id"] == "elysia-1"
    assert body["content"] == "你好，爱莉"
    assert body["sender_id"] == "user-42"
    assert body["chat_type"] == "private"
    assert body["platform"] == "ayla"
    assert "Idempotency-Key" not in transport.requests[0].headers  # inject 无幂等键


def test_inject_missing_stream_raises_client_error():
    transport = MockTransport(
        {
            ("POST", "/api/v1/chat/messages:inject"): _json_response(
                404, {"error": {"code": "stream_not_found", "message": "聊天流不存在"}}
            )
        }
    )
    client = ElysiaClient(base_url=BASE, client=httpx.Client(transport=transport, base_url=BASE))
    with pytest.raises(elysia_client.ElysiaClientError) as exc:
        client.inject_message(access_token="access-1", stream_id="nope", content="x")
    assert "stream_not_found" in str(exc.value)


# ---------- 出站命令端点 ----------

def test_send_chat_message_carries_idempotency_key():
    transport = MockTransport(
        {
            ("POST", "/api/v1/chat/messages:send"): _json_response(
                202,
                {"command": {"command_id": "cmd_1", "status": "accepted"}},
            )
        }
    )
    client = ElysiaClient(base_url=BASE, client=httpx.Client(transport=transport, base_url=BASE))
    accepted = client.send_chat_message(
        access_token="access-1",
        stream_id="elysia-1",
        parts=[{"type": "text", "text": "你好"}],
        idempotency_key="elysia-send-uuid-1",
    )
    assert isinstance(accepted, CommandAccepted)
    assert accepted.command_id == "cmd_1"
    req = transport.requests[0]
    assert req.headers["Idempotency-Key"] == "elysia-send-uuid-1"
    assert json.loads(req.content)["parts"] == [{"type": "text", "text": "你好"}]


def test_reply_chat_message_carries_idempotency_key():
    transport = MockTransport(
        {
            ("POST", "/api/v1/chat/messages/inject_abc:reply"): _json_response(
                202, {"command": {"command_id": "cmd_2", "status": "accepted"}}
            )
        }
    )
    client = ElysiaClient(base_url=BASE, client=httpx.Client(transport=transport, base_url=BASE))
    accepted = client.reply_chat_message(
        access_token="access-1",
        message_id="inject_abc",
        parts=[{"type": "text", "text": "好的"}],
        idempotency_key="elysia-reply-uuid-2",
    )
    assert accepted.command_id == "cmd_2"
    assert transport.requests[0].headers["Idempotency-Key"] == "elysia-reply-uuid-2"


# ---------- SSE 出站订阅 ----------

def _sse_envelope(*, event_id="evt_1", event_type="chat.message.received", stream_id="elysia-1",
                  content="爱莉的回复", reply_target=None, sender_id="user-42"):
    data = {
        "event_id": event_id,
        "sequence": 10,
        "event_type": event_type,
        "stream_id": stream_id,
        "channel": "elysia-app",
        "actor": {"type": "consciousness", "id": "elysia_1", "display_name": "爱莉"},
        "payload": {"content": content, "metadata": {"sender_id": sender_id}},
        "visibility": {"scope": "private", "audience": []},
    }
    if reply_target:
        data["reply_target"] = reply_target
    return data


class _SSETransport(httpx.MockTransport):
    """把预制的 SSE 文本块按 path 返回；记录请求头。"""

    def __init__(
        self,
        sse_body: str = "",
        status: int = 200,
        error_body: dict | None = None,
    ):
        super().__init__(self._handler)
        self.sse_body = sse_body
        self.status = status
        self.error_body = error_body
        self.requests: list[httpx.Request] = []

    def _handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.status != 200:
            return _json_response(self.status, self.error_body or {})
        return httpx.Response(
            200,
            headers={"content-type": "text/event-stream"},
            content=self.sse_body.encode("utf-8"),
            request=request,
        )


def _sse_frame(*, event: str, cursor: str | None, data: dict | None) -> str:
    lines = [f"event: {event}"]
    if cursor:
        lines.append(f"id: {cursor}")
    if data is not None:
        lines.append(f"data: {json.dumps(data, ensure_ascii=False)}")
    return "\n".join(lines) + "\n\n"


def _sse_client(transport) -> ElysiaClient:
    """SSE 测试用 AsyncClient（stream_sse 是异步迭代器）。"""
    return ElysiaClient(
        base_url=BASE,
        client=httpx.Client(transport=transport, base_url=BASE),
        async_client=httpx.AsyncClient(transport=transport, base_url=BASE),
    )


async def test_sse_parses_life_event_with_cursor_and_payload():
    evt = _sse_envelope()
    body = _sse_frame(event="life_event", cursor="cursor-1", data=evt)
    transport = _SSETransport(body)
    client = _sse_client(transport)

    frames = [
        frame
        async for frame in client.stream_sse(
            access_token="access-1", stream_id="elysia-1"
        )
    ]
    assert len(frames) == 1
    env: EventEnvelope = frames[0]
    assert env.event_id == "evt_1"
    assert env.event_type == "chat.message.received"
    assert env.stream_id == "elysia-1"
    assert env.is_chat_message is True
    # payload 授权：projection=full + include_payload 返回原文
    assert env.payload["content"] == "爱莉的回复"
    assert env.payload["metadata"]["sender_id"] == "user-42"
    # 订阅参数
    req = transport.requests[0]
    assert req.url.params.get("include_payload") == "true"
    assert req.url.params.get("projection") == "full"
    assert req.url.params.get("stream_id") == "elysia-1"
    assert "chat.message" in req.url.params.get_list("event_type")


async def test_sse_skips_heartbeat_and_empty_lines():
    evt = _sse_envelope(event_id="evt_hb")
    body = (
        ": heartbeat\n\n"
        "\n"
        + _sse_frame(event="life_event", cursor="cursor-2", data=evt)
    )
    transport = _SSETransport(body)
    client = _sse_client(transport)
    frames = [f async for f in client.stream_sse(access_token="access-1")]
    assert len(frames) == 1
    assert frames[0].event_id == "evt_hb"


async def test_sse_history_gap_raises_with_recovery_cursor():
    body = _sse_frame(
        event="error",
        cursor=None,
        data={
            "error": {
                "code": "history_gap",
                "message": "请求的事件历史已不连续。",
                "recovery": {"action": "restart_from_cursor", "cursor": "safe-cursor-9"},
            }
        },
    )
    transport = _SSETransport(body)
    client = _sse_client(transport)
    with pytest.raises(ElysiaHistoryGap) as exc:
        async for _ in client.stream_sse(access_token="access-1"):
            pass
    assert exc.value.recovery_cursor == "safe-cursor-9"


async def test_sse_401_maps_to_unauthenticated():
    transport = _SSETransport(
        status=401,
        error_body={"error": {"code": "unauthenticated", "message": "会话已失效"}},
    )
    client = _sse_client(transport)
    with pytest.raises(ElysiaUnauthenticated):
        async for _ in client.stream_sse(access_token="expired"):
            pass


async def test_sse_sends_last_event_id_for_resume():
    evt = _sse_envelope()
    body = _sse_frame(event="life_event", cursor="cursor-5", data=evt)
    transport = _SSETransport(body)
    client = _sse_client(transport)
    async for _ in client.stream_sse(access_token="access-1", last_event_id="cursor-4"):
        pass
    assert transport.requests[0].headers["Last-Event-ID"] == "cursor-4"


async def test_sse_non_chat_event_still_yielded_but_flag_false():
    data = {
        "event_id": "evt_presence",
        "sequence": 11,
        "event_type": "presence.updated",
        "stream_id": "elysia-1",
        "channel": "elysia-app",
        "actor": {"type": "component", "id": "x"},
        "payload": None,
    }
    body = _sse_frame(event="life_event", cursor="cursor-6", data=data)
    transport = _SSETransport(body)
    client = _sse_client(transport)
    frames = [f async for f in client.stream_sse(access_token="access-1")]
    assert len(frames) == 1
    assert frames[0].is_chat_message is False
