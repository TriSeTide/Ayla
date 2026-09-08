"""Voice search uses directory visibility, real membership and bound SQL pages."""
from datetime import datetime, timezone

import pytest
from django.db import connection
from django.test.utils import CaptureQueriesContext

from apps.accounts.models import Friendship
from apps.chat.models import Conversation, ConversationMember
from apps.common.visibility import Visibility
from apps.voice.models import VoiceChannel, VoiceChannelMember

URL = "/api/v1/search/"


@pytest.mark.django_db
def test_voice_only_counts_actual_members_and_preserves_source(auth_client, user_factory):
    client, viewer = auth_client(username="voice_search_viewer")
    owner = user_factory(username="voice_search_owner", nickname="合成房主")
    groups = [Conversation.objects.create(type="group", owner=owner, title=f"来源{i}") for i in range(2)]
    for group in groups:
        ConversationMember.objects.create(conversation=group, user=viewer)
    channel = VoiceChannel.objects.create(
        owner=owner, name="合成语音搜索", room_name="search-voice-counts",
        visibility=Visibility.GROUP, group=groups[0],
    )
    channel.allowed_groups.set(groups)
    VoiceChannelMember.objects.create(channel=channel, user=owner)
    VoiceChannelMember.objects.create(channel=channel, user=viewer)
    response = client.get(URL, {"q": "语音", "types": "voice"})
    assert response.status_code == 200, response.content
    assert set(response.json()) == {"voices"}
    item = response.json()["voices"]["items"][0]
    assert item["member_count"] == 2  # two allowed groups must not multiply members
    assert item["mine"] is True
    assert item["owner_id"] == str(owner.pk)
    assert item["owner_nickname"] == "合成房主"
    assert item["group"] == str(groups[0].pk)
    assert set(item["allowed_group_names"]) == {"来源0", "来源1"}
    assert not {"token", "access_token", "api_key", "api_secret"}.intersection(item)
    VoiceChannelMember.objects.filter(channel=channel, user=viewer).delete()
    updated = client.get(URL, {"q": "语音", "types": "voice"}).json()["voices"]["items"][0]
    assert updated["member_count"] == 1 and updated["mine"] is False


@pytest.mark.django_db
def test_voice_visibility_friends_group_owner_and_source_is_not_permission(auth_client, user_factory):
    client, viewer = auth_client(username="voice_acl_viewer")
    owner = user_factory(username="voice_acl_owner")
    group = Conversation.objects.create(type="group", owner=owner, title="合成群")
    ConversationMember.objects.create(conversation=group, user=viewer)
    public = VoiceChannel.objects.create(owner=owner, name="匹配公开", room_name="v-public")
    friends = VoiceChannel.objects.create(owner=owner, name="匹配好友", room_name="v-friends", visibility="friends")
    allowed = VoiceChannel.objects.create(owner=owner, name="匹配白名单", room_name="v-allowed", visibility="group")
    allowed.allowed_groups.add(group)
    source_only = VoiceChannel.objects.create(owner=owner, name="匹配仅来源", room_name="v-source", visibility="group", group=group)
    mine = VoiceChannel.objects.create(owner=viewer, name="匹配本人", room_name="v-mine", visibility="group")
    params = {"q": "匹配", "types": "voice", "pagination": "cursor", "limit": 20}
    def ids():
        return {row["id"] for row in client.get(URL, params).json()["voices"]["items"]}
    assert ids() == {public.pk, allowed.pk, mine.pk}
    Friendship.objects.create(user=viewer, friend=owner, status="accepted")
    assert ids() == {public.pk, friends.pk, allowed.pk, mine.pk}
    ConversationMember.objects.filter(conversation=group, user=viewer).delete()
    assert ids() == {public.pk, friends.pk, mine.pk}
    assert source_only.pk not in ids()


@pytest.mark.django_db
def test_voice_cursor_binding_and_continuation_recheck(auth_client, user_factory):
    client, viewer = auth_client(username="voice_cursor_viewer")
    owner = user_factory(username="voice_cursor_owner")
    rows = [VoiceChannel.objects.create(owner=owner, name="语音游标", room_name=f"voice-cursor-{i}") for i in range(5)]
    VoiceChannel.objects.filter(pk__in=[row.pk for row in rows]).update(created_at=datetime(2026, 1, 1, tzinfo=timezone.utc))
    params = {"q": "语音游标", "types": "voice", "pagination": "cursor", "limit": 2}
    first = client.get(URL, params).json()["voices"]
    cursor = first["next_cursor"]
    other, _ = auth_client(username="voice_cursor_other")
    assert other.get(URL, {**params, "cursor": cursor}).status_code == 400
    for change in ({"q": "另一查询"}, {"types": "game"}, {"types": "voice,game"}):
        assert client.get(URL, {**params, "cursor": cursor, **change}).status_code == 400
    VoiceChannel.objects.filter(pk=rows[2].pk).update(visibility="friends")
    rows[1].delete()
    with CaptureQueriesContext(connection) as queries:
        response = client.get(URL, {**params, "cursor": cursor})
    assert response.status_code == 200, response.content
    page = response.json()["voices"]
    assert [item["id"] for item in page["items"]] == [rows[0].pk]
    assert page["total"] == 3 and page["has_more"] is False
    assert any(f"FROM {connection.ops.quote_name('voice_channels')}" in query["sql"] and "LIMIT 3" in query["sql"] for query in queries)
