"""语音目录事件契约：只广播频道 ID，详情由权限 REST 对账。"""
from types import SimpleNamespace

import pytest

from apps.voice import services


class _Layer:
    def __init__(self):
        self.calls = []

    async def group_send(self, group, event):
        self.calls.append((group, event))


@pytest.mark.django_db
def test_created_catalog_event_contains_only_channel_id(monkeypatch):
    layer = _Layer()
    monkeypatch.setattr("channels.layers.get_channel_layer", lambda: layer)
    channel = SimpleNamespace(id=42)

    services.broadcast_channel_created_to_user(channel, SimpleNamespace(id="owner"))

    assert layer.calls == [
        ("voice_catalog", {"type": "voice.channel.created", "channel_id": "42"})
    ]


@pytest.mark.django_db
def test_deleted_catalog_event_contains_only_channel_id(monkeypatch):
    layer = _Layer()
    monkeypatch.setattr("channels.layers.get_channel_layer", lambda: layer)

    services.broadcast_channel_deleted(42, "public")

    assert layer.calls == [
        ("voice_catalog", {"type": "voice.channel.deleted", "channel_id": "42"})
    ]


@pytest.mark.django_db
def test_join_leave_updates_sort_projection_and_broadcast(monkeypatch):
    """侧栏排序投影契约：join → last_occupied_at 落库且广播帧携带；最后一人离开（变空）
    → last_vacant_at 落库且帧携带（无人区 move-to-front 的事实源，多端实时一致）。"""
    from django.contrib.auth import get_user_model

    from apps.voice.models import VoiceChannel

    User = get_user_model()
    owner = User.objects.create_user(
        username="vc_proj_owner", password="x", email="vc_proj_owner@example.com"
    )
    other = User.objects.create_user(
        username="vc_proj_other", password="x", email="vc_proj_other@example.com"
    )
    channel = VoiceChannel.objects.create(name="排序投影", room_name="room_proj", owner=owner)
    layer = _Layer()
    monkeypatch.setattr("channels.layers.get_channel_layer", lambda: layer)

    def last_event():
        events = [e for _, e in layer.calls if e["type"] == "voice.channel.member_count_changed"]
        return events[-1] if events else None

    # 有人进入 → last_occupied_at 落库 + 帧携带
    services.join_channel(channel, owner)
    channel.refresh_from_db()
    assert channel.last_occupied_at is not None
    assert last_event()["last_occupied_at"] is not None

    services.join_channel(channel, other)
    channel.refresh_from_db()
    assert channel.last_occupied_at is not None

    # 第一人离开（还有 other 在场）→ 不写 last_vacant_at（未变空）
    services.leave_channel(channel, owner)
    channel.refresh_from_db()
    assert channel.last_vacant_at is None

    # 最后一人离开（变空）→ last_vacant_at 落库 + 帧携带；last_occupied_at 保留（不回落依据）
    services.leave_channel(channel, other)
    channel.refresh_from_db()
    assert channel.last_vacant_at is not None
    assert channel.last_occupied_at is not None
    assert last_event()["last_vacant_at"] is not None
