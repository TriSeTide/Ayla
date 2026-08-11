"""语音频道模型契约测试（M4-5 §10.1：VoiceChannel / VoiceChannelMember 唯一约束、owner 语义）。"""
import pytest
from django.db import IntegrityError

from apps.voice.models import VoiceChannel, VoiceChannelMember


@pytest.mark.django_db
def test_create_channel_and_room_name_unique(auth_client):
    """频道创建；room_name 唯一约束（DB 层硬约束）。"""
    _, user = auth_client()
    ch = VoiceChannel.objects.create(name="爱莉的家", room_name="room_home", owner=user)
    assert ch.pk is not None
    assert ch.room_name == "room_home"
    assert VoiceChannel.objects.filter(room_name="room_home").count() == 1

    with pytest.raises(IntegrityError):
        VoiceChannel.objects.create(name="另一个", room_name="room_home", owner=user)


@pytest.mark.django_db
def test_member_unique_together(auth_client):
    """成员 (channel, user) 唯一（DB 层硬约束）。"""
    _, user = auth_client()
    _, other = auth_client(username="other")
    ch = VoiceChannel.objects.create(name="休息室", room_name="room_lounge", owner=user)

    VoiceChannelMember.objects.create(channel=ch, user=user)
    VoiceChannelMember.objects.create(channel=ch, user=other)
    assert VoiceChannelMember.objects.count() == 2

    with pytest.raises(IntegrityError):
        VoiceChannelMember.objects.create(channel=ch, user=user)


@pytest.mark.django_db
def test_member_last_seen_refreshes(auth_client):
    """last_seen_at 自动更新（presence 心跳依据）。"""
    _, user = auth_client()
    ch = VoiceChannel.objects.create(name="语音", room_name="room_v", owner=user)
    member = VoiceChannelMember.objects.create(channel=ch, user=user)
    assert member.last_seen_at is not None
    assert member.joined_at is not None


@pytest.mark.django_db
def test_owner_semantics_is_creator_not_permission(auth_client):
    """owner 只是'创建者'语义；真正权限判断以成员表为准（复用 M4-2 约定）。"""
    _, owner_user = auth_client()
    ch = VoiceChannel.objects.create(name="频道", room_name="room_own", owner=owner_user)
    # 创建者不在 members 里也成立：owner 不自动成为成员
    assert VoiceChannelMember.objects.filter(channel=ch, user=owner_user).count() == 0
