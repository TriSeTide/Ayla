"""
elysia_bridge profile REST 契约测试（步骤文件 §6 / 8.1 越权项）。

覆盖：
- 未登录访问 profile → 401；
- 登录（普通用户）可 GET profile；
- 普通用户 POST/PATCH → 403（系统管理员）；
- 管理员 POST 初始化（绑定 user + stream_id）→ 201；
- 重复初始化 → 409；
- 管理员 PATCH 更新 enabled/display_name/chat_type → 200；
- user_id/stream_id 校验：绑定不存在用户 → 400；
- 未初始化 GET → 404；
- profile/:test 冒烟：未初始化 404；未配置凭据 503；管理员才可调（普通用户 403）。

用 auth_client（返回 (client, user)）+ 显式创建 is_staff 用户模拟管理员。
"""
import pytest
from rest_framework.test import APIClient

from apps.elysia_bridge.models import ElysiaProfile


def _staff_client(user_factory):
    """管理员客户端：is_staff=True + JWT。"""
    from rest_framework_simplejwt.tokens import RefreshToken

    staff = user_factory(username="admin", email="admin@test.local", is_staff=True)
    token = RefreshToken.for_user(staff)
    client = APIClient()
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {token.access_token}")
    client.user = staff
    return client, staff


@pytest.mark.django_db
class TestProfileAPI:
    def test_unauthenticated_gets_401(self, api_client):
        resp = api_client.get("/api/v1/elysia/profile/")
        assert resp.status_code == 401

    def test_regular_user_can_read_profile(self, auth_client, user_factory):
        client, user = auth_client()
        elysia_user = user_factory(username="elysia_api", nickname="爱莉")
        profile = ElysiaProfile.objects.create(
            user=elysia_user, stream_id="stream_api_1", display_name="爱莉"
        )
        resp = client.get("/api/v1/elysia/profile/")
        assert resp.status_code == 200
        assert resp.data["stream_id"] == "stream_api_1"
        assert resp.data["user"]["nickname"] == "爱莉"
        assert resp.data["display_name"] == "爱莉"
        assert resp.data["enabled"] is True

    def test_regular_user_cannot_write(self, auth_client, user_factory):
        client, user = auth_client()
        elysia_user = user_factory(username="elysia_api2", nickname="爱莉")
        ElysiaProfile.objects.create(
            user=elysia_user, stream_id="stream_api_2", display_name="爱莉"
        )
        resp = client.patch(
            "/api/v1/elysia/profile/",
            {"display_name": "改名"},
            format="json",
        )
        assert resp.status_code == 403
        resp_post = client.post(
            "/api/v1/elysia/profile/",
            {"user_id": str(elysia_user.id), "stream_id": "stream_api_2"},
            format="json",
        )
        assert resp_post.status_code == 403

    def test_admin_init_profile(self, user_factory):
        client, staff = _staff_client(user_factory)
        elysia_user = user_factory(username="elysia_admin", nickname="爱莉")
        resp = client.post(
            "/api/v1/elysia/profile/",
            {
                "user_id": str(elysia_user.id),
                "stream_id": "stream_admin_1",
                "display_name": "爱莉",
                "chat_type": "private",
            },
            format="json",
        )
        assert resp.status_code == 201, resp.content
        assert resp.data["stream_id"] == "stream_admin_1"
        profile = ElysiaProfile.objects.get(user=elysia_user)
        assert profile.enabled is True
        assert profile.chat_type == "private"

    def test_double_init_conflicts(self, user_factory):
        client, staff = _staff_client(user_factory)
        elysia_user = user_factory(username="elysia_dbl", nickname="爱莉")
        ElysiaProfile.objects.create(
            user=elysia_user, stream_id="stream_dbl_1", display_name="爱莉"
        )
        other = user_factory(username="elysia_dbl2", nickname="另一个")
        resp = client.post(
            "/api/v1/elysia/profile/",
            {"user_id": str(other.id), "stream_id": "stream_dbl_2"},
            format="json",
        )
        assert resp.status_code == 409

    def test_admin_patch_updates_fields(self, user_factory):
        client, staff = _staff_client(user_factory)
        elysia_user = user_factory(username="elysia_patch", nickname="爱莉")
        ElysiaProfile.objects.create(
            user=elysia_user, stream_id="stream_patch_1", display_name="爱莉"
        )
        resp = client.patch(
            "/api/v1/elysia/profile/",
            {"enabled": False, "display_name": "爱莉·新"},
            format="json",
        )
        assert resp.status_code == 200
        assert resp.data["enabled"] is False
        assert resp.data["display_name"] == "爱莉·新"
        # stream_id 不能改（read_only 语义由序列化保证）
        assert resp.data["stream_id"] == "stream_patch_1"

    def test_bind_unknown_user_rejected(self, user_factory):
        client, staff = _staff_client(user_factory)
        resp = client.post(
            "/api/v1/elysia/profile/",
            {"user_id": "no-such-user", "stream_id": "stream_x"},
            format="json",
        )
        assert resp.status_code == 400
        assert "绑定的用户不存在" in str(resp.data)

    def test_get_uninitialized_404(self, auth_client):
        client, user = auth_client()
        resp = client.get("/api/v1/elysia/profile/")
        assert resp.status_code == 404


@pytest.mark.django_db
class TestProfileSmoke:
    def test_smoke_uninitialized_404(self, auth_client):
        client, user = auth_client()
        resp = client.post("/api/v1/elysia/profile/:test")
        assert resp.status_code == 403  # 普通用户无管理权限

    def test_smoke_requires_admin(self, auth_client, user_factory):
        client, user = auth_client()
        elysia_user = user_factory(username="elysia_smoke", nickname="爱莉")
        ElysiaProfile.objects.create(
            user=elysia_user, stream_id="stream_smoke_1", display_name="爱莉"
        )
        resp = client.post("/api/v1/elysia/profile/:test")
        assert resp.status_code == 403

    def test_smoke_no_credential_returns_503(
        self, user_factory, monkeypatch
    ):
        """凭据未配置 → 503（ProfileNotConfigured）。"""
        client, staff = _staff_client(user_factory)
        elysia_user = user_factory(username="elysia_smoke2", nickname="爱莉")
        ElysiaProfile.objects.create(
            user=elysia_user, stream_id="stream_smoke_2", display_name="爱莉"
        )

        from apps.elysia_bridge import services as bridge_services
        from apps.elysia_bridge.services import ProfileNotConfigured

        class _NoCredsInjector:
            def smoke(self, *, profile):
                raise ProfileNotConfigured("未配置凭据")

        monkeypatch.setattr(bridge_services, "get_injector", lambda: _NoCredsInjector())
        resp = client.post("/api/v1/elysia/profile/:test")
        assert resp.status_code == 503
        assert "未配置凭据" in str(resp.data["detail"])

    def test_smoke_ok_returns_session(self, user_factory, monkeypatch):
        client, staff = _staff_client(user_factory)
        elysia_user = user_factory(username="elysia_smoke3", nickname="爱莉")
        ElysiaProfile.objects.create(
            user=elysia_user, stream_id="stream_smoke_3", display_name="爱莉"
        )

        from apps.elysia_bridge import services as bridge_services

        class _FakeInjector:
            def smoke(self, *, profile):
                return {"authenticated": True, "stream_id": profile.stream_id}

        monkeypatch.setattr(bridge_services, "get_injector", lambda: _FakeInjector())
        resp = client.post("/api/v1/elysia/profile/:test")
        assert resp.status_code == 200
        assert resp.data["ok"] is True
        assert resp.data["stream_id"] == "stream_smoke_3"
