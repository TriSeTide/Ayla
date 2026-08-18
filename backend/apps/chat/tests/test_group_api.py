"""chat 群管理 REST 契约测试：加人/踢人/禁言/改公告/管理员权限/越权。"""
import pytest

from apps.chat.models import ConversationMember
from apps.chat.tests.helpers import auth_as, make_group, make_private


@pytest.mark.django_db
class TestGroupManagement:
    def test_owner_add_kick_mute_announcement(self, auth_client, user_factory):
        b = user_factory(username="gm_b")
        c = user_factory(username="gm_c")
        ca, _ = auth_client(username="gm_a")
        conv = make_group(ca, [b])
        # 加人
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/members/",
            {"user_ids": [str(c.id)]},
            format="json",
        )
        assert resp.status_code == 200
        assert resp.json()["member_count"] == 3
        # 踢人
        assert (
            ca.delete(
                f"/api/v1/chat/conversations/{conv['id']}/members/{c.id}/"
            ).status_code
            == 204
        )
        # 禁言/解除
        assert (
            ca.post(
                f"/api/v1/chat/conversations/{conv['id']}/members/{b.id}/mute/",
                {"muted": True},
                format="json",
            ).status_code
            == 200
        )
        member = ConversationMember.objects.get(conversation_id=conv["id"], user=b)
        assert member.muted is True
        # 改公告
        resp = ca.patch(
            f"/api/v1/chat/conversations/{conv['id']}/",
            {"announcement": "新公告"},
            format="json",
        )
        assert resp.status_code == 200
        assert resp.json()["announcement"] == "新公告"

    def test_admin_can_manage(self, auth_client, user_factory):
        b = user_factory(username="gm2_admin")
        c = user_factory(username="gm2_c")
        ca, _ = auth_client(username="gm2_owner")
        conv = make_group(ca, [b, c])
        ConversationMember.objects.filter(
            conversation_id=conv["id"], user=b
        ).update(role="admin")
        cadmin = auth_as(b)
        assert (
            cadmin.delete(
                f"/api/v1/chat/conversations/{conv['id']}/members/{c.id}/"
            ).status_code
            == 204
        )

    def test_kick_unknown_member_404(self, auth_client, user_factory):
        b = user_factory(username="gm3_b")
        ca, _ = auth_client(username="gm3_a")
        conv = make_group(ca, [b])
        resp = ca.delete(
            f"/api/v1/chat/conversations/{conv['id']}/members/notexist/"
        )
        assert resp.status_code == 404

    def test_typing_endpoint(self, auth_client, user_factory):
        b = user_factory(username="gm4_b")
        ca, _ = auth_client(username="gm4_a")
        conv = make_private(ca, auth_as(b))
        resp = ca.post(
            f"/api/v1/chat/conversations/{conv['id']}/typing/",
            {"is_typing": True},
            format="json",
        )
        assert resp.status_code == 200

    def test_typing_outsider_403(self, auth_client, user_factory):
        b = user_factory(username="gm5_b")
        outsider = user_factory(username="gm5_out")
        ca, _ = auth_client(username="gm5_a")
        conv = make_private(ca, auth_as(b))
        co = auth_as(outsider)
        assert (
            co.post(
                f"/api/v1/chat/conversations/{conv['id']}/typing/",
                {"is_typing": True},
                format="json",
            ).status_code
            == 403
        )
@pytest.mark.django_db
class TestRemovedMemberAccess:
    """被移除成员在移除后访问群内容必须被拒绝（问题 16 验收）。"""

    def _make_group_with_member(self, auth_client, user_factory):
        """建群：owner(a) + member(b)。返回 (ca, cb, conv)。"""
        b = user_factory(username="rm_b")
        ca, _ = auth_client(username="rm_a")
        conv = make_group(ca, [b])
        cb = auth_as(b)
        return ca, cb, conv

    def test_removed_member_cannot_get_conversation(self, auth_client, user_factory):
        ca, cb, conv = self._make_group_with_member(auth_client, user_factory)
        # 移除前成员可访问
        assert cb.get(f"/api/v1/chat/conversations/{conv['id']}/").status_code == 200
        # owner 移除成员
        assert (
            ca.delete(
                f"/api/v1/chat/conversations/{conv['id']}/members/{cb.user.id}/"
            ).status_code
            == 204
        )
        # 被移除后：群详情 403
        assert (
            cb.get(f"/api/v1/chat/conversations/{conv['id']}/").status_code == 403
        )

    def test_removed_member_cannot_list_messages(self, auth_client, user_factory):
        ca, cb, conv = self._make_group_with_member(auth_client, user_factory)
        # 移除前成员可读消息
        assert (
            cb.get(f"/api/v1/chat/conversations/{conv['id']}/messages/").status_code
            == 200
        )
        assert (
            ca.delete(
                f"/api/v1/chat/conversations/{conv['id']}/members/{cb.user.id}/"
            ).status_code
            == 204
        )
        # 被移除后：读消息 403
        assert (
            cb.get(f"/api/v1/chat/conversations/{conv['id']}/messages/").status_code
            == 403
        )

    def test_removed_member_cannot_send_message(self, auth_client, user_factory):
        ca, cb, conv = self._make_group_with_member(auth_client, user_factory)
        assert (
            ca.delete(
                f"/api/v1/chat/conversations/{conv['id']}/members/{cb.user.id}/"
            ).status_code
            == 204
        )
        resp = cb.post(
            f"/api/v1/chat/conversations/{conv['id']}/messages/",
            {"content": "我还在这里"},
            format="json",
        )
        assert resp.status_code == 403

    def test_removed_member_not_in_conversation_list(self, auth_client, user_factory):
        """被移除后，会话列表不再包含该群。"""
        ca, cb, conv = self._make_group_with_member(auth_client, user_factory)
        assert (
            ca.delete(
                f"/api/v1/chat/conversations/{conv['id']}/members/{cb.user.id}/"
            ).status_code
            == 204
        )
        items = cb.get("/api/v1/chat/conversations/").json()
        assert all(str(item["id"]) != str(conv["id"]) for item in items)

    def test_removed_member_cannot_read_or_typing(self, auth_client, user_factory):
        """被移除后：标已读 / typing 均 403。"""
        ca, cb, conv = self._make_group_with_member(auth_client, user_factory)
        assert (
            ca.delete(
                f"/api/v1/chat/conversations/{conv['id']}/members/{cb.user.id}/"
            ).status_code
            == 204
        )
        assert (
            cb.post(f"/api/v1/chat/conversations/{conv['id']}/read/").status_code == 403
        )
        assert (
            cb.post(
                f"/api/v1/chat/conversations/{conv['id']}/typing/",
                {"is_typing": True},
                format="json",
            ).status_code
            == 403
        )

    def test_removed_member_cannot_manage_group(self, auth_client, user_factory):
        """被移除后不能加人/踢人等管理操作（403 而非 404，不泄露群存在）。"""
        ca, cb, conv = self._make_group_with_member(auth_client, user_factory)
        outsider = user_factory(username="rm_out")
        assert (
            ca.delete(
                f"/api/v1/chat/conversations/{conv['id']}/members/{cb.user.id}/"
            ).status_code
            == 204
        )
        assert (
            cb.post(
                f"/api/v1/chat/conversations/{conv['id']}/members/",
                {"user_ids": [str(outsider.id)]},
                format="json",
            ).status_code
            == 403
        )

