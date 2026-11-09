"""Ayla 通道 WS consumer 契约测试（D-3，REQUIREMENTS.zh.md §7/§9/§10/§12.2）。

覆盖：
- 鉴权：无 token / 错 token 拒绝；非爱莉账号 4403；正确 token 接入并绑定 profile；
- 心跳：ping → pong（服务端不做主动超时）；
- resume：从 seq+1 起重投 pending，按 seq 升序，不重复不遗漏；
- ack：seq ≤ N 的 pending 置 delivered，游标推进；
- reply：落库 + broadcast_message_new **一次** + 回 sent；
- 幂等：同 client_message_id 两次 → 只有一条消息、只广播一次；
- 类型不符 → error 帧，**不落库**；
- 会话不存在/爱莉不是成员 → error 帧，不落库；
- 入站：消息落库后 outbox 出现，REST 落库经通道推给 DSH（帧与落库一致）；
- 单实例：新连接顶替旧连接（旧连接被关闭），且记一行日志。

风格与 apps/chat/tests/test_chat_ws.py 一致：WebsocketCommunicator +
settings_test_mysql，async 测试用 transactional_db 保证回滚隔离。
"""
import logging

import pytest
from channels.db import database_sync_to_async
from channels.routing import URLRouter
from channels.testing import WebsocketCommunicator
from django.urls import path

from apps.chat import services as chat_services
from apps.chat.models import Conversation, Message
from apps.elysia_bridge import services as bridge_services
from apps.elysia_bridge.consumers import AylaBridgeConsumer
from apps.elysia_bridge.models import AylaInboundOutbox, ElysiaProfile

pytestmark = pytest.mark.usefixtures("transactional_db")

WS_PATH = "ws/elysia-bridge/"


def _token_for(user):
    from rest_framework_simplejwt.tokens import RefreshToken

    return str(RefreshToken.for_user(user).access_token)


def _make_app():
    return URLRouter([path(WS_PATH, AylaBridgeConsumer.as_asgi())])


async def _connect(user):
    comm = WebsocketCommunicator(
        _make_app(), f"/{WS_PATH}?token={_token_for(user)}"
    )
    connected, _ = await comm.connect()
    assert connected is True
    return comm


@database_sync_to_async
def _mk_elysia(username="elysia_ws", nickname="爱莉", enabled=True):
    """建爱莉 user + profile，返回 (user, profile)。"""
    from django.contrib.auth import get_user_model

    User = get_user_model()
    user = User.objects.create_user(
        username=username, email=f"{username}@test.local", password="test-pass-123"
    )
    if nickname:
        user.nickname = nickname
        user.save(update_fields=["nickname"])
    profile = ElysiaProfile.objects.create(
        user=user, enabled=enabled, display_name=nickname
    )
    return user, profile


@database_sync_to_async
def _mk_peer(username="ws_peer", nickname="小希"):
    from django.contrib.auth import get_user_model

    User = get_user_model()
    user = User.objects.create_user(
        username=username, email=f"{username}@test.local", password="test-pass-123"
    )
    if nickname:
        user.nickname = nickname
        user.save(update_fields=["nickname"])
    return user


@database_sync_to_async
def _mk_private(a, b):
    return chat_services.get_or_create_conversation(a, b)


@database_sync_to_async
def _mk_group(owner, members, title="通道群"):
    from apps.chat.models import ConversationMember

    conv = Conversation.objects.create(
        type=Conversation.TYPE_GROUP, title=title, owner=owner
    )
    ConversationMember.objects.create(
        conversation=conv, user=owner, role=ConversationMember.ROLE_OWNER
    )
    for m in members:
        ConversationMember.objects.create(conversation=conv, user=m)
    return conv


@database_sync_to_async
def _send(user, conv, content, key=None):
    return chat_services.create_message(user, conv, content=content, idempotency_key=key)


@database_sync_to_async
def _enqueue(message):
    return bridge_services.enqueue_for_delivery(message)


@database_sync_to_async
def _outbox_rows():
    return list(AylaInboundOutbox.objects.order_by("seq"))


@database_sync_to_async
def _messages_in(conv):
    return list(Message.objects.filter(conversation=conv).order_by("seq"))


# ---------- 鉴权 ----------


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_rejects_without_token():
    comm = WebsocketCommunicator(_make_app(), f"/{WS_PATH}")
    connected, code = await comm.connect()
    assert connected is False
    assert code == 4401


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_rejects_bad_token():
    comm = WebsocketCommunicator(_make_app(), f"/{WS_PATH}?token=not-a-jwt")
    connected, code = await comm.connect()
    assert connected is False
    assert code == 4401


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_rejects_non_elysia_account_with_4403():
    """普通用户（无 ElysiaProfile）不得占用通道。"""
    peer = await _mk_peer(username="not_elysia")
    comm = WebsocketCommunicator(
        _make_app(), f"/{WS_PATH}?token={_token_for(peer)}"
    )
    connected, code = await comm.connect()
    assert connected is False
    assert code == 4403


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_rejects_disabled_profile_with_4403():
    """enabled=False 的 profile 同样不得接入（§6「必须是 enabled=True」）。"""
    user, _profile = await _mk_elysia(username="elysia_off", enabled=False)
    comm = WebsocketCommunicator(
        _make_app(), f"/{WS_PATH}?token={_token_for(user)}"
    )
    connected, code = await comm.connect()
    assert connected is False
    assert code == 4403


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_accepts_elysia_account():
    user, _profile = await _mk_elysia()
    comm = await _connect(user)
    await comm.disconnect()


# ---------- 心跳 ----------


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_ping_pong():
    user, _ = await _mk_elysia()
    comm = await _connect(user)
    await comm.send_json_to({"v": 1, "type": "ping"})
    frame = await comm.receive_json_from()
    assert frame == {"v": 1, "type": "pong"}
    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_bad_version_rejected():
    user, _ = await _mk_elysia()
    comm = await _connect(user)
    await comm.send_json_to({"v": 99, "type": "ping"})
    frame = await comm.receive_json_from()
    assert frame["type"] == "error"
    assert frame["code"] == "unsupported_version"
    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_unknown_frame_type_gets_error():
    user, _ = await _mk_elysia()
    comm = await _connect(user)
    await comm.send_json_to({"v": 1, "type": "nonsense"})
    frame = await comm.receive_json_from()
    assert frame["type"] == "error"
    assert frame["code"] == "unknown_type"
    await comm.disconnect()


# ---------- resume / ack ----------


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_resume_replays_pending_from_seq_plus_one():
    """resume{seq:1} → 只补 seq≥2 的 pending，按 seq 升序（不重复、不遗漏）。"""
    elysia, _profile = await _mk_elysia()
    peer = await _mk_peer()
    conv = await _mk_private(peer, elysia)
    for i in range(1, 4):
        msg = await _send(peer, conv, f"第{i}条")
        await _enqueue(msg)

    comm = await _connect(elysia)
    await comm.send_json_to({"v": 1, "type": "resume", "seq": 1})
    f2 = await comm.receive_json_from()
    f3 = await comm.receive_json_from()
    assert f2["type"] == "inbound" and f2["seq"] == 2
    assert f3["type"] == "inbound" and f3["seq"] == 3
    assert f2["message"]["parts"] == [{"type": "text", "text": "第2条"}]
    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_inbound_frame_matches_stored_message():
    """WS 帧内容与落库一致（§12.2）：id/conversation/sender/parts 全部对齐。"""
    elysia, _profile = await _mk_elysia()
    peer = await _mk_peer(nickname="小希")
    conv = await _mk_private(peer, elysia)
    msg = await _send(peer, conv, "好了，我吃完了")
    await _enqueue(msg)

    comm = await _connect(elysia)
    await comm.send_json_to({"v": 1, "type": "resume", "seq": 0})
    frame = await comm.receive_json_from()
    payload = frame["message"]
    assert frame["v"] == 1 and frame["type"] == "inbound"
    assert frame["seq"] == 1
    assert payload["id"] == str(msg.id)
    assert payload["conversation_id"] == str(conv.id)
    assert payload["conversation_type"] == "private"
    assert payload["sender_id"] == str(peer.id)
    assert payload["sender_name"] == "小希"
    assert payload["parts"] == [{"type": "text", "text": "好了，我吃完了"}]
    assert payload["sent_at"]
    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_image_part_carries_media_id():
    """图片以 media_id 传递，不给字节（§7.1）。"""
    elysia, _profile = await _mk_elysia()
    peer = await _mk_peer()
    conv = await _mk_private(peer, elysia)
    msg = await database_sync_to_async(chat_services.create_message)(
        peer, conv, content="", msg_type=Message.TYPE_IMAGE, media_id="a1b2c3d4"
    )
    await _enqueue(msg)

    comm = await _connect(elysia)
    await comm.send_json_to({"v": 1, "type": "resume", "seq": 0})
    frame = await comm.receive_json_from()
    assert frame["message"]["parts"] == [
        {"type": "image", "media_id": "a1b2c3d4"}
    ]
    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_ack_marks_delivered_up_to_seq():
    elysia, _profile = await _mk_elysia()
    peer = await _mk_peer()
    conv = await _mk_private(peer, elysia)
    for i in range(1, 4):
        msg = await _send(peer, conv, f"m{i}")
        await _enqueue(msg)

    comm = await _connect(elysia)
    await comm.send_json_to({"v": 1, "type": "ack", "seq": 2})
    # 没有回帧：ack 是单向推进，用一次 ping 当同步点。
    await comm.send_json_to({"v": 1, "type": "ping"})
    assert (await comm.receive_json_from())["type"] == "pong"

    rows = await _outbox_rows()
    assert [r.status for r in rows] == [
        AylaInboundOutbox.STATUS_DELIVERED,
        AylaInboundOutbox.STATUS_DELIVERED,
        AylaInboundOutbox.STATUS_PENDING,
    ]
    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_resume_skips_acked_rows():
    """ack 之后再 resume 不会重投已确认的行。"""
    elysia, _profile = await _mk_elysia()
    peer = await _mk_peer()
    conv = await _mk_private(peer, elysia)
    for i in range(1, 3):
        msg = await _send(peer, conv, f"m{i}")
        await _enqueue(msg)

    comm = await _connect(elysia)
    await comm.send_json_to({"v": 1, "type": "ack", "seq": 2})
    await comm.send_json_to({"v": 1, "type": "ping"})
    await comm.receive_json_from()
    await comm.send_json_to({"v": 1, "type": "resume", "seq": 0})
    # 全部 delivered：不应再有 inbound 帧；用 ping 做同步点。
    await comm.send_json_to({"v": 1, "type": "ping"})
    frame = await comm.receive_json_from()
    assert frame["type"] == "pong"
    await comm.disconnect()


# ---------- reply ----------


def _reply_frame(conv, content, client_message_id="ayla-channel:875:1:0", **extra):
    frame = {
        "v": 1,
        "type": "reply",
        "client_message_id": client_message_id,
        "conversation_id": str(conv.id),
        "conversation_type": str(conv.type),
        "content": content,
        "reply_to": None,
    }
    frame.update(extra)
    return frame


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_reply_stores_and_returns_sent():
    elysia, profile = await _mk_elysia()
    peer = await _mk_peer()
    conv = await _mk_private(peer, elysia)

    comm = await _connect(elysia)
    await comm.send_json_to(_reply_frame(conv, "这个决定对呀"))
    frame = await comm.receive_json_from()
    assert frame["type"] == "sent"
    assert frame["client_message_id"] == "ayla-channel:875:1:0"

    msgs = await _messages_in(conv)
    assert len(msgs) == 1
    stored = msgs[0]
    assert stored.sender_id == profile.user_id
    assert stored.content == "这个决定对呀"
    assert str(stored.id) == frame["message_id"]
    assert stored.seq == frame["seq"]
    # 保持 sent：`sent` 帧只证明 DSH 收到，不证明对端已送达。
    assert stored.status == Message.STATUS_SENT
    assert stored.idempotency_key == bridge_services.idempotency_key_for_client_message(
        "ayla-channel:875:1:0"
    )
    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_reply_idempotency_key_shape():
    """§9：`"ayla-" + sha256(id)[:24]`，且不超过 Message.idempotency_key 的 64。"""
    key = bridge_services.idempotency_key_for_client_message("x" * 200)
    assert key.startswith("ayla-")
    assert len(key) == 5 + 24
    assert len(key) <= 64


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_same_client_message_id_stores_one_message():
    elysia, _profile = await _mk_elysia()
    peer = await _mk_peer()
    conv = await _mk_private(peer, elysia)

    comm = await _connect(elysia)
    await comm.send_json_to(_reply_frame(conv, "只应有一条"))
    first = await comm.receive_json_from()
    await comm.send_json_to(_reply_frame(conv, "只应有一条"))
    second = await comm.receive_json_from()
    assert first["type"] == "sent" and second["type"] == "sent"
    assert first["message_id"] == second["message_id"]

    msgs = await _messages_in(conv)
    assert len(msgs) == 1
    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_reply_broadcasts_message_new_once(monkeypatch):
    """reply 落库后广播 message.new **一次**；幂等重放不再广播。"""
    calls = []

    def _record(message):
        calls.append(message.id)

    from apps.chat import services as chat_services_mod

    monkeypatch.setattr(chat_services_mod, "broadcast_message_new", _record)

    elysia, _profile = await _mk_elysia()
    peer = await _mk_peer()
    conv = await _mk_private(peer, elysia)

    comm = await _connect(elysia)
    await comm.send_json_to(_reply_frame(conv, "广播一次"))
    await comm.receive_json_from()
    await comm.send_json_to(_reply_frame(conv, "广播一次"))
    await comm.receive_json_from()
    assert len(calls) == 1
    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_reply_type_mismatch_rejected_and_not_stored():
    """conversation_type 与真实类型不符 → error，**不落库**（§7.2）。"""
    elysia, _profile = await _mk_elysia()
    peer = await _mk_peer()
    conv = await _mk_private(peer, elysia)  # 真实类型 private

    comm = await _connect(elysia)
    await comm.send_json_to(
        _reply_frame(conv, "发进群里？", conversation_type="group")
    )
    frame = await comm.receive_json_from()
    assert frame["type"] == "error"
    assert frame["code"] == "conversation_type_mismatch"
    assert frame["client_message_id"] == "ayla-channel:875:1:0"
    assert await _messages_in(conv) == []
    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_reply_unknown_conversation_rejected():
    elysia, _profile = await _mk_elysia()
    comm = await _connect(elysia)
    await comm.send_json_to(
        {
            "v": 1,
            "type": "reply",
            "client_message_id": "c1",
            "conversation_id": "999999",
            "conversation_type": "private",
            "content": "你好",
        }
    )
    frame = await comm.receive_json_from()
    assert frame["type"] == "error"
    assert frame["code"] == "conversation_not_found"
    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_reply_to_conversation_elysia_is_not_member():
    """爱莉不是该会话成员 → error（不能代她往别人会话里发话）。"""
    elysia, _profile = await _mk_elysia()
    a = await _mk_peer(username="outsider_a")
    b = await _mk_peer(username="outsider_b")
    conv = await _mk_private(a, b)

    comm = await _connect(elysia)
    await comm.send_json_to(_reply_frame(conv, "越权"))
    frame = await comm.receive_json_from()
    assert frame["type"] == "error"
    assert frame["code"] == "conversation_not_a_member"
    assert await _messages_in(conv) == []
    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_reply_too_large_rejected():
    elysia, _profile = await _mk_elysia()
    peer = await _mk_peer()
    conv = await _mk_private(peer, elysia)

    comm = await _connect(elysia)
    await comm.send_json_to(_reply_frame(conv, "字" * (bridge_services.MAX_TEXT_BYTES)))
    frame = await comm.receive_json_from()
    assert frame["type"] == "error"
    assert frame["code"] == "content_too_large"
    assert await _messages_in(conv) == []
    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_reply_in_group_with_matching_type():
    elysia, _profile = await _mk_elysia()
    peer = await _mk_peer()
    conv = await _mk_group(peer, [elysia])

    comm = await _connect(elysia)
    await comm.send_json_to(_reply_frame(conv, "群里的回复"))
    frame = await comm.receive_json_from()
    assert frame["type"] == "sent"
    assert len(await _messages_in(conv)) == 1
    await comm.disconnect()


# ---------- 入站登记（enqueue） ----------


@pytest.mark.django_db
def test_enqueue_skips_non_elysia_conversation(user_factory):
    a = user_factory(username="plain_a")
    b = user_factory(username="plain_b")
    conv = chat_services.get_or_create_conversation(a, b)
    msg = chat_services.create_message(a, conv, content="普通私聊")
    assert bridge_services.enqueue_for_delivery(msg) is None
    assert not AylaInboundOutbox.objects.exists()


@pytest.mark.django_db
def test_enqueue_skips_elysia_own_message(user_factory):
    elysia = user_factory(username="elysia_self")
    ElysiaProfile.objects.create(user=elysia, display_name="爱莉")
    peer = user_factory(username="peer_self")
    conv = chat_services.get_or_create_conversation(peer, elysia)
    msg = chat_services.create_message(elysia, conv, content="她自己说的")
    assert bridge_services.enqueue_for_delivery(msg) is None
    assert not AylaInboundOutbox.objects.exists()


@pytest.mark.django_db
def test_enqueue_is_idempotent_for_same_message(user_factory):
    elysia = user_factory(username="elysia_idem")
    ElysiaProfile.objects.create(user=elysia, display_name="爱莉")
    peer = user_factory(username="peer_idem")
    conv = chat_services.get_or_create_conversation(peer, elysia)
    msg = chat_services.create_message(peer, conv, content="一次就好")
    first = bridge_services.enqueue_for_delivery(msg)
    second = bridge_services.enqueue_for_delivery(msg)
    assert first.id == second.id
    assert AylaInboundOutbox.objects.count() == 1


@pytest.mark.django_db
def test_enqueue_marks_unsupported_parts_failed(user_factory):
    """未知 part（语音/文件…）整条不可投递：登记但标 failed，不丢部分后只发文字。"""
    elysia = user_factory(username="elysia_voice")
    ElysiaProfile.objects.create(user=elysia, display_name="爱莉")
    peer = user_factory(username="peer_voice")
    conv = chat_services.get_or_create_conversation(peer, elysia)
    msg = chat_services.create_message(
        peer, conv, content="", msg_type=Message.TYPE_VOICE, media_id="v1"
    )
    row = bridge_services.enqueue_for_delivery(msg)
    assert row.status == AylaInboundOutbox.STATUS_FAILED
    assert "voice" in row.last_error


@pytest.mark.django_db
def test_enqueue_marks_oversized_text_failed(user_factory):
    elysia = user_factory(username="elysia_big")
    ElysiaProfile.objects.create(user=elysia, display_name="爱莉")
    peer = user_factory(username="peer_big")
    conv = chat_services.get_or_create_conversation(peer, elysia)
    msg = chat_services.create_message(
        peer, conv, content="字" * (bridge_services.MAX_TEXT_BYTES + 1)
    )
    row = bridge_services.enqueue_for_delivery(msg)
    assert row.status == AylaInboundOutbox.STATUS_FAILED
    assert "text too large" in row.last_error


# ---------- 单实例语义 ----------


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_new_connection_replaces_old_one(caplog):
    """同一 profile 只允许一条活跃连接：新连接顶替旧连接并记一行日志（§10）。"""
    elysia, _profile = await _mk_elysia()
    old = await _connect(elysia)
    caplog.set_level(logging.WARNING, logger="apps.elysia_bridge.consumers")
    new = await _connect(elysia)

    # 旧连接收到 close（4409）
    message = await old.receive_output()
    assert message["type"] == "websocket.close"
    assert message["code"] == 4409
    assert any(
        "replaced" in rec.getMessage() for rec in caplog.records
    ), [rec.getMessage() for rec in caplog.records]

    # 新连接仍可用
    await new.send_json_to({"v": 1, "type": "ping"})
    assert (await new.receive_json_from())["type"] == "pong"
    await new.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_inbound_ready_group_event_pushes_pending():
    """REST 落库后经 group 通知 → 在线 consumer 推 inbound 帧。"""
    elysia, profile = await _mk_elysia()
    peer = await _mk_peer()
    conv = await _mk_private(peer, elysia)

    comm = await _connect(elysia)
    msg = await _send(peer, conv, "在线推送")
    row = await _enqueue(msg)

    from channels.layers import get_channel_layer

    await get_channel_layer().group_send(
        bridge_services.outbox_group_name(profile.id),
        {"type": "ayla.inbound.ready", "seq": row.seq},
    )
    frame = await comm.receive_json_from()
    assert frame["type"] == "inbound"
    assert frame["seq"] == row.seq
    assert frame["message"]["parts"] == [{"type": "text", "text": "在线推送"}]
    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_delivery_attempt_limit_marks_dead():
    """超过重投上限 → dead（保留现场，不静默丢弃，§9）。"""
    elysia, _profile = await _mk_elysia()
    peer = await _mk_peer()
    conv = await _mk_private(peer, elysia)
    msg = await _send(peer, conv, "永远不 ack")
    await _enqueue(msg)

    comm = await _connect(elysia)
    for _ in range(bridge_services.MAX_DELIVERY_ATTEMPTS):
        await comm.send_json_to({"v": 1, "type": "resume", "seq": 0})
        await comm.receive_json_from()
    rows = await _outbox_rows()
    assert rows[0].status == AylaInboundOutbox.STATUS_DEAD
    assert rows[0].attempts >= bridge_services.MAX_DELIVERY_ATTEMPTS
    await comm.disconnect()

# ---------- REST → outbox 端到端（§12.2「入站：落库后 outbox 行出现」） ----------


@pytest.mark.django_db
def test_rest_send_enqueues_outbox_row(user_factory):
    """REST 发消息给爱莉 → 消息落库 + outbox 行出现（同事务）。"""
    from rest_framework.test import APIClient
    from rest_framework_simplejwt.tokens import RefreshToken

    elysia = user_factory(username="elysia_rest", nickname="爱莉")
    ElysiaProfile.objects.create(user=elysia, display_name="爱莉")
    peer = user_factory(username="peer_rest", nickname="小希")
    conv = chat_services.get_or_create_conversation(peer, elysia)

    client = APIClient()
    client.credentials(
        HTTP_AUTHORIZATION=f"Bearer {RefreshToken.for_user(peer).access_token}"
    )
    resp = client.post(
        f"/api/v1/chat/conversations/{conv.id}/messages/",
        {"type": "text", "content": "喂，爱莉", "idempotency_key": "rest-1"},
        format="json",
    )
    assert resp.status_code == 201, resp.content

    rows = list(AylaInboundOutbox.objects.order_by("seq"))
    assert len(rows) == 1
    assert rows[0].status == AylaInboundOutbox.STATUS_PENDING
    assert rows[0].seq == 1
    assert rows[0].message.content == "喂，爱莉"


@pytest.mark.django_db
def test_rest_send_to_plain_user_creates_no_outbox(user_factory):
    """非爱莉会话不登记：普通私聊不得进入通道 outbox。"""
    from rest_framework.test import APIClient
    from rest_framework_simplejwt.tokens import RefreshToken

    from apps.accounts.models import Friendship

    a = user_factory(username="plain_rest_a")
    b = user_factory(username="plain_rest_b")
    # 普通私聊要求双向好友（Bug #2 契约），先建立关系再发消息。
    for u, f in ((a, b), (b, a)):
        Friendship.objects.get_or_create(
            user=u, friend=f, defaults={"status": Friendship.STATUS_ACCEPTED}
        )
    conv = chat_services.get_or_create_conversation(a, b)

    client = APIClient()
    client.credentials(
        HTTP_AUTHORIZATION=f"Bearer {RefreshToken.for_user(a).access_token}"
    )
    resp = client.post(
        f"/api/v1/chat/conversations/{conv.id}/messages/",
        {"type": "text", "content": "普通消息", "idempotency_key": "plain-1"},
        format="json",
    )
    assert resp.status_code == 201, resp.content
    assert not AylaInboundOutbox.objects.exists()


@pytest.mark.django_db
def test_rest_send_still_succeeds_when_enqueue_fails(user_factory, monkeypatch):
    """投递登记失败不得阻塞用户消息落库（失败可观测，但不回滚消息）。"""
    from rest_framework.test import APIClient
    from rest_framework_simplejwt.tokens import RefreshToken

    elysia = user_factory(username="elysia_fail", nickname="爱莉")
    ElysiaProfile.objects.create(user=elysia, display_name="爱莉")
    peer = user_factory(username="peer_fail")
    conv = chat_services.get_or_create_conversation(peer, elysia)

    def _boom(message):
        raise RuntimeError("outbox unavailable")

    monkeypatch.setattr(bridge_services, "enqueue_for_delivery", _boom)

    client = APIClient()
    client.credentials(
        HTTP_AUTHORIZATION=f"Bearer {RefreshToken.for_user(peer).access_token}"
    )
    resp = client.post(
        f"/api/v1/chat/conversations/{conv.id}/messages/",
        {"type": "text", "content": "登记失败也要落库", "idempotency_key": "fail-1"},
        format="json",
    )
    assert resp.status_code == 201, resp.content
    assert Message.objects.filter(conversation=conv).count() == 1

@pytest.mark.django_db
@pytest.mark.asyncio
async def test_oversized_frame_closes_connection():
    """单帧 > 1 MiB → 断连并记一行（§10），不解析、不投递。"""
    elysia, _profile = await _mk_elysia()
    comm = await _connect(elysia)
    await comm.send_to(
        text_data="x" * (bridge_services.MAX_FRAME_BYTES + 1)
    )
    message = await comm.receive_output()
    assert message["type"] == "websocket.close"
    assert message["code"] == 4413


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_reply_with_reply_to_links_quoted_message():
    """reply_to 指向本会话消息时落库带引用。"""
    elysia, _profile = await _mk_elysia()
    peer = await _mk_peer()
    conv = await _mk_private(peer, elysia)
    original = await _send(peer, conv, "原来的问题")
    await _enqueue(original)

    comm = await _connect(elysia)
    await comm.send_json_to(
        _reply_frame(conv, "回答", client_message_id="c-reply-to", reply_to=str(original.id))
    )
    frame = await comm.receive_json_from()
    assert frame["type"] == "sent"
    msgs = await _messages_in(conv)
    reply = [m for m in msgs if m.id == int(frame["message_id"])][0]
    assert reply.reply_to_id == original.id
    await comm.disconnect()

@pytest.mark.django_db
@pytest.mark.asyncio
async def test_mixed_message_parts_keep_order_and_render_mention():
    """混排消息：parts 保持原顺序，@ 段展开成文本（不静默丢弃）。"""
    elysia, _profile = await _mk_elysia()
    peer = await _mk_peer()
    conv = await _mk_private(peer, elysia)
    msg = await database_sync_to_async(chat_services.create_message)(
        peer,
        conv,
        content="看这个",
        msg_type=Message.TYPE_MIXED,
        segments=[
            {"type": "text", "text": "看这个"},
            {"type": "image", "media_id": "img-1"},
            {"type": "mention", "user_id": str(elysia.id)},
            {"type": "text", "text": "你觉得呢"},
        ],
    )
    await _enqueue(msg)

    comm = await _connect(elysia)
    await comm.send_json_to({"v": 1, "type": "resume", "seq": 0})
    frame = await comm.receive_json_from()
    assert frame["message"]["parts"] == [
        {"type": "text", "text": "看这个"},
        {"type": "image", "media_id": "img-1"},
        {"type": "text", "text": "@爱莉"},
        {"type": "text", "text": "你觉得呢"},
    ]
    await comm.disconnect()


@pytest.mark.django_db
def test_mention_part_is_supported():
    """@ 段不算「不可投递 part」：它是可渲染文本，不是未知媒体。"""
    elysia = None
    from django.contrib.auth import get_user_model

    User = get_user_model()
    elysia = User.objects.create_user(
        username="elysia_mention", email="m@test.local", password="x"
    )
    elysia.nickname = "爱莉"
    elysia.save(update_fields=["nickname"])
    ElysiaProfile.objects.create(user=elysia, display_name="爱莉")
    peer = User.objects.create_user(
        username="peer_mention", email="p@test.local", password="x"
    )
    conv = chat_services.get_or_create_conversation(peer, elysia)
    msg = chat_services.create_message(
        peer,
        conv,
        content="",
        msg_type=Message.TYPE_MIXED,
        segments=[{"type": "mention", "user_id": str(elysia.id)}],
    )
    assert bridge_services.unsupported_parts(msg) == []
    assert bridge_services.build_inbound_parts(msg) == [
        {"type": "text", "text": "@爱莉"}
    ]
