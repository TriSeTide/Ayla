"""Presence 多连接感知契约测试（真因 1）。

背景（真实生产复现，见 Ayla/.workbuddy/evidence/livekit-udp/P4-WS-热更新-结论.md §7）：
`PresenceConsumer.disconnect()` 曾无条件 clear presence + 向好友广播 offline，
不检查同账号是否还有其它活连接。于是：
- 场景 1：同账号两条连接（App + web 并存），关掉一条 → 另一条仍 OPEN 却收到自己 offline；
- 场景 3：新连接先开、旧连接 close 晚到（典型重连重叠）→ 新连接仍活着同样收到 offline。
新连接不会再发 online（`presence.self` 只在建连时来一次）⇒ 在线光环一直灰到下次重连。

修复语义：Redis 连接集合（引用计数），只有**最后一条** presence 连接断开才
clear presence + 广播 offline；存储不可用时不猜（不广播离线）。

覆盖：
1. 存储层：登记/注销/墓碑清理/存储不可用降级（False 与 None 语义不同）；
2. Consumer 层：两条连接断一条不广播 offline / 全断才广播 /
   重连重叠（新的先来、旧的后断）不误判 / 心跳续期存活标记。
"""
import asyncio
import json

import pytest
from channels.db import database_sync_to_async
from channels.testing import WebsocketCommunicator
from rest_framework_simplejwt.tokens import RefreshToken

from apps.accounts import consumers, presence
from apps.accounts.consumers import PresenceConsumer

pytestmark = pytest.mark.django_db(transaction=True)


@database_sync_to_async
def _make_user(user_factory, **kwargs):
    return user_factory(**kwargs)


def _ws_url(user) -> str:
    token = RefreshToken.for_user(user).access_token
    return f"/ws/presence/?token={token}"


@pytest.fixture
def recorded_conns(monkeypatch):
    """记录 consumer 登记过的 (user_id, channel_name)，按建连顺序。

    channel_name 由 Channels 在 `AsyncConsumer.__call__` 里生成，测试拿不到，
    这里用登记调用的旁路记录（同一函数被 `database_sync_to_async` 包装后调用，
    因此 patch 模块级名字即可生效）。
    """
    records: list[tuple[str, str]] = []
    real = consumers.register_connection

    def recorder(user_id, channel_name):
        result = real(user_id, channel_name)
        records.append((str(user_id), str(channel_name)))
        return result

    monkeypatch.setattr(consumers, "register_connection", recorder)
    return records


async def _open(user) -> WebsocketCommunicator:
    communicator = WebsocketCommunicator(PresenceConsumer.as_asgi(), _ws_url(user))
    connected, _ = await communicator.connect()
    assert connected
    # 建连时下发的第一帧是 presence.self（自己的实时状态）
    hello = await communicator.receive_json_from(timeout=2)
    assert hello["type"] == "presence.self"
    return communicator


async def _drain(communicator, timeout=0.35) -> list[dict]:
    """收集窗口期内的所有 data 帧（窗口到期返回已收集内容）。

    **不**用 `receive_output(timeout=...)` / `receive_json_from(timeout=...)`：
    asgiref 在超时时会 cancel 掉 consumer 任务，导致后续 disconnect 抛
    CancelledError（该连接就无法再验证收尾行为）。这里直接轮询输出队列。
    """
    frames: list[dict] = []
    deadline = asyncio.get_running_loop().time() + timeout
    while asyncio.get_running_loop().time() < deadline:
        try:
            message = communicator.output_queue.get_nowait()
        except asyncio.QueueEmpty:
            await asyncio.sleep(0.01)
            continue
        if message.get("type") != "websocket.send":
            continue
        text = message.get("text")
        if text:
            frames.append(json.loads(text))
    return frames


def _offline_frames(frames, user):
    return [
        frame
        for frame in frames
        if frame.get("type") == "presence.update"
        and frame.get("data", {}).get("user_id") == str(user.id)
        and frame.get("data", {}).get("status") == "offline"
    ]


# ---------- 存储层（引用计数语义） ----------

def test_register_and_unregister_counts_connections(fake_presence_redis):
    """两条连接：断一条返回 False（仍有活连接），断最后一条返回 True。"""
    user_id = "u1"
    assert presence.register_connection(user_id, "conn-a") == 1
    assert presence.register_connection(user_id, "conn-b") == 2
    assert presence.live_connection_count(user_id) == 2

    assert presence.unregister_connection(user_id, "conn-a") is False
    assert presence.live_connection_count(user_id) == 1
    assert presence.unregister_connection(user_id, "conn-b") is True
    assert presence.live_connection_count(user_id) == 0
    assert not fake_presence_redis.smembers(presence._conns_key(user_id))
    assert fake_presence_redis.hget(presence._registry_key(), "conn-b") is None


def test_unregister_prunes_tombstones_without_alive_marker(fake_presence_redis):
    """标记已过期（进程被 kill 来不及 disconnect）的连接不算活连接，且被清掉。"""
    user_id = "u2"
    presence.register_connection(user_id, "conn-a")
    presence.register_connection(user_id, "conn-crashed")
    # 模拟崩溃：存活标记自然过期消失，集合里只剩墓碑 member
    fake_presence_redis.delete(presence._conn_key("conn-crashed"))

    assert presence.live_connection_count(user_id) == 1
    assert presence.unregister_connection(user_id, "conn-a") is True
    assert presence.live_connection_count(user_id) == 0
    assert not fake_presence_redis.smembers(presence._conns_key(user_id))


def test_unregister_returns_none_when_storage_unavailable(monkeypatch):
    """存储不可用 ⇒ None（无法证明是最后一条），调用方不得据此广播离线。"""
    from apps.accounts.tests.conftest import FakePresenceRedis

    class Broken(FakePresenceRedis):
        def srem(self, *args, **kwargs):
            raise RuntimeError("redis down")

    monkeypatch.setattr(presence, "_redis_client", lambda: Broken())
    assert presence.unregister_connection("u3", "conn-a") is None


def test_purge_connection_resolves_user_from_registry(fake_presence_redis):
    """connect 中途失败时按 channel_name 兜底摘除（registry 反查 user_id）。"""
    presence.register_connection("u4", "conn-a")
    presence.register_connection("u4", "conn-b")
    assert presence.purge_connection("conn-a") is False
    assert presence.purge_connection("conn-b") is True


# ---------- Consumer 层（真实广播行为） ----------

@pytest.mark.asyncio
async def test_one_of_two_connections_closing_does_not_broadcast_offline(
    user_factory, fake_presence_redis, transactional_db
):
    """场景 1：同账号两条连接，关掉一条 → 另一条仍 OPEN 且**不**收到 offline。"""
    user = await _make_user(user_factory, username="multi_keep")
    conn1 = await _open(user)
    conn2 = await _open(user)
    assert presence.live_connection_count(str(user.id)) == 2

    await conn1.disconnect()

    frames = await _drain(conn2)
    assert _offline_frames(frames, user) == [], f"活连接被广播成离线: {frames}"
    # 账号仍在线（presence 值未被清）
    assert presence.get_presence(str(user.id)) is not None
    assert presence.live_connection_count(str(user.id)) == 1

    # 最后一条断开后才清 presence
    await conn2.disconnect()
    assert presence.get_presence(str(user.id)) is None
    assert presence.live_connection_count(str(user.id)) == 0


@pytest.mark.asyncio
async def test_offline_broadcast_only_after_last_connection_closes(
    user_factory, fake_presence_redis, transactional_db, recorded_conns
):
    """全断才广播：断第一条不广播 offline，断最后一条才广播。"""
    watcher_user = await _make_user(user_factory, username="multi_watch")
    user = await _make_user(user_factory, username="multi_all")

    watcher = await _open(watcher_user)
    conn1 = await _open(user)
    conn2 = await _open(user)
    await _drain(watcher)  # 清掉两条 online 广播

    await conn1.disconnect()
    frames = await _drain(watcher)
    assert _offline_frames(frames, user) == [], f"还有活连接却广播了离线: {frames}"

    await conn2.disconnect()
    frames = await _drain(watcher)
    assert _offline_frames(frames, user), f"最后一条连接断开应广播离线，实际: {frames}"
    assert presence.get_presence(str(user.id)) is None

    await watcher.disconnect()


@pytest.mark.asyncio
async def test_single_connection_close_broadcasts_offline(
    user_factory, fake_presence_redis, transactional_db
):
    """回归锁：单连接正常下线仍然广播 offline（不许被引用计数吞掉）。"""
    watcher_user = await _make_user(user_factory, username="single_watch")
    user = await _make_user(user_factory, username="single_off")

    watcher = await _open(watcher_user)
    conn = await _open(user)
    await _drain(watcher)

    await conn.disconnect()

    frames = await _drain(watcher)
    assert _offline_frames(frames, user), f"单连接断开未广播离线: {frames}"
    assert presence.get_presence(str(user.id)) is None

    await watcher.disconnect()


@pytest.mark.asyncio
async def test_reconnect_overlap_old_close_does_not_mark_new_offline(
    user_factory, fake_presence_redis, transactional_db
):
    """场景 3：新连接先 OPEN，旧连接 close 晚到 → 新连接不得被判离线。"""
    watcher_user = await _make_user(user_factory, username="reconnect_watch")
    user = await _make_user(user_factory, username="reconnect")

    watcher = await _open(watcher_user)
    old = await _open(user)
    await _drain(watcher)  # 清掉 online

    new = await _open(user)  # 重连：新连接先来
    await old.disconnect()  # 旧连接的 close 晚到

    frames = await _drain(new)
    assert _offline_frames(frames, user) == [], f"重连重叠被误判离线: {frames}"
    assert _offline_frames(await _drain(watcher), user) == []
    assert presence.get_presence(str(user.id)) is not None

    await new.disconnect()
    await watcher.disconnect()


@pytest.mark.asyncio
async def test_ping_keeps_connection_marker_alive(
    user_factory, fake_presence_redis, transactional_db, recorded_conns
):
    """心跳 ping 续期本条连接的存活标记（不改变计数）。"""
    user = await _make_user(user_factory, username="ping_conn")
    conn = await _open(user)
    assert recorded_conns, "未记录到连接登记"
    _, channel_name = recorded_conns[-1]
    key = presence._conn_key(channel_name)
    fake_presence_redis.ttls[key] = 1  # 人为压低，验证被续期

    await conn.send_json_to({"type": "ping", "ts": 1})
    frames = await _drain(conn)
    pongs = [frame for frame in frames if frame.get("type") == "pong"]
    assert pongs and pongs[0]["ts"] == 1, f"未收到 pong: {frames}"
    assert fake_presence_redis.ttls.get(key) == presence._CONN_TTL
    assert presence.live_connection_count(str(user.id)) == 1

    await conn.disconnect()
