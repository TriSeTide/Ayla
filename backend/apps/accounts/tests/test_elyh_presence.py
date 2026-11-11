"""规则三（方案 B）：ElyH 独立在线标记 —— 存储层 + 序列化层契约测试。

设计要点（见 apps/accounts/presence.py 的 ElyH 段注释）：
- 不复用 `presence:<user_id>`（Ayla 前端 PresenceConsumer 独占，双方会互相清除）；
- `presence:elyh:<user_id>` 自带 TTL 90s（bridge 每 30s ping），ping 续期；
- 对外可见性取「或」，两条来源互不影响；隐身只作用于 Ayla presence。
"""
import json

import pytest

from apps.accounts import presence

pytestmark = pytest.mark.django_db


def _serialize(user):
    from apps.accounts.serializers import UserPublicSerializer

    return UserPublicSerializer(user).data


# ---------- 存储层 ----------


def test_mark_and_clear_elyh_marker(fake_presence_redis):
    user_id = "elyh-u1"
    assert presence.is_elyh_online(user_id) is False

    presence.mark_elyh_online(user_id, owner="conn-a")
    assert presence.is_elyh_online(user_id) is True
    assert fake_presence_redis.ttls[presence._elyh_key(user_id)] == presence._ELYH_TTL
    assert presence._ELYH_TTL == 90  # 3× bridge 心跳周期（30s）

    presence.clear_elyh_online(user_id, owner="conn-a")
    assert presence.is_elyh_online(user_id) is False


def test_elyh_key_is_separate_from_ayla_presence_key(fake_presence_redis):
    """两套标记绝不共享 key：写 ElyH 不得让 presence:<id> 出现，反之亦然。"""
    user_id = "elyh-u2"
    presence.mark_elyh_online(user_id)
    assert presence.get_presence(user_id) is None
    assert fake_presence_redis.get(presence._key(user_id)) is None

    presence.set_presence(user_id, "online")
    presence.clear_elyh_online(user_id)
    # 清 ElyH 不能动到 Ayla presence
    assert presence.get_presence(user_id) is not None
    assert presence.is_elyh_online(user_id) is False


def test_mark_renews_ttl(fake_presence_redis):
    """ping 续期的语义：重复 mark 重设 TTL（假实现里 TTL 落到同一个 key）。"""
    user_id = "elyh-u3"
    presence.mark_elyh_online(user_id, owner="conn-a")
    key = presence._elyh_key(user_id)
    fake_presence_redis.ttls[key] = 1  # 模拟时间流逝到快过期
    presence.mark_elyh_online(user_id, owner="conn-a")
    assert fake_presence_redis.ttls[key] == presence._ELYH_TTL


def test_stale_owner_cannot_clear_new_connection(fake_presence_redis):
    """连接被顶替：旧连接的 disconnect 不得清掉新连接写的标记。"""
    user_id = "elyh-u4"
    presence.mark_elyh_online(user_id, owner="new-conn")

    presence.clear_elyh_online(user_id, owner="old-conn")
    assert presence.is_elyh_online(user_id) is True

    presence.clear_elyh_online(user_id, owner="new-conn")
    assert presence.is_elyh_online(user_id) is False


def test_elyh_helpers_degrade_when_storage_unavailable(monkeypatch):
    """Redis 不可用：读返回 False、写/清不抛（不阻断 WS 主流程）。"""

    def broken():
        raise RuntimeError("redis down")

    monkeypatch.setattr(presence, "_redis_client", broken)
    presence.mark_elyh_online("u-x")  # 不抛
    presence.clear_elyh_online("u-x")
    assert presence.is_elyh_online("u-x") is False


# ---------- 序列化层：或关系 + 互不影响 ----------


def test_online_true_when_only_elyh_marker(user_factory, fake_presence_redis):
    user = user_factory(status="auto")
    assert _serialize(user)["online"] is False

    presence.mark_elyh_online(user.id)
    data = _serialize(user)
    assert data["online"] is True
    assert data["display_status"] == "在线"

    presence.clear_elyh_online(user.id)
    data = _serialize(user)
    assert data["online"] is False
    assert data["display_status"] == "离线"


def test_online_true_when_only_ayla_presence(user_factory, fake_presence_redis):
    """ElyH 离线 + Ayla presence 在线 → 仍在线（互不影响）。"""
    user = user_factory(status="auto")
    presence.set_presence(user.id, "online")

    data = _serialize(user)
    assert data["online"] is True
    assert data["display_status"] == "在线"


def test_both_sources_offline(user_factory, fake_presence_redis):
    user = user_factory(status="auto")
    data = _serialize(user)
    assert data["online"] is False
    assert data["display_status"] == "离线"


def test_invisible_still_hidden_from_ayla_presence(user_factory, fake_presence_redis):
    """隐身：Ayla presence 在线也对外离线（既有语义不变）。"""
    user = user_factory(status="invisible")
    presence.set_presence(user.id, "online")

    data = _serialize(user)
    assert data["online"] is False
    assert data["display_status"] == "离线"


def test_elyh_not_affected_by_invisible(user_factory, fake_presence_redis):
    """ElyH 标记不参与隐身判断：爱莉没有隐身概念，ElyH 连着即在线。"""
    user = user_factory(status="invisible")
    presence.mark_elyh_online(user.id)

    data = _serialize(user)
    assert data["online"] is True
    assert data["display_status"] == "在线"


def test_dnd_and_away_keep_text_but_online_from_elyh(user_factory, fake_presence_redis):
    dnd = user_factory(status="dnd")
    presence.mark_elyh_online(dnd.id)
    data = _serialize(dnd)
    assert data["display_status"] == "勿扰"
    assert data["online"] is True

    away = user_factory(status="away")
    presence.mark_elyh_online(away.id)
    data = _serialize(away)
    assert data["display_status"] == "离开"
    assert data["online"] is True


def test_marker_payload_is_json_with_owner(fake_presence_redis):
    user_id = "elyh-u5"
    presence.mark_elyh_online(user_id, owner="conn-z")
    raw = fake_presence_redis.get(presence._elyh_key(user_id))
    payload = json.loads(raw)
    assert payload["owner"] == "conn-z"
    assert payload["ts"]
