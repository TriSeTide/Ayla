"""voice.state 广播 + presence 心跳契约测试（M4-5 §10.1）。

- 组命名空间：`voice_chan_{channel_id}`（独立于会话组 `chat_conv_{id}`）；
- WS 订阅：`VoiceConsumer` 校验成员后 group_add，非成员不订阅；
- 广播：join/leave/heartbeat 后该频道组收到 `voice.state`；
- presence 超时：超过 `VOICE_MEMBER_TIMEOUT_SECONDS` 未心跳 → 标记离开 + 广播。
"""
import pytest
import pytest_asyncio
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
def _mk_user(auth_client, **kwargs):
    """在 async 测试里经 sync_to_async 调用同步 fixture（避免 SynchronousOnlyOperation）。"""
    _, user = auth_client(**kwargs)
    return user


@database_sync_to_async
def _add_member(channel, user):
    VoiceChannelMember.objects.create(channel=channel, user=user)


@database_sync_to_async
def _member_exists(channel, user) -> bool:
    return VoiceChannelMember.objects.filter(channel=channel, user=user).exists()


def _ws_url(user) -> str:
    """WS 连接 URL（JWT 走 query string，与 M4-2 Chat WS 同款握手方式）。"""
    from rest_framework_simplejwt.tokens import RefreshToken

    token = RefreshToken.for_user(user).access_token
    return f"/ws/voice/?token={token}"


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_ws_subscribe_receives_voice_state(auth_client, transactional_db):
    """成员订阅频道组后收到 join/left 广播。"""
    user = await _mk_user(auth_client)
    ch = await _make_channel(user)
    await _add_member(ch, user)

    communicator = WebsocketCommunicator(
        consumers.VoiceConsumer.as_asgi(),
        _ws_url(user),
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
async def test_ws_non_member_not_subscribed(auth_client, transactional_db):
    """非频道成员订阅被忽略（不 group_add，收不到广播）。"""
    user = await _mk_user(auth_client)
    other = await _mk_user(auth_client, username="other")
    ch = await _make_channel(user)
    # 只有 user 是成员，other 不是

    communicator = WebsocketCommunicator(
        consumers.VoiceConsumer.as_asgi(),
        _ws_url(other),
    )
    connected, _ = await communicator.connect()
    assert connected

    await communicator.send_json_to({"type": "subscribe", "channel_ids": [str(ch.id)]})
    # 非成员不回复 voice.subscribed（无订阅）
    layer = get_channel_layer()
    await layer.group_send(
        services._voice_group_name(ch.id), services._voice_state_event(ch, user, "joined")
    )
    # 不应收到任何 voice.state；receive_nothing 轮询短窗口验证无消息
    # （比 receive_json_from(timeout=...) 安全：后者超时会取消 asgiref future，
    #  导致后续 disconnect 抛 CancelledError）
    assert await communicator.receive_nothing(timeout=0.3)

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
def test_join_switches_user_to_single_voice_channel(auth_client):
    client, user = auth_client()
    first = VoiceChannel.objects.create(name="语音一", room_name="room_single_one", owner=user)
    second = VoiceChannel.objects.create(name="语音二", room_name="room_single_two", owner=user)

    services.join_channel(first, user)
    services.join_channel(second, user)

    assert not VoiceChannelMember.objects.filter(channel=first, user=user).exists()
    assert VoiceChannelMember.objects.filter(channel=second, user=user).exists()
    assert VoiceChannelMember.objects.filter(user=user).count() == 1
    user.refresh_from_db()
    assert user.is_in_voice is True
    assert user.voice_room_id == second.id

    services.leave_channel(second, user)
    user.refresh_from_db()
    assert user.is_in_voice is False
    assert user.voice_room_id is None


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

    # 用 queryset.update() 绕过 last_seen_at(auto_now) 的 save 覆盖：直接把时间拨回 9999 秒前
    VoiceChannelMember.objects.filter(pk=member_other.pk).update(
        last_seen_at=timezone.now() - timezone.timedelta(seconds=9999)
    )

    cleared = services.mark_stale_members_left(ch, timeout_seconds=120)
    assert cleared == 1
    assert not _member_exists_check(ch, other)
    assert _member_exists_check(ch, user)


def _member_exists_check(channel, user) -> bool:
    return VoiceChannelMember.objects.filter(channel=channel, user=user).exists()
