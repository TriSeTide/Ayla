"""邮箱验证码定向测试：发码/冷却/校验/作废/过期/消费/上限/邮件内容/必填。

全部使用 locmem EmailBackend（mail.outbox），不触真实 SMTP（settings_test 已覆盖）。
"""
import pytest
from django.core import mail
from django.core.cache import cache

from apps.accounts.services.email_code import CODE_LEN, _key

# 注册写库；发码测试无需 db 但共用模块级标记无副作用
pytestmark = pytest.mark.django_db

SEND_URL = "/api/v1/auth/send-email-code/"
REG_URL = "/api/v1/auth/register/"
EMAIL = "new@test.local"


@pytest.fixture(autouse=True)
def _clean_cache():
    """每个测试前清空缓存：LocMemCache 会话内共享，避免限流/冷却状态跨测试污染。"""
    cache.clear()
    mail.outbox.clear()
    yield
    cache.clear()


def _send(api_client, email: str = EMAIL):
    return api_client.post(SEND_URL, {"email": email}, format="json")


def _code_of(email: str = EMAIL):
    return cache.get(_key(email, "code"))


def _register(api_client, username: str, email: str = EMAIL, code=None):
    payload = {
        "username": username,
        "email": email,
        "password": "test-pass-123",
        "code": code if code is not None else (_code_of(email) or ""),
    }
    return api_client.post(REG_URL, payload, format="json")


def test_send_code_ok_and_mail_sent(api_client):
    resp = _send(api_client)
    assert resp.status_code == 200
    assert resp.json()["code"] == "email_code_sent"

    code = _code_of()
    assert code and len(code) == CODE_LEN and code.isdigit()

    assert len(mail.outbox) == 1
    msg = mail.outbox[0]
    assert "Ayla 注册验证码" in msg.subject
    assert code in msg.body
    assert msg.to == [EMAIL]


def test_resend_cooldown_429(api_client):
    assert _send(api_client).status_code == 200
    resp = _send(api_client)
    assert resp.status_code == 429
    assert "60" in resp.json()["detail"]


def test_register_wrong_code_400(api_client):
    _send(api_client)
    resp = _register(api_client, username="wrong_code_user", code="000000")
    assert resp.status_code == 400
    assert "code" in resp.json()


def test_register_ok_consumes_code(api_client):
    _send(api_client)
    resp = _register(api_client, username="ok_user")
    assert resp.status_code == 201
    assert cache.get(_key(EMAIL, "code")) is None  # 一次性：注册后即失效


def test_consume_code_once(api_client):
    """服务层一次性消费：同一验证码第二次消费必须抛错（防重放）。"""
    from apps.accounts.services.email_code import EmailCodeError, consume_code

    _send(api_client)
    code = _code_of()
    consume_code(EMAIL, code)
    with pytest.raises(EmailCodeError):
        consume_code(EMAIL, code)


def test_ip_hourly_limit_429(api_client):
    """同 IP 每小时发码上限（默认 127.0.0.1）：满 30 次后第 31 次 429。"""
    for i in range(30):
        resp = _send(api_client, email=f"ipuser{i}@test.local")
        assert resp.status_code == 200, f"第 {i + 1} 次发码应为 200"
    resp = _send(api_client, email="ipoverflow@test.local")
    assert resp.status_code == 429
    assert "过于频繁" in resp.json()["detail"]


def test_send_failure_rolls_back(api_client, monkeypatch):
    """发信失败：接口 500、验证码与冷却键回滚；故障恢复后可立即重试成功。"""
    from apps.accounts.services import email_code

    def boom(**kwargs):
        raise OSError("smtp down")

    monkeypatch.setattr(email_code, "send_mail", boom)
    resp = _send(api_client)
    assert resp.status_code == 500
    assert resp.json()["code"] == "email_code_failed"
    assert cache.get(_key(EMAIL, "code")) is None
    assert cache.get(_key(EMAIL, "cd")) is None

    # 故障恢复（mock 替换为成功）→ 立即可重试
    monkeypatch.setattr(email_code, "send_mail", lambda **kwargs: None)
    resp2 = _send(api_client)
    assert resp2.status_code == 200


def test_five_wrong_attempts_invalidates(api_client):
    _send(api_client)
    real_code = _code_of()
    for i in range(5):
        resp = _register(api_client, username=f"baduser_{i}", code="000000")
        assert resp.status_code == 400
    # 满 5 次错：码已作废，真实码也无法注册
    resp = _register(api_client, username="good_user", code=real_code)
    assert resp.status_code == 400


def test_expired_code_rejected(api_client):
    _send(api_client)
    cache.delete(_key(EMAIL, "code"))  # 模拟 TTL 过期
    resp = _register(api_client, username="exp_user")
    assert resp.status_code == 400
    assert "code" in resp.json()


def test_send_code_empty_email_400(api_client):
    resp = api_client.post(SEND_URL, {"email": "   "}, format="json")
    assert resp.status_code == 400
    assert "邮箱" in resp.json()["detail"]


def test_register_duplicate_username_400(api_client):
    """重复用户名：先成功注册一个账号，再用相同用户名+新邮箱注册 → 400 用户名已存在。"""
    # 首个账号：dup-user@test.local → 成功
    first_email = "dup-user@test.local"
    code = _send_for(api_client, first_email)
    resp = _register(api_client, username="dupuser", email=first_email, code=code)
    assert resp.status_code == 201

    # 同用户名 + 新邮箱（新验证码）→ username 冲突拦截（ModelSerializer UniqueValidator 先于 validate_username）
    second_email = "dup-user-2@test.local"
    code2 = _send_for(api_client, second_email)
    resp2 = _register(api_client, username="dupuser", email=second_email, code=code2)
    assert resp2.status_code == 400
    assert "username" in resp2.json()


def test_register_duplicate_email_400(api_client):
    """重复邮箱：先成功注册一个账号，再用相同邮箱+新用户名注册 → 400 邮箱已被注册。"""
    first_email = "dup-mail@test.local"
    code = _send_for(api_client, first_email)
    resp = _register(api_client, username="mailowner", email=first_email, code=code)
    assert resp.status_code == 201

    # 同邮箱重新发码 + 不同用户名 → email 冲突拦截
    code2 = _send_for(api_client, first_email)
    resp2 = _register(api_client, username="mailowner2", email=first_email, code=code2)
    assert resp2.status_code == 400
    assert "邮箱已被注册" in resp2.json()["email"][0]


def _send_for(api_client, email: str) -> str:
    """发码并返回验证码（供重复校验用例复用）。"""
    _send(api_client, email=email)
    return _code_of(email)


def test_daily_limit_configurable(api_client):
    """每日上限可经 Django settings 覆盖（override_settings）——开发/测试可调大。"""
    from django.test import override_settings

    with override_settings(EMAIL_CODE_DAILY_LIMIT=2):
        for _ in range(2):
            assert _send(api_client).status_code == 200
            cache.delete(_key(EMAIL, "cd"))
        resp = _send(api_client)
        assert resp.status_code == 429


def test_daily_limit_429(api_client):
    for _ in range(5):
        assert _send(api_client).status_code == 200
        cache.delete(_key(EMAIL, "cd"))  # 绕过 60s 冷却，只测每日上限
    resp = _send(api_client)
    assert resp.status_code == 429
    assert "上限" in resp.json()["detail"]


def test_register_email_required(api_client):
    resp = api_client.post(
        REG_URL,
        {"username": "no_email_user", "password": "test-pass-123", "code": "123456"},
        format="json",
    )
    assert resp.status_code == 400
    assert "email" in resp.json()
