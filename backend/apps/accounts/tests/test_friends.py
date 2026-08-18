"""accounts REST 契约测试：好友列表、解除好友、全链路验证。"""
import pytest

from apps.chat.tests.helpers import auth_as


@pytest.mark.django_db
class TestFriends:

    def test_friend_list_shows_friend_not_self(self, auth_client, user_factory):
        """好友列表返回的 user 应该是好友信息，不是当前用户自己。
        这是 FriendshipSerializer.user → source="friend" 的回归测试。"""
        b = user_factory(username="fr_b", nickname="贝贝")
        ca, a = auth_client(username="fr_a")
        # a 加 b 为好友（发申请 → 同意）
        resp = ca.post(
            "/api/v1/friends/requests/",
            {"to_user_id": str(b.id), "message": "你好"},
            format="json",
        )
        assert resp.status_code == 201
        req_id = resp.json()["id"]
        # b 同意
        cb = auth_as(b)
        resp = cb.post(
            f"/api/v1/friends/requests/{req_id}/action/",
            {"action": "accept"},
            format="json",
        )
        assert resp.status_code == 200
        # a 查看好友列表
        resp = ca.get("/api/v1/friends/")
        assert resp.status_code == 200
        items = resp.json()
        assert len(items) == 1
        friend = items[0]
        # user 字段应该是好友 b 的信息，不是 a 自己
        assert friend["user"]["id"] == b.id
        assert friend["user"]["nickname"] == "贝贝"

    def test_delete_friend_bidirectional(self, auth_client, user_factory):
        """解除好友后双向 Friendship 记录都被删除，列表不再包含。"""
        b = user_factory(username="fd_b", nickname="贝贝")
        ca, a = auth_client(username="fd_a")
        # a 加 b → b 同意
        resp = ca.post(
            "/api/v1/friends/requests/",
            {"to_user_id": str(b.id)},
            format="json",
        )
        assert resp.status_code == 201
        cb = auth_as(b)
        resp = cb.post(
            f"/api/v1/friends/requests/{resp.json()['id']}/action/",
            {"action": "accept"},
            format="json",
        )
        assert resp.status_code == 200
        # 确认好友列表 1 条
        assert len(ca.get("/api/v1/friends/").json()) == 1
        # a 解除好友
        resp = ca.delete(f"/api/v1/friends/{b.id}/")
        assert resp.status_code == 204
        # a 好友列表为空
        assert len(ca.get("/api/v1/friends/").json()) == 0
        # b 的好友列表也为空（双向删除）
        assert len(cb.get("/api/v1/friends/").json()) == 0

    def test_delete_friend_wrong_user_404(self, auth_client, user_factory):
        """删除非好友返回 404 "不是好友"。"""
        b = user_factory(username="fd2_b")
        ca, _ = auth_client(username="fd2_a")
        resp = ca.delete(f"/api/v1/friends/{b.id}/")
        assert resp.status_code == 404
        assert resp.json()["detail"] == "不是好友"

    def test_delete_friend_then_readd(self, auth_client, user_factory):
        """解除好友后可以重新加好友。"""
        b = user_factory(username="fd3_b")
        ca, a = auth_client(username="fd3_a")
        # 加 → 同意
        resp = ca.post(
            "/api/v1/friends/requests/",
            {"to_user_id": str(b.id)},
            format="json",
        )
        assert resp.status_code == 201
        cb = auth_as(b)
        resp = cb.post(
            f"/api/v1/friends/requests/{resp.json()['id']}/action/",
            {"action": "accept"},
            format="json",
        )
        assert resp.status_code == 200
        # 解除
        assert ca.delete(f"/api/v1/friends/{b.id}/").status_code == 204
        # 重新加
        resp = ca.post(
            "/api/v1/friends/requests/",
            {"to_user_id": str(b.id)},
            format="json",
        )
        assert resp.status_code == 201
        cb = auth_as(b)
        resp = cb.post(
            f"/api/v1/friends/requests/{resp.json()['id']}/action/",
            {"action": "accept"},
            format="json",
        )
        assert resp.status_code == 200
        # 好友列表恢复
        assert len(ca.get("/api/v1/friends/").json()) == 1

    def test_self_not_in_friend_list(self, auth_client, user_factory):
        """自己的信息不出现在好友列表（regression: user 曾经是 Friendship.user=自己）。"""
        b = user_factory(username="fr4_b")
        ca, a = auth_client(username="fr4_a")
        # 加 b → 同意
        resp = ca.post(
            "/api/v1/friends/requests/",
            {"to_user_id": str(b.id)},
            format="json",
        )
        assert resp.status_code == 201
        cb = auth_as(b)
        resp = cb.post(
            f"/api/v1/friends/requests/{resp.json()['id']}/action/",
            {"action": "accept"},
            format="json",
        )
        assert resp.status_code == 200
        # a 的好友列表里没有 a 自己
        items = ca.get("/api/v1/friends/").json()
        for item in items:
            assert item["user"]["id"] != a.id
