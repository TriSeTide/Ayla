"""收藏 REST 契约测试（S6）。

覆盖：
1. 收藏帖子幂等（重复 POST 同 target 不重复建记录，第一次 201 第二次 200）；
2. 跨类型 target 校验（target_type 非法 400；目标不存在 400；friends 帖子路人收藏被拒）；
3. GET /favorites/ 列表 + ?type= 过滤；
4. DELETE /favorites/<id>/ 仅本人（非本人 403）。
"""
import pytest

from apps.common.visibility import Visibility
from apps.chat.models import Conversation, ConversationMember, Message
from apps.favorites.models import Favorite
from apps.posts.models import Post


def _make_group(owner, users=None):
    conv = Conversation.objects.create(type="group", title="测试群", owner=owner)
    ConversationMember.objects.create(conversation=conv, user=owner, role="owner")
    for u in users or []:
        ConversationMember.objects.create(conversation=conv, user=u)
    return conv


def _make_friends(a, b):
    from apps.accounts.models import Friendship

    Friendship.objects.create(user=a, friend=b, status="accepted")
    Friendship.objects.create(user=b, friend=a, status="accepted")


def _make_post(author, body="正文", **kwargs):
    return Post.objects.create(owner=author, body=body, **kwargs)


@pytest.mark.django_db
class TestFavoriteCreate:
    def test_favorite_post_idempotent(self, auth_client):
        client, user = auth_client(username="fav_p_author")
        post = _make_post(user, "可收藏的帖子")

        payload = {"target_type": "post", "target_id": str(post.id)}
        resp1 = client.post("/api/v1/favorites/", payload, format="json")
        assert resp1.status_code == 201, resp1.content
        resp2 = client.post("/api/v1/favorites/", payload, format="json")
        assert resp2.status_code == 200, resp2.content
        assert (
            Favorite.objects.filter(
                user=user, target_type="post", target_id=str(post.id)
            ).count()
            == 1
        )
        # 两次返回同一记录 id
        assert resp1.json()["id"] == resp2.json()["id"]

    def test_favorite_message_requires_membership_and_returns_summary(self, auth_client, user_factory):
        client, user = auth_client(username="fav_message")
        stranger = user_factory(username="fav_message_stranger")
        group = _make_group(user, [stranger])
        message = Message.objects.create(
            conversation=group,
            sender=user,
            type=Message.TYPE_TEXT,
            content="要收藏的群消息",
            idempotency_key="fav-message-key",
            seq=1,
        )

        response = client.post(
            "/api/v1/favorites/",
            {"target_type": "message", "target_id": str(message.id)},
            format="json",
        )
        assert response.status_code == 201, response.content
        assert response.json()["target"]["content"] == "要收藏的群消息"

        stranger_client, _ = auth_client(username="fav_message_outsider")
        outsider_response = stranger_client.post(
            "/api/v1/favorites/",
            {"target_type": "message", "target_id": str(message.id)},
            format="json",
        )
        assert outsider_response.status_code == 403

    def test_invalid_target_type_400(self, auth_client):
        client, user = auth_client(username="fav_badtype")
        post = _make_post(user)
        resp = client.post(
            "/api/v1/favorites/",
            {"target_type": "video", "target_id": str(post.id)},
            format="json",
        )
        assert resp.status_code == 400
        assert "target_type 非法" in resp.json()["detail"]

    def test_target_not_found_400(self, auth_client):
        client, _ = auth_client(username="fav_nf")
        resp = client.post(
            "/api/v1/favorites/",
            {"target_type": "post", "target_id": "999999"},
            format="json",
        )
        assert resp.status_code == 400
        assert "目标不存在" in resp.json()["detail"]

    def test_friends_post_stranger_denied(self, auth_client, user_factory):
        client, _ = auth_client(username="fav_stranger")
        owner = user_factory(username="fav_f_owner")
        post = _make_post(owner, "好友私帖", visibility=Visibility.FRIENDS)
        resp = client.post(
            "/api/v1/favorites/",
            {"target_type": "post", "target_id": str(post.id)},
            format="json",
        )
        assert resp.status_code == 403
        assert "无权收藏该目标" in resp.json()["detail"]
        assert Favorite.objects.count() == 0

    def test_target_summary_in_response(self, auth_client):
        client, user = auth_client(username="fav_summary")
        post = _make_post(user, "带标题收藏", title="收藏标题")
        resp = client.post(
            "/api/v1/favorites/",
            {"target_type": "post", "target_id": str(post.id)},
            format="json",
        )
        assert resp.status_code == 201, resp.content
        data = resp.json()
        assert data["target_type"] == "post"
        assert data["target_id"] == str(post.id)
        assert data["target"]["id"] == str(post.id)
        assert data["target"]["title"] == "收藏标题"


@pytest.mark.django_db
class TestFavoriteList:
    def test_list_and_type_filter(self, auth_client):
        client, user = auth_client(username="fav_list")
        post = _make_post(user, "帖子A")
        post2 = _make_post(user, "帖子B")
        # 再收藏一个 group，验证 type 过滤隔离
        group = _make_group(user)
        client.post("/api/v1/favorites/", {"target_type": "post", "target_id": str(post.id)}, format="json")
        client.post("/api/v1/favorites/", {"target_type": "post", "target_id": str(post2.id)}, format="json")
        client.post("/api/v1/favorites/", {"target_type": "group", "target_id": str(group.id)}, format="json")

        resp = client.get("/api/v1/favorites/")
        assert resp.status_code == 200
        assert len(resp.json()) == 3

        resp = client.get("/api/v1/favorites/?type=post")
        assert resp.status_code == 200
        data = resp.json()
        assert len(data) == 2
        assert all(item["target_type"] == "post" for item in data)

        resp = client.get("/api/v1/favorites/?type=group")
        assert len(resp.json()) == 1
        assert resp.json()[0]["target_type"] == "group"

    def test_list_only_own(self, auth_client, user_factory):
        client, user = auth_client(username="fav_me")
        other = user_factory(username="fav_other")
        post = _make_post(user)
        client.post("/api/v1/favorites/", {"target_type": "post", "target_id": str(post.id)}, format="json")
        # other 收藏同一帖子
        Favorite.objects.create(user=other, target_type="post", target_id=str(post.id))
        resp = client.get("/api/v1/favorites/")
        assert len(resp.json()) == 1  # 只看自己的


@pytest.mark.django_db
class TestFavoriteDelete:
    def test_delete_only_owner(self, auth_client, user_factory):
        client, user = auth_client(username="fav_d_owner")
        post = _make_post(user)
        resp = client.post("/api/v1/favorites/", {"target_type": "post", "target_id": str(post.id)}, format="json")
        fav_id = resp.json()["id"]

        # 非本人 403
        stranger_client, _ = auth_client(username="fav_d_stranger")
        assert stranger_client.delete(f"/api/v1/favorites/{fav_id}/").status_code == 403

        # 本人删除
        resp = client.delete(f"/api/v1/favorites/{fav_id}/")
        assert resp.status_code == 200
        assert not Favorite.objects.filter(pk=fav_id).exists()

    def test_delete_not_found_404(self, auth_client):
        client, _ = auth_client(username="fav_d_nf")
        resp = client.delete("/api/v1/favorites/999999/")
        assert resp.status_code == 404
