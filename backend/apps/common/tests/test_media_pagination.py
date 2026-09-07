"""Media history keysets and bounded member previews use real database queries."""
from datetime import datetime, timezone

import pytest
from django.db import connection
from django.test.utils import CaptureQueriesContext
from rest_framework.test import APIClient

from apps.boardgame.models import GameRoom, GameRoomMember
from apps.live.models import Danmaku, LiveChannel
from apps.voice.models import VoiceChannel, VoiceChatMessage
from apps.voice.models import VoiceChannelMember

pytestmark = pytest.mark.django_db
STAMP = datetime(2026, 9, 8, tzinfo=timezone.utc)


@pytest.fixture(params=["voice", "live"])
def history(request, user_factory):
    owner = user_factory()
    if request.param == "voice":
        room = VoiceChannel.objects.create(owner=owner, name="test", room_name="history-test")
        model = VoiceChatMessage
        suffix = "messages"
    else:
        room = LiveChannel.objects.create(owner=owner, title="test", stream_key="history-test")
        model = Danmaku
        suffix = "danmaku"
    model.objects.bulk_create([
        model(channel=room, sender=owner, content=f"history {i}") for i in range(9)
    ])
    model.objects.filter(channel=room).update(created_at=STAMP)
    rows = list(model.objects.filter(channel=room).order_by("id"))
    client = APIClient()
    client.force_authenticate(owner)
    path = f"/api/v1/{request.param}/channels/{room.pk}/{suffix}/"
    return client, path, room, model, rows


def test_history_equal_timestamp_pages_and_sql_bound(history):
    client, path, _, model, rows = history
    collected = []
    query = {"pagination": "cursor", "limit": 2}
    for _ in range(6):
        with CaptureQueriesContext(connection) as queries:
            response = client.get(path, query)
        assert response.status_code == 200, response.data
        data = response.json()
        assert data["total"] == 9
        assert len(data["results"]) <= 2
        selected = [q["sql"] for q in queries if model._meta.db_table in q["sql"]
                    and "COUNT(" not in q["sql"] and q["sql"].startswith("SELECT")]
        assert selected and all("LIMIT 3" in sql for sql in selected)
        ids = [int(row["id"]) for row in data["results"]]
        assert ids == sorted(ids)
        collected = ids + collected
        if not data["has_more"]:
            assert data["next_cursor"] is None
            break
        query["cursor"] = data["next_cursor"]
    assert collected == [row.pk for row in rows]


@pytest.mark.parametrize("query", [
    {"limit": 0}, {"limit": 101}, {"limit": "２"}, {"limit": "1.5"},
    {"cursor": "invalid"}, {"cursor": ""}, {"before_id": 0},
    {"limit": ["2", "3"]}, {"pagination": "offset"},
])
def test_history_rejects_bad_page_parameters(history, query):
    client, path, *_ = history
    assert client.get(path, {"pagination": "cursor", **query}).status_code == 400


def test_history_cursor_binds_user_channel_and_rechecks_visibility(history, user_factory):
    client, path, room, model, _ = history
    cursor = client.get(path, {"pagination": "cursor", "limit": 2}).json()["next_cursor"]
    other = user_factory()
    client.force_authenticate(other)
    assert client.get(path, {"cursor": cursor}).status_code == 400
    client.force_authenticate(room.owner)
    if model is VoiceChatMessage:
        other_room = VoiceChannel.objects.create(owner=room.owner, name="other", room_name="other-history")
    else:
        other_room = LiveChannel.objects.create(owner=room.owner, title="other", stream_key="other-history")
    other_path = path.replace(f"/{room.pk}/", f"/{other_room.pk}/")
    assert client.get(other_path, {"cursor": cursor}).status_code == 400
    room.visibility = "group"
    room.save(update_fields=["visibility"])
    client.force_authenticate(other)
    assert client.get(path, {"cursor": cursor}).status_code == 403


def test_history_anchor_resumes_trimmed_window_without_gaps(history):
    client, path, room, model, rows = history
    response = client.get(path, {"pagination": "cursor", "before_id": rows[5].pk, "limit": 2})
    data = response.json()
    assert [int(row["id"]) for row in data["results"]] == [rows[3].pk, rows[4].pk]
    anchor_only = client.get(path, {"before_id": rows[5].pk, "limit": 2}).json()
    assert anchor_only["results"] == data["results"]
    assert client.get(path, {"cursor": data["next_cursor"], "before_id": rows[5].pk}).status_code == 400
    model.objects.filter(pk=rows[5].pk).delete()
    assert client.get(path, {"pagination": "cursor", "before_id": rows[5].pk}).status_code == 400
    model.objects.filter(channel=room).delete()
    empty = client.get(path, {"pagination": "cursor"}).json()
    assert empty == {"results": [], "total": 0, "next_cursor": None, "has_more": False}


def test_game_member_preview_does_not_define_total_or_requester_membership(user_factory):
    owner = user_factory()
    room = GameRoom.objects.create(owner=owner, name="many members")
    users = [owner] + [user_factory() for _ in range(22)]
    GameRoomMember.objects.bulk_create([
        GameRoomMember(room=room, user=user, seat=i // 2) for i, user in enumerate(users)
    ])
    members = list(room.members.order_by("seat", "id"))
    client = APIClient()
    client.force_authenticate(users[-1])
    data = client.get(f"/api/v1/boardgame/rooms/{room.pk}/").json()
    assert len(data["members"]) == 20
    assert data["members_has_more"] is True
    assert data["member_count"] == 23
    assert data["is_member"] is True
    assert str(users[-1].pk) not in [row["user_id"] for row in data["members"]]
    path = f"/api/v1/boardgame/rooms/{room.pk}/members/"
    page = client.get(path, {"limit": 20}).json()
    assert len(page["results"]) == 20 and page["total"] == 23
    last = client.get(path, {"cursor": page["next_cursor"], "limit": 20}).json()
    ids = [int(row["id"]) for row in page["results"] + last["results"]]
    assert ids == [member.pk for member in members]
    assert last["has_more"] is False


def test_voice_member_pages_do_not_limit_total_and_bind_room_and_user(user_factory):
    owner = user_factory()
    room = VoiceChannel.objects.create(owner=owner, name="members", room_name="paged-members")
    people = [owner] + [user_factory() for _ in range(21)]
    VoiceChannelMember.objects.bulk_create([VoiceChannelMember(channel=room, user=user) for user in people])
    VoiceChannelMember.objects.filter(channel=room).update(joined_at=STAMP)
    client = APIClient()
    client.force_authenticate(owner)
    path = f"/api/v1/voice/channels/{room.pk}/members/"
    with CaptureQueriesContext(connection) as queries:
        first = client.get(path, {"pagination": "cursor", "limit": 20}).json()
    assert first["total"] == 22 and len(first["results"]) == 20
    member_selects = [q["sql"] for q in queries if "voice_channel_members" in q["sql"]
                      and "COUNT(" not in q["sql"] and q["sql"].startswith("SELECT")]
    assert member_selects and all("LIMIT 21" in sql for sql in member_selects)
    second = client.get(path, {"cursor": first["next_cursor"], "limit": 20}).json()
    assert second["has_more"] is False
    assert [row["user_id"] for row in first["results"] + second["results"]] == [str(user.pk) for user in people]
    client.force_authenticate(people[-1])
    assert client.get(path, {"cursor": first["next_cursor"]}).status_code == 400
