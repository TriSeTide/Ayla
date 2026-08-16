"""LiveKit token 签发契约测试（M4-5 §10.1：身份/房间/grants/TTL；无配置时显式失败）。"""
from datetime import timedelta

import pytest
from django.conf import settings
from django.test import override_settings

from apps.voice import livekit
from apps.voice.livekit import LiveKitNotConfigured, issue_token


def _mk_user(auth_client):
    _, user = auth_client()
    return user


@pytest.mark.django_db
def test_issue_token_binds_identity_room_and_grants(auth_client, monkeypatch):
    """token 正确绑定 identity/room/grants/TTL。"""
    user = _mk_user(auth_client)
    monkeypatch.setattr(settings, "LIVEKIT_API_KEY", "test-key")
    monkeypatch.setattr(settings, "LIVEKIT_API_SECRET", "test-secret")
    monkeypatch.setattr(settings, "LIVEKIT_TOKEN_TTL_SECONDS", 600)

    captured = {}

    class _FakeToken:
        def __init__(self, key, secret):
            captured["key"] = key
            captured["secret"] = secret

        def with_identity(self, identity):
            captured["identity"] = identity
            return self

        def with_grants(self, grants):
            captured["grants"] = grants
            return self

        def with_ttl(self, ttl):
            captured["ttl"] = ttl
            return self

        def to_jwt(self):
            captured["jwt"] = "signed-jwt"
            return "signed-jwt"

    import livekit.api as livekit_api

    monkeypatch.setattr(livekit_api, "AccessToken", _FakeToken)

    token = issue_token(user, "room_home")
    assert token == "signed-jwt"
    assert captured["identity"] == f"user_{user.id}"
    # room 由 grants 对象承载（token 层不单独暴露 room，见下方 grants.room 断言）
    grants = captured["grants"]
    assert grants.room_join is True
    assert grants.room == "room_home"
    assert grants.can_publish is True
    assert grants.can_subscribe is True
    assert captured["ttl"] == timedelta(seconds=600)


@pytest.mark.django_db
def test_issue_token_uses_custom_ttl(auth_client, monkeypatch):
    """自定义 TTL 覆盖默认值。"""
    user = _mk_user(auth_client)
    monkeypatch.setattr(settings, "LIVEKIT_API_KEY", "k")
    monkeypatch.setattr(settings, "LIVEKIT_API_SECRET", "s")
    captured = {}

    class _FakeToken:
        def __init__(self, key, secret):
            pass

        def with_identity(self, identity):
            return self

        def with_grants(self, grants):
            return self

        def with_ttl(self, ttl):
            captured["ttl"] = ttl
            return self

        def to_jwt(self):
            return "jwt"

    import livekit.api as livekit_api

    monkeypatch.setattr(livekit_api, "AccessToken", _FakeToken)
    issue_token(user, "room_x", ttl_seconds=300)
    assert captured["ttl"] == timedelta(seconds=300)


@pytest.mark.django_db
def test_issue_token_fails_without_config(auth_client, monkeypatch):
    """无配置时显式失败，不生成裸 token。"""
    user = _mk_user(auth_client)
    monkeypatch.setattr(settings, "LIVEKIT_API_KEY", "")
    monkeypatch.setattr(settings, "LIVEKIT_API_SECRET", "")
    with pytest.raises(LiveKitNotConfigured):
        issue_token(user, "room_home")


def test_parse_room_name_rejects_invalid():
    """非法 room_name 显式拒绝。"""
    with pytest.raises(ValueError):
        livekit.parse_room_name_from_channel("")
    with pytest.raises(ValueError):
        livekit.parse_room_name_from_channel("bad room/name")
    assert livekit.parse_room_name_from_channel("room_home") == "room_home"
    assert livekit.parse_room_name_from_channel("room-abc123") == "room-abc123"
