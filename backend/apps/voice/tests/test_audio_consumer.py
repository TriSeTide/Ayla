"""房间音频中继 WS 通道契约测试（ws/voice/audio/）。

为什么要单独测 consumer 一层
----------------------------
`test_audio_relay.py` 只覆盖纯逻辑（成员表/裁决/Top-K），
拿不到「consumer 类写错基类」这类问题 —— 例如把 `send_json` 用在
`AsyncWebsocketConsumer` 上会在 accept 之后抛 AttributeError，
握手仍是 101、但客户端只收到 close 1011 且看不到任何业务帧，
纯逻辑测试与 `manage.py check` 都不会报错。因此这里用
channels 官方 `WebsocketCommunicator` 走一遍真实 ASGI 生命周期。
"""
import pytest
from channels.db import database_sync_to_async
from channels.testing import WebsocketCommunicator

from apps.voice import audio_relay
from apps.voice.audio_consumer import VoiceAudioConsumer
from apps.voice.models import VoiceChannel, VoiceChannelMember


@pytest.fixture(autouse=True)
def _isolate_rooms():
    """audio_relay 的房间表是进程内模块级状态，测试间必须清干净。"""
    audio_relay._ROOMS.clear()
    yield
    audio_relay._ROOMS.clear()


@database_sync_to_async
def _mk_user(auth_client, **kwargs):
    """在 async 测试里经 sync_to_async 调用同步 fixture。"""
    _, user = auth_client(**kwargs)
    return user


@database_sync_to_async
def _make_channel(owner, name="音频", room_name="room_audio_ws"):
    return VoiceChannel.objects.create(name=name, room_name=room_name, owner=owner)


@database_sync_to_async
def _add_member(channel, user):
    VoiceChannelMember.objects.create(channel=channel, user=user)


@database_sync_to_async
def _token_for(user) -> str:
    from rest_framework_simplejwt.tokens import RefreshToken

    return str(RefreshToken.for_user(user).access_token)


async def _connect(user, channel_id, token=None) -> WebsocketCommunicator:
    """构造指向音频通道的 communicator。

    token 必须经 database_sync_to_async 取得（simplejwt 会读 model 属性），
    因此本助手是 async —— 若在同步函数里 await 不了，会静默拿到一个协程对象
    塞进 URL，表现为「所有用例握手都失败」。
    """
    value = token if token is not None else await _token_for(user)
    url = f"/ws/voice/audio/?token={value}&channel={channel_id}"
    return WebsocketCommunicator(VoiceAudioConsumer.as_asgi(), url)


# ---------- 认证与成员校验（失败路径） ----------


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_rejects_invalid_token(auth_client, transactional_db):
    """token 不是合法访问令牌 → 握手被拒。"""
    user = await _mk_user(auth_client)
    ch = await _make_channel(user)
    await _add_member(ch, user)

    comm = await _connect(user, ch.id, token="not-a-real-token")
    connected, _ = await comm.connect()
    assert not connected


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_rejects_non_member(auth_client, transactional_db):
    """非频道成员 → 握手被拒（与 VoiceConsumer 的成员语义一致）。"""
    owner = await _mk_user(auth_client)
    outsider = await _mk_user(auth_client, username="audio_outsider")
    ch = await _make_channel(owner)
    await _add_member(ch, owner)

    comm = await _connect(outsider, ch.id)
    connected, _ = await comm.connect()
    assert not connected


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_rejects_non_numeric_channel(auth_client, transactional_db):
    """channel 不是整数 → 握手被拒。"""
    user = await _mk_user(auth_client)
    ch = await _make_channel(user)
    await _add_member(ch, user)

    comm = WebsocketCommunicator(
        VoiceAudioConsumer.as_asgi(),
        f"/ws/voice/audio/?token={await _token_for(user)}&channel=abc",
    )
    connected, _ = await comm.connect()
    assert not connected


# ---------- 成功路径 ----------


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_joined_frame_delivered_with_slot(auth_client, transactional_db):
    """成员连上后必须收到 joined 帧（含 slot 与初始名单）。

    这是「consumer 基类写错」的回归守卫：基类不提供 send_json 时，
    握手仍返回 101，但这里拿不到 joined 帧（只会等到 close 1011）。
    """
    user = await _mk_user(auth_client)
    ch = await _make_channel(user)
    await _add_member(ch, user)

    comm = await _connect(user, ch.id)
    connected, _ = await comm.connect()
    assert connected

    joined = await comm.receive_json_from(timeout=2)
    assert joined["type"] == "joined"
    assert joined["slot"] == 1
    assert joined["members"] == []

    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_second_member_sees_roster_and_broadcast(auth_client, transactional_db):
    """第二人入房：自己看到 A，A 收到 member_joined；slot 递增不重复。"""
    user_a = await _mk_user(auth_client)
    user_b = await _mk_user(auth_client, username="audio_b")
    ch = await _make_channel(user_a)
    await _add_member(ch, user_a)
    await _add_member(ch, user_b)

    comm_a = await _connect(user_a, ch.id)
    assert (await comm_a.connect())[0]
    joined_a = await comm_a.receive_json_from(timeout=2)

    comm_b = await _connect(user_b, ch.id)
    assert (await comm_b.connect())[0]
    joined_b = await comm_b.receive_json_from(timeout=2)

    assert joined_b["slot"] != joined_a["slot"]
    assert [m["slot"] for m in joined_b["members"]] == [joined_a["slot"]]

    evt = await comm_a.receive_json_from(timeout=2)
    assert evt["type"] == "member_joined"
    assert evt["slot"] == joined_b["slot"]

    await comm_b.disconnect()
    await comm_a.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_audio_forwarded_with_slot_prefix_and_n_minus_one(auth_client, transactional_db):
    """只有 speaking 且未静音的音频才转发；接收端拿到 [1B slot]+负载；发送者不自收。"""
    user_a = await _mk_user(auth_client)
    user_b = await _mk_user(auth_client, username="audio_b2")
    ch = await _make_channel(user_a, room_name="room_audio_fwd")
    await _add_member(ch, user_a)
    await _add_member(ch, user_b)

    comm_a = await _connect(user_a, ch.id)
    assert (await comm_a.connect())[0]
    joined_a = await comm_a.receive_json_from(timeout=2)

    comm_b = await _connect(user_b, ch.id)
    assert (await comm_b.connect())[0]
    await comm_b.receive_json_from(timeout=2)
    await comm_a.receive_json_from(timeout=2)  # member_joined

    payload = bytes(range(20))

    # 未标记 speaking → 丢弃
    await comm_b.send_to(bytes_data=payload)
    assert await comm_a.receive_nothing(timeout=0.3)

    # 标记 speaking 后 → 转发
    await comm_b.send_to(text_data='{"type": "speaking", "on": true}')
    speaking = await comm_a.receive_json_from(timeout=2)
    assert speaking["type"] == "speaking" and speaking["on"] is True

    await comm_b.send_to(bytes_data=payload)
    # receive_from 直接返回负载（文本为 str、二进制为 bytes），不是 channel 消息字典
    frame = await comm_a.receive_from(timeout=2)
    assert isinstance(frame, bytes), f"应为二进制帧，实际 {type(frame)}"
    assert frame[0] == joined_a["slot"] + 1  # B 的 slot
    assert frame[1:] == payload

    # N-1：B 不会收到自己的音频
    assert await comm_b.receive_nothing(timeout=0.3)

    await comm_b.disconnect()
    await comm_a.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_mute_stops_forwarding(auth_client, transactional_db):
    """静音后即使仍在 speaking，也不再转发。"""
    user_a = await _mk_user(auth_client)
    user_b = await _mk_user(auth_client, username="audio_b3")
    ch = await _make_channel(user_a, room_name="room_audio_mute")
    await _add_member(ch, user_a)
    await _add_member(ch, user_b)

    comm_a = await _connect(user_a, ch.id)
    assert (await comm_a.connect())[0]
    await comm_a.receive_json_from(timeout=2)
    comm_b = await _connect(user_b, ch.id)
    assert (await comm_b.connect())[0]
    await comm_b.receive_json_from(timeout=2)
    await comm_a.receive_json_from(timeout=2)  # member_joined

    await comm_b.send_to(text_data='{"type": "speaking", "on": true}')
    await comm_a.receive_json_from(timeout=2)  # speaking 广播

    await comm_b.send_to(text_data='{"type": "mute", "on": true}')
    muted = await comm_a.receive_json_from(timeout=2)
    assert muted["type"] == "muted" and muted["on"] is True

    await comm_b.send_to(bytes_data=b"\x22" * 20)
    assert await comm_a.receive_nothing(timeout=0.4)

    await comm_b.disconnect()
    await comm_a.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_ping_pong(auth_client, transactional_db):
    """ping 原样回 ts，便于前端测 RTT。"""
    user = await _mk_user(auth_client)
    ch = await _make_channel(user, room_name="room_audio_ping")
    await _add_member(ch, user)

    comm = await _connect(user, ch.id)
    assert (await comm.connect())[0]
    await comm.receive_json_from(timeout=2)

    await comm.send_to(text_data='{"type": "ping", "ts": 12345}')
    pong = await comm.receive_json_from(timeout=2)
    assert pong["type"] == "pong" and pong["ts"] == 12345

    await comm.disconnect()


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_member_left_broadcast_and_slot_reuse(auth_client, transactional_db):
    """断开 → 对端收到 member_left；空房间被回收。"""
    user_a = await _mk_user(auth_client)
    user_b = await _mk_user(auth_client, username="audio_b4")
    ch = await _make_channel(user_a, room_name="room_audio_left")
    await _add_member(ch, user_a)
    await _add_member(ch, user_b)

    comm_a = await _connect(user_a, ch.id)
    assert (await comm_a.connect())[0]
    await comm_a.receive_json_from(timeout=2)
    comm_b = await _connect(user_b, ch.id)
    assert (await comm_b.connect())[0]
    joined_b = await comm_b.receive_json_from(timeout=2)
    await comm_a.receive_json_from(timeout=2)  # member_joined

    await comm_b.disconnect()
    left = await comm_a.receive_json_from(timeout=2)
    assert left["type"] == "member_left"
    assert left["slot"] == joined_b["slot"]

    await comm_a.disconnect()
    # 两人都走了：房间表应清空（disconnect 清理是异步的，先让事件循环转一圈）
    for _ in range(20):
        if ch.id not in audio_relay._ROOMS:
            break
        await _sleep()
    assert ch.id not in audio_relay._ROOMS


async def _sleep():
    import asyncio

    await asyncio.sleep(0.05)
