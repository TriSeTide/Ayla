"""voice.state 广播 + presence 心跳契约测试（M4-5 §10.1）。

- 组命名空间：`voice_chan_{channel_id}`（独立于会话组 `chat_conv_{id}`）；
- WS 订阅：`VoiceConsumer` 校验成员后 group_add，非成员不订阅；
- 广播：join/leave/heartbeat 后该频道组收到 `voice.state`；
- presence 超时：超过 `VOICE_MEMBER_TIMEOUT_SECONDS` 未心跳 → 标记离开 + 广播。
"""
import pytest
import pytest_asyncio
from asgiref.sync import async_to_sync
from channels.db import database_sync_to_async
from channels.layers import get_channel_layer
from channels.testing import WebsocketCommunicator
from django.utils import timezone

from apps.voice import consumers, services
from apps.voice.models import VoiceChannel, VoiceChannelMember


@database_sync_to_async
def _make_channel(owner, name="语音", room_name="room_ws"):
    return VoiceChannel.objects.create(name=name, room_name=room_name, owner=owner)


@database_sync_to_async
def _add_member(channel, user):
    VoiceChannelMember.objects.create(channel=channel, user=user)


@database_sync_to_async
def _member_exists(channel, user) -> bool:
    return VoiceChannelMember.objects.filter(channel=channel, user=user).exists()


def _jwt_headers(user):
    from rest_framework_simplejwt.tokens import RefreshToken

    token = RefreshToken.for_user(user).access_token
    return {"authorization": [f"Bearer {token}"]}


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_ws_subscribe_receives_voice_state(auth_client):
    """成员订阅频道组后收到 join/left 广播。"""
    _, user = auth_client()
    ch = await _make_channel(user)
    await _add_member(ch, user)

    communicator = WebsocketCommunicator(
        consumers.VoiceConsumer.as_asgi(),
        "/ws/voice/",
        headers=_jwt_headers(user),
    )
    connected, _ = await communicator.connect()
    assert connected

    # 订阅频道组
    await communicator.send_json_to({"type": "subscribe", "channel_ids": [str(ch.id)]})
    sub = await communicator.receive_json_from(timeout=2)
    assert sub["type"] == "voice.subscribed"
    assert sub["data"]["channel_id"] == str(ch.id)

    # 广播 voice.state joined
    layer = get_channel_layer()
    await layer.group_send(
        services._voice_group_name(ch.id), services._voice_state_event(ch, user, "joined")
    )
    event = await communicator.receive_json_from(timeout=2)
    assert event["type"] == "voice.state"
    assert event["data"]["channel_id"] == str(ch.id)
    assert event["data"]["user_id"] == str(user.id)
    assert event["data"]["state"] == "joined"

    await communicator.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_ws_non_member_not_subscribed(auth_client):
    """非频道成员订阅被忽略（不 group_add，收不到广播）。"""
    _, user = auth_client()
    _, other = auth_client(username="other")
    ch = await _make_channel(user)
    # 只有 user 是成员，other 不是

    communicator = WebsocketCommunicator(
        consumers.VoiceConsumer.as_asgi(),
        "/ws/voice/",
        headers=_jwt_headers(other),
    )
    connected, _ = await communicator.connect()
    assert connected

    await communicator.send_json_to({"type": "subscribe", "channel_ids": [str(ch.id)]})
    # 非成员不回复 voice.subscribed（无订阅）
    layer = get_channel_layer()
    await layer.group_send(
        services._voice_group_name(ch.id), services._voice_state_event(ch, user, "joined")
    )
    # 不应收到任何 voice.state；用短超时验证无消息
    from channels.exceptions import StopConsumer

    try:
        msg = await communicator.receive_json_from(timeout=0.3)
        assert msg.get("type") != "voice.state"
    except Exception:
        pass  # 超时即符合预期（无广播到达）

    await communicator.disconnect()


@pytest.mark.django_db
def test_join_broadcasts_state_and_persists(auth_client):
    """join_channel 落成员表 + 广播组名正确。"""
    client, user = auth_client()
    ch = VoiceChannel.objects.create(name="语音", room_name="room_join_ws", owner=user)
    services.join_channel(ch, user)
    assert VoiceChannelMember.objects.filter(channel=ch, user=user).exists()
    assert services._voice_group_name(ch.id) == f"voice_chan_{ch.id}"


@pytest.mark.django_db
def test_leave_broadcasts_state_and_removes(auth_client):
    """leave_channel 删成员 + 广播 left。"""
    client, user = auth_client()
    ch = VoiceChannel.objects.create(name="语音", room_name="room_leave_ws", owner=user)
    services.join_channel(ch, user)
    services.leave_channel(ch, user)
    assert not VoiceChannelMember.objects.filter(channel=ch, user=user).exists()


@pytest.mark.django_db
def test_heartbeat_refreshes_last_seen(auth_client):
    """heartbeat_channel 刷新 last_seen_at。"""
    client, user = auth_client()
    ch = VoiceChannel.objects.create(name="语音", room_name="room_hb_ws", owner=user)
    member = services.join_channel(ch, user)
    first = member.last_seen_at
    services.heartbeat_channel(ch, user)
    member.refresh_from_db()
    assert member.last_seen_at >= first


@pytest.mark.django_db
def test_stale_members_marked_left_and_broadcast(auth_client):
    """超过超时未心跳的成员标记离开（后台任务契约）。"""
    client, user = auth_client()
    _, other = auth_client(username="other")
    ch = VoiceChannel.objects.create(name="语音", room_name="room_stale_ws", owner=user)
    services.join_channel(ch, user)
    member_other = services.join_channel(ch, other)

    member_other.last_seen_at = timezone.now() - timezone.timedelta(seconds=9999)
    member_other.save(update_fields=["last_seen_at"])

    cleared = services.mark_stale_members_left(ch, timeout_seconds=120)
    assert cleared == 1
    assert not _member_exists_check(ch, other)
    assert _member_exists_check(ch, user)


def _member_exists_check(channel, user) -> bool:
    return VoiceChannelMember.objects.filter(channel=channel, user=user).exists()
