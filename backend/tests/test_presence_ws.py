"""Presence WebSocket 契约测试（settings_test 的 InMemory channel layer + WebsocketCommunicator）。

覆盖：
- 连接成功/失败（token 校验）；
- 心跳 ping -> pong；
- 全局广播组投递：连接时加入 "presence" 组，A 上线/下线事件能到达其他在线客户端
  （修复：此前只加入 presence_<id> 个人组，group_send("presence") 无人接收）；
- 隐身用户上线不广播（对外完全离线，隐私边界）。

注：group_send 经 channel layer 异步投递，帧顺序不保证，断言一律用谓词等待。
"""
import asyncio

import pytest
from channels.db import database_sync_to_async
from channels.routing import URLRouter
from channels.testing import WebsocketCommunicator
from django.urls import path

from apps.accounts.consumers import PresenceConsumer


def _token_for(user):
    from rest_framework_simplejwt.tokens import RefreshToken

    return str(RefreshToken.for_user(user).access_token)


def _make_app():
    return URLRouter([path("ws/presence/", PresenceConsumer.as_asgi())])


async def _receive_until(comm, pred, timeout=3.0):
    """循环接收直到满足谓词（忽略其他帧与顺序），超时抛 TimeoutError。"""

    async def _read():
        while True:
            frame = await comm.receive_json_from()
            if pred(frame):
                return frame

    return await asyncio.wait_for(_read(), timeout)


def _is_type(t: str):
    return lambda f: f["type"] == t


def _is_update_for(user_id: str, status: str):
    return (
        lambda f: f["type"] == "presence.update"
        and f.get("data", {}).get("user_id") == user_id
        and f.get("data", {}).get("status") == status
    )


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_connect_with_valid_token(user_factory):
    user = await database_sync_to_async(user_factory)(username="ws_ok")
    token = _token_for(user)
    comm = WebsocketCommunicator(_make_app(), f"/ws/presence/?token={token}")
    connected, _ = await comm.connect()
    assert connected is True

    # 收到 presence.self 初始帧（组广播可能异步到达，谓词等待）
    frame = await _receive_until(comm, _is_type("presence.self"))
    assert frame["type"] == "presence.self"

    # 心跳 ping -> pong
    await comm.send_json_to({"type": "ping", "ts": 1})
    pong = await _receive_until(comm, _is_type("pong"))
    assert pong["type"] == "pong"

    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_connect_with_invalid_token():
    comm = WebsocketCommunicator(_make_app(), "/ws/presence/?token=bad-token")
    connected, _ = await comm.connect()
    assert connected is False


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_connect_without_token():
    comm = WebsocketCommunicator(_make_app(), "/ws/presence/")
    connected, _ = await comm.connect()
    assert connected is False


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_broadcast_reaches_other_members(user_factory):
    """A/B 双连接：B 上线/下线广播能到达 A（全局 presence 组投递）。"""
    user_a = await database_sync_to_async(user_factory)(username="ws_broad_a")
    user_b = await database_sync_to_async(user_factory)(username="ws_broad_b")
    comm_a = WebsocketCommunicator(_make_app(), f"/ws/presence/?token={_token_for(user_a)}")
    comm_b = WebsocketCommunicator(_make_app(), f"/ws/presence/?token={_token_for(user_b)}")

    connected_a, _ = await comm_a.connect()
    assert connected_a is True
    await _receive_until(comm_a, _is_type("presence.self"))

    # B 上线：A 应收到 presence.update online（B）
    connected_b, _ = await comm_b.connect()
    assert connected_b is True
    await _receive_until(comm_b, _is_type("presence.self"))
    frame = await _receive_until(comm_a, _is_update_for(user_b.id, "online"))
    assert frame["data"]["user_id"] == user_b.id
    assert frame["data"]["status"] == "online"

    # B 断开：A 应收到 presence.update offline（B）
    await comm_b.disconnect()
    frame_off = await _receive_until(comm_a, _is_update_for(user_b.id, "offline"))
    assert frame_off["data"]["status"] == "offline"

    await comm_a.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_invisible_user_not_broadcast(user_factory):
    """隐身用户上线不广播在线（对外完全离线，隐私边界）。"""
    user_a = await database_sync_to_async(user_factory)(username="ws_invis_a")
    user_b = await database_sync_to_async(user_factory)(
        username="ws_invis_b", status="invisible"
    )
    comm_a = WebsocketCommunicator(_make_app(), f"/ws/presence/?token={_token_for(user_a)}")
    comm_b = WebsocketCommunicator(_make_app(), f"/ws/presence/?token={_token_for(user_b)}")

    connected_a, _ = await comm_a.connect()
    assert connected_a is True
    await _receive_until(comm_a, _is_type("presence.self"))

    connected_b, _ = await comm_b.connect()
    assert connected_b is True
    await _receive_until(comm_b, _is_type("presence.self"))

    # 契约：A 不应收到 B 的在线广播（后台收集 1s 窗口断言）
    frames: list[dict] = []
    stop = asyncio.Event()

    async def _collect():
        while not stop.is_set():
            try:
                f = await asyncio.wait_for(comm_a.receive_json_from(), timeout=0.2)
                frames.append(f)
            except asyncio.TimeoutError:
                continue

    collector = asyncio.create_task(_collect())
    await asyncio.sleep(1.0)
    stop.set()
    await collector
    assert not any(
        f.get("data", {}).get("user_id") == user_b.id and f["type"] == "presence.update"
        for f in frames
    ), f"invisible user leaked presence: {frames}"

    await comm_b.disconnect()
    await comm_a.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_status_change_broadcast(user_factory, auth_client):
    """PATCH /me/profile/ 改状态模式 → 全局 presence 组收到 presence.status（实时更新所有显示点）。"""
    from rest_framework_simplejwt.tokens import RefreshToken

    client, user = await database_sync_to_async(auth_client)(username="ws_status_a")
    user_b = await database_sync_to_async(user_factory)(username="ws_status_b")
    token_b = str(RefreshToken.for_user(user_b).access_token)
    comm = WebsocketCommunicator(_make_app(), f"/ws/presence/?token={token_b}")
    connected, _ = await comm.connect()
    assert connected is True
    await _receive_until(comm, _is_type("presence.self"))

    # A 保存「勿扰」→ B 收到 presence.status（user_id=A, status=dnd）
    resp = await database_sync_to_async(client.patch)(
        "/api/v1/me/profile/", {"status": "dnd"}, format="json"
    )
    assert resp.status_code == 200
    frame = await _receive_until(
        comm,
        lambda f: f["type"] == "presence.status"
        and f.get("data", {}).get("user_id") == str(user.id),
    )
    assert frame["data"]["status"] == "dnd"

    # 未变化的状态保存不广播（幂等）
    resp2 = await database_sync_to_async(client.patch)(
        "/api/v1/me/profile/", {"status": "dnd"}, format="json"
    )
    assert resp2.status_code == 200
    with pytest.raises(asyncio.TimeoutError):
        await _receive_until(
            comm,
            lambda f: f["type"] == "presence.status"
            and f.get("data", {}).get("user_id") == str(user.id),
            timeout=0.5,
        )

    await comm.disconnect()
