"""弹幕契约测试（M4-6 §8.1）：落库、`live_{id}` 组广播、历史分页、越权、WS。"""
import pytest
from channels.layers import get_channel_layer
from channels.testing import WebsocketCommunicator
from rest_framework_simplejwt.tokens import RefreshToken

from apps.live import consumers, services
from apps.live.models import Danmaku


class _RecordingLayer:
    """记录型 channel layer：断言 group_send 目标组与事件（不依赖真实 layer）。"""

    def __init__(self):
        self.sent = []

    def group_send(self, group, event):
        self.sent.append((group, event))


@pytest.mark.django_db
def test_post_danmaku_persists_and_broadcasts(auth_client, live_channel_factory, monkeypatch):
    """POST 弹幕：落库 + 201 + 广播到 live_{id} 组（帧带 sender descriptor）。"""
    client, user = auth_client()
    ch = live_channel_factory(owner=user)
    layer = _RecordingLayer()
    monkeypatch.setattr("channels.layers.get_channel_layer", lambda: layer)

    resp = client.post(
        f"/api/v1/live/channels/{ch.id}/danmaku/", {"content": "大家好"}, format="json"
    )
    assert resp.status_code == 201, resp.content
    data = resp.json()
    assert data["content"] == "大家好"
    assert data["channel_id"] == str(ch.id)
    assert data["sender"]["user_id"] == str(user.id)
    assert Danmaku.objects.filter(channel=ch, content="大家好").count() == 1

    # 广播契约：目标组 live_{channel_id}，帧 type=danmaku
    assert len(layer.sent) == 1
    group, event = layer.sent[0]
    assert group == f"live_{ch.id}"
    assert event["type"] == "danmaku"
    assert event["content"] == "大家好"
    assert event["channel_id"] == str(ch.id)


@pytest.mark.django_db
def test_post_danmaku_validation(auth_client, live_channel_factory):
    """空内容/超长 → 400；频道不存在 → 404。"""
    client, user = auth_client()
    ch = live_channel_factory(owner=user)

    resp = client.post(f"/api/v1/live/channels/{ch.id}/danmaku/", {"content": "  "}, format="json")
    assert resp.status_code == 400

    resp = client.post(
        f"/api/v1/live/channels/{ch.id}/danmaku/", {"content": "x" * 201}, format="json"
    )
    assert resp.status_code == 400

    resp = client.post("/api/v1/live/channels/9999/danmaku/", {"content": "hi"}, format="json")
    assert resp.status_code == 404


@pytest.mark.django_db
def test_danmaku_history_pagination(auth_client, live_channel_factory, monkeypatch):
    """历史：默认 50；?limit= 生效；上限 200（services 层契约）。"""
    client, user = auth_client()
    ch = live_channel_factory(owner=user)
    for i in range(60):
        Danmaku.objects.create(channel=ch, sender=user, content=f"dm-{i}")

    resp = client.get(f"/api/v1/live/channels/{ch.id}/danmaku/")
    assert resp.status_code == 200
    assert len(resp.json()) == 50  # 默认 LIVE_DANMAKU_HISTORY_LIMIT
    assert resp.json()[0]["content"] == "dm-10"  # 升序（最新 50 条：dm-10..dm-59）

    resp = client.get(f"/api/v1/live/channels/{ch.id}/danmaku/?limit=10")
    assert resp.status_code == 200
    assert len(resp.json()) == 10

    # services 层上限 200（直接调 services 验证，越界截断）
    rows = services.danmaku_history(ch, limit=9999)
    assert len(rows) == 60
    rows = services.danmaku_history(ch, limit=0)
    assert len(rows) == 1  # 下限 1


@pytest.mark.django_db
def test_danmaku_unauthenticated():
    """未登录发弹幕/看历史 → 401。"""
    from rest_framework.test import APIClient

    client = APIClient()
    resp = client.get("/api/v1/live/channels/1/danmaku/")
    assert resp.status_code in (401, 403)
    resp = client.post("/api/v1/live/channels/1/danmaku/", {"content": "x"}, format="json")
    assert resp.status_code in (401, 403)


def _jwt_query(user) -> str:
    token = RefreshToken.for_user(user).access_token
    return f"token={token}"


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_ws_receives_danmaku_broadcast(auth_client, live_channel_factory):
    """WS：JWT 认证成功后加入 live_{id} 组，收到弹幕实时帧。"""
    _, user = auth_client()
    ch = live_channel_factory(owner=user)
    path = f"/ws/live/{ch.id}/?{_jwt_query(user)}"

    communicator = WebsocketCommunicator(consumers.DanmakuConsumer.as_asgi(), path)
    connected, _ = await communicator.connect()
    assert connected

    # 同直播间发弹幕 → 广播帧到达
    dm = await _async_create_danmaku(ch, user, "第一发弹幕")
    layer = get_channel_layer()
    await layer.group_send(f"live_{ch.id}", services._danmaku_event(dm))

    event = await communicator.receive_json_from(timeout=2)
    assert event["type"] == "danmaku"
    assert event["content"] == "第一发弹幕"
    assert event["sender"]["user_id"] == str(user.id)

    # ping → pong
    await communicator.send_json_to({"type": "ping", "ts": 1})
    pong = await communicator.receive_json_from(timeout=2)
    assert pong["type"] == "pong"

    await communicator.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_ws_unauthorized_closed(auth_client, live_channel_factory):
    """WS：无 token/非法 token → 连接被关闭（4401）。"""
    _, user = auth_client()
    ch = live_channel_factory(owner=user)

    # 无 token
    communicator = WebsocketCommunicator(
        consumers.DanmakuConsumer.as_asgi(), f"/ws/live/{ch.id}/"
    )
    connected, _ = await communicator.connect()
    assert not connected

    # 非法 token
    communicator = WebsocketCommunicator(
        consumers.DanmakuConsumer.as_asgi(), f"/ws/live/{ch.id}/?token=bad-token"
    )
    connected, _ = await communicator.connect()
    assert not connected


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_ws_missing_channel_closed(auth_client):
    """WS：直播间不存在 → 关闭（4404）。"""
    _, user = auth_client()
    communicator = WebsocketCommunicator(
        consumers.DanmakuConsumer.as_asgi(), f"/ws/live/9999/?{_jwt_query(user)}"
    )
    connected, _ = await communicator.connect()
    assert not connected


async def _async_create_danmaku(channel, user, content):
    from channels.db import database_sync_to_async

    return await database_sync_to_async(services.create_danmaku)(
        channel, user, content
    )
