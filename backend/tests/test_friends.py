"""好友生命周期契约测试：申请 -> 同意 -> 列表 -> 删除；403 越权。"""
import pytest

from apps.accounts.models import FriendRequest, Friendship


@pytest.mark.django_db
class TestFriendRequest:
    def test_send_request_and_list(self, auth_client, user_factory):
        target = user_factory(username="fri_target")
        client, me = auth_client(username="fri_me")

        resp = client.post(
            "/api/v1/friends/requests/",
            {"to_user_id": str(target.id), "message": "加个好友"},
            format="json",
        )
        assert resp.status_code == 201
        assert resp.json()["status"] == "pending"

        # 目标收到待处理列表
        target_client = _auth_as(target)
        resp = target_client.get("/api/v1/friends/requests/")
        assert resp.status_code == 200
        items = resp.json()
        assert len(items) == 1
        assert items[0]["from_user"]["username"] == "fri_me"

    def test_send_request_to_self_rejected(self, auth_client):
        client, me = auth_client(username="fri_self")
        resp = client.post(
            "/api/v1/friends/requests/",
            {"to_user_id": str(me.id)},
            format="json",
        )
        assert resp.status_code == 400

    def test_send_request_to_unknown_user(self, auth_client):
        client, _ = auth_client(username="fri_unknown")
        resp = client.post(
            "/api/v1/friends/requests/",
            {"to_user_id": "no-such-user"},
            format="json",
        )
        assert resp.status_code == 400


@pytest.mark.django_db
class TestFriendAccept:
    def test_accept_creates_bidirectional_friendship(self, auth_client, user_factory):
        target = user_factory(username="ac_target")
        me_client, me = auth_client(username="ac_me")
        me_client.post(
            "/api/v1/friends/requests/",
            {"to_user_id": str(target.id)},
            format="json",
        )

        req = FriendRequest.objects.get(from_user=me, to_user=target)
        target_client = _auth_as(target)
        resp = target_client.post(
            f"/api/v1/friends/requests/{req.id}/action/",
            {"action": "accept"},
            format="json",
        )
        assert resp.status_code == 200

        assert Friendship.objects.filter(
            user=me, friend=target, status="accepted"
        ).exists()
        assert Friendship.objects.filter(
            user=target, friend=me, status="accepted"
        ).exists()

        # 双方好友列表均可见
        me_resp = me_client.get("/api/v1/friends/")
        target_resp = target_client.get("/api/v1/friends/")
        assert len(me_resp.json()) == 1
        assert len(target_resp.json()) == 1

    def test_reject_no_friendship(self, auth_client, user_factory):
        target = user_factory(username="rj_target")
        me_client, me = auth_client(username="rj_me")
        me_client.post(
            "/api/v1/friends/requests/",
            {"to_user_id": str(target.id)},
            format="json",
        )
        req = FriendRequest.objects.get(from_user=me, to_user=target)
        target_client = _auth_as(target)
        resp = target_client.post(
            f"/api/v1/friends/requests/{req.id}/action/",
            {"action": "reject"},
            format="json",
        )
        assert resp.status_code == 200
        assert not Friendship.objects.filter(user=me, friend=target).exists()

    def test_non_receiver_cannot_handle_request(self, auth_client, user_factory):
        target = user_factory(username="att_target")
        other = user_factory(username="att_other")
        me_client, me = auth_client(username="att_me")
        me_client.post(
            "/api/v1/friends/requests/",
            {"to_user_id": str(target.id)},
            format="json",
        )
        req = FriendRequest.objects.get(from_user=me, to_user=target)
        other_client = _auth_as(other)
        resp = other_client.post(
            f"/api/v1/friends/requests/{req.id}/action/",
            {"action": "accept"},
            format="json",
        )
        assert resp.status_code == 404  # 越权不可见


@pytest.mark.django_db
class TestFriendDelete:
    def test_delete_removes_both_directions(self, auth_client, user_factory):
        target = user_factory(username="del_target")
        me_client, me = auth_client(username="del_me")
        me_client.post(
            "/api/v1/friends/requests/",
            {"to_user_id": str(target.id)},
            format="json",
        )
        req = FriendRequest.objects.get(from_user=me, to_user=target)
        target_client = _auth_as(target)
        target_client.post(
            f"/api/v1/friends/requests/{req.id}/action/",
            {"action": "accept"},
            format="json",
        )

        resp = me_client.delete(f"/api/v1/friends/{target.id}/")
        assert resp.status_code == 204
        assert not Friendship.objects.filter(user=me, friend=target).exists()
        assert not Friendship.objects.filter(user=target, friend=me).exists()

    def test_delete_non_friend_404(self, auth_client, user_factory):
        other = user_factory(username="nf_other")
        client, _ = auth_client(username="nf_me")
        assert client.delete(f"/api/v1/friends/{other.id}/").status_code == 404


def _auth_as(user):
    from rest_framework.test import APIClient
    from rest_framework_simplejwt.tokens import RefreshToken

    client = APIClient()
    token = RefreshToken.for_user(user)
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {token.access_token}")
    client.user = user
    return client
