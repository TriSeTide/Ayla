"""语音频道 REST 契约测试（M4-5 §10.1：建/查/加入/离开/心跳/越权）。"""
import pytest
from django.test import override_settings

from apps.voice import livekit
from apps.voice.models import VoiceChannel, VoiceChannelMember, VoiceChatMessage


@pytest.mark.django_db
def test_create_and_list_channels(auth_client):
    """登录建频道；列表返回含人数。"""
    client, user = auth_client()
    resp = client.post("/api/v1/voice/channels/", {"name": "爱莉的家"}, format="json")
    assert resp.status_code == 201, resp.content
    data = resp.json()
    assert data["name"] == "爱莉的家"
    assert data["room_name"].startswith("room_")
    assert data["owner_id"] == user.id

    resp = client.get("/api/v1/voice/channels/")
    assert resp.status_code == 200
    assert len(resp.json()) == 1
    assert resp.json()[0]["member_count"] == 0


@pytest.mark.django_db
def test_create_channel_requires_name(auth_client):
    client, _ = auth_client()
    resp = client.post("/api/v1/voice/channels/", {"name": "  "}, format="json")
    assert resp.status_code == 400


@pytest.mark.django_db
def test_join_returns_livekit_token(auth_client, monkeypatch):
    """加入频道 → 落成员表 + 返回 LiveKit token（配置存在时）。"""
    client, user = auth_client()
    ch = VoiceChannel.objects.create(name="语音", room_name="room_join", owner=user)
    monkeypatch.setattr(
        "apps.voice.views.livekit.issue_token", lambda u, r: "signed-token"
    )
    monkeypatch.setattr(
        "apps.voice.views.settings.LIVEKIT_WS_URL", "ws://127.0.0.1:7880"
    )
    monkeypatch.setattr(
        "apps.voice.views.settings.LIVEKIT_TOKEN_TTL_SECONDS", 600
    )
    resp = client.post(f"/api/v1/voice/channels/{ch.id}/join/")
    assert resp.status_code == 200, resp.content
    data = resp.json()
    assert data["token"] == "signed-token"
    assert data["room_name"] == "room_join"
    assert data["ws_url"] == "ws://127.0.0.1:7880"
    assert VoiceChannelMember.objects.filter(channel=ch, user=user).exists()


@pytest.mark.django_db
def test_join_fails_without_livekit_config(auth_client, monkeypatch):
    """LiveKit 未配置时 join 返回 503（不伪造 token）。"""
    client, user = auth_client()
    ch = VoiceChannel.objects.create(name="语音", room_name="room_nc", owner=user)

    def _raise(*a, **k):
        raise livekit.LiveKitNotConfigured("no config")

    monkeypatch.setattr("apps.voice.views.livekit.issue_token", _raise)
    resp = client.post(f"/api/v1/voice/channels/{ch.id}/join/")
    assert resp.status_code == 503


@pytest.mark.django_db
def test_owner_must_transfer_before_leave(auth_client):
    """房主离开时若还有其他成员，必须先转让（403）；成员仍保留。"""
    client, user = auth_client()
    _, other = auth_client(username="voice_leave_other")
    ch = VoiceChannel.objects.create(name="语音", room_name="room_leave", owner=user)
    VoiceChannelMember.objects.create(channel=ch, user=user)
    VoiceChannelMember.objects.create(channel=ch, user=other)
    resp = client.post(f"/api/v1/voice/channels/{ch.id}/leave/")
    assert resp.status_code == 403
    assert VoiceChannelMember.objects.filter(channel=ch, user=user).exists()
    assert VoiceChannelMember.objects.filter(channel=ch, user=other).exists()


@pytest.mark.django_db
def test_heartbeat_requires_membership(auth_client):
    client, user = auth_client()
    ch = VoiceChannel.objects.create(name="语音", room_name="room_hb", owner=user)
    # 非成员心跳 → 403
    resp = client.post(f"/api/v1/voice/channels/{ch.id}/heartbeat/")
    assert resp.status_code == 403
    # 加入后心跳 → 200
    VoiceChannelMember.objects.create(channel=ch, user=user)
    resp = client.post(f"/api/v1/voice/channels/{ch.id}/heartbeat/")
    assert resp.status_code == 200


@pytest.mark.django_db
def test_members_list_only_members(auth_client):
    client, user = auth_client()
    _, other = auth_client(username="other")
    ch = VoiceChannel.objects.create(name="语音", room_name="room_mem", owner=user)
    VoiceChannelMember.objects.create(channel=ch, user=user)
    VoiceChannelMember.objects.create(channel=ch, user=other)
    resp = client.get(f"/api/v1/voice/channels/{ch.id}/members/")
    assert resp.status_code == 200
    assert len(resp.json()) == 2


@pytest.mark.django_db
def test_rename_only_owner(auth_client):
    client, owner = auth_client()
    ch = VoiceChannel.objects.create(name="原名", room_name="room_rn", owner=owner)

    # 非 owner 客户端改名称 → 403（用独立用户名，避免与上方 other 用户 email 撞唯一约束）
    other_client, _ = auth_client(username="other_rename")
    resp = other_client.patch(f"/api/v1/voice/channels/{ch.id}/", {"name": "非法改名"}, format="json")
    assert resp.status_code == 403

    # owner 客户端改名称 → 200
    resp = client.patch(f"/api/v1/voice/channels/{ch.id}/", {"name": "新名"}, format="json")
    assert resp.status_code == 200
    assert VoiceChannel.objects.get(pk=ch.id).name == "新名"


@pytest.mark.django_db
def test_channel_not_found(auth_client):
    client, _ = auth_client()
    resp = client.get("/api/v1/voice/channels/9999/")
    assert resp.status_code == 404
    resp = client.post("/api/v1/voice/channels/9999/join/")
    assert resp.status_code == 404


@pytest.mark.django_db
def test_voice_room_chat_is_independent_from_group_messages(auth_client):
    client, user = auth_client(username="voice_chat_owner")
    ch = VoiceChannel.objects.create(name="语音", room_name="room_chat_independent", owner=user)
    VoiceChannelMember.objects.create(channel=ch, user=user)

    sent = client.post(
        f"/api/v1/voice/channels/{ch.id}/messages/",
        {"content": "房内消息"},
        format="json",
    )
    assert sent.status_code == 201, sent.content
    assert sent.json()["content"] == "房内消息"
    assert VoiceChatMessage.objects.filter(channel=ch, content="房内消息").exists()

    history = client.get(f"/api/v1/voice/channels/{ch.id}/messages/")
    assert history.status_code == 200
    assert [item["content"] for item in history.json()] == ["房内消息"]


@pytest.mark.django_db
def test_owner_member_actions_and_leave_contract(auth_client):
    owner_client, owner = auth_client(username="voice_owner_actions")
    member_client, member = auth_client(username="voice_member_actions")
    ch = VoiceChannel.objects.create(name="管理房", room_name="room_owner_actions", owner=owner)
    VoiceChannelMember.objects.create(channel=ch, user=owner)
    VoiceChannelMember.objects.create(channel=ch, user=member)

    kicked = owner_client.post(
        f"/api/v1/voice/channels/{ch.id}/members/{member.id}/action/",
        {"action": "kick"}, format="json",
    )
    assert kicked.status_code == 200, kicked.content
    assert not VoiceChannelMember.objects.filter(channel=ch, user=member).exists()

    VoiceChannelMember.objects.create(channel=ch, user=member)
    transferred = owner_client.post(
        f"/api/v1/voice/channels/{ch.id}/members/{member.id}/action/",
        {"action": "transfer"}, format="json",
    )
    assert transferred.status_code == 200, transferred.content
    ch.refresh_from_db()
    assert ch.owner_id == member.id
    assert owner_client.post(f"/api/v1/voice/channels/{ch.id}/leave/").status_code == 200


@pytest.mark.django_db
def test_unauthenticated_rejected():
    from rest_framework.test import APIClient

    client = APIClient()
    resp = client.get("/api/v1/voice/channels/")
    assert resp.status_code in (401, 403)


@pytest.mark.django_db
def test_owner_leave_when_alone(auth_client):
    """房主是唯一成员时允许直接离开（修复死锁），频道保留为空。"""
    client, owner = auth_client()
    ch = VoiceChannel.objects.create(name="单人房", room_name="room_solo_leave", owner=owner)
    VoiceChannelMember.objects.create(channel=ch, user=owner)

    resp = client.post(f"/api/v1/voice/channels/{ch.id}/leave/")
    assert resp.status_code == 200, resp.content
    assert not VoiceChannelMember.objects.filter(channel=ch, user=owner).exists()
    # 频道本身保留
    assert VoiceChannel.objects.filter(pk=ch.id).exists()


@pytest.mark.django_db
def test_transfer_to_self_rejected(auth_client):
    """转让给自己返回 400，与 kick 不能踢自己防护对称。"""
    client, owner = auth_client()
    ch = VoiceChannel.objects.create(name="自转房", room_name="room_self_transfer", owner=owner)
    VoiceChannelMember.objects.create(channel=ch, user=owner)

    url = f"/api/v1/voice/channels/{ch.id}/members/{owner.id}/action/"
    resp = client.post(url, {"action": "transfer"}, format="json")
    assert resp.status_code == 400, resp.content
    ch.refresh_from_db()
    assert ch.owner_id == owner.id