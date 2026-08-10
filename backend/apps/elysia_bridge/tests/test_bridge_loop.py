"""
SSE 订阅循环契约测试（8.1 清单第 5~6 项）—— mock Elysium 流，验证 run_bridge_loop。

覆盖：
- 收到 chat.message.* + 匹配 stream → 投影落库 + 广播 elysia.reply（复用 outbound）；
- 非匹配 stream 事件 → 跳过不落库；
- 断线重连：传输错误后按最后 cursor 重连（重连时带 cursor/Last-Event-ID）；
- history_gap 错误帧 → 按 recovery.cursor 重连；
- 心跳不推进 cursor（cursor 只在有事件时更新）；
- stop_event 置位 → 优雅退出循环；
- 401 → 走凭据 refresh 恢复后重连。

用 fake ElysiaClient（记录 stream_sse 调用参数，按剧本产出事件/抛异常）。
测试通过 on_event 回调在收到预期事件后 set stop_event，使循环优雅退出
（避免真实场景"流结束即重连"导致测试无限跑）。
"""
import asyncio

import pytest
from channels.db import database_sync_to_async

from apps.chat import services as chat_services
from apps.chat.models import Message
from apps.elysia_bridge import services as bridge_services
from apps.elysia_bridge.elysia_client import (
    ElysiaHistoryGap,
    ElysiaTransportError,
    ElysiaUnauthenticated,
    EventEnvelope,
)
from apps.elysia_bridge.models import ElysiaProfile

pytestmark = pytest.mark.usefixtures("transactional_db")


# ---------- fake 客户端 ----------

def _envelope(*, event_id, stream_id, content="回复", cursor=None, sender_id=None):
    payload = {"content": content, "metadata": {}}
    if sender_id is not None:
        payload["metadata"]["sender_id"] = sender_id
    data = {
        "event_id": event_id,
        "sequence": 1,
        "event_type": "chat.message.delivery_confirmed",
        "stream_id": stream_id,
        "channel": "elysia-app",
        "actor": {"type": "consciousness", "id": "elysia_1", "display_name": "爱莉"},
        "payload": payload,
    }
    env = EventEnvelope.from_mapping(data)
    if cursor:
        object.__setattr__(env, "cursor", cursor)
    return env


class _FakeClient:
    """按剧本驱动 stream_sse 的 fake client（跨连接推进，不重放）。

    每个元素是 (kind, payload)：
    - ("event", envelope)  yield 一个事件；
    - ("raise", exc)       抛异常（模拟断线/错误帧/401）。

    剧本是**全局游标**：每次 stream_sse 调用从上一次停止处继续，因此
    一次连接内按顺序消费若干元素后抛异常/结束，下一次连接接着消费剩余元素，
    可精确模拟"断线→重连→继续收到后续事件"。
    """

    def __init__(self, script):
        self.script = list(script)
        self.calls: list[dict] = []
        self._pos = 0

    async def stream_sse(self, **kwargs):
        self.calls.append(kwargs)
        while self._pos < len(self.script):
            kind, payload = self.script[self._pos]
            if kind == "event":
                self._pos += 1
                yield payload
            elif kind == "raise":
                self._pos += 1
                raise payload
            else:
                self._pos += 1
                continue


class _FakeCreds:
    def __init__(self, token="token-1"):
        self.token = token
        self.refreshed = 0

    def ensure_session(self, *, stream_id):
        return self.token

    def refresh(self):
        self.refreshed += 1
        self.token = f"token-{self.refreshed + 1}"
        return self.token


@database_sync_to_async
def _mk_profile_sync(user_factory):
    elysia_user = user_factory(username="elysia_loop_core", nickname="爱莉")
    profile = ElysiaProfile.objects.create(
        user=elysia_user,
        stream_id="stream_loop_1",
        enabled=True,
        display_name="爱莉",
    )
    user = user_factory(username="user_loop_a", nickname="汐汐")
    conv = chat_services.get_or_create_conversation(user, elysia_user)
    return profile, user, conv


async def _mk_profile(user_factory):
    return await _mk_profile_sync(user_factory)


@database_sync_to_async
def _count(conv):
    return Message.objects.filter(conversation=conv).count()


@database_sync_to_async
def _find(conv, key):
    return Message.objects.filter(conversation=conv, idempotency_key=key).first()


async def _run_until(client, creds, stop, *, profile, target_event_id, **kwargs):
    """跑循环直到收到 target_event_id 后 set stop 并优雅退出。"""

    async def _maybe_stop(env):
        if env.event_id == target_event_id:
            stop.set()

    await asyncio.wait_for(
        bridge_services.run_bridge_loop(
            profile=profile,
            client=client,
            credentials=creds,
            stop_event=stop,
            reconnect_seconds=0.01,
            on_event=_maybe_stop,
            **kwargs,
        ),
        timeout=10,
    )


# ---------- 契约测试 ----------

async def test_loop_projects_chat_event_and_broadcasts(user_factory):
    profile, user, conv = await _mk_profile(user_factory)
    env = _envelope(
        event_id="evt_loop_1",
        stream_id="stream_loop_1",
        content="爱莉的回复",
        cursor="cursor-1",
        sender_id=str(user.id),
    )
    client = _FakeClient([("event", env)])
    creds = _FakeCreds()
    stop = asyncio.Event()

    await _run_until(client, creds, stop, profile=profile, target_event_id="evt_loop_1")

    # 已投影落库
    msg = await _find(conv, "elysia-evt_loop_1")
    assert msg is not None
    assert msg.sender_id == profile.user_id
    assert msg.content == "爱莉的回复"
    # 订阅参数：stream 匹配 + payload 授权
    call = client.calls[0]
    assert call["stream_id"] == "stream_loop_1"
    assert call["include_payload"] is True
    assert "chat.message" in call["event_types"]


async def test_loop_skips_non_matching_stream(user_factory):
    profile, user, conv = await _mk_profile(user_factory)
    env_other = _envelope(
        event_id="evt_loop_other",
        stream_id="another-stream",
        content="不该投",
        cursor="cursor-x",
    )
    client = _FakeClient([("event", env_other)])
    creds = _FakeCreds()
    stop = asyncio.Event()

    await _run_until(
        client, creds, stop, profile=profile, target_event_id="evt_loop_other"
    )

    assert await _count(conv) == 0


async def test_loop_reconnects_with_last_cursor_after_transport_error(user_factory):
    """传输错误后重连，第二次连接带上次事件的 cursor（补历史，不丢）。"""
    profile, user, conv = await _mk_profile(user_factory)
    env1 = _envelope(
        event_id="evt_loop_r1",
        stream_id="stream_loop_1",
        content="第一条",
        cursor="cursor-r1",
        sender_id=str(user.id),
    )
    env2 = _envelope(
        event_id="evt_loop_r2",
        stream_id="stream_loop_1",
        content="第二条",
        cursor="cursor-r2",
        sender_id=str(user.id),
    )
    # 第一次连接：事件r1 → 断线；第二次连接（带cursor-r1）：事件r2 → on_event 停止
    client = _FakeClient(
        [
            ("event", env1),
            ("raise", ElysiaTransportError("connection reset")),
            ("event", env2),
        ]
    )
    creds = _FakeCreds()
    stop = asyncio.Event()

    await _run_until(
        client, creds, stop, profile=profile, target_event_id="evt_loop_r2"
    )

    assert len(client.calls) == 2
    # 第一次无 cursor；第二次带 cursor-r1
    assert client.calls[0].get("cursor") is None
    assert client.calls[1].get("cursor") == "cursor-r1"
    assert client.calls[1].get("last_event_id") == "cursor-r1"
    # 两条都投影了
    assert await _count(conv) == 2


async def test_loop_resumes_from_history_gap_recovery_cursor(user_factory):
    """history_gap 错误帧 → 按 recovery.cursor 重连（禁止跳到尾部）。"""
    profile, user, conv = await _mk_profile(user_factory)
    env2 = _envelope(
        event_id="evt_loop_h2",
        stream_id="stream_loop_1",
        content="缺口后第一条",
        cursor="cursor-h2",
        sender_id=str(user.id),
    )
    client = _FakeClient(
        [
            ("raise", ElysiaHistoryGap("gap", recovery_cursor="safe-cursor-9")),
            ("event", env2),
        ]
    )
    creds = _FakeCreds()
    stop = asyncio.Event()

    await _run_until(
        client, creds, stop, profile=profile, target_event_id="evt_loop_h2"
    )

    assert len(client.calls) == 2
    # 第二次连接从 recovery.cursor 重连
    assert client.calls[1].get("cursor") == "safe-cursor-9"
    assert await _find(conv, "elysia-evt_loop_h2") is not None


async def test_loop_heartbeat_does_not_advance_cursor(user_factory):
    """无 cursor 事件不推进 last_cursor；只有带 cursor 的事件才推进。"""
    profile, user, conv = await _mk_profile(user_factory)
    env1 = _envelope(
        event_id="evt_loop_hb1",
        stream_id="stream_loop_1",
        content="无cursor",
        cursor=None,
        sender_id=str(user.id),
    )
    env2 = _envelope(
        event_id="evt_loop_hb2",
        stream_id="stream_loop_1",
        content="带cursor",
        cursor="cursor-hb2",
        sender_id=str(user.id),
    )
    env3 = _envelope(
        event_id="evt_loop_hb3",
        stream_id="stream_loop_1",
        content="重连后",
        cursor="cursor-hb3",
        sender_id=str(user.id),
    )
    # 第一次连接：env1(无cursor) + env2(cursor-hb2) → 断线；
    # 第二次连接（cursor=cursor-hb2）：env3 → set stop 退出
    client = _FakeClient(
        [
            ("event", env1),
            ("event", env2),
            ("raise", ElysiaTransportError("drop")),
            ("event", env3),
        ]
    )
    creds = _FakeCreds()
    stop = asyncio.Event()

    async def _stop_after_hb3(env):
        if env.event_id == "evt_loop_hb3":
            stop.set()

    await asyncio.wait_for(
        bridge_services.run_bridge_loop(
            profile=profile,
            client=client,
            credentials=creds,
            stop_event=stop,
            reconnect_seconds=0.01,
            on_event=_stop_after_hb3,
        ),
        timeout=10,
    )

    assert len(client.calls) == 2
    # 第二次重连 cursor 来自 env2（cursor-hb2），env1 的无 cursor 事件未覆盖它
    assert client.calls[1].get("cursor") == "cursor-hb2"
    # env1/env2/env3 全部投影
    assert await _find(conv, "elysia-evt_loop_hb1") is not None
    assert await _find(conv, "elysia-evt_loop_hb2") is not None
    assert await _find(conv, "elysia-evt_loop_hb3") is not None


async def test_loop_unauth_refreshes_and_reconnects(user_factory):
    """401 → 凭据 refresh 恢复 → 重连继续。"""
    profile, user, conv = await _mk_profile(user_factory)
    env = _envelope(
        event_id="evt_loop_ua",
        stream_id="stream_loop_1",
        content="401后恢复",
        cursor="cursor-ua",
        sender_id=str(user.id),
    )
    client = _FakeClient(
        [
            ("raise", ElysiaUnauthenticated("expired")),
            ("event", env),
        ]
    )
    creds = _FakeCreds()
    stop = asyncio.Event()

    await _run_until(
        client, creds, stop, profile=profile, target_event_id="evt_loop_ua"
    )

    assert creds.refreshed == 1
    assert await _find(conv, "elysia-evt_loop_ua") is not None


async def test_loop_stops_gracefully_on_stop_event(user_factory):
    """stop_event 置位后循环退出（不再重连）。"""
    profile, user, conv = await _mk_profile(user_factory)
    env = _envelope(
        event_id="evt_loop_stop",
        stream_id="stream_loop_1",
        content="停止前",
        cursor="cursor-stop",
        sender_id=str(user.id),
    )
    client = _FakeClient([("event", env)])
    creds = _FakeCreds()
    stop = asyncio.Event()

    async def _stop(env):
        stop.set()

    await asyncio.wait_for(
        bridge_services.run_bridge_loop(
            profile=profile,
            client=client,
            credentials=creds,
            stop_event=stop,
            reconnect_seconds=0.01,
            on_event=_stop,
        ),
        timeout=10,
    )

    # 流结束后因 stop 已 set，不再重连
    assert len(client.calls) == 1
    assert await _find(conv, "elysia-evt_loop_stop") is not None
