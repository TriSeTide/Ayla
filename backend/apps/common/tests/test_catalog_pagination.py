"""Room catalog pages preserve visibility, global order and bounded SQL reads."""
from datetime import datetime, timedelta, timezone
from itertools import count

import pytest
from django.db import connection
from django.test.utils import CaptureQueriesContext
from rest_framework.test import APIClient

from apps.boardgame.models import GameRoom, GameRoomMember
from apps.chat.models import Conversation, ConversationMember
from apps.live.models import LiveChannel
from apps.voice.models import VoiceChannel, VoiceChannelMember

pytestmark = pytest.mark.django_db
BASE_TIME = datetime(2026, 9, 1, 12, tzinfo=timezone.utc)
CATALOGS = {
    "voice": (VoiceChannel, "/api/v1/voice/channels/"),
    "live": (LiveChannel, "/api/v1/live/channels/"),
    "boardgame": (GameRoom, "/api/v1/boardgame/rooms/"),
}


@pytest.fixture(params=tuple(CATALOGS))
def catalog(request, user_factory):
    kind = request.param
    model, path = CATALOGS[kind]
    owner = user_factory()
    sequence = count(1)

    def create(**fields):
        index = next(sequence)
        created_at = fields.pop("created_at", BASE_TIME)
        fields.setdefault("owner", owner)
        if kind == "voice":
            fields.setdefault("name", f"语音 {index}")
            fields.setdefault("room_name", f"catalog-test-room-{index}")
        elif kind == "live":
            fields.setdefault("title", f"直播 {index}")
            fields.setdefault("stream_key", f"catalog-test-stream-{index}")
        else:
            fields.setdefault("name", f"桌游 {index}")
        row = model.objects.create(**fields)
        model.objects.filter(pk=row.pk).update(created_at=created_at)
        row.refresh_from_db()
        return row

    client = APIClient()
    client.force_authenticate(owner)
    return kind, model, path, owner, client, create


def _ids(rows):
    return [int(row["id"]) for row in rows]


def _read_all(client, path, **params):
    rows = []
    totals = []
    for _ in range(20):
        response = client.get(path, params)
        assert response.status_code == 200, response.data
        body = response.json()
        rows.extend(body["results"])
        totals.append(body["total"])
        assert len(body["results"]) <= int(params.get("limit", 20))
        if not body["has_more"]:
            assert body["next_cursor"] is None
            return rows, totals
        assert body["next_cursor"]
        params["cursor"] = body["next_cursor"]
    pytest.fail("pagination did not terminate")


def test_legacy_requests_still_return_complete_arrays(catalog):
    kind, _, path, _, client, create = catalog
    rows = [create(created_at=BASE_TIME + timedelta(minutes=i)) for i in range(4)]
    response = client.get(path)
    assert response.status_code == 200
    assert isinstance(response.json(), list)
    expected = rows if kind == "voice" else rows[::-1]
    assert _ids(response.json()) == [row.pk for row in expected]


def test_equal_timestamps_page_without_duplicates_and_keep_total(catalog):
    _, _, path, _, client, create = catalog
    rows = [create() for _ in range(7)]
    data, totals = _read_all(client, path, limit=2)
    assert _ids(data) == [row.pk for row in reversed(rows)]
    assert len(set(_ids(data))) == 7
    assert totals == [7, 7, 7, 7]


def test_database_select_is_limited_before_serializing(catalog):
    _, model, path, _, client, create = catalog
    for _ in range(8):
        create()
    with CaptureQueriesContext(connection) as captured:
        response = client.get(path, {"limit": 2})
    assert response.status_code == 200
    assert len(response.data["results"]) == 2
    catalog_reads = [
        query["sql"].upper()
        for query in captured.captured_queries
        if f'FROM {connection.ops.quote_name(model._meta.db_table)}' in query["sql"]
        and "COUNT(" not in query["sql"].upper()
    ]
    assert catalog_reads
    assert all("LIMIT 3" in sql for sql in catalog_reads), catalog_reads


def test_head_insert_and_row_deletion_do_not_shift_cursor_pages(catalog):
    _, model, path, _, client, create = catalog
    rows = [create(created_at=BASE_TIME - timedelta(minutes=i)) for i in range(6)]
    first = client.get(path, {"limit": 2}).json()
    assert _ids(first["results"]) == [rows[0].pk, rows[1].pk]
    new_head = create(created_at=BASE_TIME + timedelta(minutes=1))
    model.objects.filter(pk__in=[rows[0].pk, rows[2].pk]).delete()
    remainder, totals = _read_all(client, path, limit=2, cursor=first["next_cursor"])
    assert _ids(remainder) == [row.pk for row in rows[3:]]
    assert totals == [5, 5]
    refreshed = client.get(path, {"limit": 2}).json()
    assert int(refreshed["results"][0]["id"]) == new_head.pk


def test_group_alias_filters_before_pagination_and_preserves_visibility(catalog, user_factory):
    _, _, path, owner, _, create = catalog
    viewer = user_factory()
    group = Conversation.objects.create(type="group", title="可见群", owner=owner)
    other_group = Conversation.objects.create(type="group", title="另一群", owner=owner)
    ConversationMember.objects.create(conversation=group, user=viewer)
    public = create(visibility="public")
    public.allowed_groups.add(group, other_group)
    restricted = create(visibility="group")
    restricted.allowed_groups.add(group)
    hidden = create(visibility="group")
    hidden.allowed_groups.add(other_group)
    create(group=group, visibility="group")  # FK alone never grants access.
    create(visibility="friends")
    create(visibility="public")  # Visible, but outside the selected group.
    client = APIClient()
    client.force_authenticate(viewer)
    rows, totals = _read_all(client, path, group_id=group.pk, limit=1)
    assert set(_ids(rows)) == {public.pk, restricted.pk}
    assert len(rows) == 2
    assert totals == [2, 2]
    equivalent, _ = _read_all(client, path, scope=f"group:{group.pk}", limit=1)
    assert _ids(equivalent) == _ids(rows)
    # The group-scoped feed retains existing public visibility even for non-members.
    other, _ = _read_all(client, path, group_id=other_group.pk, limit=1)
    assert _ids(other) == [public.pk]
    if catalog[0] == "live":
        assert all(row["stream_key"] is None and row["rtmp_url"] is None for row in rows)


def test_access_is_rechecked_after_a_cursor_was_issued(catalog, user_factory):
    _, _, path, owner, _, create = catalog
    viewer = user_factory()
    group = Conversation.objects.create(type="group", title="临时群", owner=owner)
    membership = ConversationMember.objects.create(conversation=group, user=viewer)
    for _ in range(4):
        row = create(visibility="group")
        row.allowed_groups.add(group)
    client = APIClient()
    client.force_authenticate(viewer)
    first = client.get(path, {"limit": 1, "group_id": group.pk}).json()
    membership.delete()
    response = client.get(path, {
        "limit": 1, "group_id": group.pk, "cursor": first["next_cursor"],
    })
    assert response.status_code == 200
    assert response.data["results"] == []
    assert response.data["has_more"] is False
    assert response.data["next_cursor"] is None
    assert response.data["total"] == 0
    if catalog[0] == "voice":
        assert response.data["total_member_count"] == 0


def test_cursor_is_bound_to_resource_user_and_filters(catalog, user_factory):
    kind, _, path, _, client, create = catalog
    for _ in range(3):
        create()
    cursor = client.get(path, {"limit": 1}).json()["next_cursor"]
    assert client.get(path, {"limit": 1, "cursor": cursor, "group_id": 999}).status_code == 400
    other_path = CATALOGS["live" if kind != "live" else "voice"][1]
    assert client.get(other_path, {"limit": 1, "cursor": cursor}).status_code == 400
    client.force_authenticate(user_factory())
    assert client.get(path, {"limit": 1, "cursor": cursor}).status_code == 400


@pytest.mark.parametrize("limit", ["", "0", "-1", "101", "bad", "1.5", "1e2", "9999999999"])
def test_invalid_limits_are_diagnostic_400(catalog, limit):
    _, _, path, _, client, _ = catalog
    response = client.get(path, {"limit": limit})
    assert response.status_code == 400
    assert "limit" in response.data["detail"]


@pytest.mark.parametrize("cursor", ["", "bad", "not:a:valid:cursor"])
def test_invalid_cursors_are_not_silent_first_pages(catalog, cursor):
    _, _, path, _, client, _ = catalog
    response = client.get(path, {"cursor": cursor})
    assert response.status_code == 400
    assert "cursor" in response.data["detail"]


def test_repeated_params_and_invalid_group_alias_are_rejected(catalog):
    _, _, path, _, client, _ = catalog
    assert client.get(path + "?limit=1&limit=2").status_code == 400
    assert client.get(path, {"limit": 1, "group_id": "bad"}).status_code == 400
    assert client.get(path, {"limit": 1, "group_id": "0"}).status_code == 400
    assert client.get(path, {"limit": 1, "group_id": 2, "scope": "group:3"}).status_code == 400


def test_activity_rank_and_time_are_global_across_pages(catalog):
    kind, _, path, owner, client, create = catalog
    if kind == "boardgame":
        pytest.skip("Game rooms use creation order, covered by the cursor tests.")
    if kind == "voice":
        active_old = create(last_occupied_at=BASE_TIME)
        active_new = create(last_occupied_at=BASE_TIME + timedelta(hours=1))
        active_null = create()
        for row in (active_old, active_new, active_null):
            VoiceChannelMember.objects.create(channel=row, user=owner)
        past_old = create(last_occupied_at=BASE_TIME, last_vacant_at=BASE_TIME)
        past_new = create(last_vacant_at=BASE_TIME + timedelta(hours=2))
        past_null = create(last_occupied_at=BASE_TIME)
    else:
        active_old = create(status="live", started_at=BASE_TIME)
        active_new = create(status="live", started_at=BASE_TIME + timedelta(hours=1))
        active_null = create(status="live")
        past_old = create(started_at=BASE_TIME, ended_at=BASE_TIME)
        past_new = create(started_at=BASE_TIME, ended_at=BASE_TIME + timedelta(hours=2))
        past_null = create(started_at=BASE_TIME)
    never_old = create(created_at=BASE_TIME + timedelta(days=1))
    never_new = create(created_at=BASE_TIME + timedelta(days=2))
    rows, totals = _read_all(client, path, limit=2)
    assert _ids(rows) == [row.pk for row in (
        active_new, active_old, active_null, past_new, past_old, past_null, never_new, never_old,
    )]
    assert totals == [8, 8, 8, 8]
    if kind == "voice":
        assert all(row["member_count"] == 1 and row["mine"] for row in rows[:3])
        assert all(row["member_count"] == 0 and not row["mine"] for row in rows[3:])


def test_domain_filters_keep_complete_totals(catalog, user_factory):
    kind, _, path, owner, client, create = catalog
    if kind == "voice":
        pytest.skip("Voice only accepts the shared group scope.")
    other_owner = user_factory()
    if kind == "live":
        selected = [create(status="live") for _ in range(3)]
        create(status="idle")
        create(status="live", owner=other_owner)
        params = {"only_live": "1", "owner": owner.pk}
    else:
        selected = [create() for _ in range(3)]
        for room in selected:
            GameRoomMember.objects.create(room=room, user=owner)
        create()
        foreign = create(owner=other_owner)
        GameRoomMember.objects.create(room=foreign, user=owner)
        params = {"mine": "1", "owner": owner.pk}
    rows, totals = _read_all(client, path, limit=2, **params)
    assert set(_ids(rows)) == {row.pk for row in selected}
    assert totals == [3, 3]
    missing_owner = client.get(path, {"limit": 1, "owner": "nonexistent-user-id"})
    assert missing_owner.status_code == 200
    assert missing_owner.data["results"] == []
    assert missing_owner.data["total"] == 0


def test_voice_member_total_counts_the_full_filtered_directory(user_factory):
    owner = user_factory()
    group = Conversation.objects.create(type="group", title="人数统计群", owner=owner)
    for index in range(4):
        channel = VoiceChannel.objects.create(
            owner=owner, name=f"语音{index}", room_name=f"member-total-{index}",
        )
        VoiceChannelMember.objects.create(channel=channel, user=owner)
        if index < 3:
            channel.allowed_groups.add(group)
    client = APIClient()
    client.force_authenticate(owner)
    response = client.get(CATALOGS["voice"][1], {"limit": 1, "group_id": group.pk})
    assert response.status_code == 200
    assert len(response.data["results"]) == 1
    assert response.data["results"][0]["member_count"] == 1
    assert response.data["total"] == 3
    assert response.data["total_member_count"] == 3
