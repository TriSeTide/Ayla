"""隐私设置换绑/改密定向测试：JWT 认证 + 邮箱验证码（双验证/单验证）、一次性消费、密码强度。

全部使用 locmem EmailBackend + cache（settings_test），不触真实 SMTP。
"""
import pytest
from django.contrib.auth import get_user_model
from django.core.cache import cache

from apps.accounts.services.email_code import _key

User = get_user_model()

SEND_URL = "/api/v1/auth/send-email-code/"
PASSWORD_URL = "/api/v1/auth/change-password/"
EMAIL_URL = "/api/v1/auth/change-email/"
LOGIN_URL = "/api/v1/auth/login/"

pytestmark = pytest.mark.django_db


@pytest.fixture(autouse=True)
def _clean_cache():
    cache.clear()
    yield
    cache.clear()


def _send_code(api_client, email: str):
    resp = api_client.post(SEND_URL, {"email": email}, format="json")
    assert resp.status_code == 200, resp.content
    return cache.get(_key(email, "code"))


def _post(api_client, url: str, payload: dict):
    return api_client.post(url, payload, format="json")


def _login(api_client, username: str, password: str):
    return api_client.post(
        LOGIN_URL, {"username": username, "password": password}, format="json"
    )


# ---------- 更改密码 ----------

def test_change_password_ok(auth_client):
    client, user = auth_client()
    code = _send_code(client, user.email)
    resp = _post(client, PASSWORD_URL, {"code": code, "new_password": "new-secure-pass-456"})
    assert resp.status_code == 200

    # 旧密码失效、新密码可登录
    assert _login(client, user.username, "test-pass-123").status_code == 401
    assert _login(client, user.username, "new-secure-pass-456").status_code == 200
    # 验证码一次性消费
    assert cache.get(_key(user.email, "code")) is None


def test_change_password_wrong_code_400(auth_client):
    client, user = auth_client()
    _send_code(client, user.email)
    resp = _post(client, PASSWORD_URL, {"code": "000000", "new_password": "new-secure-pass-456"})
    assert resp.status_code == 400
    assert "code" in resp.json()


def test_change_password_unauth_401(api_client):
    resp = _post(api_client, PASSWORD_URL, {"code": "123456", "new_password": "new-secure-pass-456"})
    assert resp.status_code == 401


def test_change_password_weak_rejected(auth_client):
    client, user = auth_client()
    code = _send_code(client, user.email)
    resp = _post(client, PASSWORD_URL, {"code": code, "new_password": "12345678"})
    assert resp.status_code == 400
    assert "new_password" in resp.json()


# ---------- 换绑邮箱（双验证） ----------

def test_change_email_ok_double_verify(auth_client):
    client, user = auth_client()
    old_email = user.email
    current_code = _send_code(client, old_email)
    new_email = "newbox@test.local"
    new_code = _send_code(client, new_email)

    resp = _post(client, EMAIL_URL, {
        "current_code": current_code,
        "new_email": new_email,
        "new_code": new_code,
    })
    assert resp.status_code == 200
    user.refresh_from_db()
    assert user.email == new_email
    # 双码均已消费：新邮箱码与旧邮箱码都失效
    assert cache.get(_key(old_email, "code")) is None
    assert cache.get(_key(new_email, "code")) is None


def test_change_email_existing_target_400(auth_client, user_factory):
    """新邮箱已被其他用户占用 → 400（含并发唯一性兜底路径）。"""
    client, user = auth_client()
    other = user_factory(email="taken@test.local")
    assert other.email == "taken@test.local"
    current_code = _send_code(client, user.email)
    _send_code(client, "taken@test.local")
    resp = _post(client, EMAIL_URL, {
        "current_code": current_code,
        "new_email": "taken@test.local",
        "new_code": cache.get(_key("taken@test.local", "code")),
    })
    assert resp.status_code == 400
    assert "new_email" in resp.json()


def test_change_password_no_bound_email_400(auth_client):
    """未绑定邮箱用户不能走改密（需邮箱验证）。"""
    client, user = auth_client()
    user.email = ""
    user.save(update_fields=["email"])
    resp = _post(client, PASSWORD_URL, {"code": "123456", "new_password": "new-secure-pass-456"})
    assert resp.status_code == 400
    assert "email" in resp.json()


def test_change_email_wrong_new_code_400(auth_client):
    client, user = auth_client()
    current_code = _send_code(client, user.email)
    _send_code(client, "newbox2@test.local")
    resp = _post(client, EMAIL_URL, {
        "current_code": current_code,
        "new_email": "newbox2@test.local",
        "new_code": "000000",
    })
    assert resp.status_code == 400
    assert "new_code" in resp.json()


def test_change_email_unauth_401(api_client):
    resp = _post(api_client, EMAIL_URL, {
        "current_code": "123456", "new_email": "x@test.local", "new_code": "654321"
    })
    assert resp.status_code == 401


def test_change_email_bind_without_current_email(auth_client):
    """未绑定邮箱用户：仅需新邮箱验证码（首绑）。"""
    client, user = auth_client()
    user.email = ""
    user.save(update_fields=["email"])
    new_email = "firstbind@test.local"
    new_code = _send_code(client, new_email)

    resp = _post(client, EMAIL_URL, {
        "current_code": "",
        "new_email": new_email,
        "new_code": new_code,
    })
    assert resp.status_code == 200
    user.refresh_from_db()
    assert user.email == new_email
