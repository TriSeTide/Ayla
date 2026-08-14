"""群动态 highlights 契约测试（S6）。

覆盖：
1. 单群 highlights：造 live(status=live)/post(带图)/game(status=playing) 各 1，
   断言返回三类、cover_url 正确（post 有 thumbnail URL、live/game 为 None）、
   按时间降序、target_url 正确；
2. 无动态空列表（空群 → []）；
3. 非成员访问单群 highlights → 403；
4. 批量 ?ids=：返回 dict 结构、非成员群不出现在结果里。
"""
import pytest

from apps.chat.models import Conversation, ConversationMember
from apps.live.models import LiveChannel
from apps.media.models import MediaObject
from apps.posts.models import Post, PostImage
from apps.boardgame.models import GameRoom


def _make_group(owner, users=None):
    conv = Conversation.objects.create(type="group", title="测试群", owner=owner)
    ConversationMember.objects.create(conversation=conv, user=owner, role="owner")
    for u in users or []:
        ConversationMember.objects.create(conversation=conv, user=u)
    return conv


def _make_live(owner, group, status="live"):
    return LiveChannel.objects.create(
        title="直播间", owner=owner, group=group, status=status, stream_key=f"sk-{group.id}-{owner.id}"
    )


def _make_game(owner, group, status="playing"):
    return GameRoom.objects.create(name="桌游室", owner=owner, group=group, status=status)


def _make_image_media(owner, media_id):
    return MediaObject.objects.create(
        media_id=media_id,
        owner=owner,
        kind=MediaObject.KIND_IMAGE,
        content_hash=f"h-{media_id}",
        mime_type="image/png",
        size=100,
        storage_path=f"image/{media_id}",
        status=MediaObject.STATUS_READY,
    )


def _make_post_with_image(owner, group, body="带图帖", title=""):
    post = Post.objects.create(owner=owner, group=group, body=body, title=title)
    media = _make_image_media(owner, f"media-{post.id}")
    PostImage.objects.create(post=post, media=media, order=0)
    return post, media


@pytest.mark.django_db
class TestSingleHighlights:
    def test_three_types_and_cover_url(self, auth_client):
        client, user = auth_client(username="hl_owner")
        group = _make_group(user)

        ch = _make_live(user, group, status="live")
        post, media = _make_post_with_image(user, group, body="带图帖内容", title="带图标题")
        game = _make_game(user, group, status="playing")

        resp = client.get(f"/api/v1/chat/conversations/{group.id}/highlights/")
        assert resp.status_code == 200, resp.content
        data = resp.json()
        assert len(data) == 3
        types = {h["type"] for h in data}
        assert types == {"live", "post", "game"}

        by_type = {h["type"]: h for h in data}

        assert by_type["live"]["title"] == "直播间"
        assert by_type["live"]["cover_url"] is None
        assert by_type["live"]["target_url"] == f"/live/{ch.id}"

        assert by_type["post"]["title"] == "带图标题"
        assert by_type["post"]["cover_url"] == f"/api/v1/media/{media.media_id}/thumbnail"
        assert by_type["post"]["target_url"] == f"/posts/{post.id}"

        assert by_type["game"]["title"] == "桌游室"
        assert by_type["game"]["cover_url"] is None
        assert by_type["game"]["target_url"] == f"/games/{game.id}"

    def test_ordered_by_created_at_desc(self, auth_client):
        client, user = auth_client(username="hl_order")
        group = _make_group(user)

        post, _ = _make_post_with_image(user, group, body="最早")
        game = _make_game(user, group, status="playing")
        ch = _make_live(user, group, status="live")

        resp = client.get(f"/api/v1/chat/conversations/{group.id}/highlights/")
        data = resp.json()
        created_ats = [h["created_at"] for h in data]
        assert created_ats == sorted(created_ats, reverse=True)

    def test_post_without_image_excluded(self, auth_client):
        client, user = auth_client(username="hl_noimg")
        group = _make_group(user)
        # 无图帖子不应出现在 highlights
        Post.objects.create(owner=user, group=group, body="无图帖")
        resp = client.get(f"/api/v1/chat/conversations/{group.id}/highlights/")
        assert resp.json() == []

    def test_empty_group_returns_empty(self, auth_client):
        client, user = auth_client(username="hl_empty")
        group = _make_group(user)
        resp = client.get(f"/api/v1/chat/conversations/{group.id}/highlights/")
        assert resp.status_code == 200
        assert resp.json() == []

    def test_non_member_forbidden(self, auth_client, user_factory):
        client, _ = auth_client(username="hl_outsider")
        owner = user_factory(username="hl_o2")
        group = _make_group(owner)
        _make_live(owner, group, status="live")
        resp = client.get(f"/api/v1/chat/conversations/{group.id}/highlights/")
        assert resp.status_code == 403

    def test_not_found(self, auth_client):
        client, _ = auth_client(username="hl_nf")
        resp = client.get("/api/v1/chat/conversations/999999/highlights/")
        assert resp.status_code == 404

    def test_private_conversation_forbidden(self, auth_client, user_factory):
        client, user = auth_client(username="hl_priv")
        peer = user_factory(username="hl_peer")
        priv = Conversation.objects.create(type="private", owner=user)
        ConversationMember.objects.create(conversation=priv, user=user)
        ConversationMember.objects.create(conversation=priv, user=peer)
        resp = client.get(f"/api/v1/chat/conversations/{priv.id}/highlights/")
        assert resp.status_code == 403


@pytest.mark.django_db
class TestBatchHighlights:
    def test_batch_returns_dict_and_filters_non_member(self, auth_client, user_factory):
        client, user = auth_client(username="hl_batch")
        other = user_factory(username="hl_batch_other")

        my_group = _make_group(user)
        other_group = _make_group(other)

        _make_live(user, my_group, status="live")
        _make_live(other, other_group, status="live")

        resp = client.get(
            f"/api/v1/chat/conversations/highlights/?ids={my_group.id},{other_group.id}"
        )
        assert resp.status_code == 200, resp.content
        data = resp.json()
        assert isinstance(data, dict)
        # 只返回我所在的群
        assert str(my_group.id) in data
        assert str(other_group.id) not in data
        assert len(data[str(my_group.id)]) == 1
        assert data[str(my_group.id)][0]["type"] == "live"

    def test_batch_missing_ids_400(self, auth_client):
        client, _ = auth_client(username="hl_batch_no_ids")
        resp = client.get("/api/v1/chat/conversations/highlights/")
        assert resp.status_code == 400

    def test_batch_empty_ids_400(self, auth_client):
        client, _ = auth_client(username="hl_batch_empty")
        resp = client.get("/api/v1/chat/conversations/highlights/?ids=")
        assert resp.status_code == 400

    def test_batch_nonexistent_id_absent(self, auth_client):
        client, user = auth_client(username="hl_batch_nf")
        group = _make_group(user)
        _make_live(user, group, status="live")
        resp = client.get(
            f"/api/v1/chat/conversations/highlights/?ids={group.id},999999"
        )
        assert resp.status_code == 200
        data = resp.json()
        assert str(group.id) in data
        assert "999999" not in data
