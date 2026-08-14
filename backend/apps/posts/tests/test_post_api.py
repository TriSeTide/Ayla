"""帖子 REST 契约测试（S3，开发文档 §1.3）。

覆盖：发帖（正文必填/配图校验/可见性默认）、信息流可见性过滤、scope（feed/mine/group）、
游标分页（去重 + has_more/next_cursor）、详情/编辑/删除仅作者、评论增删/回复归属。
"""
import pytest
from django.utils import timezone

from apps.common.visibility import Visibility
from apps.chat.models import Conversation, ConversationMember
from apps.posts.models import Comment, Post, PostImage

from .conftest import make_image_media


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


# ---------- 发帖 ----------

@pytest.mark.django_db
class TestCreatePost:
    def test_create_public_default(self, auth_client):
        client, user = auth_client(username="p_author")
        resp = client.post(
            "/api/v1/posts/", {"body": "第一篇帖子"}, format="json"
        )
        assert resp.status_code == 201, resp.content
        data = resp.json()
        assert data["body"] == "第一篇帖子"
        assert data["visibility"] == Visibility.PUBLIC
        assert data["group"] is None
        assert data["group_name"] is None
        assert data["author_id"] == user.id
        assert data["is_author"] is True
        assert data["images"] == []
        assert data["comment_count"] == 0

    def test_create_requires_body(self, auth_client):
        client, _ = auth_client(username="p_no_body")
        resp = client.post("/api/v1/posts/", {"title": "无正文"}, format="json")
        assert resp.status_code == 400

    def test_create_with_images(self, auth_client):
        client, user = auth_client(username="p_img")
        m1 = make_image_media(user, "p-img-1")
        m2 = make_image_media(user, "p-img-2")
        resp = client.post(
            "/api/v1/posts/",
            {"body": "带图", "images": [m1.media_id, m2.media_id]},
            format="json",
        )
        assert resp.status_code == 201, resp.content
        data = resp.json()
        assert len(data["images"]) == 2
        assert [img["order"] for img in data["images"]] == [0, 1]
        assert data["images"][0]["media"]["media_id"] == m1.media_id
        assert PostImage.objects.filter(post_id=data["id"]).count() == 2

    def test_create_images_limit_9(self, auth_client):
        client, user = auth_client(username="p_img9")
        ids = []
        for i in range(10):
            ids.append(make_image_media(user, f"p9-img-{i}").media_id)
        resp = client.post(
            "/api/v1/posts/", {"body": "超9张", "images": ids}, format="json"
        )
        assert resp.status_code == 400

    def test_create_image_not_found(self, auth_client):
        client, _ = auth_client(username="p_img_nf")
        resp = client.post(
            "/api/v1/posts/",
            {"body": "坏图", "images": ["no-such-media"]},
            format="json",
        )
        assert resp.status_code == 400
        assert "media_not_found" in str(resp.json())

    def test_create_image_access_denied(self, auth_client, user_factory):
        client, _ = auth_client(username="p_img_denied")
        other = user_factory(username="p_img_other")
        media = make_image_media(other, "p-img-owned")
        resp = client.post(
            "/api/v1/posts/",
            {"body": "别人的图", "images": [media.media_id]},
            format="json",
        )
        assert resp.status_code == 403

    def test_create_group_defaults_to_group_visibility(self, auth_client):
        client, user = auth_client(username="p_group_author")
        group = _make_group(user)
        resp = client.post(
            "/api/v1/posts/",
            {"body": "群内帖子", "group": str(group.id)},
            format="json",
        )
        assert resp.status_code == 201, resp.content
        data = resp.json()
        assert data["visibility"] == Visibility.GROUP
        assert data["group"] == str(group.id)
        assert data["group_name"] == "测试群"

    def test_create_group_visibility_requires_group(self, auth_client):
        client, _ = auth_client(username="p_grp_vis")
        resp = client.post(
            "/api/v1/posts/",
            {"body": "x", "visibility": Visibility.GROUP},
            format="json",
        )
        assert resp.status_code == 400
        assert "群" in resp.json()["detail"]

    def test_create_group_must_be_group_conversation(self, auth_client, user_factory):
        client, user = auth_client(username="p_grp_conv")
        peer = user_factory(username="p_grp_peer")
        priv = Conversation.objects.create(type="private", owner=user)
        ConversationMember.objects.create(conversation=priv, user=user)
        ConversationMember.objects.create(conversation=priv, user=peer)
        resp = client.post(
            "/api/v1/posts/",
            {"body": "x", "group": str(priv.id)},
            format="json",
        )
        assert resp.status_code == 400
        assert "群" in resp.json()["detail"]


# ---------- 信息流 / scope / 分页 ----------

@pytest.mark.django_db
class TestFeed:
    def test_feed_filters_by_visibility(self, auth_client, user_factory):
        client, viewer = auth_client(username="f_viewer")
        owner = user_factory(username="f_owner")
        friend = user_factory(username="f_friend")
        member = user_factory(username="f_member")
        _make_friends(owner, friend)
        group = _make_group(owner, [member])

        _make_post(owner, "public", visibility=Visibility.PUBLIC)
        _make_post(owner, "friends", visibility=Visibility.FRIENDS)
        _make_post(owner, "grouped", visibility=Visibility.GROUP, group=group)

        # viewer 与 owner 无关 → 只看到 public
        resp = client.get("/api/v1/posts/")
        assert resp.status_code == 200
        bodies = {p["body"] for p in resp.json()["results"]}
        assert bodies == {"public"}

        # viewer 成为 owner 好友 → 多看到 friends
        _make_friends(viewer, owner)
        resp = client.get("/api/v1/posts/")
        bodies = {p["body"] for p in resp.json()["results"]}
        assert bodies == {"public", "friends"}

        # viewer 入群 → 看到 group
        ConversationMember.objects.create(conversation=group, user=viewer)
        resp = client.get("/api/v1/posts/")
        bodies = {p["body"] for p in resp.json()["results"]}
        assert bodies == {"public", "friends", "grouped"}

    def test_scope_mine(self, auth_client, user_factory):
        client, me = auth_client(username="f_me")
        other = user_factory(username="f_other")
        _make_post(me, "mine-1")
        _make_post(other, "other-1")
        resp = client.get("/api/v1/posts/?scope=mine")
        bodies = {p["body"] for p in resp.json()["results"]}
        assert bodies == {"mine-1"}

    def test_scope_group(self, auth_client, user_factory):
        client, member = auth_client(username="f_gm")
        owner = user_factory(username="f_go")
        group = _make_group(owner, [member])
        _make_post(owner, "g-post", visibility=Visibility.GROUP, group=group)
        _make_post(owner, "not-g-post", visibility=Visibility.PUBLIC)

        resp = client.get(f"/api/v1/posts/?scope=group:{group.id}")
        assert resp.status_code == 200
        bodies = {p["body"] for p in resp.json()["results"]}
        assert bodies == {"g-post"}

    def test_scope_group_non_member_sees_nothing(self, auth_client, user_factory):
        client, outsider = auth_client(username="f_go_out")
        owner = user_factory(username="f_go_owner")
        group = _make_group(owner)
        _make_post(owner, "g-secret", visibility=Visibility.GROUP, group=group)
        resp = client.get(f"/api/v1/posts/?scope=group:{group.id}")
        assert resp.status_code == 200
        assert resp.json()["results"] == []

    def test_scope_invalid(self, auth_client):
        client, _ = auth_client(username="f_badscope")
        resp = client.get("/api/v1/posts/?scope=whatever")
        assert resp.status_code == 400

    def test_cursor_pagination_no_duplicates(self, auth_client):
        client, user = auth_client(username="f_pages")
        # 同一微秒可能撞 created_at，靠 id 兜底排序去重（游标设计点）
        total = 5
        for i in range(total):
            _make_post(user, f"page-{i}")
        limit = 2
        seen = []
        cursor = None
        pages = 0
        while True:
            url = f"/api/v1/posts/?scope=mine&limit={limit}"
            if cursor:
                url += f"&cursor={cursor}"
            resp = client.get(url)
            assert resp.status_code == 200, resp.content
            body = resp.json()
            results = body["results"]
            seen.extend(p["id"] for p in results)
            pages += 1
            if not body["has_more"]:
                break
            assert body["next_cursor"] is not None
            cursor = body["next_cursor"]
        assert len(seen) == total
        assert len(set(seen)) == total  # 无重复
        assert pages == 3  # 5 条 / 每页 2 条 → 3 页

    def test_cursor_invalid(self, auth_client):
        client, _ = auth_client(username="f_badcursor")
        resp = client.get("/api/v1/posts/?cursor=@@@bad@@@")
        assert resp.status_code == 400


# ---------- 媒体访问控制（帖子配图路径） ----------

@pytest.mark.django_db
class TestPostImageAccess:
    def test_public_post_image_accessible_to_viewer(self, auth_client, user_factory):
        from apps.media.services import can_access_media

        client, author = auth_client(username="mia_author")
        media = make_image_media(author, "mia-img-1")
        client.post(
            "/api/v1/posts/",
            {"body": "公开带图", "images": [media.media_id]},
            format="json",
        )
        viewer = user_factory(username="mia_viewer")
        assert can_access_media(viewer, media) is True

    def test_friends_only_post_image_denied_to_stranger(self, auth_client, user_factory):
        from apps.media.services import can_access_media

        client, author = auth_client(username="mia_f_author")
        media = make_image_media(author, "mia-img-2")
        client.post(
            "/api/v1/posts/",
            {"body": "好友可见带图", "images": [media.media_id], "visibility": "friends"},
            format="json",
        )
        stranger = user_factory(username="mia_f_stranger")
        assert can_access_media(stranger, media) is False


# ---------- 详情 / 编辑 / 删除 ----------

@pytest.mark.django_db
class TestPostDetail:
    def test_detail_forbidden_for_invisible(self, auth_client, user_factory):
        client, _ = auth_client(username="d_viewer")
        owner = user_factory(username="d_owner")
        post = _make_post(owner, "secret", visibility=Visibility.FRIENDS)
        resp = client.get(f"/api/v1/posts/{post.id}/")
        assert resp.status_code == 403
        assert "无权" in resp.json()["detail"]

    def test_detail_author_visible(self, auth_client):
        client, user = auth_client(username="d_author")
        post = _make_post(user, "own", visibility=Visibility.FRIENDS)
        resp = client.get(f"/api/v1/posts/{post.id}/")
        assert resp.status_code == 200
        assert resp.json()["body"] == "own"

    def test_patch_only_author(self, auth_client, user_factory):
        client, author = auth_client(username="d_p_author")
        post = _make_post(author, "旧正文")
        # 非作者改 → 403
        stranger_client, _ = auth_client(username="d_p_stranger")
        resp = stranger_client.patch(
            f"/api/v1/posts/{post.id}/", {"body": "越权改"}, format="json"
        )
        assert resp.status_code == 403
        # 作者改 → 200
        resp = client.patch(
            f"/api/v1/posts/{post.id}/", {"body": "新正文"}, format="json"
        )
        assert resp.status_code == 200
        assert resp.json()["body"] == "新正文"

    def test_patch_empty_body_400(self, auth_client):
        client, user = auth_client(username="d_p_empty")
        post = _make_post(user, "正文")
        resp = client.patch(f"/api/v1/posts/{post.id}/", {"body": "   "}, format="json")
        assert resp.status_code == 400

    def test_patch_no_fields_400(self, auth_client):
        client, user = auth_client(username="d_p_nofields")
        post = _make_post(user, "正文")
        resp = client.patch(f"/api/v1/posts/{post.id}/", {}, format="json")
        assert resp.status_code == 400

    def test_delete_only_author(self, auth_client, user_factory):
        client, author = auth_client(username="d_d_author")
        post = _make_post(author, "要删")
        stranger_client, _ = auth_client(username="d_d_stranger")
        assert (
            stranger_client.delete(f"/api/v1/posts/{post.id}/").status_code == 403
        )
        resp = client.delete(f"/api/v1/posts/{post.id}/")
        assert resp.status_code == 200
        assert not Post.objects.filter(pk=post.id).exists()


# ---------- 评论 ----------

@pytest.mark.django_db
class TestComment:
    def test_list_and_create(self, auth_client, user_factory):
        client, author = auth_client(username="c_author")
        post = _make_post(author, "有评论")
        resp = client.post(
            f"/api/v1/posts/{post.id}/comments/",
            {"body": "沙发"},
            format="json",
        )
        assert resp.status_code == 201, resp.content
        data = resp.json()
        assert data["body"] == "沙发"
        assert data["post_id"] == str(post.id)
        assert data["author_id"] == author.id
        assert data["reply_to"] is None
        assert data["is_author"] is True

        resp = client.get(f"/api/v1/posts/{post.id}/comments/")
        assert resp.status_code == 200
        assert [c["body"] for c in resp.json()] == ["沙发"]

    def test_comment_empty_body_400(self, auth_client):
        client, author = auth_client(username="c_empty")
        post = _make_post(author, "正文")
        resp = client.post(
            f"/api/v1/posts/{post.id}/comments/", {"body": "  "}, format="json"
        )
        assert resp.status_code == 400

    def test_reply_to_must_be_in_same_post(self, auth_client):
        client, author = auth_client(username="c_reply")
        post = _make_post(author, "正文")
        other = _make_post(author, "另一篇")
        foreign = Comment.objects.create(post=other, author=author, body="外帖评论")
        resp = client.post(
            f"/api/v1/posts/{post.id}/comments/",
            {"body": "回复", "reply_to": foreign.id},
            format="json",
        )
        assert resp.status_code == 404

    def test_reply_to_ok(self, auth_client):
        client, author = auth_client(username="c_reply_ok")
        post = _make_post(author, "正文")
        parent = Comment.objects.create(post=post, author=author, body="父评论")
        resp = client.post(
            f"/api/v1/posts/{post.id}/comments/",
            {"body": "子评论", "reply_to": parent.id},
            format="json",
        )
        assert resp.status_code == 201
        assert resp.json()["reply_to"] == str(parent.id)

    def test_comment_on_invisible_post_403(self, auth_client, user_factory):
        client, _ = auth_client(username="c_outsider")
        owner = user_factory(username="c_owner")
        post = _make_post(owner, "私密", visibility=Visibility.FRIENDS)
        resp = client.post(
            f"/api/v1/posts/{post.id}/comments/", {"body": "hi"}, format="json"
        )
        assert resp.status_code == 403
        assert client.get(f"/api/v1/posts/{post.id}/comments/").status_code == 403

    def test_delete_comment_only_author(self, auth_client):
        client, author = auth_client(username="c_d_author")
        post = _make_post(author, "正文")
        comment = Comment.objects.create(post=post, author=author, body="我的评论")
        stranger_client, _ = auth_client(username="c_d_stranger")
        assert (
            stranger_client.delete(f"/api/v1/posts/comments/{comment.id}/").status_code
            == 403
        )
        resp = client.delete(f"/api/v1/posts/comments/{comment.id}/")
        assert resp.status_code == 200
        assert not Comment.objects.filter(pk=comment.id).exists()
