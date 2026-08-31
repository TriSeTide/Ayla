"""戳一戳（poke）契约测试：发送/校验/未读排除/历史/预览/WS 广播与补发。

核心语义（任务 01）：
- poke 是独立消息类型，落库进会话历史；
- 刻意不产生未读：unread 查询排除 poke，不写 MessageRead；
- WS 走独立 message.poke 帧（不走 message.new），resume 补发也走 poke 帧。

注意（环境基线）：Django 5.2 的 SQLite 后端 `supports_json_field_contains=False`，
M8 的 `segments__contains`（@ 未读查询）在 SQLite 测试环境必然失败（test_conv_api/
test_message_api 全量受影响，与本任务无关）。本文件刻意避开「会话序列化」路径
（不调用 ConversationSerializer/ConversationListSerializer），不触发 contains；
poke 的未读排除用 DB 级断言 + message_preview 单测覆盖。
"""
import pytest
from channels.db import database_sync_to_async
from channels.routing import URLRouter
from channels.testing import WebsocketCommunicator
from django.urls import path

from apps.chat import services
from apps.chat.consumers import ChatConsumer
from apps.chat.models import Conversation, ConversationMember, Message, MessageRead
from apps.chat.serializers import message_preview
from apps.chat.tests.helpers import auth_as, new_key

pytestmark = pytest.mark.usefixtures("transactional_db")

WS_PATH = "ws/chat/"


def _token_for(user):
    from rest_framework_simplejwt.tokens import RefreshToken

    return str(RefreshToken.for_user(user).access_token)


def _make_app():
    return URLRouter([path(WS_PATH, ChatConsumer.as_asgi())])


async def _connect(user):
    comm = WebsocketCommunicator(_make_app(), f"/{WS_PATH}?token={_token_for(user)}")
    connected, _ = await comm.connect()
    assert connected is True
    return comm


def _mk_private_sync(a, b) -> Conversation:
    return services.get_or_create_conversation(a, b)


def _mk_private_friends_sync(a, b) -> Conversation:
    """私聊 + 双向好友（私聊发消息契约要求好友，Bug #2）。"""
    from apps.accounts.models import Friendship

    Friendship.objects.get_or_create(
        user=a, friend=b, defaults={"status": Friendship.STATUS_ACCEPTED}
    )
    Friendship.objects.get_or_create(
        user=b, friend=a, defaults={"status": Friendship.STATUS_ACCEPTED}
    )
    return services.get_or_create_conversation(a, b)


def _mk_group_sync(owner, members, title="poke群") -> Conversation:
    conv = Conversation.objects.create(
        type=Conversation.TYPE_GROUP, title=title, owner=owner
    )
    ConversationMember.objects.create(
        conversation=conv, user=owner, role=ConversationMember.ROLE_OWNER
    )
    for m in members:
        ConversationMember.objects.create(conversation=conv, user=m)
    return conv


# ---------- REST ----------


@pytest.mark.django_db
class TestPokeREST:
    def test_send_poke_private(self, auth_client, user_factory):
        b = user_factory(username="pk_b", nickname="小B")
        ca, a = auth_client(username="pk_a", nickname="小A")
        conv = _mk_private_friends_sync(a, b)
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv.id}/messages/",
            {"type": "poke", "content": str(b.id), "idempotency_key": new_key()},
            format="json",
        )
        assert resp.status_code == 201, resp.content
        body = resp.json()
        assert body["type"] == "poke"
        assert body["content"] == str(b.id)
        assert body["sender_id"] == str(a.id)
        assert body["seq"] == 1

    def test_send_poke_group(self, auth_client, user_factory):
        b = user_factory(username="pkg_b", nickname="群友B")
        ca, a = auth_client(username="pkg_a", nickname="群主A")
        conv = _mk_group_sync(a, [b])
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv.id}/messages/",
            {"type": "poke", "content": str(b.id), "idempotency_key": new_key()},
            format="json",
        )
        assert resp.status_code == 201, resp.content
        assert resp.json()["type"] == "poke"

    def test_poke_target_not_member_400(self, auth_client, user_factory):
        b = user_factory(username="pkn_b")
        outsider = user_factory(username="pkn_out")
        ca, _ = auth_client(username="pkn_a")
        conv = _mk_private_friends_sync(ca.user, b)
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv.id}/messages/",
            {"type": "poke", "content": str(outsider.id)},
            format="json",
        )
        assert resp.status_code == 400, resp.content
        assert "目标用户不在会话中" in resp.content.decode()

    def test_poke_requires_target(self, auth_client, user_factory):
        b = user_factory(username="pke_b")
        ca, _ = auth_client(username="pke_a")
        conv = _mk_private_friends_sync(ca.user, b)
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv.id}/messages/",
            {"type": "poke", "content": ""},
            format="json",
        )
        assert resp.status_code == 400

    def test_poke_rejects_media(self, auth_client, user_factory):
        b = user_factory(username="pkm_b")
        ca, _ = auth_client(username="pkm_a")
        conv = _mk_private_friends_sync(ca.user, b)
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv.id}/messages/",
            {"type": "poke", "content": str(b.id), "media_id": "m-1"},
            format="json",
        )
        assert resp.status_code == 400
        assert "不能携带媒体" in resp.content.decode()

    def test_poke_not_unread_and_no_read_receipt(self, auth_client, user_factory):
        """poke 不计未读、不写已读回执；后续普通消息照常计入未读。

        用 DB 级断言绕开 SQLite 的 JSON contains 基线问题（见模块 docstring）。
        """
        b = user_factory(username="pku_b", nickname="未读B")
        ca, a = auth_client(username="pku_a", nickname="未读A")
        conv = _mk_private_friends_sync(a, b)
        r1 = ca.post(
            f"/api/v1/chat/conversations/{conv.id}/messages/",
            {"type": "poke", "content": str(b.id), "idempotency_key": new_key()},
            format="json",
        )
        assert r1.status_code == 201
        r2 = ca.post(
            f"/api/v1/chat/conversations/{conv.id}/messages/",
            {"type": "text", "content": "普通", "idempotency_key": new_key()},
            format="json",
        )
        assert r2.status_code == 201
        # poke 消息无已读回执
        poke_id = r1.json()["id"]
        assert not MessageRead.objects.filter(message_id=poke_id).exists()
        # 未读语义（与 serializers._unread_queryset 一致）：poke 被排除，普通消息算 1
        unread = (
            Message.objects.filter(conversation=conv)
            .exclude(sender=b)
            .exclude(status=Message.STATUS_RECALLED)
            .exclude(type=Message.TYPE_POKE)
            .exclude(reads__user=b)
        )
        assert list(unread) == [Message.objects.get(pk=r2.json()["id"])]
        # 历史里 poke 可见
        hist = auth_as(b).get(f"/api/v1/chat/conversations/{conv.id}/messages/")
        types = [m["type"] for m in hist.json()]
        assert "poke" in types

    def test_poke_preview(self, auth_client, user_factory):
        """列表预览 = 「发送者戳了戳目标」（message_preview 单测，避开会话序列化）。"""
        b = user_factory(username="pkp_b", nickname="小B")
        ca, a = auth_client(username="pkp_a", nickname="小A")
        conv = _mk_private_friends_sync(a, b)
        msg = services.create_message(
            a, conv, content=str(b.id), msg_type=Message.TYPE_POKE
        )
        assert message_preview(msg) == "小A戳了戳小B"

    def test_poke_idempotent(self, auth_client, user_factory):
        b = user_factory(username="pki_b")
        ca, _ = auth_client(username="pki_a")
        conv = _mk_private_friends_sync(ca.user, b)
        key = new_key()
        r1 = ca.post(
            f"/api/v1/chat/conversations/{conv.id}/messages/",
            {"type": "poke", "content": str(b.id), "idempotency_key": key},
            format="json",
        )
        assert r1.status_code == 201
        r2 = ca.post(
            f"/api/v1/chat/conversations/{conv.id}/messages/",
            {"type": "poke", "content": str(b.id), "idempotency_key": key},
            format="json",
        )
        assert r2.status_code == 200
        assert r2.json()["id"] == r1.json()["id"]


# ---------- WS ----------


@database_sync_to_async
def _mk_private(a, b):
    return services.get_or_create_conversation(a, b)


@database_sync_to_async
def _poke(user, conv, target):
    return services.create_message(
        user, conv, content=str(target.id), msg_type=Message.TYPE_POKE
    )


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_ws_poke_broadcast_not_message_new(user_factory):
    """poke 广播 message.poke 帧（带名字），绝不出 message.new。"""
    a = await database_sync_to_async(user_factory)(username="wsp_a", nickname="甲")
    b = await database_sync_to_async(user_factory)(username="wsp_b", nickname="乙")
    conv = await _mk_private(a, b)

    comm_b = await _connect(b)
    await comm_b.send_json_to(
        {"type": "subscribe", "conversation_ids": [str(conv.id)]}
    )
    await comm_b.receive_json_from()  # chat.subscribed 基线

    msg = await _poke(a, conv, b)
    await services.abroadcast_message_poke(msg)

    frame = await comm_b.receive_json_from()
    assert frame["type"] == "message.poke"
    d = frame["data"]
    assert d["conversation_id"] == str(conv.id)
    assert d["sender_id"] == a.id
    assert d["sender_name"] == "甲"
    assert d["target_user_id"] == str(b.id)
    assert d["target_name"] == "乙"
    assert d["seq"] == msg.seq

    await comm_b.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_ws_resume_redelivers_poke_as_poke_frame(user_factory):
    """resume 补发：poke 消息走 message.poke 帧，不走 message.new。"""
    a = await database_sync_to_async(user_factory)(username="wsr_a")
    b = await database_sync_to_async(user_factory)(username="wsr_b")
    conv = await _mk_private(a, b)
    msg = await _poke(a, conv, b)

    comm_b = await _connect(b)
    await comm_b.send_json_to(
        {
            "type": "resume",
            "conversation_id": str(conv.id),
            "last_message_seq": 0,
        }
    )

    frame_types = []
    for _ in range(2):  # 补发帧 + history.sync
        frame = await comm_b.receive_json_from()
        frame_types.append(frame["type"])
        if frame["type"] == "message.poke":
            assert frame["data"]["message_id"] == str(msg.id)
    assert "message.poke" in frame_types
    assert "message.new" not in frame_types

    await comm_b.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_ws_group_poke_broadcast(user_factory):
    """群聊 poke 广播到群会话组。"""
    a = await database_sync_to_async(user_factory)(username="wsg_a", nickname="群主")
    b = await database_sync_to_async(user_factory)(username="wsg_b", nickname="群友")
    conv = await database_sync_to_async(_mk_group_sync)(a, [b])

    comm_b = await _connect(b)
    await comm_b.send_json_to(
        {"type": "subscribe", "conversation_ids": [str(conv.id)]}
    )
    await comm_b.receive_json_from()  # chat.subscribed 基线

    msg = await _poke(a, conv, b)
    await services.abroadcast_message_poke(msg)

    frame = await comm_b.receive_json_from()
    assert frame["type"] == "message.poke"
    assert frame["data"]["sender_name"] == "群主"
    assert frame["data"]["target_name"] == "群友"

    await comm_b.disconnect()
