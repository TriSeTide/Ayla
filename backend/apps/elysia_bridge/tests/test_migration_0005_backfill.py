"""数据迁移 0005：存量账号补齐爱莉好友 + 会话（幂等 / 可重跑 / 反向语义）。

覆盖：
- 前进：既有 active 用户（排除爱莉自己与 inactive 用户）都拿到双向 accepted 好友
  和一条 PRIVATE 会话（两条成员记录）；
- 幂等：同一迁移函数重复执行不产生重复行；
- 爱莉 profile 缺失/禁用：迁移不失败；
- 反向：RunPython.noop —— 回退到 0004 后关系行**保留**（理由见迁移 docstring），
  再次前进也不会重复插入。
"""
import importlib

import pytest
from django.db import connection
from django.db.migrations.executor import MigrationExecutor

pytestmark = pytest.mark.django_db(transaction=True)

BEFORE = ("elysia_bridge", "0004_converge_profile_and_inbound_outbox")
AFTER = ("elysia_bridge", "0005_backfill_elysia_relationship")


def _forward_fn():
    """取迁移模块里的 forward（RunPython 调用的同一个函数）。"""
    module = importlib.import_module(
        "apps.elysia_bridge.migrations.0005_backfill_elysia_relationship"
    )
    return module.forward


def _run_forward():
    """用全局 app registry 调迁移函数。

    RunPython 传入的是历史 app registry；这里用 `django.apps.apps`——两者都只提供
    `get_model`，且本迁移只读写这几张表，字段集在 0004 之后未变，因此等价。
    """
    from django.apps import apps as global_apps

    _forward_fn()(global_apps, None)


@pytest.fixture
def migrated():
    """先迁到 0004（即"0005 尚未应用"的库状态），用例结束后恢复最新。"""
    executor = MigrationExecutor(connection)
    executor.migrate([BEFORE])
    yield
    executor = MigrationExecutor(connection)
    executor.loader.build_graph()
    executor.migrate(executor.loader.graph.leaf_nodes())


def _mk_users():
    """在当前迁移状态下建：爱莉 + 2 个普通用户 + 1 个 inactive 用户。"""
    from django.contrib.auth import get_user_model

    from apps.elysia_bridge.models import ElysiaProfile

    User = get_user_model()
    elysia = User.objects.create_user(
        username="mig_elysia", email="mig_elysia@t.local", password="x"
    )
    ElysiaProfile.objects.create(user=elysia, enabled=True, display_name="爱莉希雅")
    a = User.objects.create_user(username="mig_a", email="mig_a@t.local", password="x")
    b = User.objects.create_user(username="mig_b", email="mig_b@t.local", password="x")
    dead = User.objects.create_user(
        username="mig_dead", email="mig_dead@t.local", password="x", is_active=False
    )
    return elysia, a, b, dead


def _counts(user, elysia):
    """(user→爱莉 好友数, 爱莉→user 好友数, 两人共有私聊会话数)。"""
    from apps.accounts.models import Friendship
    from apps.chat.models import Conversation

    return (
        Friendship.objects.filter(user=user, friend=elysia).count(),
        Friendship.objects.filter(user=elysia, friend=user).count(),
        Conversation.objects.filter(type="private")
        .filter(members__user=user)
        .filter(members__user=elysia)
        .distinct()
        .count(),
    )


def test_forward_backfills_every_active_user(migrated):
    elysia, a, b, dead = _mk_users()

    _run_forward()

    for user in (a, b):
        assert _counts(user, elysia) == (1, 1, 1), user.username

    from apps.accounts.models import Friendship

    # 爱莉自己不得与自己成好友；inactive 用户不补
    assert Friendship.objects.filter(user=elysia, friend=elysia).count() == 0
    assert _counts(dead, elysia) == (0, 0, 0)


def test_forward_creates_accepted_status_and_two_members(migrated):
    elysia, a, _b, _dead = _mk_users()
    _run_forward()

    from apps.accounts.models import Friendship
    from apps.chat.models import Conversation, ConversationMember

    assert Friendship.objects.get(user=a, friend=elysia).status == "accepted"
    assert Friendship.objects.get(user=elysia, friend=a).status == "accepted"

    conv = (
        Conversation.objects.filter(type="private")
        .filter(members__user=a)
        .filter(members__user=elysia)
        .distinct()
        .get()
    )
    members = ConversationMember.objects.filter(conversation=conv)
    assert members.count() == 2
    assert set(members.values_list("user_id", flat=True)) == {a.id, elysia.id}


def test_forward_is_idempotent(migrated):
    elysia, a, _b, _dead = _mk_users()

    _run_forward()
    _run_forward()
    _run_forward()

    from apps.accounts.models import Friendship
    from apps.chat.models import Conversation, ConversationMember

    assert _counts(a, elysia) == (1, 1, 1)
    assert Friendship.objects.filter(user=a, friend=elysia).count() == 1
    conv = (
        Conversation.objects.filter(type="private")
        .filter(members__user=a)
        .filter(members__user=elysia)
        .distinct()
        .get()
    )
    assert ConversationMember.objects.filter(conversation=conv).count() == 2


def test_forward_converges_existing_pending_friendship(migrated):
    """已有 pending 行（历史脏数据）→ 收敛为 accepted，不新增行。"""
    elysia, a, _b, _dead = _mk_users()
    from apps.accounts.models import Friendship

    Friendship.objects.create(user=a, friend=elysia, status="pending")

    _run_forward()

    assert Friendship.objects.filter(user=a, friend=elysia).count() == 1
    assert Friendship.objects.get(user=a, friend=elysia).status == "accepted"
    assert _counts(a, elysia) == (1, 1, 1)


def test_forward_skips_without_enabled_profile(migrated):
    """爱莉 profile 缺失/禁用时迁移不失败（只记一行日志）。"""
    from django.contrib.auth import get_user_model

    from apps.elysia_bridge.models import ElysiaProfile

    User = get_user_model()
    elysia_user = User.objects.create_user(
        username="mig_elysia_off", email="mig_eo@t.local", password="x"
    )
    ElysiaProfile.objects.create(
        user=elysia_user, enabled=False, display_name="爱莉希雅"
    )
    a = User.objects.create_user(username="mig_c", email="mig_c@t.local", password="x")

    _run_forward()  # 不抛

    from apps.accounts.models import Friendship

    assert Friendship.objects.filter(user=a).count() == 0


def test_reverse_is_noop_and_rows_survive(migrated):
    """反向为 noop：回退到 0004 后关系行保留（不做不可逆的会话/消息删除）。"""
    elysia, a, _b, _dead = _mk_users()
    _run_forward()
    assert _counts(a, elysia) == (1, 1, 1)

    executor = MigrationExecutor(connection)
    executor.migrate([BEFORE])

    from apps.accounts.models import Friendship

    # 迁移记录回退，但数据仍在（noop 反向）
    assert Friendship.objects.filter(user=a, friend=elysia).count() == 1

    executor = MigrationExecutor(connection)
    executor.loader.build_graph()
    executor.migrate([AFTER])

    assert _counts(a, elysia) == (1, 1, 1)
