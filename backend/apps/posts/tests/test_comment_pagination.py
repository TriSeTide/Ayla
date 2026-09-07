"""Chronological comment pages retain permissions, provenance and old arrays."""
import pytest
from django.db import connection
from django.test.utils import CaptureQueriesContext
from django.utils import timezone

from apps.posts.models import Comment, Post


@pytest.mark.django_db
def test_comment_pages_traverse_timestamp_ties_with_sql_limit(auth_client):
    client, author = auth_client(username="comment_page_author")
    post = Post.objects.create(owner=author, body="post", visibility="public")
    comments = [Comment.objects.create(post=post, author=author, body=str(i)) for i in range(7)]
    Comment.objects.filter(post=post).update(created_at=timezone.now())
    url = f"/api/v1/posts/{post.id}/comments/"
    assert len(client.get(url).json()) == 7
    result_ids = []
    cursor = None
    while True:
        params = {"limit": 2}
        if cursor:
            params["cursor"] = cursor
        with CaptureQueriesContext(connection) as queries:
            response = client.get(url, params)
        assert response.status_code == 200
        page = response.json()
        assert page["total"] == 7
        result_ids.extend(item["id"] for item in page["results"])
        sql = [query["sql"] for query in queries.captured_queries if "LIMIT 3" in query["sql"] and connection.ops.quote_name("post_comments") in query["sql"]]
        assert sql
        if not page["has_more"]:
            assert page["next_cursor"] is None
            break
        cursor = page["next_cursor"]
    assert result_ids == [comment.id for comment in comments]


@pytest.mark.django_db
def test_comment_cursor_binds_post_and_reader_and_rechecks_permission(auth_client):
    client, owner = auth_client(username="comment_owner")
    reader, _ = auth_client(username="comment_reader")
    post = Post.objects.create(owner=owner, body="post", visibility="public")
    other = Post.objects.create(owner=owner, body="other", visibility="public")
    for i in range(3):
        Comment.objects.create(post=post, author=owner, body=str(i))
    url = f"/api/v1/posts/{post.id}/comments/"
    cursor = reader.get(url, {"limit": 1}).json()["next_cursor"]
    assert client.get(url, {"cursor": cursor}).status_code == 400
    assert reader.get(f"/api/v1/posts/{other.id}/comments/", {"cursor": cursor}).status_code == 400
    post.visibility = "friends"
    post.save(update_fields=["visibility"])
    assert reader.get(url, {"cursor": cursor}).status_code == 403


@pytest.mark.django_db
def test_comment_delete_and_new_comment_preserve_the_next_boundary(auth_client):
    client, author = auth_client(username="comment_boundary")
    post = Post.objects.create(owner=author, body="post")
    comments = [Comment.objects.create(post=post, author=author, body=str(i)) for i in range(4)]
    url = f"/api/v1/posts/{post.id}/comments/"
    cursor = client.get(url, {"limit": 2}).json()["next_cursor"]
    comments[0].delete()
    new = Comment.objects.create(post=post, author=author, body="new")
    page = client.get(url, {"limit": 10, "cursor": cursor}).json()
    assert [item["id"] for item in page["results"]] == [comments[2].id, comments[3].id, new.id]
    assert page["total"] == 4


@pytest.mark.django_db
@pytest.mark.parametrize("query", ["limit=0", "limit=101", "limit=abc", "limit=2&limit=3", "cursor=", "cursor=bad", "cursor=a&cursor=b"])
def test_comment_page_rejects_bad_boundaries(auth_client, query):
    client, author = auth_client()
    post = Post.objects.create(owner=author, body="post")
    assert client.get(f"/api/v1/posts/{post.id}/comments/?{query}").status_code == 400
