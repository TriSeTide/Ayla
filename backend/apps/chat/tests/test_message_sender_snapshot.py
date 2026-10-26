"""消息发送者快照（MessageSerializer.sender）契约测试（2026-10-26）。

为什么需要：
用户实报「群成员退出后，他的历史消息头像变成占位字」。根因链：
- 消息只有 sender_id，昵称/头像靠前端从 conversation.members 反查；
- 成员退群后就不在成员表里 ⇒ 前端拿不到名字 ⇒ 头像退化。

修法：消息直接带发送者公开资料快照 ⇒ 退群成员的头像与未退群时完全一致
（有图显示图、无图显示名字首字），在线光环也能按 sender.id 实时求值。

本文件锁住契约：序列化必须带 sender（含 id/nickname/avatar），
且成员退群后仍然带（这是修复的全部意义）。
"""
from __future__ import annotations

import pytest
from rest_framework.test import APIClient

from apps.accounts.models import User
from apps.chat.models import Conversation, ConversationMember, Message


def _user(username: str, **extra) -> User:
    return User.objects.create_user(
        username=username,
        password="x",
        email=username + "@t.local",
        **extra,
    )


@pytest.mark.django_db
def test_message_serializer_includes_sender_snapshot():
    """消息序列化必须带发送者快照（id / nickname / avatar）。"""
    owner = _user("snap_owner")
    member = _user("snap_member", nickname="小樱", avatar="https://cdn/a.png")
    conv = Conversation.objects.create(type=Conversation.TYPE_GROUP, title="g", owner=owner)
    ConversationMember.objects.create(conversation=conv, user=owner, role=ConversationMember.ROLE_OWNER)
    ConversationMember.objects.create(conversation=conv, user=member, role=ConversationMember.ROLE_MEMBER)
    msg = Message.objects.create(conversation=conv, sender=member, seq=1, content="hi", type="text")

    client = APIClient()
    client.force_authenticate(owner)
    resp = client.get(f"/api/v1/chat/conversations/{conv.id}/messages/")
    assert resp.status_code == 200
    rows = resp.json()
    rows = rows.get("results", rows) if isinstance(rows, dict) else rows
    hit = [r for r in rows if r["id"] == str(msg.id)]
    assert hit, "消息必须出现在列表里"

    sender = hit[0].get("sender")
    assert sender is not None, "★ 必须带 sender 快照（退群成员头像依赖它）"
    assert str(sender["id"]) == str(member.id)
    assert sender["nickname"] == "小樱"
    assert sender["avatar"] == "https://cdn/a.png"


@pytest.mark.django_db
def test_sender_snapshot_survives_member_leaving_group():
    """★ 核心：成员退群后，历史消息的 sender 快照仍在。

    这才是用户报的那个场景 —— 退群不该让历史消息头像失去名字来源。
    """
    owner = _user("snap_owner2")
    leaver = _user("snap_leaver", nickname="退群人", avatar="https://cdn/b.png")
    conv = Conversation.objects.create(type=Conversation.TYPE_GROUP, title="g2", owner=owner)
    ConversationMember.objects.create(conversation=conv, user=owner, role=ConversationMember.ROLE_OWNER)
    membership = ConversationMember.objects.create(
        conversation=conv, user=leaver, role=ConversationMember.ROLE_MEMBER
    )
    msg = Message.objects.create(conversation=conv, sender=leaver, seq=1, content="bye", type="text")

    membership.delete()
    assert not ConversationMember.objects.filter(conversation=conv, user=leaver).exists()

    client = APIClient()
    client.force_authenticate(owner)
    resp = client.get(f"/api/v1/chat/conversations/{conv.id}/messages/")
    assert resp.status_code == 200
    rows = resp.json()
    rows = rows.get("results", rows) if isinstance(rows, dict) else rows
    hit = [r for r in rows if r["id"] == str(msg.id)]
    assert hit, "退群成员的历史消息必须仍在"

    sender = hit[0].get("sender")
    assert sender is not None, "★ 退群后仍必须带 sender 快照（本次修复的核心）"
    assert sender["nickname"] == "退群人"
    assert sender["avatar"] == "https://cdn/b.png"
