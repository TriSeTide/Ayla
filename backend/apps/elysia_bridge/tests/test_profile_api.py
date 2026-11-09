"""elysia_bridge profile REST 契约测试（D-2 字段收敛后）。

覆盖：
- 未登录访问 profile → 401；
- 登录（普通用户）可 GET profile；
- 普通用户 POST/PATCH → 403（系统管理员）；
- 管理员 POST 初始化（只绑 user）→ 201；
- 重复初始化 → 409；
- 管理员 PATCH 更新 enabled/display_name → 200；
- user_id 校验：绑定不存在用户 → 400；
- 已删字段（stream_id/platform/chat_type）不再出现在读写契约里；
- 未初始化 GET → 404；
- profile/:test 探测：普通用户 403；无连接 503；禁用 400；
- bridge/health/：登录可读、无连接时 200、不泄露消息正文。

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
        ElysiaProfile.objects.create(user=elysia_user, display_name="爱莉")
        resp = client.get("/api/v1/elysia/profile/")
        assert resp.status_code == 200
        assert resp.data["user"]["nickname"] == "爱莉"
        assert resp.data["display_name"] == "爱莉"
        assert resp.data["enabled"] is True

    def test_removed_fields_not_exposed(self, auth_client, user_factory):
        """D-2 删除的字段不得再出现在响应里（前端会据此判断契约）。"""
        client, user = auth_client()
        elysia_user = user_factory(username="elysia_api_gone", nickname="爱莉")
        ElysiaProfile.objects.create(user=elysia_user, display_name="爱莉")
        resp = client.get("/api/v1/elysia/profile/")
        assert resp.status_code == 200
        for field in ("stream_id", "platform", "chat_type"):
            assert field not in resp.data, f"{field} 应已随 D-2 删除"

    def test_regular_user_cannot_write(self, auth_client, user_factory):
        client, user = auth_client()
        elysia_user = user_factory(username="elysia_api2", nickname="爱莉")
        ElysiaProfile.objects.create(user=elysia_user, display_name="爱莉")
        resp = client.patch(
            "/api/v1/elysia/profile/",
            {"display_name": "改名"},
            format="json",
        )
        assert resp.status_code == 403
        resp_post = client.post(
            "/api/v1/elysia/profile/",
            {"user_id": str(elysia_user.id)},
            format="json",
        )
        assert resp_post.status_code == 403

    def test_admin_init_profile(self, user_factory):
        client, staff = _staff_client(user_factory)
        elysia_user = user_factory(username="elysia_admin", nickname="爱莉")
        resp = client.post(
            "/api/v1/elysia/profile/",
            {"user_id": str(elysia_user.id), "display_name": "爱莉"},
            format="json",
        )
        assert resp.status_code == 201, resp.content
        assert resp.data["display_name"] == "爱莉"
        profile = ElysiaProfile.objects.get(user=elysia_user)
        assert profile.enabled is True
        assert profile.display_name == "爱莉"

    def test_admin_init_ignores_removed_fields(self, user_factory):
        """旧客户端仍传 stream_id/platform/chat_type：序列化器忽略，不 500。"""
        client, staff = _staff_client(user_factory)
        elysia_user = user_factory(username="elysia_legacy_post", nickname="爱莉")
        resp = client.post(
            "/api/v1/elysia/profile/",
            {
                "user_id": str(elysia_user.id),
                "display_name": "爱莉",
                "stream_id": "legacy-stream",
                "platform": "ayla",
                "chat_type": "private",
            },
            format="json",
        )
        assert resp.status_code == 201, resp.content
        assert "stream_id" not in resp.data

    def test_double_init_conflicts(self, user_factory):
        client, staff = _staff_client(user_factory)
        elysia_user = user_factory(username="elysia_dbl", nickname="爱莉")
        ElysiaProfile.objects.create(user=elysia_user, display_name="爱莉")
        other = user_factory(username="elysia_dbl2", nickname="另一个")
        resp = client.post(
            "/api/v1/elysia/profile/",
            {"user_id": str(other.id)},
            format="json",
        )
        assert resp.status_code == 409

    def test_admin_patch_updates_fields(self, user_factory):
        client, staff = _staff_client(user_factory)
        elysia_user = user_factory(username="elysia_patch", nickname="爱莉")
        ElysiaProfile.objects.create(user=elysia_user, display_name="爱莉")
        resp = client.patch(
            "/api/v1/elysia/profile/",
            {"enabled": False, "display_name": "爱莉·新"},
            format="json",
        )
        assert resp.status_code == 200
        assert resp.data["enabled"] is False
        assert resp.data["display_name"] == "爱莉·新"

    def test_bind_unknown_user_rejected(self, user_factory):
        client, staff = _staff_client(user_factory)
        resp = client.post(
            "/api/v1/elysia/profile/",
            {"user_id": "no-such-user"},
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
        ElysiaProfile.objects.create(user=elysia_user, display_name="爱莉")
        resp = client.post("/api/v1/elysia/profile/:test")
        assert resp.status_code == 403

    def test_smoke_probe_reports_disconnected_when_no_consumer(self, user_factory):
        """D-3：探测改为数通道活跃连接。无连接 → 503 + ok=False，不假装连通也不 500。"""
        client, staff = _staff_client(user_factory)
        elysia_user = user_factory(username="elysia_smoke2", nickname="爱莉")
        ElysiaProfile.objects.create(user=elysia_user, display_name="爱莉")

        resp = client.post("/api/v1/elysia/profile/:test")
        assert resp.status_code == 503
        assert resp.data["ok"] is False
        assert resp.data["active_connections"] == 0

    def test_smoke_probe_ok_when_consumer_connected(self, user_factory):
        """有活跃通道连接 → 200 + ok=True（探测的是 consumer 在线，不是凭据）。"""
        from apps.elysia_bridge import services

        client, staff = _staff_client(user_factory)
        elysia_user = user_factory(username="elysia_smoke_ok", nickname="爱莉")
        profile = ElysiaProfile.objects.create(user=elysia_user, display_name="爱莉")

        # 直接往通道 group 里塞一个成员，模拟 DSH 的活跃连接。
        from channels.layers import get_channel_layer

        layer = get_channel_layer()
        from asgiref.sync import async_to_sync

        async_to_sync(layer.group_add)(
            services.outbox_group_name(profile.id), "fake_ayla_conn"
        )
        try:
            resp = client.post("/api/v1/elysia/profile/:test")
            assert resp.status_code == 200, resp.content
            assert resp.data["ok"] is True
            assert resp.data["active_connections"] == 1
        finally:
            async_to_sync(layer.group_discard)(
                services.outbox_group_name(profile.id), "fake_ayla_conn"
            )

    def test_smoke_disabled_profile_returns_400(self, user_factory):
        """profile 禁用 → 400（先启用再探测），不进入探测路径。"""
        client, staff = _staff_client(user_factory)
        elysia_user = user_factory(username="elysia_smoke3", nickname="爱莉")
        ElysiaProfile.objects.create(user=elysia_user, display_name="爱莉", enabled=False)

        resp = client.post("/api/v1/elysia/profile/:test")
        assert resp.status_code == 400

@pytest.mark.django_db
class TestBridgeHealth:
    """GET /bridge/health/ —— 通道健康（D-3，DEVELOPMENT.zh.md §5）。

    契约：任意登录用户可读；无连接也 200；只给数量与身份映射，
    **不泄露待发消息正文**。
    """

    def test_requires_auth(self, api_client):
        resp = api_client.get("/api/v1/elysia/bridge/health/")
        assert resp.status_code == 401

    def test_uninitialized_profile_returns_200_with_null_profile(self, auth_client):
        client, user = auth_client()
        resp = client.get("/api/v1/elysia/bridge/health/")
        assert resp.status_code == 200
        assert resp.data["ok"] is False
        assert resp.data["profile"] is None
        assert resp.data["pending"] == 0
        assert resp.data["active_connections"] == 0

    def test_no_connection_is_ok_false_not_500(self, auth_client, user_factory):
        client, user = auth_client()
        elysia_user = user_factory(username="elysia_health", nickname="爱莉")
        ElysiaProfile.objects.create(user=elysia_user, display_name="爱莉")
        resp = client.get("/api/v1/elysia/bridge/health/")
        assert resp.status_code == 200
        assert resp.data["ok"] is False
        assert resp.data["active_connections"] == 0
        assert resp.data["profile"]["enabled"] is True

    def test_counts_pending_without_leaking_content(self, auth_client, user_factory):
        """pending 只给条数：响应里不得出现待发消息正文。"""
        from apps.chat import services as chat_services
        from apps.elysia_bridge.services import enqueue_for_delivery

        client, user = auth_client()
        elysia_user = user_factory(username="elysia_health2", nickname="爱莉")
        ElysiaProfile.objects.create(user=elysia_user, display_name="爱莉")
        conv = chat_services.get_or_create_conversation(user, elysia_user)
        msg = chat_services.create_message(
            user, conv, content="这是一条不应出现在健康接口里的私密正文"
        )
        enqueue_for_delivery(msg)

        resp = client.get("/api/v1/elysia/bridge/health/")
        assert resp.status_code == 200
        assert resp.data["pending"] == 1
        assert "私密正文" not in str(resp.data)

    def test_disabled_profile_is_not_ok(self, auth_client, user_factory):
        client, user = auth_client()
        elysia_user = user_factory(username="elysia_health3", nickname="爱莉")
        ElysiaProfile.objects.create(
            user=elysia_user, display_name="爱莉", enabled=False
        )
        resp = client.get("/api/v1/elysia/bridge/health/")
        assert resp.status_code == 200
        assert resp.data["ok"] is False
        assert resp.data["profile"]["enabled"] is False
