"""Emoji catalogs, item reads, group permissions and flattened search pages."""
from datetime import datetime, timezone

import pytest
from django.db import connection
from django.test.utils import CaptureQueriesContext
from rest_framework.test import APIClient

from apps.chat.models import Conversation, ConversationMember
from apps.emoji.models import EmojiItem, EmojiPack
from apps.media.models import MediaObject

pytestmark = pytest.mark.django_db


@pytest.fixture
def setup(user_factory):
    owner, stranger = user_factory(), user_factory()
    client = APIClient()
    client.force_authenticate(owner)
    stamp = datetime(2026, 9, 8, tzinfo=timezone.utc)
    packs = [EmojiPack.objects.create(owner=owner, name=f"personal {i}") for i in range(3)]
    packs += [EmojiPack.objects.create(is_system=True, name=f"system {i}") for i in range(2)]
    hidden = EmojiPack.objects.create(owner=stranger, name="private")
    for pack in packs + [hidden]:
        for index in range(4):
            media = MediaObject.objects.create(owner=owner, media_id=f"page-{pack.pk}-{index}", kind="emoji", status="ready")
            EmojiItem.objects.create(pack=pack, media=media, tag="match" if index % 2 == 0 else "other")
    EmojiPack.objects.all().update(created_at=stamp)
    EmojiItem.objects.all().update(created_at=stamp)
    return owner, stranger, client, packs, hidden


def test_pack_catalog_is_bounded_and_does_not_embed_items(setup):
    _, _, client, packs, _ = setup
    response = client.get("/api/v1/emoji/packs/", {"pagination": "cursor", "limit": 2})
    first = response.json()
    assert first["total"] == 5 and len(first["results"]) == 2
    assert all(row["is_system"] and row["item_count"] == 4 and "items" not in row for row in first["results"])
    collected = first["results"]
    cursor = first["next_cursor"]
    while cursor:
        body = client.get("/api/v1/emoji/packs/", {"cursor": cursor, "limit": 2}).json()
        collected += body["results"]
        cursor = body["next_cursor"]
    assert [int(row["id"]) for row in collected] == [pack.pk for pack in packs[:2:-1] + packs[2::-1]]
    default = client.get("/api/v1/emoji/packs/", {"pagination": "cursor"}).json()
    assert len(default["results"]) == 5 and default["total"] == 5
    for params in ({"pagination": "offset"}, {"pagination": ["cursor", "cursor"]}, {"before_id": 1}):
        assert client.get("/api/v1/emoji/packs/", params).status_code == 400


def test_item_pages_recheck_visibility_and_sql_limit(setup):
    _, stranger, client, packs, hidden = setup
    path = f"/api/v1/emoji/packs/{packs[0].pk}/items/"
    with CaptureQueriesContext(connection) as queries:
        first = client.get(path, {"pagination": "cursor", "limit": 2}).json()
    item_selects = [q["sql"] for q in queries if "emoji_items" in q["sql"] and "COUNT(" not in q["sql"] and q["sql"].startswith("SELECT")]
    assert item_selects and all("LIMIT 3" in sql for sql in item_selects)
    assert first["total"] == 4 and len(first["results"]) == 2
    second = client.get(path, {"cursor": first["next_cursor"], "limit": 2}).json()
    assert second["has_more"] is False
    assert len({row["id"] for row in first["results"] + second["results"]}) == 4
    assert client.get(f"/api/v1/emoji/packs/{hidden.pk}/items/", {"pagination": "cursor"}).status_code == 403
    client.force_authenticate(stranger)
    assert client.get(path, {"cursor": first["next_cursor"]}).status_code == 403


def test_search_pages_all_visible_hits_and_binds_keyword(setup):
    _, _, client, _, _ = setup
    path = "/api/v1/emoji/search/?pagination=cursor&limit=3"
    first = client.post(path, {"keyword": "match"}, format="json").json()
    assert first["total"] == 10 and len(first["results"]) == 3
    assert all("pack_id" in row and "hits" not in row for row in first["results"])
    cursor = first["next_cursor"]
    response = client.post(f"{path}&cursor={cursor}", {"keyword": "other"}, format="json")
    assert response.status_code == 400
    hits = first["results"]
    while cursor:
        data = client.post(f"{path}&cursor={cursor}", {"keyword": "match"}, format="json").json()
        hits += data["results"]
        cursor = data["next_cursor"]
    assert len({row["id"] for row in hits}) == 10
    empty = client.post(path, {"keyword": "absent"}, format="json").json()
    assert empty == {"results": [], "total": 0, "next_cursor": None, "has_more": False}


def test_group_summary_has_no_items_and_each_page_rechecks_membership(setup):
    owner, stranger, client, packs, _ = setup
    group = Conversation.objects.create(type="group", title="emoji", owner=owner)
    membership = ConversationMember.objects.create(conversation=group, user=owner, role="owner")
    pack = packs[0]
    pack.owner = None
    pack.group = group
    pack.save(update_fields=["owner", "group"])
    summary = client.get(f"/api/v1/emoji/groups/{group.pk}/pack/", {"summary": 1}).json()
    assert "items" not in summary["pack"] and summary["pack"]["item_count"] == 4
    assert summary["can_upload"] is True and summary["can_delete"] is True
    policy = client.patch(f"/api/v1/emoji/groups/{group.pk}/pack/?summary=1", {"allow_member_upload": True}, format="json").json()
    assert "items" not in policy["pack"] and policy["allow_member_upload"] is True
    path = f"/api/v1/emoji/groups/{group.pk}/pack/items/"
    first = client.get(path, {"limit": 2}).json()
    second = client.get(path, {"cursor": first["next_cursor"], "limit": 2}).json()
    assert len(first["results"]) == len(second["results"]) == 2
    assert first["total"] == second["total"] == 4
    membership.delete()
    assert client.get(path, {"cursor": first["next_cursor"]}).status_code == 403
    client.force_authenticate(stranger)
    assert client.get(path, {"limit": 2}).status_code == 403
