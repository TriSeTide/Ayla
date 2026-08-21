"""会话管理契约测试：置顶、隐藏（软删除）、last_message 预览。

对应需求：Ayla 子模块 /messages 私信列表管理（删除[仅隐藏]、置顶）+ 列表最新一条消息预览。
- 置顶是成员各自视图（is_pinned），彼此独立；
- 隐藏是软删除（不删消息，仅本人列表不显示）；对方再发消息自动取消隐藏重新出现；
- last_message 返回最新一条消息摘要，无消息为 null。
全部不依赖 Redis/MySQL。
"""
import pytest

from apps.chat.tests.helpers import auth_as, make_private, new_key


@pytest.mark.django_db
class TestPin:
    def test_pin_default_false_in_list(self, auth_client, user_factory):
        b = user_factory(username="pin_b")
        ca, _ = auth_client(username="pin_a")
        make_private(ca, auth_as(b))
        conv = ca.get("/api/v1/chat/conversations/").json()[0]
        assert conv["is_pinned"] is False

    def test_pin_toggle_lifecycle(self, auth_client, user_factory):
        b = user_factory(username="pin2_b")
        ca, _ = auth_client(username="pin2_a")
        conv = make_private(ca, auth_as(b))
        cid = conv["id"]
        # 置顶
        resp = ca.post(f"/api/v1/chat/conversations/{cid}/pin/", {"pinned": True}, format="json")
        assert resp.status_code == 200
        assert resp.json()["pinned"] is True
        listed = ca.get("/api/v1/chat/conversations/").json()
        assert next(c for c in listed if c["id"] == cid)["is_pinned"] is True
        # 取消置顶
        assert (
            ca.post(f"/api/v1/chat/conversations/{cid}/pin/", {"pinned": False}, format="json").json()["pinned"]
            is False
        )
        listed = ca.get("/api/v1/chat/conversations/").json()
        assert next(c for c in listed if c["id"] == cid)["is_pinned"] is False

    def test_pin_is_per_user_independent(self, auth_client, user_factory):
        b = user_factory(username="pin3_b")
        ca, _ = auth_client(username="pin3_a")
        make_private(ca, auth_as(b))
        cb = auth_as(b)
        # a 置顶不影响 b
        ca.post(f"/api/v1/chat/conversations/{ca.get('/api/v1/chat/conversations/').json()[0]['id']}/pin/", {"pinned": True}, format="json")
        b_list = [c for c in cb.get("/api/v1/chat/conversations/").json()]
        assert all(c["is_pinned"] is False for c in b_list)

    def test_pin_forbidden_for_outsider(self, auth_client, user_factory):
        b = user_factory(username="pin4_b")
        outsider = user_factory(username="pin4_out")
        ca, _ = auth_client(username="pin4_a")
        conv = make_private(ca, auth_as(b))
        assert (
            auth_as(outsider).post(
                f"/api/v1/chat/conversations/{conv['id']}/pin/", {"pinned": True}, format="json"
            ).status_code
            == 403
        )

    def test_pin_unknown_conversation_404(self, auth_client):
        ca, _ = auth_client(username="pin5_a")
        assert (
            ca.post("/api/v1/chat/conversations/99999/pin/", {"pinned": True}, format="json").status_code
            == 404
        )


@pytest.mark.django_db
class TestHide:
    def test_hide_removes_from_my_list(self, auth_client, user_factory):
        b = user_factory(username="hide_b")
        ca, _ = auth_client(username="hide_a")
        conv = make_private(ca, auth_as(b))
        cid = conv["id"]
        assert any(c["id"] == cid for c in ca.get("/api/v1/chat/conversations/").json())
        resp = ca.post(f"/api/v1/chat/conversations/{cid}/hide/", format="json")
        assert resp.status_code == 200
        assert resp.json()["hidden"] is True
        # 本人列表不再出现
        assert all(c["id"] != cid for c in ca.get("/api/v1/chat/conversations/").json())
        # 会话数据仍在，对方仍能看到
        cb = auth_as(b)
        assert any(c["id"] == cid for c in cb.get("/api/v1/chat/conversations/").json())

    def test_hide_then_peer_message_restores(self, auth_client, user_factory):
        b = user_factory(username="hide2_b")
        ca, _ = auth_client(username="hide2_a")
        conv = make_private(ca, auth_as(b))
        cid = conv["id"]
        # a 隐藏会话
        ca.post(f"/api/v1/chat/conversations/{cid}/hide/", format="json")
        assert all(c["id"] != cid for c in ca.get("/api/v1/chat/conversations/").json())
        # b 发一条消息 → a 的隐藏被自动清除，会话重新出现
        cb = auth_as(b)
        assert (
            cb.post(
                f"/api/v1/chat/conversations/{cid}/messages/",
                {"content": "在吗？", "idempotency_key": new_key()},
                format="json",
            ).status_code
            == 201
        )
        assert any(c["id"] == cid for c in ca.get("/api/v1/chat/conversations/").json())

    def test_hide_forbidden_for_outsider(self, auth_client, user_factory):
        b = user_factory(username="hide3_b")
        outsider = user_factory(username="hide3_out")
        ca, _ = auth_client(username="hide3_a")
        conv = make_private(ca, auth_as(b))
        assert (
            auth_as(outsider).post(
                f"/api/v1/chat/conversations/{conv['id']}/hide/", format="json"
            ).status_code
            == 403
        )

    def test_hide_preserves_messages(self, auth_client, user_factory):
        b = user_factory(username="hide4_b")
        ca, _ = auth_client(username="hide4_a")
        conv = make_private(ca, auth_as(b))
        cid = conv["id"]
        key = new_key()
        m = ca.post(
            f"/api/v1/chat/conversations/{cid}/messages/",
            {"content": "别忘了这条", "idempotency_key": key},
            format="json",
        ).json()
        ca.post(f"/api/v1/chat/conversations/{cid}/hide/", format="json")
        msgs = ca.get(f"/api/v1/chat/conversations/{cid}/messages/").json()
        assert any(x["id"] == m["id"] for x in msgs)


@pytest.mark.django_db
class TestLastMessage:
    def test_no_message_last_message_null(self, auth_client, user_factory):
        b = user_factory(username="lm_b")
        ca, _ = auth_client(username="lm_a")
        make_private(ca, auth_as(b))
        conv = ca.get("/api/v1/chat/conversations/").json()[0]
        assert conv["last_message"] is None

    def test_last_message_shows_latest(self, auth_client, user_factory):
        b = user_factory(username="lm2_b", nickname="贝贝")
        ca, a = auth_client(username="lm2_a")
        conv = make_private(ca, auth_as(b))
        cid = conv["id"]
        ca.post(
            f"/api/v1/chat/conversations/{cid}/messages/",
            {"content": "第一条", "idempotency_key": new_key()},
            format="json",
        )
        ca.post(
            f"/api/v1/chat/conversations/{cid}/messages/",
            {"content": "最新一条", "idempotency_key": new_key()},
            format="json",
        )
        conv = next(
            c for c in ca.get("/api/v1/chat/conversations/").json() if c["id"] == cid
        )
        lm = conv["last_message"]
        assert lm["content"] == "最新一条"
        assert lm["type"] == "text"
        assert lm["sender_id"] == str(a.id)
        assert lm["sender_name"] in ("", a.username) or lm["sender_name"]
        assert lm["seq"] is not None
        assert lm["created_at"] is not None