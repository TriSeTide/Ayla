"""
爱莉 Voice Live 转写投影契约测试（M4-5 §5.2 第 3 步 / §3.3 主体性铁律）—— mock 数据、不依赖真实 Elysium。

覆盖：
- `role="assistant"` 的 final transcript → 投影为语音频道关联会话里的爱莉消息
  （sender=爱莉 user、内容=transcript 原文、幂等键 `elysia-voice-<event_id 哈希>`）+ 广播 `elysia.reply`（source=voice_call）；
- 幂等：同 event_id 重复投影不重复落库（同 key 返回同一条）；
- 主体性边界（AGENTS.md §4.1）：
  * `role="user"` 的 final transcript → 不落库（应用侧绝不把用户话当作爱莉发言）；
  * 空文本 final transcript → 跳过，不伪造内容；
  * 无会话可路由 → 返回 None，不落库；
  * 落库内容 == transcript 原文，一字不改。
- 广播断言：InMemory channel layer + WebsocketCommunicator 接 M4-2 Chat WS（同 test_outbound.py）。

异步版 aproject_voice_transcript 走 database_sync_to_async 卸载 ORM，广播在 async 上下文
await group_send（同 aproject_elysia_reply），async 测试用 transactional_db 保证回滚。
"""
import logging

import pytest
from channels.db import database_sync_to_async
from channels.routing import URLRouter
from channels.testing import WebsocketCommunicator
from django.urls import path

from apps.chat import services as chat_services
from apps.chat.consumers import ChatConsumer
from apps.chat.models import Message
from apps.elysia_bridge.elysia_client import EventEnvelope, VoiceTranscriptEntry
from apps.elysia_bridge.models import ElysiaProfile
from apps.elysia_bridge import services as bridge_services

pytestmark = pytest.mark.usefixtures("transactional_db")

WS_PATH = "ws/chat/"


# ---------- 测试数据构造 ----------

@database_sync_to_async
def _make_profile(user_factory, *, stream_id="stream_voice_live"):
    elysia_user = user_factory(username="elysia_voice_core", nickname="爱莉")
    profile = ElysiaProfile.objects.create(
        user=elysia_user,
        stream_id=stream_id,
        enabled=True,
        display_name="爱莉",
    )
    user = user_factory(username="user_voice_a", nickname="汐汐")
    return elysia_user, profile, user


@database_sync_to_async
def _mk_private(a, b):
    return chat_services.get_or_create_conversation(a, b)


@database_sync_to_async
def _count_messages(conv, key):
    return Message.objects.filter(conversation=conv, idempotency_key=key).count()


@database_sync_to_async
def _total_messages(conv):
    return Message.objects.filter(conversation=conv).count()


def _entry(*, sequence=1, role="assistant", text="爱莉的语音回复", visibility="private"):
    return VoiceTranscriptEntry.from_mapping(
        {
            "sequence": sequence,
            "occurred_at": "2026-08-11T08:01:00Z",
            "role": role,
            "text": text,
            "provider_event_id": f"prov_{sequence}",
            "visibility": visibility,
        }
    )


def _event_key(event_id: str) -> str:
    """由 event_id 派生真实幂等键（与 elysia_bridge.services._stable_id_hash 一致）。"""
    import hashlib

    return f"elysia-voice-{hashlib.sha256(event_id.encode('utf-8')).hexdigest()[:24]}"


# ---------- WS 辅助 ----------

def _token_for(user):
    from rest_framework_simplejwt.tokens import RefreshToken

    return str(RefreshToken.for_user(user).access_token)


async def _connect_ws(user):
    app = URLRouter([path(WS_PATH, ChatConsumer.as_asgi())])
    comm = WebsocketCommunicator(app, f"/{WS_PATH}?token={_token_for(user)}")
    connected, _ = await comm.connect()
    assert connected is True
    return comm


# ---------- 契约测试 ----------

async def test_assistant_final_transcript_projects_elysia_message_and_broadcasts(user_factory):
    elysia_user, profile, user = await _make_profile(user_factory)
    conv = await _mk_private(user, elysia_user)

    comm = await _connect_ws(user)
    await comm.send_json_to({"type": "subscribe", "conversation_ids": [str(conv.id)]})
    await comm.receive_json_from()  # 基线 chat.subscribed

    entry = _entry(text="我在呢，汐汐")
    msg = await bridge_services.aproject_voice_transcript(
        profile, "call_live_1", entry, event_id="evt_voice_1"
    )

    # 已落库：sender=爱莉 user、内容=transcript 原文、幂等键=elysia-voice-<event_id 哈希>
    assert msg is not None
    assert msg.sender_id == profile.user_id
    assert msg.content == "我在呢，汐汐"
    assert msg.idempotency_key == _event_key("evt_voice_1")
    assert msg.conversation_id == conv.id
    assert msg.type == Message.TYPE_TEXT

    # 用户 WS 收到 elysia.reply 帧，source=voice_call（与 M4-4 聊天投影区分来源）
    frame = await comm.receive_json_from()
    assert frame["type"] == "elysia.reply"
    data = frame["data"]
    assert data["conversation_id"] == str(conv.id)
    assert data["message_id"] == str(msg.id)
    assert data["sender_id"] == profile.user_id
    assert data["content"] == "我在呢，汐汐"
    assert data["source"] == "voice_call"

    await comm.disconnect()


async def test_repeat_transcript_event_is_idempotent(user_factory):
    elysia_user, profile, user = await _make_profile(user_factory)
    await _mk_private(user, elysia_user)
    entry = _entry(text="再说一遍这句话")

    first = await bridge_services.aproject_voice_transcript(
        profile, "call_live_1", entry, event_id="evt_voice_dup"
    )
    second = await bridge_services.aproject_voice_transcript(
        profile, "call_live_1", entry, event_id="evt_voice_dup"
    )

    assert first is not None and second is not None
    assert first.id == second.id
    count = await _count_messages(first.conversation, _event_key("evt_voice_dup"))
    assert count == 1


async def test_user_role_transcript_not_projected(user_factory, caplog):
    """主体性边界：user 的 final transcript 只属于真人，绝不投影成爱莉发言。"""
    elysia_user, profile, user = await _make_profile(user_factory)
    conv = await _mk_private(user, elysia_user)
    entry = _entry(role="user", text="这是汐汐说的话")

    with caplog.at_level(logging.DEBUG, logger="apps.elysia_bridge.services"):
        msg = await bridge_services.aproject_voice_transcript(
            profile, "call_live_1", entry, event_id="evt_voice_user"
        )

    assert msg is None
    assert await _total_messages(conv) == 0
    assert any("role=user skipped" in r.message for r in caplog.records)


async def test_empty_text_transcript_skipped_not_fabricated(user_factory, caplog):
    elysia_user, profile, user = await _make_profile(user_factory)
    conv = await _mk_private(user, elysia_user)

    with caplog.at_level(logging.WARNING, logger="apps.elysia_bridge.services"):
        entry = _entry(text="   ")
        msg = await bridge_services.aproject_voice_transcript(
            profile, "call_live_1", entry, event_id="evt_voice_empty"
        )

    assert msg is None
    assert await _total_messages(conv) == 0
    assert any("has no text" in r.message for r in caplog.records)


async def test_no_conversation_returns_none_with_warning(user_factory, caplog):
    elysia_user, profile, _user = await _make_profile(user_factory)
    # 没有任何用户与爱莉私聊过 → 无法路由语音频道会话
    with caplog.at_level(logging.WARNING, logger="apps.elysia_bridge.services"):
        entry = _entry(text="无人听到的回复")
        msg = await bridge_services.aproject_voice_transcript(
            profile, "call_live_1", entry, event_id="evt_voice_noconv"
        )

    assert msg is None
    assert any("no conversation" in r.message for r in caplog.records)


async def test_sovereignty_boundary_content_is_transcript_verbatim(user_factory):
    """主体性边界：落库内容 == transcript 原文，不加前缀后缀、不改写。"""
    elysia_user, profile, user = await _make_profile(user_factory)
    await _mk_private(user, elysia_user)

    entry = _entry(text="这是我自己的原话，一字不改")
    msg = await bridge_services.aproject_voice_transcript(
        profile, "call_live_1", entry, event_id="evt_voice_verbatim"
    )

    assert msg is not None
    assert msg.content == "这是我自己的原话，一字不改"


# ---------- run_bridge 事件分派（M4-5 §5.2 第 2/3 步，_handle_envelope） ----------


def _voice_envelope(
    *,
    event_type="voice_call.transcript.final",
    stream_id="stream_voice_live",
    payload=None,
    event_id="evt_voice_dispatch",
):
    return EventEnvelope.from_mapping(
        {
            "event_id": event_id,
            "sequence": 31,
            "event_type": event_type,
            "stream_id": stream_id,
            "channel": "elysia-app",
            "actor": {"type": "consciousness", "id": "elysia_1", "display_name": "爱莉"},
            "payload": payload or {},
        }
    )


async def test_handle_envelope_dispatches_voice_transcript_final(user_factory):
    """voice_call.transcript.final 事件经 _handle_envelope 分派 → 投影爱莉发言。"""
    elysia_user, profile, user = await _make_profile(user_factory)
    conv = await _mk_private(user, elysia_user)

    env = _voice_envelope(
        payload={
            "call_id": "call_dispatch_1",
            "transcript": {
                "sequence": 1,
                "occurred_at": "2026-08-11T08:01:00Z",
                "role": "assistant",
                "text": "我听到了，汐汐",
                "provider_event_id": "prov_dispatch_1",
                "visibility": "private",
            },
        },
        event_id="evt_voice_dispatch_1",
    )
    msg = await bridge_services._handle_envelope(profile, env)

    assert msg is not None
    assert msg.sender_id == profile.user_id
    assert msg.content == "我听到了，汐汐"
    assert msg.idempotency_key == _event_key("evt_voice_dispatch_1")
    assert msg.conversation_id == conv.id


async def test_handle_envelope_voice_event_non_final_not_projected(user_factory, caplog):
    """voice_call.state_changed 等状态事件只记录不投影（技术状态不落库为发言）。"""
    elysia_user, profile, user = await _make_profile(user_factory)
    conv = await _mk_private(user, elysia_user)

    env = _voice_envelope(
        event_type="voice_call.state_changed",
        payload={"call_id": "call_state_1", "state": "active"},
        event_id="evt_voice_state_1",
    )
    with caplog.at_level(logging.DEBUG, logger="apps.elysia_bridge.services"):
        msg = await bridge_services._handle_envelope(profile, env)

    assert msg is None
    assert await _total_messages(conv) == 0
    assert any("voice_call event" in r.message for r in caplog.records)


async def test_handle_envelope_voice_transcript_unparseable_safe_ignored(
    user_factory, caplog
):
    """payload 缺 role/text 的 transcript.final → 安全忽略（绝不伪造内容）。"""
    elysia_user, profile, user = await _make_profile(user_factory)
    conv = await _mk_private(user, elysia_user)

    env = _voice_envelope(
        payload={"call_id": "call_bad_1", "transcript": {"sequence": 1}},
        event_id="evt_voice_bad_1",
    )
    with caplog.at_level(logging.DEBUG, logger="apps.elysia_bridge.services"):
        msg = await bridge_services._handle_envelope(profile, env)

    assert msg is None
    assert await _total_messages(conv) == 0
    assert any("no parseable transcript" in r.message for r in caplog.records)


async def test_handle_envelope_voice_stream_mismatch_skipped(user_factory, caplog):
    """stream_id 不匹配的 voice_call 事件在顶层过滤（不投影）。"""
    elysia_user, profile, user = await _make_profile(user_factory)
    conv = await _mk_private(user, elysia_user)

    env = _voice_envelope(
        stream_id="stream_other_voice",
        payload={
            "call_id": "call_x",
            "transcript": {"role": "assistant", "text": "不该被听到"},
        },
        event_id="evt_voice_mismatch",
    )
    msg = await bridge_services._handle_envelope(profile, env)

    assert msg is None
    assert await _total_messages(conv) == 0
