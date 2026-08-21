"""chat 用户级 WS 广播契约测试（S2：group.request.resolved / group.invite.new）。

申请人/被邀请人不是会话成员，收不到 chat_conv_* 组广播；S2 新增
`chat_user_<id>` 用户级组，connect 即加入。本文件验证该组能收到两类新事件。
沿用 test_chat_ws.py 的 transactional_db + InMemory channel layer 模式。
"""
import pytest
from channels.db import database_sync_to_async
from channels.routing import URLRouter
from channels.testing import WebsocketCommunicator
from django.urls import path

from apps.accounts.models import FriendRequest
from apps.chat import services
from apps.chat.consumers import ChatConsumer
from apps.chat.models import Conversation, ConversationMember

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
def _mk_request(applicant, conv, message="想加入"):
    req, _ = services.create_join_request(applicant, conv, message)
    return req


@database_sync_to_async
def _accept(req, handler):
    services.accept_join_request(req, handler)
    return req


@database_sync_to_async
def _mk_invite(inviter, conv, invitee):
    inv, _ = services.create_group_invite(inviter, conv, invitee)
    return inv


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_join_request_resolved_broadcast(user_factory):
    """审批通过后，申请人（非成员）收到 group.request.resolved。"""
    owner = await database_sync_to_async(user_factory)(username="wjr_owner")
    member = await database_sync_to_async(user_factory)(username="wjr_member")
    applicant = await database_sync_to_async(user_factory)(username="wjr_app")
    conv = await _mk_group(owner, [member])
    req = await _mk_request(applicant, conv)

    comm = await _connect(applicant)
    req = await _accept(req, owner)
    await services.abroadcast_group_request_resolved(
        applicant.id,
        request_id=req.id,
        conversation_id=conv.id,
        conversation_title=conv.title,
        status=req.status,
        handled_by_id=owner.id,
        handled_at=req.handled_at,
    )
    frame = await comm.receive_json_from()
    assert frame["type"] == "group.request.resolved"
    data = frame["data"]
    assert data["request_id"] == str(req.id)
    assert data["conversation_id"] == str(conv.id)
    assert data["conversation_title"] == conv.title
    assert data["status"] == "accepted"
    assert data["handled_by_id"] == str(owner.id)
    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_invite_new_broadcast(user_factory):
    """新邀请创建后，被邀请人（非成员）收到 group.invite.new。"""
    owner = await database_sync_to_async(user_factory)(username="wgi_owner")
    member = await database_sync_to_async(user_factory)(username="wgi_member")
    invitee = await database_sync_to_async(user_factory)(username="wgi_invitee")
    conv = await _mk_group(owner, [member])
    inv = await _mk_invite(owner, conv, invitee)

    comm = await _connect(invitee)
    await services.abroadcast_group_invite_new(
        invitee.id,
        invite_id=inv.id,
        conversation_id=conv.id,
        conversation_title=conv.title,
        inviter_id=owner.id,
        inviter_name=owner.nickname or owner.username,
        created_at=inv.created_at,
    )
    frame = await comm.receive_json_from()
    assert frame["type"] == "group.invite.new"
    data = frame["data"]
    assert data["invite_id"] == str(inv.id)
    assert data["conversation_id"] == str(conv.id)
    assert data["inviter_id"] == str(owner.id)
    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_unrelated_user_receives_nothing(user_factory):
    """无关用户连接同一 WS，收不到用户级广播（组隔离）。"""
    owner = await database_sync_to_async(user_factory)(username="wiso_owner")
    member = await database_sync_to_async(user_factory)(username="wiso_member")
    applicant = await database_sync_to_async(user_factory)(username="wiso_app")
    unrelated = await database_sync_to_async(user_factory)(username="wiso_other")
    conv = await _mk_group(owner, [member])
    req = await _mk_request(applicant, conv)

    comm_unrelated = await _connect(unrelated)
    req = await _accept(req, owner)
    await services.abroadcast_group_request_resolved(
        applicant.id,
        request_id=req.id,
        conversation_id=conv.id,
        conversation_title=conv.title,
        status=req.status,
        handled_by_id=owner.id,
        handled_at=req.handled_at,
    )
    # 无关用户无帧
    try:
        import asyncio

        with pytest.raises(asyncio.TimeoutError):
            await asyncio.wait_for(comm_unrelated.receive_json_from(), timeout=0.3)
    finally:
        await comm_unrelated.disconnect()


@database_sync_to_async
def _mk_friend_request(from_user, to_user, message="想加好友"):
    return FriendRequest.objects.create(
        from_user=from_user, to_user=to_user, message=message
    )


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_friend_request_new_broadcast(user_factory):
    """新好友申请 → 接收方收到 friend.request.new（认证消息红点实时）。"""
    sender = await database_sync_to_async(user_factory)(
        username="wfr_sender", nickname="发哥"
    )
    receiver = await database_sync_to_async(user_factory)(username="wfr_receiver")
    req = await _mk_friend_request(sender, receiver)

    comm = await _connect(receiver)
    await services.abroadcast_friend_request_new(
        receiver.id,
        request_id=req.id,
        from_user_id=sender.id,
        from_user_name=sender.nickname or sender.username,
        message=req.message,
        created_at=req.created_at,
    )
    frame = await comm.receive_json_from()
    assert frame["type"] == "friend.request.new"
    data = frame["data"]
    assert data["request_id"] == str(req.id)
    assert data["from_user_id"] == str(sender.id)
    assert data["from_user_name"] == "发哥"
    assert data["message"] == "想加好友"
    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_friend_request_resolved_broadcast(user_factory):
    """好友申请被处理 → 发起方收到 friend.request.resolved。"""
    sender = await database_sync_to_async(user_factory)(username="wfrr_sender")
    receiver = await database_sync_to_async(user_factory)(username="wfrr_receiver")
    req = await _mk_friend_request(sender, receiver)

    comm = await _connect(sender)
    await services.abroadcast_friend_request_resolved(
        sender.id,
        request_id=req.id,
        status="accepted",
        handled_at=req.created_at,
    )
    frame = await comm.receive_json_from()
    assert frame["type"] == "friend.request.resolved"
    data = frame["data"]
    assert data["request_id"] == str(req.id)
    assert data["status"] == "accepted"
    await comm.disconnect()
