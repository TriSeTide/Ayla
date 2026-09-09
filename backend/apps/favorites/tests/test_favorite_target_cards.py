"""Favorite cards expose complete public display data without granting target access."""
import json

import pytest
from django.db import connection
from django.test.utils import CaptureQueriesContext
from django.utils import timezone

from apps.boardgame.models import GameRoom, GameRoomMember
from apps.chat.models import Conversation, ConversationMember, GroupSubGroup, Message
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
    for kind, target in (("post", post), ("live", live), ("voice", voice), ("game", game), ("message", message)):
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
    assert rows["message"]["content"] == message.content[:120]
    assert rows["message"]["sender_nickname"] == "合成作者"
    assert rows["message"]["seq"] == 1 and rows["message"]["status"] == "sent"
    assert rows["message"]["media_id"] is None and rows["message"]["segments"] is None
    assert set(rows["message"]) == {
        "id", "conversation_id", "sender_id", "sender_nickname", "subgroup_id",
        "type", "content", "media_id", "segments", "reply_to", "reply_to_seq",
        "status", "seq", "created_at",
    }
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


@pytest.mark.django_db
def test_message_cards_carry_media_segments_subgroup_and_recall(auth_client, user_factory):
    """收藏消息卡片携带聊天气泡所需字段：媒体引用、混排段、子群、撤回态与定位序号。"""
    client, viewer = auth_client(username="rich_media_viewer")
    owner = user_factory(username="rich_media_owner", nickname="媒体作者")
    group = Conversation.objects.create(type="group", owner=owner, title="媒体群")
    ConversationMember.objects.create(conversation=group, user=viewer)
    ConversationMember.objects.create(conversation=group, user=owner)
    subgroup = GroupSubGroup.objects.create(conversation=group, name="子群A")
    image = MediaObject.objects.create(
        owner=owner, media_id="fav-image", kind="image", mime_type="image/png",
        status="ready", width=320, height=240, size=1024,
        storage_path="internal-fixture-path", thumbnail_path="internal-fixture-thumb",
    )
    image_msg = Message.objects.create(
        conversation=group, sender=owner, type="image", media_id="fav-image",
        content="图片说明", idempotency_key="fav-image-msg", seq=1, subgroup=subgroup,
    )
    mixed_msg = Message.objects.create(
        conversation=group, sender=owner, type="mixed", content="文字[图片]",
        segments=[{"type": "text", "text": "文字"}, {"type": "image", "media_id": "fav-image"}],
        idempotency_key="fav-mixed-msg", seq=2,
    )
    recalled = Message.objects.create(
        conversation=group, sender=owner, type="voice", media_id="fav-voice",
        content="语音", idempotency_key="fav-voice-msg", seq=3, status="recalled",
    )
    reply = Message.objects.create(
        conversation=group, sender=owner, type="text", content="引用回复",
        idempotency_key="fav-reply-msg", seq=4, reply_to=image_msg,
    )
    for message in (image_msg, mixed_msg, recalled, reply):
        bookmark(viewer, "message", message)
    response = client.get(URL, {"limit": 20})
    assert response.status_code == 200, response.content
    rows = {row["target_id"]: row["target"] for row in response.json()["results"]}

    image_card = rows[str(image_msg.pk)]
    assert image_card["type"] == "image" and image_card["media_id"] == "fav-image"
    assert image_card["segments"] is None
    assert image_card["subgroup_id"] == str(subgroup.pk)
    assert image_card["sender_nickname"] == "媒体作者"
    assert image_card["seq"] == 1 and image_card["status"] == "sent"

    mixed_card = rows[str(mixed_msg.pk)]
    assert mixed_card["type"] == "mixed" and mixed_card["media_id"] is None
    assert mixed_card["segments"] == [
        {"type": "text", "text": "文字"},
        {
            "type": "image", "media_id": "fav-image",
            "media": {
                "media_id": "fav-image", "kind": "image", "mime_type": "image/png",
                "size": 1024, "status": "ready", "width": 320, "height": 240,
                "duration": None, "thumbnail": "/api/v1/media/fav-image/thumbnail",
                "waveform": None, "created_at": timezone.localtime(image.created_at).isoformat(),
            },
        },
    ]

    assert rows[str(recalled.pk)]["status"] == "recalled"
    assert rows[str(recalled.pk)]["media_id"] == "fav-voice"
    assert rows[str(reply.pk)]["reply_to"] == str(image_msg.pk)
    assert rows[str(reply.pk)]["reply_to_seq"] == 1

    serialized = json.dumps(rows)
    for excluded in ("storage_path", "internal-fixture", "waveform_path", "thumbnail_path"):
        assert excluded not in serialized
