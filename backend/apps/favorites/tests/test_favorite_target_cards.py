"""Favorite cards expose complete public display data without granting target access."""
import json

import pytest
from django.db import connection
from django.test.utils import CaptureQueriesContext

from apps.boardgame.models import GameRoom, GameRoomMember
from apps.chat.models import Conversation, ConversationMember, Message
from apps.favorites.models import Favorite
from apps.live.models import LiveChannel
from apps.media.models import MediaObject
from apps.posts.models import Comment, Post, PostImage, PostView
from apps.voice.models import VoiceChannel, VoiceChannelMember

URL = "/api/v1/favorites/"


def bookmark(user, kind, target):
    return Favorite.objects.create(user=user, target_type=kind, target_id=str(target.pk))


@pytest.mark.django_db
def test_all_card_types_have_display_data_and_safe_descriptors(auth_client, user_factory):
    client, viewer = auth_client(username="rich_favorite_viewer")
    owner = user_factory(username="rich_favorite_owner", nickname="合成作者", avatar="/api/v1/media/owner/content")
    group = Conversation.objects.create(type="group", owner=owner, title="合成来源群", avatar="/api/v1/media/group/content", announcement="内部群公告")
    ConversationMember.objects.create(conversation=group, user=viewer)
    ConversationMember.objects.create(conversation=group, user=owner)
    post = Post.objects.create(owner=owner, body="完整正文" * 80, group=group, view_count=7)
    post.allowed_groups.add(group)
    media = MediaObject.objects.create(owner=owner, media_id="favorite-image", kind="image", mime_type="image/png", status="ready", width=320, height=240, storage_path="internal-fixture-path", thumbnail_path="internal-fixture-thumb")
    PostImage.objects.create(post=post, media=media, order=0)
    Comment.objects.create(post=post, author=owner, body="评论一")
    Comment.objects.create(post=post, author=viewer, body="评论二")
    PostView.objects.create(post=post, user=viewer)
    live = LiveChannel.objects.create(owner=owner, title="合成直播", cover="/api/v1/media/cover/content", description="直播说明", status="live", stream_key="fixture-publish-secret", group=group)
    voice = VoiceChannel.objects.create(owner=owner, name="合成语音", room_name="favorite-voice", group=group)
    VoiceChannelMember.objects.create(channel=voice, user=owner)
    VoiceChannelMember.objects.create(channel=voice, user=viewer)
    game = GameRoom.objects.create(owner=owner, name="合成桌游", game_type="boardgame", status="playing", group=group)
    GameRoomMember.objects.create(room=game, user=owner, seat=0)
    GameRoomMember.objects.create(room=game, user=viewer, seat=1)
    message = Message.objects.create(conversation=group, sender=owner, content="安全消息摘要" * 40, type="text", idempotency_key="favorite-safe-message", seq=1)
    for kind, target in (("post", post), ("live", live), ("voice", voice), ("game", game), ("group", group), ("message", message)):
        if hasattr(target, "allowed_groups"):
            target.allowed_groups.add(group)
        bookmark(viewer, kind, target)
    response = client.get(URL, {"limit": 20})
    assert response.status_code == 200, response.content
    rows = {row["target_type"]: row["target"] for row in response.json()["results"]}
    card = rows["post"]
    assert card["id"] == str(post.pk) and card["raw_title"] == ""
    assert card["title"] == post.body[:30] and card["body"] == post.body
    assert card["author"]["nickname"] == "合成作者" and card["author"]["avatar"] == owner.avatar
    assert card["comment_count"] == 2 and card["view_count"] == 7 and card["is_viewed"] is True
    assert card["images"][0]["media"]["thumbnail"] == "/api/v1/media/favorite-image/thumbnail"
    assert card["group_name"] == "合成来源群" and card["allowed_group_names"] == ["合成来源群"]
    assert rows["live"]["cover"] == live.cover and rows["live"]["status"] == "live"
    assert rows["live"]["owner_id"] == str(owner.pk) and rows["live"]["owner_nickname"] == "合成作者"
    assert rows["voice"]["member_count"] == 2 and rows["voice"]["mine"] is True
    assert rows["voice"]["owner_nickname"] == "合成作者"
    assert rows["game"]["game_type"] == "boardgame" and rows["game"]["status"] == "playing"
    assert rows["game"]["member_count"] == 2 and rows["game"]["is_member"] is True
    assert "members" not in rows["game"]
    assert rows["group"]["avatar"] == group.avatar and rows["group"]["member_count"] == 2
    assert rows["group"]["is_member"] is True and "announcement" not in rows["group"]
    assert rows["message"]["content"] == message.content[:120]
    assert set(rows["message"]) == {"id", "conversation_id", "type", "content", "created_at"}
    serialized = json.dumps(rows)
    for excluded in ("fixture-publish-secret", "stream_key", "rtmp_url", "hls_url", "flv_url", "storage_path", "internal-fixture", '"email"', '"password"'):
        assert excluded not in serialized


@pytest.mark.django_db
def test_owner_create_and_legacy_list_never_return_live_transport_credentials(auth_client):
    client, owner = auth_client(username="rich_live_owner")
    live = LiveChannel.objects.create(owner=owner, title="本人直播", stream_key="fixture-owner-publish-secret")
    response = client.post(URL, {"target_type": "live", "target_id": str(live.pk)}, format="json")
    assert response.status_code == 201, response.content
    created = response.json()["target"]
    legacy = client.get(URL).json()[0]["target"]
    page = client.get(URL, {"limit": 20}).json()["results"][0]["target"]
    for card in (created, legacy, page):
        assert card["is_owner"] is True
        assert not {"stream_key", "rtmp_url", "hls_url", "flv_url"}.intersection(card)
        assert "fixture-owner-publish-secret" not in json.dumps(card)


@pytest.mark.django_db
@pytest.mark.parametrize("kind", ["post", "live", "voice", "game"])
def test_visibility_is_rechecked_for_rich_cards_without_removing_bookmark(auth_client, user_factory, kind):
    client, viewer = auth_client(username=f"rich_acl_{kind}")
    owner = user_factory(username=f"rich_acl_owner_{kind}")
    model, kwargs = {
        "post": (Post, {"body": "正文"}),
        "live": (LiveChannel, {"title": "直播", "stream_key": "acl-live-fixture"}),
        "voice": (VoiceChannel, {"name": "语音", "room_name": "acl-voice-fixture"}),
        "game": (GameRoom, {"name": "桌游"}),
    }[kind]
    target = model.objects.create(owner=owner, **kwargs)
    saved = bookmark(viewer, kind, target)
    assert client.get(URL).json()[0]["target"] is not None
    target.visibility = "friends"
    target.save(update_fields=["visibility"])
    for params in ({}, {"limit": 20}):
        payload = client.get(URL, params).json()
        item = payload[0] if isinstance(payload, list) else payload["results"][0]
        assert item["id"] == saved.pk and item["target"] is None
    group = Conversation.objects.create(type="group", owner=owner, title="临时授权群")
    ConversationMember.objects.create(conversation=group, user=viewer)
    target.allowed_groups.add(group)
    assert client.get(URL).json()[0]["target"] is not None
    ConversationMember.objects.filter(conversation=group, user=viewer).delete()
    assert client.get(URL, {"limit": 20}).json()["results"][0]["target"] is None
    assert Favorite.objects.filter(pk=saved.pk).exists()


@pytest.mark.django_db
def test_message_membership_deleted_target_and_bad_legacy_id_stay_unavailable(auth_client, user_factory):
    client, viewer = auth_client(username="rich_unavailable")
    owner = user_factory(username="rich_unavailable_owner")
    group = Conversation.objects.create(type="group", owner=owner, title="消息群")
    membership = ConversationMember.objects.create(conversation=group, user=viewer)
    message = Message.objects.create(conversation=group, sender=owner, content="原摘要", type="text", idempotency_key="rich-unavailable", seq=1)
    bookmark(viewer, "message", message)
    post = Post.objects.create(owner=owner, body="将被删除")
    bookmark(viewer, "post", post)
    Favorite.objects.create(user=viewer, target_type="voice", target_id="not-a-number")
    Favorite.objects.create(user=viewer, target_type="game", target_id="9" * 64)
    membership.delete()
    post.delete()
    response = client.get(URL, {"limit": 20})
    assert response.status_code == 200, response.content
    assert response.json()["total"] == 4
    assert all(item["target"] is None for item in response.json()["results"])


@pytest.mark.django_db
def test_target_loading_is_batched_for_the_current_page(auth_client):
    client, owner = auth_client(username="rich_batched")
    for i in range(5):
        post = Post.objects.create(owner=owner, body=f"批量正文{i}")
        Comment.objects.create(post=post, author=owner, body="评论")
        bookmark(owner, "post", post)
    with CaptureQueriesContext(connection) as one:
        one_response = client.get(URL, {"limit": 1})
    with CaptureQueriesContext(connection) as five:
        five_response = client.get(URL, {"limit": 5})
    assert one_response.status_code == five_response.status_code == 200
    assert len(one_response.json()["results"]) == 1
    assert len(five_response.json()["results"]) == 5
    assert len(five) <= len(one) + 1
    assert all(item["target"]["comment_count"] == 1 for item in five_response.json()["results"])
