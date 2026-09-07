"""Aggregate search cursors paginate each visible result group independently."""
from datetime import datetime, timezone

import pytest
from django.contrib.auth import get_user_model
from django.db import connection
from django.test.utils import CaptureQueriesContext

from apps.boardgame.models import GameRoom
from apps.chat.models import Conversation, ConversationMember
from apps.common.visibility import Visibility
from apps.live.models import LiveChannel
from apps.posts.models import Post

URL = "/api/v1/search/"
TIME = datetime(2026, 1, 1, tzinfo=timezone.utc)
KINDS = {"user": "users", "group": "groups", "post": "posts", "live": "lives", "game": "games"}


def make_rows(kind, owner, user_factory, count=5):
    if kind == "user":
        rows = [user_factory(username=f"cursor_find_{index}") for index in range(count)]
        get_user_model().objects.filter(pk__in=[row.pk for row in rows]).update(date_joined=TIME)
        return rows
    models = {"group": Conversation, "post": Post, "live": LiveChannel, "game": GameRoom}
    fields = {
        "group": {"type": "group", "title": "cursor_find"},
        "post": {"body": "cursor_find", "visibility": Visibility.PUBLIC},
        "live": {"title": "cursor_find", "visibility": Visibility.PUBLIC},
        "game": {"name": "cursor_find", "visibility": Visibility.PUBLIC},
    }
    rows = [models[kind].objects.create(owner=owner, **fields[kind], **(
        {"stream_key": f"cursor-stream-{index}"} if kind == "live" else {}
    )) for index in range(count)]
    models[kind].objects.filter(pk__in=[row.pk for row in rows]).update(created_at=TIME)
    return rows


@pytest.mark.django_db
class TestSearchCursor:
    def test_membership_is_for_current_user_and_independent_of_directory_pages(self, auth_client, user_factory):
        client, viewer = auth_client(username="search_member_viewer")
        owner = user_factory(username="search_member_owner")
        group = Conversation.objects.create(owner=owner, type="group", title="cursor_find joined")
        ConversationMember.objects.create(conversation=group, user=viewer)
        params = {"q": "cursor_find", "types": "group", "pagination": "cursor", "limit": 3}
        assert client.get(URL, params).json()["groups"]["items"][0]["is_member"] is True
        other, _ = auth_client(username="search_member_other")
        assert other.get(URL, params).json()["groups"]["items"][0]["is_member"] is False

    @pytest.mark.parametrize("kind", list(KINDS))
    def test_all_rows_once_for_equal_timestamps(self, auth_client, user_factory, kind):
        client, user = auth_client(username="search_pages")
        rows = make_rows(kind, user, user_factory)
        params = {"q": "cursor_find", "types": kind, "pagination": "cursor", "limit": 2}
        seen = []
        while True:
            response = client.get(URL, params)
            assert response.status_code == 200, response.content
            page = response.json()[KINDS[kind]]
            assert page["total"] == 5
            seen.extend(str(item["id"]) for item in page["items"])
            if not page["has_more"]:
                assert page["next_cursor"] is None
                break
            params["cursor"] = page["next_cursor"]
        expected = [str(row.pk) for row in sorted(rows, key=lambda row: row.pk, reverse=True)]
        assert seen == expected

    def test_aggregate_first_page_has_independent_cursors_and_legacy_is_unchanged(self, auth_client, user_factory):
        client, user = auth_client(username="search_aggregate_pages")
        for kind in KINDS:
            make_rows(kind, user, user_factory, 3)
        legacy = client.get(URL, {"q": "cursor_find", "limit": 2}).json()
        assert all(set(group) == {"items", "total"} for group in legacy.values())
        first = client.get(URL, {"q": "cursor_find", "pagination": "cursor", "limit": 2}).json()
        assert all(group["has_more"] and len(group["items"]) == 2 for group in first.values())
        assert len({group["next_cursor"] for group in first.values()}) == 5

    def test_cursor_binding_and_malformed_values_fail_explicitly(self, auth_client, user_factory):
        client, user = auth_client(username="search_bound")
        make_rows("post", user, user_factory, 3)
        params = {"q": "cursor_find", "types": "post", "pagination": "cursor", "limit": 1}
        cursor = client.get(URL, params).json()["posts"]["next_cursor"]
        other, _ = auth_client(username="search_bound_other")
        assert other.get(URL, {**params, "cursor": cursor}).status_code == 400
        for override in ({"q": "different"}, {"types": "group"}, {"types": "post,group"},
                         {"pagination": "unknown"}, {"cursor": ""}, {"cursor": "bad"},
                         {"limit": 0}, {"limit": 51}, {"limit": "x"}, {"limit": [1, 2]}):
            assert client.get(URL, {**params, "cursor": cursor, **override}).status_code == 400

    def test_next_page_rechecks_visibility_and_uses_sql_limit(self, auth_client, user_factory):
        client, viewer = auth_client(username="search_live_acl")
        owner = user_factory(username="search_acl_owner")
        rows = make_rows("post", owner, user_factory, 5)
        params = {"q": "cursor_find", "types": "post", "pagination": "cursor", "limit": 2}
        first = client.get(URL, params).json()["posts"]
        Post.objects.filter(pk=rows[2].pk).update(visibility=Visibility.FRIENDS)
        rows[1].delete()
        Post.objects.create(owner=owner, body="cursor_find 新增", visibility=Visibility.PUBLIC)
        with CaptureQueriesContext(connection) as queries:
            response = client.get(URL, {**params, "cursor": first["next_cursor"]})
        assert response.status_code == 200, response.content
        page = response.json()["posts"]
        assert [item["id"] for item in page["items"]] == [rows[0].pk]
        assert page["total"] == 4
        assert any(f"FROM {connection.ops.quote_name('posts')}" in query["sql"]
                   and "LIMIT 3" in query["sql"] for query in queries)
