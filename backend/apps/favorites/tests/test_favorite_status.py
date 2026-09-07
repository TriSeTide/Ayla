"""A bounded status lookup cannot enumerate bookmarks or reveal target content."""
import pytest
from rest_framework.test import APIClient

from apps.favorites.models import Favorite


@pytest.mark.django_db
def test_status_only_requested_owner_and_type(auth_client, user_factory):
    client, user = auth_client(username="status_owner")
    other = user_factory(username="status_other")
    favorite = Favorite.objects.create(user=user, target_type="post", target_id="1")
    Favorite.objects.create(user=user, target_type="post", target_id="2")
    Favorite.objects.create(user=other, target_type="post", target_id="3")
    Favorite.objects.create(user=user, target_type="live", target_id="3")
    response = client.post("/api/v1/favorites/status/", {
        "target_type": "post", "target_ids": ["1", "3", "1", "404"],
    }, format="json")
    assert response.status_code == 200
    assert response.json() == {"target_type": "post", "statuses": {
        "1": favorite.id, "3": None, "404": None,
    }}


@pytest.mark.django_db
@pytest.mark.parametrize("ids", [None, "1", list(range(101)), [True], [{}], [""], ["a" * 65]])
def test_status_rejects_unbounded_or_invalid_ids(auth_client, ids):
    client, _ = auth_client()
    response = client.post("/api/v1/favorites/status/", {
        "target_type": "post", "target_ids": ids,
    }, format="json")
    assert response.status_code == 400


@pytest.mark.django_db
def test_status_accepts_100_and_empty(auth_client):
    client, _ = auth_client()
    for ids in [[], [str(i) for i in range(100)]]:
        response = client.post("/api/v1/favorites/status/", {
            "target_type": "message", "target_ids": ids,
        }, format="json")
        assert response.status_code == 200
        assert response.json()["statuses"] == dict.fromkeys(ids)


@pytest.mark.django_db
def test_status_requires_login_and_known_type(auth_client):
    assert APIClient().post("/api/v1/favorites/status/", {
        "target_type": "post", "target_ids": ["1"],
    }, format="json").status_code in (401, 403)
    client, _ = auth_client()
    assert client.post("/api/v1/favorites/status/", {
        "target_type": "invalid", "target_ids": ["1"],
    }, format="json").status_code == 400
