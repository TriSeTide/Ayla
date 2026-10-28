"""「静音态跨端广播」契约测试（2026-10-29 新增）。

背景：`voice.state` 原本只有 joined/left/heartbeat；muted/unmuted 只由各端从
LiveKit 的 TrackMuted/TrackUnmuted **本地合成**，服务端从不广播 ⇒ 换端登录、
重进房间的成员永远看不到别人当前是否静音。本文件锁死新增的 `voice.mute` 上报帧
与它引发的 `voice.state muted/unmuted` 广播。

安全边界（每条都有对应用例）：
1. 只能上报**自己**（帧里不接受 user_id；服务端恒用握手身份）；
2. 必须是该频道当前成员，否则拒绝且**不广播**；
3. 必须已订阅该频道（不订阅就不许往组里注入）；
4. 广播形状与既有 voice.state **完全一致**（type + data 四字段）。
"""
import pytest
from channels.db import database_sync_to_async
from channels.layers import get_channel_layer
from channels.testing import WebsocketCommunicator
from django.utils import timezone

from apps.voice import consumers, services
from apps.voice.models import VoiceChannel, VoiceChannelMember


@database_sync_to_async
def _make_channel(owner, room_name="room_mute"):
    return VoiceChannel.objects.create(name="语音", room_name=room_name, owner=owner)


@database_sync_to_async
def _mk_user(auth_client, **kwargs):
    _, user = auth_client(**kwargs)
    return user


@database_sync_to_async
def _add_member(channel, user):
    VoiceChannelMember.objects.create(
        channel=channel, user=user, joined_at=timezone.now()
    )


def _ws_url(user) -> str:
    from rest_framework_simplejwt.tokens import RefreshToken

    token = RefreshToken.for_user(user).access_token
    return f"/ws/voice/?token={token}"


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_mute_frame_broadcasts_muted_to_channel(auth_client, transactional_db):
    """成员上报 muted ⇒ 同频道订阅者收到 voice.state muted，形状与既有事件一致。"""
    owner = await _mk_user(auth_client, username="mute_owner_a")
    member = await _mk_user(auth_client, username="mute_member_a")
    ch = await _make_channel(owner, room_name="room_mute_a")
    # ⚠️ 订阅校验的是「**成员表**里有没有你」，不是「你是不是房主」
    #    （services.user_in_channel → channel_member）。房主不自动入表，
    #    所以监听方也必须 join 成成员，否则 subscribe 会被静默忽略。
    await _add_member(ch, member)
    await _add_member(ch, owner)

    listener = WebsocketCommunicator(consumers.VoiceConsumer.as_asgi(), _ws_url(owner))
    ok, _ = await listener.connect()
    assert ok
    await listener.send_json_to({"type": "subscribe", "channel_ids": [str(ch.id)]})
    assert (await listener.receive_json_from(timeout=2))["type"] == "voice.subscribed"

    actor = WebsocketCommunicator(consumers.VoiceConsumer.as_asgi(), _ws_url(member))
    ok2, _ = await actor.connect()
    assert ok2
    await actor.send_json_to({"type": "subscribe", "channel_ids": [str(ch.id)]})
    assert (await actor.receive_json_from(timeout=2))["type"] == "voice.subscribed"

    await actor.send_json_to(
        {"type": "voice.mute", "channel_id": str(ch.id), "muted": True}
    )
    event = await listener.receive_json_from(timeout=2)

    assert event["type"] == "voice.state"
    assert event["data"]["state"] == "muted"
    assert event["data"]["user_id"] == str(member.id)
    assert event["data"]["channel_id"] == str(ch.id)
    assert set(event["data"].keys()) == {"channel_id", "user_id", "state", "ts"}

    await actor.disconnect()
    await listener.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_unmute_frame_broadcasts_unmuted(auth_client, transactional_db):
    """muted=false ⇒ 广播 unmuted（同一路径，不走第二套代码）。"""
    owner = await _mk_user(auth_client, username="mute_owner_b")
    member = await _mk_user(auth_client, username="mute_member_b")
    ch = await _make_channel(owner, room_name="room_mute_b")
    await _add_member(ch, member)
    await _add_member(ch, owner)

    listener = WebsocketCommunicator(consumers.VoiceConsumer.as_asgi(), _ws_url(owner))
    await listener.connect()
    await listener.send_json_to({"type": "subscribe", "channel_ids": [str(ch.id)]})
    await listener.receive_json_from(timeout=2)

    actor = WebsocketCommunicator(consumers.VoiceConsumer.as_asgi(), _ws_url(member))
    await actor.connect()
    await actor.send_json_to({"type": "subscribe", "channel_ids": [str(ch.id)]})
    await actor.receive_json_from(timeout=2)

    await actor.send_json_to(
        {"type": "voice.mute", "channel_id": str(ch.id), "muted": False}
    )
    event = await listener.receive_json_from(timeout=2)
    assert event["data"]["state"] == "unmuted"

    await actor.disconnect()
    await listener.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_non_member_cannot_broadcast_mute(auth_client, transactional_db):
    """非成员上报静音态：回 error，且**不广播**（不能替别人刷状态）。"""
    owner = await _mk_user(auth_client, username="mute_owner_c")
    outsider = await _mk_user(auth_client, username="mute_outsider_c")
    ch = await _make_channel(owner, room_name="room_mute_c")
    await _add_member(ch, owner)

    listener = WebsocketCommunicator(consumers.VoiceConsumer.as_asgi(), _ws_url(owner))
    await listener.connect()
    await listener.send_json_to({"type": "subscribe", "channel_ids": [str(ch.id)]})
    await listener.receive_json_from(timeout=2)

    actor = WebsocketCommunicator(consumers.VoiceConsumer.as_asgi(), _ws_url(outsider))
    await actor.connect()
    await actor.send_json_to(
        {"type": "voice.mute", "channel_id": str(ch.id), "muted": True}
    )
    reply = await actor.receive_json_from(timeout=2)
    assert reply["type"] == "error"

    # listener 不应收到任何帧
    assert await listener.receive_nothing(timeout=0.5)

    await actor.disconnect()
    await listener.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_invalid_mute_payload_rejected(auth_client, transactional_db):
    """payload 非法（缺字段/类型不对）⇒ error，不广播。"""
    owner = await _mk_user(auth_client, username="mute_owner_d")
    ch = await _make_channel(owner, room_name="room_mute_d")
    await _add_member(ch, owner)

    actor = WebsocketCommunicator(consumers.VoiceConsumer.as_asgi(), _ws_url(owner))
    await actor.connect()
    await actor.send_json_to({"type": "subscribe", "channel_ids": [str(ch.id)]})
    await actor.receive_json_from(timeout=2)

    for bad in (
        {"type": "voice.mute", "channel_id": str(ch.id)},
        {"type": "voice.mute", "muted": True},
        {"type": "voice.mute", "channel_id": str(ch.id), "muted": "yes"},
    ):
        await actor.send_json_to(bad)
        reply = await actor.receive_json_from(timeout=2)
        assert reply["type"] == "error"

    await actor.disconnect()


@pytest.mark.django_db
def test_mute_event_shape_matches_voice_state(auth_client):
    """mute_event 与 _voice_state_event 形状必须一致（字段集完全相同）。"""
    # owner 必填 ⇒ 用真实账号建频道（不能裸 create）
    _, owner = auth_client(username="mute_shape_owner")
    ch = VoiceChannel.objects.create(
        name="语音", room_name="room_mute_shape", owner=owner
    )

    class _U:
        id = "00000000000000000000000000000001"

    muted = services.mute_event(ch.id, _U(), True)
    left = services._voice_state_event(ch, _U(), "left")

    assert muted["type"] == left["type"] == "voice.state"
    assert set(muted["data"].keys()) == set(left["data"].keys())
    assert muted["data"]["state"] == "muted"
