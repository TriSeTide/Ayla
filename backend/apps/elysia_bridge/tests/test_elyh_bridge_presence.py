"""规则三（方案 B）：ElyH 通道连接 ↔ 爱莉在线标记的 consumer 契约测试。

覆盖：
- connect 成功 → 写 `presence:elyh:<user_id>`，且**不写** Ayla 的 `presence:<user_id>`；
- ping → 续期（TTL 被重设为 90s）；
- disconnect → 清标记；
- 顶替场景（新连接顶掉旧连接）：旧连接断开不得清掉新连接的标记；
- 端到端：ElyH 连着时 UserPublicSerializer 把爱莉显示为在线，断开后离线。

风格与 test_bridge_ws.py 一致：WebsocketCommunicator + transactional_db；
Redis 用 FakePresenceRedis（monkeypatch presence._redis_client）。
"""
import asyncio

import pytest
from channels.db import database_sync_to_async
from channels.routing import URLRouter
from channels.testing import WebsocketCommunicator
from django.urls import path

from apps.accounts import presence
from apps.accounts.tests.conftest import FakePresenceRedis
from apps.elysia_bridge.consumers import AylaBridgeConsumer
from apps.elysia_bridge.models import ElysiaProfile

pytestmark = pytest.mark.usefixtures("transactional_db")

WS_PATH = "ws/elysia-bridge/"


@pytest.fixture
def fake_redis(monkeypatch):
    fake = FakePresenceRedis()
    monkeypatch.setattr(presence, "_redis_client", lambda: fake)
    return fake


def _token_for(user):
    from rest_framework_simplejwt.tokens import RefreshToken

    return str(RefreshToken.for_user(user).access_token)


def _make_app():
    return URLRouter([path(WS_PATH, AylaBridgeConsumer.as_asgi())])


async def _connect(user):
    comm = WebsocketCommunicator(_make_app(), f"/{WS_PATH}?token={_token_for(user)}")
    connected, _ = await comm.connect()
    assert connected is True
    return comm


@database_sync_to_async
def _mk_elysia(username="elysia_online", enabled=True):
    from django.contrib.auth import get_user_model

    User = get_user_model()
    user = User.objects.create_user(
        username=username, email=f"{username}@test.local", password="test-pass-123"
    )
    user.nickname = "爱莉希雅"
    user.save(update_fields=["nickname"])
    ElysiaProfile.objects.create(user=user, enabled=enabled, display_name="爱莉希雅")
    return user


@database_sync_to_async
def _serialized(user_id):
    from django.contrib.auth import get_user_model

    from apps.accounts.serializers import UserPublicSerializer

    user = get_user_model().objects.get(pk=user_id)
    return UserPublicSerializer(user).data


async def _wait_until(predicate, timeout=2.0, interval=0.01):
    """等一个异步副作用落地。

    `WebsocketCommunicator.connect()` 在收到 `websocket.accept` 就返回——而
    consumer 的 connect 在 accept **之后**还要 group_add / 写在线标记。因此
    "connect 返回"不等于"connect 执行完"，直接断言会和 consumer 协程抢跑。
    这里轮询等待，不使用 ping（ping 自己也会续期，会掩盖 connect 是否写了标记）。
    """
    deadline = asyncio.get_running_loop().time() + timeout
    while asyncio.get_running_loop().time() < deadline:
        if predicate():
            return True
        await asyncio.sleep(interval)
    return predicate()


# ---------- connect / disconnect ----------


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_connect_marks_elyh_online_and_leaves_ayla_presence_alone(fake_redis):
    elysia = await _mk_elysia()
    assert presence.is_elyh_online(elysia.id) is False

    comm = await _connect(elysia)
    assert await _wait_until(lambda: presence.is_elyh_online(elysia.id)) is True
    # 关键：绝不复用 Ayla PresenceConsumer 的 key（否则两边互相清除）
    assert fake_redis.get(presence._key(elysia.id)) is None
    assert presence.get_presence(elysia.id) is None

    await comm.disconnect()
    assert presence.is_elyh_online(elysia.id) is False


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_ping_renews_elyh_ttl(fake_redis):
    elysia = await _mk_elysia()
    comm = await _connect(elysia)
    await _wait_until(lambda: presence.is_elyh_online(elysia.id))

    key = presence._elyh_key(elysia.id)
    fake_redis.ttls[key] = 1  # 模拟时间流逝，标记接近过期

    await comm.send_json_to({"v": 1, "type": "ping"})
    assert (await comm.receive_json_from())["type"] == "pong"
    assert fake_redis.ttls[key] == presence._ELYH_TTL

    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_rejected_connection_does_not_mark_online(fake_redis):
    """鉴权失败（非爱莉账号）不得留下在线标记。"""
    from django.contrib.auth import get_user_model

    user = await database_sync_to_async(get_user_model().objects.create_user)(
        username="not_elysia_online", password="test-pass-123"
    )
    comm = WebsocketCommunicator(_make_app(), f"/{WS_PATH}?token={_token_for(user)}")
    connected, code = await comm.connect()
    assert connected is False and code == 4403
    assert presence.is_elyh_online(user.id) is False


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_replaced_old_connection_does_not_clear_new_marker(fake_redis):
    """新连接顶替旧连接：旧连接的 disconnect 不得清掉新连接写的标记。"""
    elysia = await _mk_elysia()
    old = await _connect(elysia)
    assert await _wait_until(lambda: presence.is_elyh_online(elysia.id))
    new = await _connect(elysia)

    # 旧连接收到 4409 close，让它的 disconnect 真正跑完
    message = await old.receive_output()
    assert message["type"] == "websocket.close"
    await asyncio.sleep(0.3)

    assert presence.is_elyh_online(elysia.id) is True
    # 新连接仍然健康（ping 仍有 pong），并且标记仍被它续期
    await new.send_json_to({"v": 1, "type": "ping"})
    assert (await new.receive_json_from())["type"] == "pong"
    assert presence.is_elyh_online(elysia.id) is True

    await new.disconnect()
    assert presence.is_elyh_online(elysia.id) is False


# ---------- 对外可见性（端到端） ----------


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_serializer_reports_elysia_online_while_bridge_connected(fake_redis):
    elysia = await _mk_elysia()
    before = await _serialized(elysia.id)
    assert before["online"] is False and before["display_status"] == "离线"

    comm = await _connect(elysia)
    assert await _wait_until(lambda: presence.is_elyh_online(elysia.id))
    during = await _serialized(elysia.id)
    assert during["online"] is True and during["display_status"] == "在线"

    await comm.disconnect()
    after = await _serialized(elysia.id)
    assert after["online"] is False and after["display_status"] == "离线"
