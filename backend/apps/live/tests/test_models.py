"""直播模型契约测试（M4-6 §8.1）：stream_key 唯一、status choices、Danmaku 落库。"""
import pytest
from django.db import IntegrityError

from apps.live.models import Danmaku, LiveChannel
from apps.live.services import gen_stream_key


@pytest.mark.django_db
def test_stream_key_unique(auth_client):
    """stream_key 唯一（DB 硬约束）：重复插入抛 IntegrityError。"""
    _, owner = auth_client()
    key = gen_stream_key()
    LiveChannel.objects.create(title="A", owner=owner, stream_key=key)
    with pytest.raises(IntegrityError):
        LiveChannel.objects.create(title="B", owner=owner, stream_key=key)


@pytest.mark.django_db
def test_stream_key_format_and_length(auth_client):
    """stream_key 为 hex(24)（48 字符），≤64。"""
    _, owner = auth_client()
    ch = LiveChannel.objects.create(
        title="A", owner=owner, stream_key=gen_stream_key()
    )
    assert len(ch.stream_key) == 48
    assert len(ch.stream_key) <= 64
    assert all(c in "0123456789abcdef" for c in ch.stream_key)


@pytest.mark.django_db
def test_status_default_idle_and_choices(auth_client):
    """status 默认 idle，choices 只允许 idle/live/ended。"""
    _, owner = auth_client()
    ch = LiveChannel.objects.create(
        title="A", owner=owner, stream_key=gen_stream_key()
    )
    assert ch.status == "idle"
    choices = {c[0] for c in LiveChannel.STATUS_CHOICES}
    assert choices == {"idle", "live", "ended"}


@pytest.mark.django_db
def test_danmaku_persist(auth_client):
    """弹幕落库：channel/sender/content/created_at。"""
    _, owner = auth_client()
    ch = LiveChannel.objects.create(
        title="A", owner=owner, stream_key=gen_stream_key()
    )
    dm = Danmaku.objects.create(channel=ch, sender=owner, content="你好")
    assert dm.channel_id == ch.id
    assert dm.sender_id == owner.id
    assert dm.content == "你好"
    assert dm.created_at is not None


@pytest.mark.django_db
def test_danmaku_cascade_on_channel_delete(auth_client):
    """删除频道级联删弹幕。"""
    _, owner = auth_client()
    ch = LiveChannel.objects.create(
        title="A", owner=owner, stream_key=gen_stream_key()
    )
    Danmaku.objects.create(channel=ch, sender=owner, content="x")
    ch.delete()
    assert Danmaku.objects.count() == 0
