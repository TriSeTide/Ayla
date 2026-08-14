"""chat 群申请/邀请 REST 契约测试（S2，开发文档 §1.2）。

覆盖：申请状态机（pending→accepted/rejected）、重复申请幂等、已是成员 400、
非 owner 审批 403、accept 事务内建成员；邀请权限、幂等、处理邀请本人专属。
"""
import pytest

from apps.chat.models import (
    Conversation,
    ConversationMember,
    GroupInvite,
    GroupJoinRequest,
)
from apps.chat.tests.helpers import auth_as, make_group


def _group(auth_client, user_factory, member_users, owner_name="jr_owner"):
    ca, _ = auth_client(username=owner_name)
    return make_group(ca, member_users), ca


@pytest.mark.django_db
class TestGroupJoinRequest:
    def test_apply_join_creates_pending(self, auth_client, user_factory):
        b = user_factory(username="jr_b")
        conv, _ = _group(auth_client, user_factory, [b])
        applicant = user_factory(username="jr_app1")
        ca = auth_as(applicant)
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/join-requests/",
            {"message": "想加入"},
            format="json",
        )
        assert resp.status_code == 201, resp.content
        data = resp.json()
        assert data["status"] == "pending"
        assert data["conversation_id"] == str(conv["id"])
        assert data["conversation_title"] == conv["title"]
        assert data["applicant"]["id"] == str(applicant.id)
        assert (
            GroupJoinRequest.objects.filter(
                conversation_id=conv["id"], applicant=applicant
            ).count()
            == 1
        )

    def test_apply_join_idempotent(self, auth_client, user_factory):
        b = user_factory(username="jr_b")
        conv, _ = _group(auth_client, user_factory, [b])
        applicant = user_factory(username="jr_app2")
        ca = auth_as(applicant)
        url = f"/api/v1/chat/conversations/{conv['id']}/join-requests/"
        first = ca.post(url, {"message": "再来"}, format="json")
        second = ca.post(url, {"message": "再来"}, format="json")
        assert first.status_code == 201
        assert second.status_code == 200  # 幂等复用，不新建
        assert second.json()["id"] == first.json()["id"]
        assert (
            GroupJoinRequest.objects.filter(
                conversation_id=conv["id"], applicant=applicant
            ).count()
            == 1
        )

    def test_apply_join_already_member_400(self, auth_client, user_factory):
        b = user_factory(username="jr_b")
        conv, _ = _group(auth_client, user_factory, [b])
        cb = auth_as(b)
        resp = cb.post(
            f"/api/v1/chat/conversations/{conv['id']}/join-requests/",
            format="json",
        )
        assert resp.status_code == 400

    def test_apply_join_private_conv_403(self, auth_client, user_factory):
        b = user_factory(username="jr_b")
        ca, _ = auth_client(username="jr_priv_owner")
        cb = auth_as(b)
        # 建私聊：A 与 B 私聊，B 不能对私聊会话申请入群
        ca.post(
            "/api/v1/chat/conversations/private/",
            {"user_id": str(b.id)},
            format="json",
        )
        conv_id = Conversation.objects.get(type="private").id
        resp = cb.post(
            f"/api/v1/chat/conversations/{conv_id}/join-requests/",
            format="json",
        )
        assert resp.status_code == 403

    def test_owner_accept_creates_member(self, auth_client, user_factory):
        b = user_factory(username="jr_b")
        conv, ca = _group(auth_client, user_factory, [b])
        applicant = user_factory(username="jr_app3")
        req = GroupJoinRequest.objects.create(
            conversation_id=conv["id"], applicant=applicant
        )
        resp = ca.post(
            f"/api/v1/chat/join-requests/{req.id}/action/",
            {"action": "accept"},
            format="json",
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["status"] == "accepted"
        member = ConversationMember.objects.get(
            conversation_id=conv["id"], user=applicant
        )
        assert member.role == ConversationMember.ROLE_MEMBER

    def test_admin_can_approve(self, auth_client, user_factory):
        b = user_factory(username="jr_b")
        conv, ca = _group(auth_client, user_factory, [b])
        # 把 b 提升为 admin
        ConversationMember.objects.filter(
            conversation_id=conv["id"], user=b
        ).update(role=ConversationMember.ROLE_ADMIN)
        applicant = user_factory(username="jr_app4")
        req = GroupJoinRequest.objects.create(
            conversation_id=conv["id"], applicant=applicant
        )
        cb = auth_as(b)
        resp = cb.post(
            f"/api/v1/chat/join-requests/{req.id}/action/",
            {"action": "accept"},
            format="json",
        )
        assert resp.status_code == 200
        assert resp.json()["status"] == "accepted"

    def test_non_owner_approve_403(self, auth_client, user_factory):
        b = user_factory(username="jr_b")
        c = user_factory(username="jr_c")
        conv, _ = _group(auth_client, user_factory, [b, c])
        applicant = user_factory(username="jr_app5")
        req = GroupJoinRequest.objects.create(
            conversation_id=conv["id"], applicant=applicant
        )
        cc = auth_as(c)  # 普通成员，无审批权
        resp = cc.post(
            f"/api/v1/chat/join-requests/{req.id}/action/",
            {"action": "accept"},
            format="json",
        )
        assert resp.status_code == 403
        # 状态未被修改，仍 pending
        req.refresh_from_db()
        assert req.status == GroupJoinRequest.STATUS_PENDING

    def test_outsider_approve_403(self, auth_client, user_factory):
        b = user_factory(username="jr_b")
        conv, _ = _group(auth_client, user_factory, [b])
        applicant = user_factory(username="jr_app6")
        outsider = user_factory(username="jr_out")
        req = GroupJoinRequest.objects.create(
            conversation_id=conv["id"], applicant=applicant
        )
        co = auth_as(outsider)
        assert (
            co.post(
                f"/api/v1/chat/join-requests/{req.id}/action/",
                {"action": "reject"},
                format="json",
            ).status_code
            == 403
        )

    def test_reject_does_not_add_member(self, auth_client, user_factory):
        b = user_factory(username="jr_b")
        conv, ca = _group(auth_client, user_factory, [b])
        applicant = user_factory(username="jr_app7")
        req = GroupJoinRequest.objects.create(
            conversation_id=conv["id"], applicant=applicant
        )
        resp = ca.post(
            f"/api/v1/chat/join-requests/{req.id}/action/",
            {"action": "reject"},
            format="json",
        )
        assert resp.status_code == 200
        assert resp.json()["status"] == "rejected"
        assert not ConversationMember.objects.filter(
            conversation_id=conv["id"], user=applicant
        ).exists()

    def test_handle_already_handled_404(self, auth_client, user_factory):
        b = user_factory(username="jr_b")
        conv, ca = _group(auth_client, user_factory, [b])
        applicant = user_factory(username="jr_app8")
        req = GroupJoinRequest.objects.create(
            conversation_id=conv["id"], applicant=applicant
        )
        ca.post(
            f"/api/v1/chat/join-requests/{req.id}/action/",
            {"action": "accept"},
            format="json",
        )
        # 已处理，再操作 404
        assert (
            ca.post(
                f"/api/v1/chat/join-requests/{req.id}/action/",
                {"action": "reject"},
                format="json",
            ).status_code
            == 404
        )

    def test_list_pending_owner_only(self, auth_client, user_factory):
        b = user_factory(username="jr_b")
        c = user_factory(username="jr_c")
        conv, ca = _group(auth_client, user_factory, [b, c])
        applicant = user_factory(username="jr_app9")
        GroupJoinRequest.objects.create(
            conversation_id=conv["id"], applicant=applicant
        )
        # owner 可见
        resp = ca.get(f"/api/v1/chat/conversations/{conv['id']}/join-requests/")
        assert resp.status_code == 200
        items = resp.json()
        assert len(items) == 1
        assert items[0]["applicant"]["id"] == str(applicant.id)
        # 普通成员 403
        cc = auth_as(c)
        assert (
            cc.get(f"/api/v1/chat/conversations/{conv['id']}/join-requests/").status_code
            == 403
        )


@pytest.mark.django_db
class TestGroupInvite:
    def test_member_invite_creates_pending(self, auth_client, user_factory):
        b = user_factory(username="gi_b")
        conv, ca = _group(auth_client, user_factory, [b])
        target = user_factory(username="gi_t1")
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/invites/",
            {"invitee_id": str(target.id)},
            format="json",
        )
        assert resp.status_code == 201, resp.content
        data = resp.json()
        assert data["status"] == "pending"
        assert data["conversation_id"] == str(conv["id"])
        assert data["invitee"]["id"] == str(target.id)
        assert data["inviter"]["id"] == ca.user.id
        assert (
            GroupInvite.objects.filter(
                conversation_id=conv["id"], invitee=target
            ).count()
            == 1
        )

    def test_invite_idempotent(self, auth_client, user_factory):
        b = user_factory(username="gi_b")
        conv, ca = _group(auth_client, user_factory, [b])
        target = user_factory(username="gi_t2")
        url = f"/api/v1/chat/conversations/{conv['id']}/invites/"
        first = ca.post(url, {"invitee_id": str(target.id)}, format="json")
        second = ca.post(url, {"invitee_id": str(target.id)}, format="json")
        assert first.status_code == 201
        assert second.status_code == 200
        assert second.json()["id"] == first.json()["id"]
        assert (
            GroupInvite.objects.filter(
                conversation_id=conv["id"], invitee=target
            ).count()
            == 1
        )

    def test_non_member_invite_403(self, auth_client, user_factory):
        b = user_factory(username="gi_b")
        conv, _ = _group(auth_client, user_factory, [b])
        outsider = user_factory(username="gi_out")
        target = user_factory(username="gi_t3")
        co = auth_as(outsider)
        resp = co.post(
            f"/api/v1/chat/conversations/{conv['id']}/invites/",
            {"invitee_id": str(target.id)},
            format="json",
        )
        assert resp.status_code == 403

    def test_invite_already_member_400(self, auth_client, user_factory):
        b = user_factory(username="gi_b")
        conv, ca = _group(auth_client, user_factory, [b])
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/invites/",
            {"invitee_id": str(b.id)},
            format="json",
        )
        assert resp.status_code == 400

    def test_invite_self_400(self, auth_client, user_factory):
        b = user_factory(username="gi_b")
        conv, ca = _group(auth_client, user_factory, [b])
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/invites/",
            {"invitee_id": str(ca.user.id)},
            format="json",
        )
        assert resp.status_code == 400

    def test_my_invites_pending_only(self, auth_client, user_factory):
        b = user_factory(username="gi_b")
        conv, ca = _group(auth_client, user_factory, [b])
        target = user_factory(username="gi_t4")
        # 两个邀请：一个 pending，一个已处理
        ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/invites/",
            {"invitee_id": str(target.id)},
            format="json",
        )
        GroupInvite.objects.create(
            conversation_id=conv["id"], inviter=ca.user, invitee=target,
            status=GroupInvite.STATUS_ACCEPTED,
        )
        ct = auth_as(target)
        resp = ct.get("/api/v1/chat/me/invites/")
        assert resp.status_code == 200
        items = resp.json()
        assert len(items) == 1
        assert items[0]["status"] == "pending"
        assert items[0]["inviter"]["id"] == str(ca.user.id)

    def test_invitee_accept_creates_member(self, auth_client, user_factory):
        b = user_factory(username="gi_b")
        conv, ca = _group(auth_client, user_factory, [b])
        target = user_factory(username="gi_t5")
        inv = GroupInvite.objects.create(
            conversation_id=conv["id"], inviter=ca.user, invitee=target
        )
        ct = auth_as(target)
        resp = ct.post(
            f"/api/v1/chat/invites/{inv.id}/action/",
            {"action": "accept"},
            format="json",
        )
        assert resp.status_code == 200
        assert resp.json()["status"] == "accepted"
        member = ConversationMember.objects.get(
            conversation_id=conv["id"], user=target
        )
        assert member.role == ConversationMember.ROLE_MEMBER

    def test_other_user_handle_invite_403(self, auth_client, user_factory):
        b = user_factory(username="gi_b")
        conv, ca = _group(auth_client, user_factory, [b])
        target = user_factory(username="gi_t6")
        other = user_factory(username="gi_t6_other")
        inv = GroupInvite.objects.create(
            conversation_id=conv["id"], inviter=ca.user, invitee=target
        )
        co = auth_as(other)
        resp = co.post(
            f"/api/v1/chat/invites/{inv.id}/action/",
            {"action": "accept"},
            format="json",
        )
        assert resp.status_code == 403

    def test_reject_invite_no_member(self, auth_client, user_factory):
        b = user_factory(username="gi_b")
        conv, ca = _group(auth_client, user_factory, [b])
        target = user_factory(username="gi_t7")
        inv = GroupInvite.objects.create(
            conversation_id=conv["id"], inviter=ca.user, invitee=target
        )
        ct = auth_as(target)
        resp = ct.post(
            f"/api/v1/chat/invites/{inv.id}/action/",
            {"action": "reject"},
            format="json",
        )
        assert resp.status_code == 200
        assert resp.json()["status"] == "rejected"
        assert not ConversationMember.objects.filter(
            conversation_id=conv["id"], user=target
        ).exists()
