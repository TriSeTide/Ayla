"""Favorite cursor pages retain ownership, legacy arrays and live target access."""
from datetime import datetime, timezone

import pytest
from django.db import connection
from django.test.utils import CaptureQueriesContext

from apps.common.visibility import Visibility
from apps.favorites.models import Favorite
from apps.posts.models import Post

URL = "/api/v1/favorites/"


def bookmarks(user, count, *, owner=None):
    rows = []
    for index in range(count):
        post = Post.objects.create(owner=owner or user, body=f"收藏正文 {index}")
        rows.append(Favorite.objects.create(user=user, target_type="post", target_id=str(post.pk)))
    Favorite.objects.filter(pk__in=[row.pk for row in rows]).update(
        created_at=datetime(2026, 1, 1, tzinfo=timezone.utc),
    )
    return rows


@pytest.mark.django_db
class TestFavoriteCursor:
    def test_legacy_array_and_sql_bounded_complete_walk(self, auth_client):
        client, user = auth_client(username="fav_pages")
        rows = bookmarks(user, 5)
        legacy = client.get(URL)
        assert isinstance(legacy.json(), list)
        assert len(legacy.json()) == 5
        with CaptureQueriesContext(connection) as queries:
            response = client.get(URL, {"limit": 2})
        assert response.status_code == 200
        page = response.json()
        assert page["total"] == 5
        assert page["has_more"] is True
        assert any(f"FROM {connection.ops.quote_name('favorites')}" in query["sql"]
                   and "LIMIT 3" in query["sql"] for query in queries)
        seen = [item["id"] for item in page["results"]]
        while page["has_more"]:
            response = client.get(URL, {"limit": 2, "cursor": page["next_cursor"]})
            assert response.status_code == 200
            page = response.json()
            seen.extend(item["id"] for item in page["results"])
        assert seen == [row.pk for row in reversed(rows)]
        assert page["next_cursor"] is None

    def test_cursor_bound_to_user_and_type(self, auth_client):
        client, user = auth_client(username="fav_bound")
        bookmarks(user, 3)
        cursor = client.get(URL, {"limit": 1, "type": "post"}).json()["next_cursor"]
        other, _ = auth_client(username="fav_other")
        assert other.get(URL, {"limit": 1, "type": "post", "cursor": cursor}).status_code == 400
        assert client.get(URL, {"limit": 1, "cursor": cursor}).status_code == 400
        assert client.get(URL, {"limit": 1, "type": "live", "cursor": cursor}).status_code == 400

    def test_insert_and_delete_do_not_shift_cursor_or_restore_deleted_row(self, auth_client):
        client, user = auth_client(username="fav_changes")
        rows = bookmarks(user, 5)
        first = client.get(URL, {"limit": 2}).json()
        rows[2].delete()
        new_post = Post.objects.create(owner=user, body="后来新增")
        newer = Favorite.objects.create(user=user, target_type="post", target_id=str(new_post.pk))
        second = client.get(URL, {"limit": 2, "cursor": first["next_cursor"]}).json()
        assert [row["id"] for row in second["results"]] == [rows[1].pk, rows[0].pk]
        assert newer.pk not in [row["id"] for row in second["results"]]
        assert second["has_more"] is False

    @pytest.mark.parametrize("params", [
        {"limit": 0}, {"limit": 101}, {"limit": "x"}, {"cursor": ""},
        {"cursor": "tampered"}, {"limit": [1, 2]},
    ])
    def test_invalid_page_parameters_are_400(self, auth_client, params):
        client, _ = auth_client(username="fav_invalid")
        assert client.get(URL, params).status_code == 400

    def test_access_revoked_target_is_null_but_bookmark_survives(self, auth_client, user_factory):
        client, user = auth_client(username="fav_private")
        owner = user_factory(username="fav_owner")
        row = bookmarks(user, 1, owner=owner)[0]
        assert client.get(URL, {"limit": 20}).json()["results"][0]["target"] is not None
        Post.objects.filter(pk=row.target_id).update(visibility=Visibility.FRIENDS)
        for params in ({}, {"limit": 20}):
            response = client.get(URL, params)
            data = response.json()
            item = data[0] if isinstance(data, list) else data["results"][0]
            assert item["id"] == row.pk
            assert item["target"] is None
        assert Favorite.objects.filter(pk=row.pk).exists()
