"""搜索群头像的媒体权限：登录发现、准确引用、撤销与非头像资源隔离。"""

import pytest
from django.contrib.auth.models import AnonymousUser
from rest_framework.test import APIClient

from apps.chat.models import Conversation, ConversationMember, Message
from apps.media import storage
from apps.media.models import MediaObject
from apps.media.services import can_access_media

from .conftest import make_png_bytes


@pytest.fixture
def group_avatar(user_factory):
    owner = user_factory(username="avatar_owner")
    media_id = "search-group-avatar"
    image = make_png_bytes()
    media = MediaObject.objects.create(
        media_id=media_id,
        owner=owner,
        kind=MediaObject.KIND_IMAGE,
        content_hash="search-avatar-hash",
        mime_type="image/png",
        size=len(image),
        storage_path=storage.original_key("image", media_id),
        status=MediaObject.STATUS_READY,
    )
    storage.get_storage().put(media.storage_path, image, "image/png")
    group = Conversation.objects.create(
        type=Conversation.TYPE_GROUP,
        title="搜索头像测试群",
        owner=owner,
        avatar=f"/api/v1/media/{media_id}/content",
    )
    ConversationMember.objects.create(conversation=group, user=owner, role="owner")
    return group, media


@pytest.mark.django_db
class TestSearchGroupAvatarAccess:
    @pytest.mark.parametrize("join_policy", ["public", "application"])
    def test_nonmember_can_sign_and_read_discoverable_group_avatar(
        self, auth_client, group_avatar, join_policy
    ):
        client, viewer = auth_client(username="avatar_viewer")
        group, media = group_avatar
        group.join_policy = join_policy
        group.save(update_fields=["join_policy"])

        search = client.get("/api/v1/search/", {"q": group.title, "types": "group"})
        assert search.status_code == 200
        assert search.json()["groups"]["items"][0]["avatar"] == group.avatar
        assert not group.members.filter(user=viewer).exists()
        assert client.post(f"/api/v1/media/{media.media_id}:sign", format="json").status_code == 200
        response = client.get(group.avatar)
        assert response.status_code == 200
        assert b"".join(response.streaming_content) == make_png_bytes()

    def test_anonymous_cannot_use_public_group_avatar_reference(self, group_avatar):
        group, media = group_avatar
        anonymous = APIClient()
        assert can_access_media(AnonymousUser(), media) is False
        assert anonymous.get(group.avatar).status_code == 401
        assert anonymous.post(f"/api/v1/media/{media.media_id}:sign", format="json").status_code == 401

    @pytest.mark.parametrize("replacement", ["", "/api/v1/media/replacement/content"])
    def test_clearing_or_replacing_avatar_revokes_new_access(self, auth_client, group_avatar, replacement):
        client, viewer = auth_client(username="avatar_revoke_viewer")
        group, media = group_avatar
        assert can_access_media(viewer, media) is True
        group.avatar = replacement
        group.save(update_fields=["avatar"])
        assert can_access_media(viewer, media) is False
        assert client.post(f"/api/v1/media/{media.media_id}:sign", format="json").status_code == 403
        assert client.get(f"/api/v1/media/{media.media_id}/content").status_code == 403

    @pytest.mark.parametrize("template", [
        "/api/v1/media/{media_id}-suffix/content",
        "/api/v1/media/{media_id}/content?extra=1",
        "https://example.invalid/api/v1/media/{media_id}/content",
    ])
    def test_partial_or_noncanonical_avatar_reference_does_not_grant_access(
        self, auth_client, group_avatar, template
    ):
        client, viewer = auth_client(username="avatar_exact_viewer")
        group, media = group_avatar
        group.avatar = template.format(media_id=media.media_id)
        group.save(update_fields=["avatar"])
        assert can_access_media(viewer, media) is False
        assert client.post(f"/api/v1/media/{media.media_id}:sign", format="json").status_code == 403

    def test_private_conversation_avatar_remains_member_only(self, auth_client, group_avatar, user_factory):
        client, viewer = auth_client(username="avatar_private_outsider")
        group, media = group_avatar
        member = user_factory(username="avatar_private_member")
        group.type = Conversation.TYPE_PRIVATE
        group.save(update_fields=["type"])
        ConversationMember.objects.create(conversation=group, user=member)
        assert can_access_media(member, media) is True
        assert can_access_media(viewer, media) is False
        assert client.post(f"/api/v1/media/{media.media_id}:sign", format="json").status_code == 403

    def test_invalid_nonimage_avatar_reference_does_not_publish_file(self, auth_client, group_avatar):
        client, viewer = auth_client(username="avatar_file_outsider")
        _group, media = group_avatar
        media.kind = MediaObject.KIND_FILE
        media.save(update_fields=["kind"])
        assert can_access_media(viewer, media) is False
        assert client.post(f"/api/v1/media/{media.media_id}:sign", format="json").status_code == 403

    def test_ordinary_group_attachment_does_not_become_discoverable(self, auth_client, group_avatar):
        client, viewer = auth_client(username="avatar_attachment_outsider")
        group, media = group_avatar
        group.avatar = ""
        group.save(update_fields=["avatar"])
        Message.objects.create(
            conversation=group, sender=group.owner, type="image", media_id=media.media_id,
            content="fixture", idempotency_key="search-avatar-attachment", seq=1,
        )
        assert can_access_media(viewer, media) is False
        assert client.post(f"/api/v1/media/{media.media_id}:sign", format="json").status_code == 403
