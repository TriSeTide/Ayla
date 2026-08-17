"""chat 会话 REST 契约测试：私聊幂等创建、会话列表、建群、越权。

全部不依赖 Redis/MySQL。
"""
import pytest

from apps.chat.models import Conversation, ConversationMember
from apps.chat.tests.helpers import auth_as, make_group, make_private


@pytest.mark.django_db
class TestPrivateConversation:
    def test_private_create_idempotent_two_requests(self, auth_client, user_factory):
        b = user_factory(username="pv_b")
        ca, a = auth_client(username="pv_a")
        # 先建 a-b
        resp1 = ca.post(
            "/api/v1/chat/conversations/private/",
            {"user_id": str(b.id)},
            format="json",
        )
        assert resp1.status_code == 200
        conv1 = resp1.json()
        assert conv1["type"] == "private"
        # 同两人再请求 → 同一会话
        resp2 = ca.post(
            "/api/v1/chat/conversations/private/",
            {"user_id": str(b.id)},
            format="json",
        )
        assert resp2.status_code == 200
        assert resp2.json()["id"] == conv1["id"]
        # members 两条
        assert Conversation.objects.get(pk=conv1["id"]).members.count() == 2

    def test_private_from_other_side_returns_same(self, auth_client, user_factory):
        b = user_factory(username="pv2_b")
        ca, a = auth_client(username="pv2_a")
        make_private(ca, auth_as(b))
        # b 侧请求同一会话
        cb = auth_as(b)
        resp = cb.post(
            "/api/v1/chat/conversations/private/",
            {"user_id": str(a.id)},
            format="json",
        )
        assert resp.status_code == 200
        assert resp.json()["type"] == "private"
        assert Conversation.objects.filter(type="private").count() == 1

    def test_private_unknown_user_404(self, auth_client):
        ca, _ = auth_client(username="pv3_a")
        resp = ca.post(
            "/api/v1/chat/conversations/private/",
            {"user_id": "no-such"},
            format="json",
        )
        assert resp.status_code == 404

    def test_private_self_forbidden(self, auth_client):
        ca, a = auth_client(username="pv4_a")
        resp = ca.post(
            "/api/v1/chat/conversations/private/",
            {"user_id": str(a.id)},
            format="json",
        )
        assert resp.status_code == 400


@pytest.mark.django_db
class TestConversationList:
    def test_list_shows_my_conversations(self, auth_client, user_factory):
        b = user_factory(username="cl_b", nickname="贝贝")
        ca, a = auth_client(username="cl_a")
        make_private(ca, auth_as(b))
        resp = ca.get("/api/v1/chat/conversations/")
        assert resp.status_code == 200
        items = resp.json()
        assert len(items) == 1
        conv = items[0]
        assert conv["type"] == "private"
        assert conv["my_role"] == "owner"
        # 私聊展示对方昵称作为 title
        assert conv["title"] == "贝贝"

    def test_list_excludes_others(self, auth_client, user_factory):
        b = user_factory(username="cl2_b")
        c = user_factory(username="cl2_c")
        ca, _ = auth_client(username="cl2_a")
        make_private(ca, auth_as(b))
        cc = auth_as(c)
        resp = cc.get("/api/v1/chat/conversations/")
        assert resp.json() == []


@pytest.mark.django_db
class TestGroup:
    def test_create_group_with_members(self, auth_client, user_factory):
        b = user_factory(username="gr_b")
        c = user_factory(username="gr_c")
        ca, a = auth_client(username="gr_a")
        conv = make_group(ca, [b, c], title="铁三角")
        assert conv["type"] == "group"
        assert conv["title"] == "铁三角"
        assert conv["my_role"] == "owner"
        assert conv["member_count"] == 3

    def test_create_group_requires_title(self, auth_client):
        ca, _ = auth_client(username="gr2_a")
        resp = ca.post(
            "/api/v1/chat/conversations/group/", {"title": ""}, format="json"
        )
        assert resp.status_code == 400

    def test_owner_cannot_kick_self(self, auth_client, user_factory):
        b = user_factory(username="gr3_b")
        ca, a = auth_client(username="gr3_a")
        conv = make_group(ca, [b])
        resp = ca.delete(
            f"/api/v1/chat/conversations/{conv['id']}/members/{a.id}/"
        )
        assert resp.status_code == 403

    def test_group_detail_and_members(self, auth_client, user_factory):
        b = user_factory(username="gr4_b")
        ca, _ = auth_client(username="gr4_a")
        conv = make_group(ca, [b])
        resp = ca.get(f"/api/v1/chat/conversations/{conv['id']}/")
        assert resp.status_code == 200
        body = resp.json()
        assert len(body["members"]) == 2
        roles = {m["id"]: m["role"] for m in body["members"]}
        assert list(roles.values()).count("owner") == 1
        assert list(roles.values()).count("member") == 1
        # 群头像字段：默认空串，序列化始终携带
        assert "avatar" in body
        assert body["avatar"] == ""


@pytest.mark.django_db
class TestGroupAvatar:
    """群头像 PATCH 契约：owner/admin 可改（content URL），成员 403，非法地址 400。"""

    def _avatar_url(self, media_id: str) -> str:
        return f"/api/v1/media/{media_id}/content"

    def test_owner_patch_group_avatar(self, auth_client, user_factory):
        b = user_factory(username="gav_b")
        ca, _ = auth_client(username="gav_owner")
        conv = make_group(ca, [b])
        from apps.media.tests.conftest import upload_image

        media_id, _ = upload_image(ca)
        url = self._avatar_url(media_id)
        resp = ca.patch(
            f"/api/v1/chat/conversations/{conv['id']}/",
            {"avatar": url},
            format="json",
        )
        assert resp.status_code == 200
        assert resp.json()["avatar"] == url
        # 会话列表/详情都带新头像
        assert ca.get(f"/api/v1/chat/conversations/{conv['id']}/").json()["avatar"] == url
        assert any(c["id"] == conv["id"] and c["avatar"] == url
                   for c in ca.get("/api/v1/chat/conversations/").json())

    def test_admin_can_patch_group_avatar(self, auth_client, user_factory):
        b = user_factory(username="gav2_admin")
        ca, _ = auth_client(username="gav2_owner")
        conv = make_group(ca, [b])
        from apps.chat.models import ConversationMember

        ConversationMember.objects.filter(conversation_id=conv["id"], user=b).update(role="admin")
        from apps.media.tests.conftest import upload_image

        media_id, _ = upload_image(auth_as(b))
        resp = auth_as(b).patch(
            f"/api/v1/chat/conversations/{conv['id']}/",
            {"avatar": self._avatar_url(media_id)},
            format="json",
        )
        assert resp.status_code == 200

    def test_member_cannot_patch_group_avatar(self, auth_client, user_factory):
        b = user_factory(username="gav3_b")
        ca, _ = auth_client(username="gav3_owner")
        conv = make_group(ca, [b])
        resp = auth_as(b).patch(
            f"/api/v1/chat/conversations/{conv['id']}/",
            {"avatar": "/api/v1/media/whatever/content"},
            format="json",
        )
        assert resp.status_code == 403

    def test_owner_patch_invalid_avatar_url_400(self, auth_client, user_factory):
        b = user_factory(username="gav4_b")
        ca, _ = auth_client(username="gav4_owner")
        conv = make_group(ca, [b])
        # 外部 URL 拒绝
        resp = ca.patch(
            f"/api/v1/chat/conversations/{conv['id']}/",
            {"avatar": "https://evil.example/a.png"},
            format="json",
        )
        assert resp.status_code == 400
        # 不存在的 media id 拒绝
        resp = ca.patch(
            f"/api/v1/chat/conversations/{conv['id']}/",
            {"avatar": self._avatar_url("no-such-media")},
            format="json",
        )
        assert resp.status_code == 400

    def test_owner_clear_group_avatar(self, auth_client, user_factory):
        b = user_factory(username="gav5_b")
        ca, _ = auth_client(username="gav5_owner")
        conv = make_group(ca, [b])
        from apps.media.tests.conftest import upload_image

        media_id, _ = upload_image(ca)
        url = self._avatar_url(media_id)
        assert ca.patch(
            f"/api/v1/chat/conversations/{conv['id']}/", {"avatar": url}, format="json"
        ).status_code == 200
        # 空串清除头像
        resp = ca.patch(
            f"/api/v1/chat/conversations/{conv['id']}/", {"avatar": ""}, format="json"
        )
        assert resp.status_code == 200
        assert resp.json()["avatar"] == ""


@pytest.mark.django_db
class TestPermission403:
    def test_outsider_cannot_read_detail(self, auth_client, user_factory):
        b = user_factory(username="p1_b")
        outsider = user_factory(username="p1_out")
        ca, _ = auth_client(username="p1_a")
        conv = make_private(ca, auth_as(b))
        co = auth_as(outsider)
        assert (
            co.get(f"/api/v1/chat/conversations/{conv['id']}/").status_code == 403
        )

    def test_outsider_cannot_list_messages(self, auth_client, user_factory):
        b = user_factory(username="p2_b")
        outsider = user_factory(username="p2_out")
        ca, _ = auth_client(username="p2_a")
        conv = make_private(ca, auth_as(b))
        co = auth_as(outsider)
        assert (
            co.get(
                f"/api/v1/chat/conversations/{conv['id']}/messages/"
            ).status_code
            == 403
        )

    def test_outsider_cannot_send_message(self, auth_client, user_factory):
        b = user_factory(username="p3_b")
        outsider = user_factory(username="p3_out")
        ca, _ = auth_client(username="p3_a")
        conv = make_private(ca, auth_as(b))
        co = auth_as(outsider)
        assert (
            co.post(
                f"/api/v1/chat/conversations/{conv['id']}/messages/",
                {"content": "hack"},
                format="json",
            ).status_code
            == 403
        )

    def test_unknown_conversation_404(self, auth_client):
        ca, _ = auth_client(username="p4_a")
        assert ca.get("/api/v1/chat/conversations/99999/").status_code == 404
        assert (
            ca.get("/api/v1/chat/conversations/99999/messages/").status_code == 404
        )

    def test_non_admin_cannot_manage_group(self, auth_client, user_factory):
        owner = auth_client(username="p5_owner")
        admin = user_factory(username="p5_admin")
        member = user_factory(username="p5_member")
        ca, _ = owner
        conv = make_group(ca, [admin, member])
        cm = auth_as(member)
        # 普通成员不能加人
        resp = cm.post(
            f"/api/v1/chat/conversations/{conv['id']}/members/",
            {"user_ids": [admin.id]},
            format="json",
        )
        assert resp.status_code == 403
        # 普通成员不能踢人
        assert (
            cm.delete(
                f"/api/v1/chat/conversations/{conv['id']}/members/{admin.id}/"
            ).status_code
            == 403
        )
        # 普通成员不能禁言
        assert (
            cm.post(
                f"/api/v1/chat/conversations/{conv['id']}/members/{admin.id}/mute/",
                {"muted": True},
                format="json",
            ).status_code
            == 403
        )
        # 普通成员不能改公告
        assert (
            cm.patch(
                f"/api/v1/chat/conversations/{conv['id']}/",
                {"announcement": "x"},
                format="json",
            ).status_code
            == 403
        )
