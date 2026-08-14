"""me/badges/ 聚合契约测试（S2，开发文档 §1.8，B9）。

覆盖：空状态全 0、私聊/群聊未读分别聚合、好友申请 pending、
入群邀请 pending、我作为 owner/admin 收到的入群申请 pending。
"""
import pytest

from apps.accounts.models import FriendRequest
from apps.chat.models import (
    Conversation,
    ConversationMember,
    GroupInvite,
    GroupJoinRequest,
)
from apps.chat.tests.helpers import auth_as, make_group, make_private
from apps.chat import services


@pytest.mark.django_db
class TestBadges:
    def test_badges_empty(self, auth_client):
        ca, _ = auth_client(username="bd_empty")
        resp = ca.get("/api/v1/me/badges/")
        assert resp.status_code == 200
        assert resp.json() == {
            "private_unread": 0,
            "group_unread": 0,
            "friend_requests": 0,
            "group_invites": 0,
            "join_requests_pending": 0,
        }

    def test_unread_aggregation(self, auth_client, user_factory):
        b = user_factory(username="bd_b")
        ca, a = auth_client(username="bd_a")
        cb = auth_as(b)
        # 私聊：B 发消息，A 未读 → private_unread
        priv = make_private(ca, cb)
        services.create_message(
            b, Conversation.objects.get(pk=priv["id"]), content="私聊未读"
        )
        # 群聊：B 发消息，A 未读 → group_unread
        conv = make_group(ca, [b])
        services.create_message(
            b, Conversation.objects.get(pk=conv["id"]), content="群聊未读"
        )
        data = ca.get("/api/v1/me/badges/").json()
        assert data["private_unread"] == 1
        assert data["group_unread"] == 1
        # 已读后归零
        from apps.chat.models import Message

        for msg in Message.objects.exclude(sender=a):
            services.mark_read(a, msg)
        data = ca.get("/api/v1/me/badges/").json()
        assert data["private_unread"] == 0
        assert data["group_unread"] == 0

    def test_friend_requests(self, auth_client, user_factory):
        b = user_factory(username="bd_fr_b")
        ca, a = auth_client(username="bd_fr_a")
        FriendRequest.objects.create(
            from_user=b, to_user=a, status=FriendRequest.STATUS_PENDING
        )
        data = ca.get("/api/v1/me/badges/").json()
        assert data["friend_requests"] == 1

    def test_group_invites(self, auth_client, user_factory):
        b = user_factory(username="bd_gi_b")
        cb = auth_as(b)
        ca, a = auth_client(username="bd_gi_a")
        conv = make_group(cb, [])  # b 建群
        GroupInvite.objects.create(
            conversation=Conversation.objects.get(pk=conv["id"]),
            inviter=b,
            invitee=a,
        )
        data = ca.get("/api/v1/me/badges/").json()
        assert data["group_invites"] == 1

    def test_join_requests_pending_for_owner_and_admin(self, auth_client, user_factory):
        b = user_factory(username="bd_jr_b")
        c = user_factory(username="bd_jr_c")
        ca, a = auth_client(username="bd_jr_a")
        conv = make_group(ca, [b])
        # c 是申请人
        GroupJoinRequest.objects.create(
            conversation=Conversation.objects.get(pk=conv["id"]), applicant=c
        )
        # 我(owner)视角
        data = ca.get("/api/v1/me/badges/").json()
        assert data["join_requests_pending"] == 1
        # b 是普通成员 → 不计
        cb = auth_as(b)
        data = cb.get("/api/v1/me/badges/").json()
        assert data["join_requests_pending"] == 0
        # b 提升为 admin 后计入
        ConversationMember.objects.filter(
            conversation_id=conv["id"], user=b
        ).update(role=ConversationMember.ROLE_ADMIN)
        data = cb.get("/api/v1/me/badges/").json()
        assert data["join_requests_pending"] == 1
        # 处理掉后归零
        GroupJoinRequest.objects.filter(conversation_id=conv["id"]).update(
            status=GroupJoinRequest.STATUS_REJECTED
        )
        data = ca.get("/api/v1/me/badges/").json()
        assert data["join_requests_pending"] == 0
