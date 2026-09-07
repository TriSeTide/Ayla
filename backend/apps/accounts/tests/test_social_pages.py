"""Social keyset contracts: scope, permission, ties and SQL bounds."""
from urllib.parse import urlencode

import pytest
from django.db import connection
from django.test.utils import CaptureQueriesContext
from django.utils import timezone

from apps.accounts.models import FriendRequest, Friendship


def page(client, path, **params):
    return client.get(path + "?" + urlencode({"pagination": "cursor", "limit": 2, **params}))


@pytest.mark.django_db
def test_user_search_continues_tied_dates_and_binds_query_actor(auth_client, user_factory):
    client, actor = auth_client(username="search_actor")
    others = [user_factory(username=f"needle_{index}") for index in range(5)]
    type(actor).objects.filter(pk__in=[user.pk for user in others]).update(date_joined=timezone.now())
    with CaptureQueriesContext(connection) as queries:
        first = page(client, "/api/v1/users/search/", q="needle").json()
    assert len(first["results"]) == 2 and first["total"] == 5 and first["has_more"]
    assert any("LIMIT 3" in query["sql"] for query in queries)
    second = page(client, "/api/v1/users/search/", q="needle", cursor=first["next_cursor"]).json()
    third = page(client, "/api/v1/users/search/", q="needle", cursor=second["next_cursor"]).json()
    ids = [item["id"] for batch in (first, second, third) for item in batch["results"]]
    assert len(ids) == len(set(ids)) == 5
    assert third["next_cursor"] is None and not third["has_more"]
    assert page(client, "/api/v1/users/search/", q="other", cursor=first["next_cursor"]).status_code == 400
    other_client, _ = auth_client(username="other_actor")
    assert page(other_client, "/api/v1/users/search/", q="needle", cursor=first["next_cursor"]).status_code == 400
    assert isinstance(client.get("/api/v1/users/search/?q=needle").json(), list)


@pytest.mark.django_db
@pytest.mark.parametrize("query", ["limit=0", "limit=101", "limit=-1", "limit=no", "cursor=broken", "limit=2&limit=3", "pagination=offset"])
def test_invalid_social_pages_fail(auth_client, query):
    client, _ = auth_client()
    suffix = query if query.startswith("pagination") else "pagination=cursor&" + query
    assert client.get("/api/v1/friends/?" + suffix).status_code == 400


@pytest.mark.django_db
def test_friend_requests_filter_before_page_and_recheck_current_rows(auth_client, user_factory):
    client, actor = auth_client(username="request_actor")
    people = [user_factory(username=f"request_person_{index}") for index in range(5)]
    requests = [FriendRequest.objects.create(from_user=user, to_user=actor) for user in people]
    FriendRequest.objects.create(from_user=actor, to_user=people[0])
    FriendRequest.objects.create(from_user=people[0], to_user=actor, status="accepted")
    first = page(client, "/api/v1/friends/requests/", direction="received", status="pending").json()
    assert first["total"] == 5 and len(first["results"]) == 2
    returned = {item["id"] for item in first["results"]}
    unseen = next(item for item in requests if item.id not in returned)
    unseen.status = "accepted"
    unseen.save(update_fields=["status"])
    second = page(client, "/api/v1/friends/requests/", direction="received", status="pending", cursor=first["next_cursor"]).json()
    assert second["total"] == 4
    assert unseen.id not in {item["id"] for item in second["results"]}
    assert page(client, "/api/v1/friends/requests/", direction="sent", status="pending", cursor=first["next_cursor"]).status_code == 400


@pytest.mark.django_db
def test_friend_pages_exclude_other_actors_and_preserve_legacy(auth_client, user_factory):
    client, actor = auth_client(username="friend_actor")
    other = user_factory(username="friend_other")
    people = [user_factory(username=f"friend_person_{index}") for index in range(4)]
    for person in people:
        Friendship.objects.create(user=actor, friend=person)
    Friendship.objects.create(user=other, friend=actor)
    first = page(client, "/api/v1/friends/").json()
    second = page(client, "/api/v1/friends/", cursor=first["next_cursor"]).json()
    assert first["total"] == 4
    assert len(first["results"]) + len(second["results"]) == 4
    assert len(client.get("/api/v1/friends/").json()) == 4
