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
