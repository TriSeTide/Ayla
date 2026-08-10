"""accounts 契约测试：注册/登录/资料/搜索/好友/403 越权。"""
import pytest

from django.contrib.auth import get_user_model

User = get_user_model()


@pytest.mark.django_db
class TestRegister:
    def test_register_returns_tokens(self, api_client):
        resp = api_client.post(
            "/api/v1/auth/register/",
            {
                "username": "alice",
                "email": "alice@test.local",
                "password": "pass-word-123",
                "nickname": "爱丽丝",
            },
            format="json",
        )
        assert resp.status_code == 201
        body = resp.json()
        assert body["user"]["username"] == "alice"
        assert body["user"]["nickname"] == "爱丽丝"
        assert "access" in body and "refresh" in body
        assert "password" not in body["user"]

    def test_register_duplicate_username(self, api_client, user_factory):
        user_factory(username="bob", email="bob@test.local")
        resp = api_client.post(
            "/api/v1/auth/register/",
            {"username": "bob", "email": "new@test.local", "password": "pass-word-123"},
            format="json",
        )
        assert resp.status_code == 400

    def test_register_weak_password(self, api_client):
        resp = api_client.post(
            "/api/v1/auth/register/",
            {"username": "carol", "email": "c@test.local", "password": "123"},
            format="json",
        )
        assert resp.status_code == 400


@pytest.mark.django_db
class TestLogin:
    def test_login_ok(self, api_client, user_factory):
        user_factory(username="dave", password="pass-word-123")
        resp = api_client.post(
            "/api/v1/auth/login/",
            {"username": "dave", "password": "pass-word-123"},
            format="json",
        )
        assert resp.status_code == 200
        assert "access" in resp.json()

    def test_login_wrong_password(self, api_client, user_factory):
        user_factory(username="dave2", password="pass-word-123")
        resp = api_client.post(
            "/api/v1/auth/login/",
            {"username": "dave2", "password": "wrong"},
            format="json",
        )
        assert resp.status_code == 401


@pytest.mark.django_db
class TestAuthRequired:
    def test_me_requires_auth(self, api_client):
        assert api_client.get("/api/v1/me/").status_code == 401

    def test_friends_requires_auth(self, api_client):
        assert api_client.get("/api/v1/friends/").status_code == 401

    def test_me_ok_with_auth(self, auth_client):
        client, user = auth_client(username="erin")
        resp = client.get("/api/v1/me/")
        assert resp.status_code == 200
        assert resp.json()["id"] == str(user.id)


@pytest.mark.django_db
class TestProfile:
    def test_update_profile(self, auth_client):
        client, user = auth_client(username="frank")
        resp = client.patch(
            "/api/v1/me/profile/",
            {"nickname": "新昵称", "signature": "hello", "status": "away"},
            format="json",
        )
        assert resp.status_code == 200
        user.refresh_from_db()
        assert user.nickname == "新昵称"
        assert user.signature == "hello"
        assert user.status == "away"

    def test_update_profile_rejects_invalid_status(self, auth_client):
        client, _ = auth_client(username="grace")
        resp = client.patch(
            "/api/v1/me/profile/", {"status": "fly"}, format="json"
        )
        assert resp.status_code == 400


@pytest.mark.django_db
class TestUserSearch:
    def test_search_by_username(self, api_client, auth_client, user_factory):
        user_factory(username="target_user", nickname="目标")
        client, _ = auth_client(username="searcher")
        resp = client.get("/api/v1/users/search/", {"q": "target"})
        assert resp.status_code == 200
        names = [u["username"] for u in resp.json()]
        assert "target_user" in names
        assert "searcher" not in names

    def test_search_excludes_self(self, auth_client):
        client, user = auth_client(username="self_user")
        resp = client.get("/api/v1/users/search/", {"q": "self"})
        assert resp.json() == []
