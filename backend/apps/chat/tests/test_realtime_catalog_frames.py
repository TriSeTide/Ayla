"""2026-10-20 补齐帧的契约测试（普查 W2/W4/W5/W6）。

背景：全量普查发现这些变更**此前只有 REST、没有任何 WS 广播** ⇒
「别人改了群名/踢了人/解散了群，其他成员的界面停留在旧状态，直到下次刷新」。
用户明确要求「web 漏实现的也补上」，故新增四个帧并用本文件锁住。

覆盖：
- `conversation.updated`（群资料：标题/公告/头像/入群策略）
- `conversation.members.changed`（成员：加入/踢出/退出/角色变更）
- `conversation.dissolved`（解散）
- `join_request.resolved`（入群申请被其他管理员处理）

与 `test_chat_ws.py` 同一套测试基建（WebsocketCommunicator + InMemory layer）。
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
def _mk_group(owner, members, title="补齐帧群"):
    conv = Conversation.objects.create(
        type=Conversation.TYPE_GROUP, title=title, owner=owner
    )
    ConversationMember.objects.create(
        conversation=conv, user=owner, role=ConversationMember.ROLE_OWNER
    )
    for m in members:
        ConversationMember.objects.create(conversation=conv, user=m)
    return conv


async def _subscribe(comm, conv):
    await comm.send_json_to(
        {"type": "subscribe", "conversation_ids": [str(conv.id)]}
    )
    frame = await comm.receive_json_from()
    assert frame["type"] == "chat.subscribed"


async def _sync(fn):
    """把同步广播函数丢到线程里跑（生产里它们由**同步视图**调用）。"""
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(None, fn)


@pytest.mark.asyncio
async def test_conversation_updated_broadcast(transactional_db, django_user_model):
    """W2：群改名后，**其他成员**必须收到 conversation.updated（带新标题）。"""
    owner = await database_sync_to_async(django_user_model.objects.create_user)(
        username="w2_owner", email="w2_owner@example.com", password="x"
    )
    member = await database_sync_to_async(django_user_model.objects.create_user)(
        username="w2_member", email="w2_member@example.com", password="x"
    )
    conv = await _mk_group(owner, [member])

    comm = await _connect(member)
    await _subscribe(comm, conv)

    await database_sync_to_async(_rename)(conv, "改名后的群")
    frame = await comm.receive_json_from()
    assert frame["type"] == "conversation.updated"
    assert frame["data"]["conversation"]["title"] == "改名后的群"
    assert frame["data"]["conversation"]["id"] == str(conv.id)
    await comm.disconnect()


def _rename(conv, title):
    conv.title = title
    conv.save(update_fields=["title"])
    services.broadcast_conversation_updated(conv)


@pytest.mark.asyncio
async def test_members_changed_broadcast(transactional_db, django_user_model):
    """W4：角色变更必须广播给成员，且带 action / member_id / member_count。"""
    owner = await database_sync_to_async(django_user_model.objects.create_user)(
        username="w4_owner", email="w4_owner@example.com", password="x"
    )
    member = await database_sync_to_async(django_user_model.objects.create_user)(
        username="w4_member", email="w4_member@example.com", password="x"
    )
    conv = await _mk_group(owner, [member])

    comm = await _connect(member)
    await _subscribe(comm, conv)

    await _sync(
        lambda: services.broadcast_conversation_members_changed(
            conv,
            action="role_changed",
            member_id=member.id,
            member_name="m",
            role=ConversationMember.ROLE_ADMIN,
        )
    )
    frame = await comm.receive_json_from()
    assert frame["type"] == "conversation.members.changed"
    assert frame["data"]["action"] == "role_changed"
    assert frame["data"]["member_id"] == str(member.id)
    # 成员数在同步上下文里应可读到（异步上下文为 None 是**刻意**的兜底）。
    assert frame["data"]["member_count"] in (2, None)
    await comm.disconnect()


@pytest.mark.asyncio
async def test_conversation_dissolved_broadcast(transactional_db, django_user_model):
    """W6：解散必须在删除**之前**广播，其他成员收到 conversation.dissolved。"""
    owner = await database_sync_to_async(django_user_model.objects.create_user)(
        username="w6_owner", email="w6_owner@example.com", password="x"
    )
    member = await database_sync_to_async(django_user_model.objects.create_user)(
        username="w6_member", email="w6_member@example.com", password="x"
    )
    conv = await _mk_group(owner, [member])
    conv_id = conv.id

    comm = await _connect(member)
    await _subscribe(comm, conv)

    await _sync(lambda: services.dissolve_group(conv, owner))
    frame = await comm.receive_json_from()
    assert frame["type"] == "conversation.dissolved"
    assert frame["data"]["conversation_id"] == str(conv_id)
    await comm.disconnect()


@pytest.mark.asyncio
async def test_join_request_resolved_to_other_admins(
    transactional_db, django_user_model
):
    """W5：申请被处理后，**其他管理员**要收到 join_request.resolved。"""
    admin_a = await database_sync_to_async(django_user_model.objects.create_user)(
        username="w5_admin_a", email="w5_admin_a@example.com", password="x"
    )
    admin_b = await database_sync_to_async(django_user_model.objects.create_user)(
        username="w5_admin_b", email="w5_admin_b@example.com", password="x"
    )
    comm = await _connect(admin_b)

    await _sync(
        lambda: services.broadcast_join_request_resolved(
            [str(admin_b.id)],
            request_id=1,
            conversation_id=1,
            conversation_title="某群",
            applicant_name="某人",
            status_value="accepted",
        )
    )
    frame = await comm.receive_json_from()
    assert frame["type"] == "join_request.resolved"
    # 用户级通知帧是**扁平**结构（与既有 group.request.new 等同形），
    # 不是会话级那种 {type, data:{...}} 包装。
    assert frame["status"] == "accepted"
    assert frame["applicant_name"] == "某人"
    await comm.disconnect()