"""Profile count is the complete visible owner subset, not the current page."""
import pytest

from apps.common.visibility import Visibility
from apps.posts.models import Post


@pytest.mark.django_db
def test_owner_total_remains_stable_across_pages_and_excludes_hidden_posts(auth_client, user_factory):
    client, viewer = auth_client(username="profile_total_viewer")
    owner = user_factory(username="profile_total_owner")
    visible = [Post.objects.create(owner=owner, body=f"row {index}", visibility=Visibility.PUBLIC) for index in range(23)]
    Post.objects.create(owner=owner, body="hidden", visibility=Visibility.FRIENDS)
    Post.objects.create(owner=viewer, body="viewer unrelated", visibility=Visibility.PUBLIC)
    first = client.get("/api/v1/posts/", {"owner": owner.id, "limit": 20})
    assert first.status_code == 200
    data = first.json()
    assert data["total"] == 23 and len(data["results"]) == 20 and data["has_more"]
    second = client.get("/api/v1/posts/", {"owner": owner.id, "limit": 20, "cursor": data["next_cursor"]})
    assert second.status_code == 200
    tail = second.json()
    assert tail["total"] == 23 and len(tail["results"]) == 3 and not tail["has_more"]
    assert {row["id"] for row in data["results"] + tail["results"]} == {post.id for post in visible}
