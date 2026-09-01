"""收藏 WS 广播契约测试（任务 07）。

收藏是用户私有数据：收藏/取消收藏后只向收藏者本人的用户级组
`chat_user_<user_id>` 广播 `favorite.changed`（同账号各界面实时同步），
其他用户不感知他人收藏。

覆盖：
1. 收藏成功 → 广播 added（组 + 载荷：target_type/target_id/favorite_id/action）；
2. 幂等重复收藏（200）→ 同样广播 added（前端 setFavorite 幂等，无害）；
3. 取消收藏成功 → 广播 removed（favorite_id 为被删收藏 id）；
4. 非本人删除 403 → 不广播。
"""
import pytest

from apps.favorites.models import Favorite
from apps.posts.models import Post


class _Layer:
    def __init__(self):
        self.calls = []

    async def group_send(self, group, event):
        self.calls.append((group, event))


def _make_post(author, body="可收藏的帖子"):
    return Post.objects.create(owner=author, body=body)


@pytest.mark.django_db
def test_favorite_added_broadcast_to_owner_user_group(monkeypatch, auth_client):
    layer = _Layer()
    monkeypatch.setattr("channels.layers.get_channel_layer", lambda: layer)
    client, user = auth_client(username="fav_bc_add")
    post = _make_post(user)

    resp = client.post(
        "/api/v1/favorites/",
        {"target_type": "post", "target_id": str(post.id)},
        format="json",
    )
    assert resp.status_code == 201, resp.content
    fav_id = resp.json()["id"]

    assert layer.calls == [
        (
            f"chat_user_{user.id}",
            {
                "type": "favorite.changed",
                "data": {
                    "target_type": "post",
                    "target_id": str(post.id),
                    "favorite_id": fav_id,
                    "action": "added",
                },
            },
        )
    ]


@pytest.mark.django_db
def test_favorite_added_broadcast_on_idempotent_repost(monkeypatch, auth_client):
    """幂等重复收藏（200）也广播 added：前端 setFavorite 幂等，重复应用无害。"""
    layer = _Layer()
    monkeypatch.setattr("channels.layers.get_channel_layer", lambda: layer)
    client, user = auth_client(username="fav_bc_idem")
    post = _make_post(user)

    client.post(
        "/api/v1/favorites/",
        {"target_type": "post", "target_id": str(post.id)},
        format="json",
    )
    layer.calls.clear()
    resp = client.post(
        "/api/v1/favorites/",
        {"target_type": "post", "target_id": str(post.id)},
        format="json",
    )
    assert resp.status_code == 200, resp.content
    fav_id = resp.json()["id"]

    assert layer.calls == [
        (
            f"chat_user_{user.id}",
            {
                "type": "favorite.changed",
                "data": {
                    "target_type": "post",
                    "target_id": str(post.id),
                    "favorite_id": fav_id,
                    "action": "added",
                },
            },
        )
    ]


@pytest.mark.django_db
def test_favorite_removed_broadcast(monkeypatch, auth_client):
    layer = _Layer()
    monkeypatch.setattr("channels.layers.get_channel_layer", lambda: layer)
    client, user = auth_client(username="fav_bc_rm")
    post = _make_post(user)
    fav = Favorite.objects.create(user=user, target_type="post", target_id=str(post.id))

    resp = client.delete(f"/api/v1/favorites/{fav.id}/")
    assert resp.status_code == 200, resp.content

    assert layer.calls == [
        (
            f"chat_user_{user.id}",
            {
                "type": "favorite.changed",
                "data": {
                    "target_type": "post",
                    "target_id": str(post.id),
                    "favorite_id": fav.id,
                    "action": "removed",
                },
            },
        )
    ]


@pytest.mark.django_db
def test_favorite_delete_denied_does_not_broadcast(monkeypatch, auth_client, user_factory):
    layer = _Layer()
    monkeypatch.setattr("channels.layers.get_channel_layer", lambda: layer)
    client, user = auth_client(username="fav_bc_owner")
    stranger_client, _ = auth_client(username="fav_bc_stranger")
    post = _make_post(user)
    fav = Favorite.objects.create(user=user, target_type="post", target_id=str(post.id))

    resp = stranger_client.delete(f"/api/v1/favorites/{fav.id}/")
    assert resp.status_code == 403
    assert layer.calls == []  # 非本人删除被拒，不广播
