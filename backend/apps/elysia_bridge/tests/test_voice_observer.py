"""
voice_observer 契约测试 —— observer WS 事件 → 状态/投影广播（mock 依赖，不连真实 Elysium）。

覆盖：
- `_observer_ws_url`：http/https → ws/wss + ticket query；
- 事件分派（WebsocketCommunicator 接 ChatConsumer 断言帧）：
  * observer.ready / state → 补拉完整状态 → 广播 `elysia.voice.call.status`；
  * transcript（is_final + role=assistant）→ 投影（幂等事件 id 透传）→ 广播 `elysia.voice.projected`（累计投影数）；
  * transcript partial / role=user → 不投影；
  * ended / error(fatal) → 广播状态 + 返回终态（停止观察）；
  * 无关帧安全忽略；
- ensure_observing / stop_observing：幂等启停（FakeThread 不真连网）。
"""
import logging

import pytest
from channels.db import database_sync_to_async
from channels.routing import URLRouter
from channels.testing import WebsocketCommunicator
from django.urls import path

from apps.chat.consumers import ChatConsumer
from apps.elysia_bridge import voice_observer
from apps.elysia_bridge.elysia_client import VoiceCallStatus
from apps.elysia_bridge.models import ElysiaProfile

pytestmark = pytest.mark.usefixtures("transactional_db")

WS_PATH = "ws/chat/"


# ---------- 测试数据构造 ----------


@database_sync_to_async
def _make_profile(user_factory):
    elysia_user = user_factory(username="elysia_voice_obs", nickname="爱莉")
    profile = ElysiaProfile.objects.create(
        user=elysia_user,
        stream_id="stream_voice_obs",
        enabled=True,
        display_name="爱莉",
    )
    user = user_factory(username="user_voice_obs", nickname="汐汐")
    return elysia_user, profile, user


def _token_for(user):
    from rest_framework_simplejwt.tokens import RefreshToken

    return str(RefreshToken.for_user(user).access_token)


async def _connect_ws(user):
    app = URLRouter([path(WS_PATH, ChatConsumer.as_asgi())])
    comm = WebsocketCommunicator(app, f"/{WS_PATH}?token={_token_for(user)}")
    connected, _ = await comm.connect()
    assert connected is True
    return comm


def _fake_status(state="active", **kw) -> VoiceCallStatus:
    return VoiceCallStatus(
        call_id=kw.pop("call_id", "call-1"),
        episode_id="ep-1",
        state=state,
        mode="auto",
        provider="voice_live",
        created_at="2026-08-11T08:00:00Z",
        updated_at="2026-08-11T08:01:00Z",
        resumable=True,
        connected=state not in ("ended", "failed"),
        **kw,
    )


# ---------- URL 派生 ----------


def test_observer_ws_url_http_https():
    assert (
        voice_observer._observer_ws_url("http://el:8000", "call-1", "tok1")
        == "ws://el:8000/api/v1/voice-calls/call-1/observe?ticket=tok1"
    )
    assert (
        voice_observer._observer_ws_url("https://el:8000/", "c2", "tok2")
        == "wss://el:8000/api/v1/voice-calls/c2/observe?ticket=tok2"
    )


# ---------- 事件分派 → 广播 ----------


async def test_state_event_broadcasts_call_status(user_factory, monkeypatch):
    _, profile, user = await _make_profile(user_factory)
    monkeypatch.setattr(
        "apps.elysia_bridge.services.get_voice_call_status",
        lambda profile, call_id: _fake_status("active"),
    )
    comm = await _connect_ws(user)
    try:
        terminal = await voice_observer._handle_observer_frame(
            profile, "call-1", {"type": "state"}
        )
        assert terminal is False
        frame = await comm.receive_json_from(timeout=1)
        assert frame["type"] == "elysia.voice.call.status"
        assert frame["data"]["call"]["call_id"] == "call-1"
        assert frame["data"]["call"]["state"] == "active"
    finally:
        await comm.disconnect()


async def test_observer_ready_broadcasts_call_status(user_factory, monkeypatch):
    _, profile, user = await _make_profile(user_factory)
    monkeypatch.setattr(
        "apps.elysia_bridge.services.get_voice_call_status",
        lambda profile, call_id: _fake_status("active"),
    )
    comm = await _connect_ws(user)
    try:
        terminal = await voice_observer._handle_observer_frame(
            profile,
            "call-1",
            {"type": "observer.ready", "protocol": 1, "call_id": "call-1", "session": None},
        )
        assert terminal is False
        frame = await comm.receive_json_from(timeout=1)
        assert frame["type"] == "elysia.voice.call.status"
    finally:
        await comm.disconnect()


async def test_transcript_final_assistant_projects_and_broadcasts(
    user_factory, monkeypatch
):
    from apps.chat.services import get_or_create_conversation

    _, profile, user = await _make_profile(user_factory)
    await database_sync_to_async(get_or_create_conversation)(profile.user, user)

    projected = []

    async def fake_aproject(profile, call_id, entry, *, event_id):
        projected.append((call_id, entry.role, entry.text, event_id))
        return None

    monkeypatch.setattr(
        "apps.elysia_bridge.services.aproject_voice_transcript", fake_aproject
    )
    comm = await _connect_ws(user)
    try:
        terminal = await voice_observer._handle_observer_frame(
            profile,
            "call-1",
            {
                "type": "transcript",
                "role": "assistant",
                "text": "我在呢，汐汐",
                "is_final": True,
                "event_id": "evt_obs_1",
            },
        )
        assert terminal is False
        assert projected == [("call-1", "assistant", "我在呢，汐汐", "evt_obs_1")]
        frame = await comm.receive_json_from(timeout=1)
        assert frame["type"] == "elysia.voice.projected"
        assert frame["data"]["call_id"] == "call-1"
        assert frame["data"]["projected_total"] == 0
    finally:
        await comm.disconnect()


async def test_transcript_user_or_partial_not_projected(user_factory, monkeypatch):
    _, profile, user = await _make_profile(user_factory)
    projected = []

    async def fake_aproject(profile, call_id, entry, *, event_id):
        projected.append((call_id, entry.role))
        return None

    monkeypatch.setattr(
        "apps.elysia_bridge.services.aproject_voice_transcript", fake_aproject
    )
    comm = await _connect_ws(user)
    try:
        # role=user 的 final：不投影（主体性边界）
        terminal = await voice_observer._handle_observer_frame(
            profile,
            "call-1",
            {"type": "transcript", "role": "user", "text": "用户的话", "is_final": True},
        )
        assert terminal is False
        assert projected == []
        # partial：不投影
        terminal = await voice_observer._handle_observer_frame(
            profile,
            "call-1",
            {
                "type": "transcript",
                "role": "assistant",
                "text": "半句",
                "is_final": False,
                "event_id": "evt_partial",
            },
        )
        assert terminal is False
        assert projected == []
        # 空文本 final：不投影
        terminal = await voice_observer._handle_observer_frame(
            profile,
            "call-1",
            {
                "type": "transcript",
                "role": "assistant",
                "text": "",
                "is_final": True,
                "event_id": "evt_empty",
            },
        )
        assert terminal is False
        assert projected == []
    finally:
        await comm.disconnect()


async def test_ended_event_stops_observing(user_factory, monkeypatch):
    _, profile, user = await _make_profile(user_factory)
    monkeypatch.setattr(
        "apps.elysia_bridge.services.get_voice_call_status",
        lambda profile, call_id: _fake_status("ended"),
    )
    comm = await _connect_ws(user)
    try:
        terminal = await voice_observer._handle_observer_frame(
            profile, "call-1", {"type": "ended", "reason": "user_requested", "state": "ended"}
        )
        assert terminal is True  # 终态 → 停止观察
        frame = await comm.receive_json_from(timeout=1)
        assert frame["type"] == "elysia.voice.call.status"
        assert frame["data"]["call"]["state"] == "ended"
    finally:
        await comm.disconnect()


async def test_fatal_error_stops_observing(user_factory, monkeypatch):
    _, profile, user = await _make_profile(user_factory)
    monkeypatch.setattr(
        "apps.elysia_bridge.services.get_voice_call_status",
        lambda profile, call_id: _fake_status("failed"),
    )
    comm = await _connect_ws(user)
    try:
        terminal = await voice_observer._handle_observer_frame(
            profile, "call-1", {"type": "error", "message": "boom", "fatal": True}
        )
        assert terminal is True
        frame = await comm.receive_json_from(timeout=1)
        assert frame["type"] == "elysia.voice.call.status"
    finally:
        await comm.disconnect()


async def test_non_fatal_error_keeps_observing(user_factory, monkeypatch):
    _, profile, user = await _make_profile(user_factory)
    monkeypatch.setattr(
        "apps.elysia_bridge.services.get_voice_call_status",
        lambda profile, call_id: _fake_status("active"),
    )
    comm = await _connect_ws(user)
    try:
        terminal = await voice_observer._handle_observer_frame(
            profile, "call-1", {"type": "error", "message": "retry", "fatal": False}
        )
        assert terminal is False
    finally:
        await comm.disconnect()


async def test_unknown_frame_safely_ignored(user_factory, monkeypatch):
    _, profile, user = await _make_profile(user_factory)
    comm = await _connect_ws(user)
    try:
        terminal = await voice_observer._handle_observer_frame(
            profile, "call-1", {"type": "some.unknown", "data": {}}
        )
        assert terminal is False
    finally:
        await comm.disconnect()


# ---------- 生命周期（幂等启停，FakeThread 不真连网） ----------


def test_ensure_observing_idempotent_and_stop(monkeypatch, user_factory):
    from django.conf import settings
    from django.contrib.auth import get_user_model

    # 测试配置默认关闭 observer；本测试验证线程管理逻辑，需打开
    monkeypatch.setattr(settings, "VOICE_OBSERVER_ENABLED", True)

    User = get_user_model()
    elysia_user = user_factory(username="elysia_obs_lifecycle", nickname="爱莉")
    profile = ElysiaProfile.objects.create(
        user=elysia_user, stream_id="stream_obs_lc", enabled=True
    )
    assert User.objects.filter(pk=elysia_user.pk).exists()

    started: list[dict] = []

    class FakeThread:
        def __init__(self, *args, **kwargs):
            self._kw = kwargs
            self._alive = True

        def start(self):
            started.append(self._kw)

        def is_alive(self):
            return self._alive

    monkeypatch.setattr(voice_observer.threading, "Thread", FakeThread)
    # 首次启动
    voice_observer.ensure_observing(profile, "call-1")
    assert len(started) == 1
    assert started[0]["name"] == "elysia-voice-observer-call-1"
    assert started[0]["daemon"] is True
    # 同 call 幂等：不重复启动
    voice_observer.ensure_observing(profile, "call-1")
    assert len(started) == 1
    # stop 后（线程假死）再 ensure → 重启新线程
    voice_observer.stop_observing("call-1")
    voice_observer._observer_thread._alive = False  # 模拟线程结束
    voice_observer.ensure_observing(profile, "call-2")
    assert len(started) == 2
    assert started[1]["name"] == "elysia-voice-observer-call-2"
    # 清理：置回 None 避免影响其他测试
    with voice_observer._observer_lock:
        voice_observer._observer_thread = None
        voice_observer._observer_stop = None
        voice_observer._observing_call_id = None
