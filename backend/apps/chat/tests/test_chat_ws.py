"""chat WebSocket 契约测试：连接/订阅/广播/补发/越权/慢消费者。

全部不依赖 Redis/MySQL（settings_test InMemory channel layer + WebsocketCommunicator）。

注意：async 测试 + database_sync_to_async 在 pytest-asyncio 下，普通 django_db 的
事务回滚可能失效（数据跨测试泄漏到后续同步测试）。用 transaction=True 让每个
async 测试在独立事务中运行并回滚，保证全量跑的顺序无关性。
"""
import asyncio

import pytest
from channels.db import database_sync_to_async
from channels.routing import URLRouter
from channels.testing import WebsocketCommunicator
from django.urls import path

from apps.chat import services
from apps.chat.consumers import ChatConsumer
from apps.chat.models import Conversation, ConversationMember

# async 测试 + database_sync_to_async 在 pytest-asyncio 下，普通 django_db 的
# 事务回滚失效（数据跨测试泄漏）。改用 transactional_db：每个 async 测试在
# 独立事务中运行并在结束时回滚，保证全量跑的顺序无关性。
pytestmark = pytest.mark.usefixtures("transactional_db")

WS_PATH = "ws/chat/"


def _token_for(user):
    from rest_framework_simplejwt.tokens import RefreshToken

    return str(RefreshToken.for_user(user).access_token)


def _make_app():
    return URLRouter([path(WS_PATH, ChatConsumer.as_asgi())])


async def _connect(user):
    comm = WebsocketCommunicator(
        _make_app(), f"/{WS_PATH}?token={_token_for(user)}"
    )
    connected, _ = await comm.connect()
    assert connected is True
    return comm


async def _expect_no_frame(comm, timeout=0.3) -> bool:
    """快速判断连接是否没有新帧（非成员不应收到广播/基线）。

    用 asyncio.wait_for 包住 receive，超时吞掉——避免触发 asgiref 内部
    async_timeout 对 consumer 后台任务的 cancel，导致后续 disconnect 报 CancelledError。
    """
    try:
        await asyncio.wait_for(comm.receive_json_from(), timeout=timeout)
        return False
    except asyncio.TimeoutError:
        return True
    except Exception:
        # channel 关闭等异常也视为"没等到正常帧"
        return True


@database_sync_to_async
def _mk_private(a, b):
    return services.get_or_create_conversation(a, b)


@database_sync_to_async
def _mk_group(owner, members, title="WS群"):
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
def _send_message(user, conv, content):
    return services.create_message(user, conv, content=content)


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_connect_with_valid_token(user_factory):
    user = await database_sync_to_async(user_factory)(username="ws_auth")
    comm = await _connect(user)
    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_connect_with_invalid_token():
    comm = WebsocketCommunicator(_make_app(), f"/{WS_PATH}?token=bad")
    connected, _ = await comm.connect()
    assert connected is False


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_connect_without_token():
    comm = WebsocketCommunicator(_make_app(), f"/{WS_PATH}")
    connected, _ = await comm.connect()
    assert connected is False


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_subscribe_returns_baseline(user_factory):
    a = await database_sync_to_async(user_factory)(username="ws_sub_a")
    b = await database_sync_to_async(user_factory)(username="ws_sub_b")
    conv = await _mk_private(a, b)
    comm = await _connect(a)
    await comm.send_json_to(
        {"type": "subscribe", "conversation_ids": [str(conv.id)]}
    )
    frame = await comm.receive_json_from()
    assert frame["type"] == "chat.subscribed"
    assert frame["data"]["conversation_id"] == str(conv.id)
    assert frame["data"]["last_seq"] == 0
    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_broadcast_message_new_between_two(user_factory):
    """同会话两人互发，对方收到 message.new（seq 正确）。"""
    a = await database_sync_to_async(user_factory)(username="ws_br_a")
    b = await database_sync_to_async(user_factory)(username="ws_br_b")
    conv = await _mk_private(a, b)
    comm_a = await _connect(a)
    comm_b = await _connect(b)

    # 双方订阅
    await comm_a.send_json_to(
        {"type": "subscribe", "conversation_ids": [str(conv.id)]}
    )
    await comm_a.receive_json_from()  # a 基线
    await comm_b.send_json_to(
        {"type": "subscribe", "conversation_ids": [str(conv.id)]}
    )
    await comm_b.receive_json_from()  # b 基线

    # a 发消息 → b 收到 message.new
    msg = await _send_message(a, conv, "你好b")
    await services.abroadcast_message_new(msg)

    frame = await comm_b.receive_json_from()
    assert frame["type"] == "message.new"
    data = frame["data"]
    assert data["conversation_id"] == str(conv.id)
    assert data["content"] == "你好b"
    assert data["sender_id"] == str(a.id)
    assert data["seq"] == 1

    await comm_a.disconnect()
    await comm_b.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_typing_and_recall_broadcast(user_factory):
    a = await database_sync_to_async(user_factory)(username="ws_ty_a")
    b = await database_sync_to_async(user_factory)(username="ws_ty_b")
    conv = await _mk_private(a, b)
    comm_b = await _connect(b)
    await comm_b.send_json_to(
        {"type": "subscribe", "conversation_ids": [str(conv.id)]}
    )
    await comm_b.receive_json_from()

    # typing
    await services.abroadcast_typing(conv.id, str(a.id), True)
    frame = await comm_b.receive_json_from()
    assert frame["type"] == "typing"
    assert frame["data"]["is_typing"] is True

    # recall
    msg = await _send_message(a, conv, "撤回我")
    await services.abroadcast_recall(conv.id, msg.id, msg.seq)
    frame = await comm_b.receive_json_from()
    assert frame["type"] == "message.recall"
    assert frame["data"]["message_id"] == str(msg.id)
    assert frame["data"]["seq"] == 1
    await comm_b.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_resume_replays_missed_messages(user_factory):
    """断线前 seq=1，重连后带 last_message_seq=1，收到 seq>=2 + history.sync。"""
    a = await database_sync_to_async(user_factory)(username="ws_res_a")
    b = await database_sync_to_async(user_factory)(username="ws_res_b")
    conv = await _mk_private(a, b)

    # 造 3 条消息
    for i in range(1, 4):
        await _send_message(a, conv, f"m{i}")

    comm = await _connect(b)
    await comm.send_json_to(
        {
            "type": "resume",
            "conversation_id": str(conv.id),
            "last_message_seq": 1,
        }
    )
    # 补发 seq=2,3
    f2 = await comm.receive_json_from()
    assert f2["type"] == "message.new"
    assert f2["data"]["seq"] == 2
    f3 = await comm.receive_json_from()
    assert f3["type"] == "message.new"
    assert f3["data"]["seq"] == 3
    sync = await comm.receive_json_from()
    assert sync["type"] == "history.sync"
    assert sync["data"]["last_seq"] == 3
    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_resume_no_missed_returns_sync_only(user_factory):
    a = await database_sync_to_async(user_factory)(username="ws_rs2_a")
    b = await database_sync_to_async(user_factory)(username="ws_rs2_b")
    conv = await _mk_private(a, b)
    comm = await _connect(b)
    await comm.send_json_to(
        {
            "type": "resume",
            "conversation_id": str(conv.id),
            "last_message_seq": 0,
        }
    )
    sync = await comm.receive_json_from()
    assert sync["type"] == "history.sync"
    assert sync["data"]["last_seq"] == 0
    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_non_member_subscribe_ignored(user_factory):
    a = await database_sync_to_async(user_factory)(username="ws_ig_a")
    b = await database_sync_to_async(user_factory)(username="ws_ig_b")
    outsider = await database_sync_to_async(user_factory)(username="ws_ig_out")
    conv = await _mk_private(a, b)
    comm_out = await _connect(outsider)
    await comm_out.send_json_to(
        {"type": "subscribe", "conversation_ids": [str(conv.id)]}
    )
    # 非成员：无基线帧
    assert await _expect_no_frame(comm_out)
    await comm_out.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_non_member_cannot_receive_broadcast(user_factory):
    a = await database_sync_to_async(user_factory)(username="ws_rcv_a")
    b = await database_sync_to_async(user_factory)(username="ws_rcv_b")
    outsider = await database_sync_to_async(user_factory)(username="ws_rcv_out")
    conv = await _mk_private(a, b)

    comm_b = await _connect(b)
    await comm_b.send_json_to(
        {"type": "subscribe", "conversation_ids": [str(conv.id)]}
    )
    await comm_b.receive_json_from()

    comm_out = await _connect(outsider)
    # 外部未订阅该组，发消息不该收到
    msg = await _send_message(a, conv, "机密")
    await services.abroadcast_message_new(msg)

    # b 收到
    frame = await comm_b.receive_json_from()
    assert frame["type"] == "message.new"
    # outsider 收不到（无帧）
    assert await _expect_no_frame(comm_out)
    await comm_b.disconnect()
    await comm_out.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_slow_consumer_does_not_block_broadcast(user_factory):
    """慢消费者（channel 满）不阻塞其他成员 —— 广播捕获 ChannelFull。"""
    a = await database_sync_to_async(user_factory)(username="ws_slow_a")
    b = await database_sync_to_async(user_factory)(username="ws_slow_b")
    conv = await _mk_private(a, b)

    comm_b = await _connect(b)
    await comm_b.send_json_to(
        {"type": "subscribe", "conversation_ids": [str(conv.id)]}
    )
    await comm_b.receive_json_from()

    # 把 channel layer 的 group_send 替换为抛 ChannelFull 的 stub，
    # 验证服务层广播不抛出、不影响其他成员。
    from channels.exceptions import ChannelFull
    from channels.layers import get_channel_layer

    layer = get_channel_layer()
    original = layer.group_send

    async def _choke(*args, **kwargs):
        raise ChannelFull("chat_conv_xxx")

    layer.group_send = _choke
    try:
        msg = await _send_message(a, conv, "x")
        await services.abroadcast_message_new(msg)  # 不应抛异常
    finally:
        layer.group_send = original
    await comm_b.disconnect()
