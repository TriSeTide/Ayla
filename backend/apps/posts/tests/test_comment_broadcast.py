"""评论实时推送契约：comment.created / comment.deleted 的分发范围与载荷。

对齐帖子的可见性（与 post.created 同纪律）：公开帖进全局信息流组；
群/白名单帖进对应会话组；帖主本人在其用户组。
"""
import pytest

from apps.common.visibility import Visibility
from apps.posts import services
from apps.posts.models import Post


class _Layer:
    def __init__(self):
        self.calls = []

    async def group_send(self, group, event):
        self.calls.append((group, event))


@pytest.mark.django_db
def test_comment_created_public_goes_to_feed(monkeypatch, user_factory):
    layer = _Layer()
    monkeypatch.setattr("channels.layers.get_channel_layer", lambda: layer)
    author = user_factory(username="c_author")
    post = Post.objects.create(owner=author, body="帖子", visibility=Visibility.PUBLIC)

    services.broadcast_comment_created(
        post,
        {"id": 1, "body": "评论", "post_id": str(post.id), "author_id": str(author.id)},
        comment_count=1,
    )

    groups = {g for g, _ in layer.calls}
    assert services.POST_FEED_GROUP in groups
    event = dict(layer.calls)[services.POST_FEED_GROUP]
    assert event["type"] == "comment.created"
    assert event["data"]["post_id"] == str(post.id)
    assert event["data"]["comment_count"] == 1
    assert event["data"]["comment"]["id"] == 1
    # 帖主本人也能收到（作者用户组）
    assert f"chat_user_{author.id}" in groups


@pytest.mark.django_db
def test_comment_deleted_public_contains_id(monkeypatch, user_factory):
    layer = _Layer()
    monkeypatch.setattr("channels.layers.get_channel_layer", lambda: layer)
    author = user_factory(username="c_del")
    post = Post.objects.create(owner=author, body="帖子", visibility=Visibility.PUBLIC)

    services.broadcast_comment_deleted(post, comment_id=7, comment_count=2)

    groups = {g for g, _ in layer.calls}
    assert services.POST_FEED_GROUP in groups
    event = dict(layer.calls)[services.POST_FEED_GROUP]
    assert event["type"] == "comment.deleted"
    assert event["data"]["post_id"] == str(post.id)
    assert event["data"]["comment_id"] == 7
    assert event["data"]["comment_count"] == 2
