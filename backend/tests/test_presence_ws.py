"""Presence WebSocket 契约测试（settings_test 的 InMemory channel layer + WebsocketCommunicator）。"""
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


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_connect_with_valid_token(user_factory):
    user = await database_sync_to_async(user_factory)(username="ws_ok")
    token = _token_for(user)
    comm = WebsocketCommunicator(_make_app(), f"/ws/presence/?token={token}")
    connected, _ = await comm.connect()
    assert connected is True

    # 收到 presence.self 初始帧
    frame = await comm.receive_json_from()
    assert frame["type"] == "presence.self"

    # 心跳 ping -> pong
    await comm.send_json_to({"type": "ping", "ts": 1})
    pong = await comm.receive_json_from()
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
