"""用户规则一 + 二：注册即成爱莉的好友 + 默认有她的私聊会话。

用户（TriSeTide）2026-11-11 定的三条规则里前两条，不引入任何"爱莉专属入口"：

1. 所有账号默认有爱莉的好友；
2. 消息列表默认有爱莉的聊天会话。

覆盖：
- 注册后双向 Friendship（accepted）+ 一条 PRIVATE 会话 + 两条成员记录；
- 爱莉 profile 缺失 / disabled 时注册仍然 201（不抛错，不建关系）；
- helper 自身幂等：重复调用不重复插入，也不重复建会话；
- helper 抛异常时注册仍 201（views 层 try/except + logger.exception）。
"""
import logging

import pytest
from django.contrib.auth import get_user_model

from apps.chat.models import Conversation, ConversationMember
from apps.elysia_bridge.models import ElysiaProfile
from apps.elysia_bridge.services import ensure_elysia_relationship

pytestmark = pytest.mark.django_db

User = get_user_model()

REG_URL = "/api/v1/auth/register/"
SEND_URL = "/api/v1/auth/send-email-code/"


@pytest.fixture(autouse=True)
def _clean_cache():
    from django.core.cache import cache

    cache.clear()
    yield
    cache.clear()


def _make_elysia(user_factory, username="elysia_ct", enabled=True):
    """建爱莉 user + profile（不建 profile 用 enabled=None）。"""
    elysia = user_factory(username=username, nickname="爱莉希雅")
    profile = None
    if enabled is not None:
        profile = ElysiaProfile.objects.create(
            user=elysia, enabled=enabled, display_name="爱莉希雅"
        )
    return elysia, profile


def _register(api_client, username, email=None):
    """走真实注册链路：先发码，再注册。"""
    email = email or f"{username}@test.local"
    assert api_client.post(SEND_URL, {"email": email}, format="json").status_code == 200
    from django.core.cache import cache

    from apps.accounts.services.email_code import _key

    return api_client.post(
        REG_URL,
        {
            "username": username,
            "email": email,
            "password": "test-pass-123",
            "code": cache.get(_key(email, "code")),
        },
        format="json",
    )


def _friendships(a, b):
    from apps.accounts.models import Friendship

    return Friendship.objects.filter(user=a, friend=b).first(), Friendship.objects.filter(
        user=b, friend=a
    ).first()


def _private_conversations(a, b):
    return (
        Conversation.objects.filter(type=Conversation.TYPE_PRIVATE)
        .filter(members__user=a)
        .filter(members__user=b)
        .distinct()
    )


# ---------- 规则一 + 二：注册 ----------


def test_register_creates_both_friendships_and_private_conversation(
    api_client, user_factory
):
    elysia, _profile = _make_elysia(user_factory)

    resp = _register(api_client, "friend_newbie")
    assert resp.status_code == 201
    user = User.objects.get(username="friend_newbie")

    forward, backward = _friendships(user, elysia)
    assert forward is not None and forward.status == "accepted"
    assert backward is not None and backward.status == "accepted"

    convs = _private_conversations(user, elysia)
    assert convs.count() == 1
    conv = convs.get()
    members = ConversationMember.objects.filter(conversation=conv)
    assert members.count() == 2
    assert set(members.values_list("user_id", flat=True)) == {user.id, elysia.id}


def test_register_twice_does_not_duplicate_relationship(api_client, user_factory):
    """同名重复注册被拒；用第二个账号注册也不影响爱莉侧的行数（唯一约束兜底）。"""
    elysia, _profile = _make_elysia(user_factory)

    assert _register(api_client, "dup_user").status_code == 201
    # 同用户名再注册：validation 拦掉，不产生第二行
    assert _register(api_client, "dup_user", email="dup2@test.local").status_code == 400

    user = User.objects.get(username="dup_user")
    from apps.accounts.models import Friendship

    assert Friendship.objects.filter(user=user, friend=elysia).count() == 1
    assert Friendship.objects.filter(user=elysia, friend=user).count() == 1
    assert _private_conversations(user, elysia).count() == 1


def test_ensure_is_idempotent_when_called_repeatedly(user_factory):
    elysia, _profile = _make_elysia(user_factory)
    user = user_factory(username="idem_user")

    for _ in range(3):
        assert ensure_elysia_relationship(user) is True

    from apps.accounts.models import Friendship

    assert Friendship.objects.filter(user=user, friend=elysia).count() == 1
    assert Friendship.objects.filter(user=elysia, friend=user).count() == 1
    assert _private_conversations(user, elysia).count() == 1


def test_ensure_converges_pending_friendship(user_factory):
    """若已存在 pending 行（历史脏数据），补齐时收敛为 accepted 而非重复插入。"""
    from apps.accounts.models import Friendship

    elysia, _profile = _make_elysia(user_factory)
    user = user_factory(username="pending_user")
    Friendship.objects.create(user=user, friend=elysia, status="pending")

    assert ensure_elysia_relationship(user) is True
    assert Friendship.objects.filter(user=user, friend=elysia).count() == 1
    assert Friendship.objects.get(user=user, friend=elysia).status == "accepted"


def test_ensure_skips_elysia_self(user_factory):
    elysia, _profile = _make_elysia(user_factory)

    assert ensure_elysia_relationship(elysia) is False
    from apps.accounts.models import Friendship

    assert Friendship.objects.filter(user=elysia, friend=elysia).count() == 0


# ---------- 降级：爱莉缺失 / disabled ----------


def test_register_ok_when_no_elysia_profile(api_client):
    """爱莉 profile 不存在：注册仍 201，且不建任何关系。"""
    resp = _register(api_client, "no_elysia_user")
    assert resp.status_code == 201

    from apps.accounts.models import Friendship

    user = User.objects.get(username="no_elysia_user")
    assert Friendship.objects.filter(user=user).count() == 0
    assert Conversation.objects.filter(members__user=user).count() == 0


def test_register_ok_when_elysia_disabled(api_client, user_factory):
    """profile enabled=False：视为没有爱莉，注册仍 201，不建关系。"""
    elysia, _profile = _make_elysia(user_factory, enabled=False)

    resp = _register(api_client, "disabled_elysia_user")
    assert resp.status_code == 201

    from apps.accounts.models import Friendship

    user = User.objects.get(username="disabled_elysia_user")
    assert Friendship.objects.filter(user=user, friend=elysia).count() == 0
    assert _private_conversations(user, elysia).count() == 0


def test_register_ok_when_helper_raises(api_client, user_factory, monkeypatch, caplog):
    """helper 意外抛错：注册仍 201（账号已建），异常只进日志。"""
    _make_elysia(user_factory)

    import apps.elysia_bridge.services as bridge_services

    def boom(_user):
        raise RuntimeError("boom")

    monkeypatch.setattr(bridge_services, "ensure_elysia_relationship", boom)
    caplog.set_level(logging.ERROR, logger="apps.accounts.views")

    resp = _register(api_client, "boom_user")
    assert resp.status_code == 201
    assert User.objects.filter(username="boom_user").exists()
    assert any(
        "ensure_elysia_relationship failed" in rec.getMessage()
        for rec in caplog.records
    ), [rec.getMessage() for rec in caplog.records]
