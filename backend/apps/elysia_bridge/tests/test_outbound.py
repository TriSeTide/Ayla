"""
出站 SSE 投影契约测试（8.1 清单第 4~7 项）—— mock Elysium，不依赖真实服务。

覆盖：
- 收到 `chat.message.*` + 匹配 stream → 投影落库（sender=爱莉 user）+ 广播 `elysia.reply`；
- 幂等：同 event_id 重复投影不重复落库（key=`elysia-<event_id>`）；
- 出站路由：标准 payload.metadata.chat.target_user_id 定位用户会话；
  兼容 payload.metadata.sender_id / correlation_id；匹配不到 → 降级到 profile
  默认会话 + warning（不静默丢弃）；
- 无会话 → 返回 None，不落库；
- 事件无 content → 跳过，不伪造内容；
- 主体性边界：应用侧从不生成爱莉第一人称内容（只取 payload.content 原文）。

广播断言：InMemory channel layer + WebsocketCommunicator 接 M4-2 Chat WS。
投影走异步版 aproject_elysia_reply（与 M4-2 abroadcast_* 同语义，同事件循环
广播，InMemory layer 不跨循环丢消息），async 测试与 M4-2 test_chat_ws 一致用
transactional_db 保证事务回滚。
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
from apps.elysia_bridge.elysia_client import EventEnvelope
from apps.elysia_bridge.models import ElysiaProfile
from apps.elysia_bridge import services as bridge_services

# async 测试：transactional_db 保证独立事务 + 回滚（同 M4-2 test_chat_ws）
pytestmark = pytest.mark.usefixtures("transactional_db")

WS_PATH = "ws/chat/"


# ---------- 测试数据构造 ----------

@database_sync_to_async
def _make_profile(user_factory, *, enabled=True, stream_id="stream_elysia_out"):
    elysia_user = user_factory(username="elysia_out_core", nickname="爱莉")
    profile = ElysiaProfile.objects.create(
        user=elysia_user,
        stream_id=stream_id,
        enabled=enabled,
        display_name="爱莉",
    )
    user = user_factory(username="user_out_a", nickname="汐汐")
    return elysia_user, profile, user


@database_sync_to_async
def _mk_private(a, b):
    return chat_services.get_or_create_conversation(a, b)


@database_sync_to_async
def _count_messages(conv, key):
    return Message.objects.filter(conversation=conv, idempotency_key=key).count()


def _event_key(event_id: str) -> str:
    """由 event_id 派生真实幂等键（与 elysia_bridge.services._stable_id_hash 一致）。"""
    import hashlib

    return f"elysia-{hashlib.sha256(event_id.encode('utf-8')).hexdigest()[:24]}"


@database_sync_to_async
def _refresh(obj):
    obj.refresh_from_db()
    return obj


def _chat_envelope(
    *,
    event_id="evt_out_1",
    stream_id="stream_elysia_out",
    content="爱莉的回复",
    sender_id=None,
    target_user_id=None,
    correlation_id=None,
    cursor="cursor-7",
):
    payload = {"content": content, "metadata": {}}
    if sender_id is not None:
        payload["metadata"]["sender_id"] = sender_id
    if target_user_id is not None:
        payload["metadata"]["chat"] = {"target_user_id": target_user_id}
    data = {
        "event_id": event_id,
        "sequence": 21,
        "event_type": "chat.message.delivery_confirmed",
        "stream_id": stream_id,
        "channel": "elysia-app",
        "actor": {"type": "consciousness", "id": "elysia_1", "display_name": "爱莉"},
        "payload": payload,
    }
    if correlation_id:
        data["correlation_id"] = correlation_id
    env = EventEnvelope.from_mapping(data)
    if cursor:
        object.__setattr__(env, "cursor", cursor)
    return env


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

async def test_chat_event_projects_message_and_broadcasts_elysia_reply(user_factory):
    elysia_user, profile, user = await _make_profile(user_factory)
    conv = await _mk_private(user, elysia_user)

    comm = await _connect_ws(user)
    await comm.send_json_to(
        {"type": "subscribe", "conversation_ids": [str(conv.id)]}
    )
    await comm.receive_json_from()  # 基线 chat.subscribed

    env = _chat_envelope(sender_id=str(user.id))
    msg = await bridge_services.aproject_elysia_reply(profile, env)

    # 已落库：sender=爱莉 user、内容=payload 原文、幂等键=elysia-<event_id 哈希>
    assert msg is not None
    assert msg.sender_id == profile.user_id
    assert msg.content == "爱莉的回复"
    assert msg.idempotency_key == _event_key(env.event_id)
    assert msg.conversation_id == conv.id

    # 用户 WS 收到 elysia.reply 帧
    frame = await comm.receive_json_from()
    assert frame["type"] == "elysia.reply"
    data = frame["data"]
    assert data["conversation_id"] == str(conv.id)
    assert data["message_id"] == str(msg.id)
    assert data["sender_id"] == profile.user_id
    assert data["content"] == "爱莉的回复"
    assert data["event_id"] == env.event_id

    await comm.disconnect()


async def test_repeat_event_is_idempotent(user_factory):
    elysia_user, profile, user = await _make_profile(user_factory)
    conv = await _mk_private(user, elysia_user)
    env = _chat_envelope(event_id="evt_out_dup", sender_id=str(user.id))

    first = await bridge_services.aproject_elysia_reply(profile, env)
    second = await bridge_services.aproject_elysia_reply(profile, env)

    assert first is not None and second is not None
    assert first.id == second.id
    count = await _count_messages(conv, _event_key("evt_out_dup"))
    assert count == 1


async def test_routes_by_standard_chat_target_user_id(user_factory):
    elysia_user, profile, user = await _make_profile(user_factory)
    conv_a = await _mk_private(user, elysia_user)
    # 用户 B（独立创建，避免 email 冲突）
    from django.contrib.auth import get_user_model

    User = get_user_model()

    @database_sync_to_async
    def _mk_b():
        return User.objects.create_user(
            username="user_out_b", email="user_out_b@test.local", password="x"
        )

    user_b = await _mk_b()
    conv_b = await _mk_private(user_b, elysia_user)

    env = _chat_envelope(
        event_id="evt_out_target",
        target_user_id=str(user_b.id),
        sender_id=str(user.id),
    )
    msg = await bridge_services.aproject_elysia_reply(profile, env)

    # 标准 chat.target_user_id 优先于兼容字段，路由到 B 的会话。
    assert msg is not None
    assert msg.conversation_id == conv_b.id
    assert msg.conversation_id != conv_a.id
    assert msg.sender_id == profile.user_id


async def test_routes_by_legacy_metadata_sender_id(user_factory):
    elysia_user, profile, user = await _make_profile(user_factory)
    conv = await _mk_private(user, elysia_user)

    env = _chat_envelope(event_id="evt_out_sa", sender_id=str(user.id))
    msg = await bridge_services.aproject_elysia_reply(profile, env)

    assert msg is not None
    assert msg.conversation_id == conv.id


async def test_routes_by_correlation_id(user_factory):
    elysia_user, profile, user = await _make_profile(user_factory)
    conv = await _mk_private(user, elysia_user)

    env = _chat_envelope(
        event_id="evt_out_corr", correlation_id=f"elysia:{user.id}"
    )
    msg = await bridge_services.aproject_elysia_reply(profile, env)
    assert msg is not None
    assert msg.conversation_id == conv.id


async def test_unrouted_event_falls_back_to_default_conversation_with_warning(
    user_factory, caplog
):
    elysia_user, profile, user = await _make_profile(user_factory)
    conv = await _mk_private(user, elysia_user)

    # 事件无 sender_id/correlation 回显 → 降级到最近的私聊会话 + warning
    with caplog.at_level(logging.WARNING, logger="apps.elysia_bridge.services"):
        env = _chat_envelope(event_id="evt_out_nosender")
        msg = await bridge_services.aproject_elysia_reply(profile, env)

    assert msg is not None
    assert msg.conversation_id == conv.id
    assert any("has no resolvable sender" in r.message for r in caplog.records)


async def test_no_conversation_returns_none_with_warning(user_factory, caplog):
    elysia_user, profile, _user = await _make_profile(user_factory)
    # 没有任何用户与爱莉私聊过
    with caplog.at_level(logging.WARNING, logger="apps.elysia_bridge.services"):
        env = _chat_envelope(event_id="evt_out_noconv")
        msg = await bridge_services.aproject_elysia_reply(profile, env)

    assert msg is None
    assert any("no conversation" in r.message for r in caplog.records)


async def test_event_without_content_skipped_not_fabricated(user_factory):
    elysia_user, profile, user = await _make_profile(user_factory)
    await _mk_private(user, elysia_user)

    env = _chat_envelope(event_id="evt_out_empty", content="")
    msg = await bridge_services.aproject_elysia_reply(profile, env)
    assert msg is None

    env2 = _chat_envelope(
        event_id="evt_out_nocontent", content=None, sender_id=str(user.id)
    )
    msg2 = await bridge_services.aproject_elysia_reply(profile, env2)
    assert msg2 is None


async def test_sovereignty_boundary_app_never_fabricates_content(user_factory):
    """主体性边界：应用侧内容只来自投影事件，绝不拼接/生成爱莉第一人称。"""
    elysia_user, profile, user = await _make_profile(user_factory)
    await _mk_private(user, elysia_user)

    env = _chat_envelope(event_id="evt_out_sovereign", content="这是我自己的话")
    msg = await bridge_services.aproject_elysia_reply(profile, env)

    # 落库内容 == 投影原文，一字不改、不加前缀后缀
    assert msg is not None
    assert msg.content == "这是我自己的话"
