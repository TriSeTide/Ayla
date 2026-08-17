"""媒体访问控制契约测试（8.1 清单：消息引用、表情包路径、头像引用路径、越权）。"""
import pytest

from apps.chat.models import Conversation, ConversationMember
from apps.chat.services import get_or_create_conversation
from apps.media.models import MediaObject
from apps.media.services import can_access_media
from apps.emoji.models import EmojiPack

from .conftest import make_png_bytes, upload_image
from .helpers import auth_as


@pytest.mark.django_db
class TestAccessControl:
    def _mk_image_media(self, user):
        from apps.media import storage

        store = storage.get_storage()
        media = MediaObject.objects.create(
            media_id="acc-media-1",
            owner=user,
            kind="image",
            content_hash="h1",
            mime_type="image/png",
            size=100,
            storage_path=storage.original_key("image", "acc-media-1"),
            status=MediaObject.STATUS_READY,
        )
        store.put(media.storage_path, make_png_bytes(), "image/png")
        return media

    def test_owner_always_access(self, user_factory):
        owner = user_factory(username="acc_o")
        media = self._mk_image_media(owner)
        assert can_access_media(owner, media) is True

    def test_message_reference_member_access(self, user_factory):
        a = user_factory(username="acc_a")
        b = user_factory(username="acc_b")
        c = user_factory(username="acc_c")
        media = self._mk_image_media(a)
        conv = get_or_create_conversation(a, b)
        from apps.chat.models import Message
        Message.objects.create(
            conversation=conv, sender=a, type="image", media_id=media.media_id,
            content="pic", idempotency_key="acc-k1", seq=1,
        )
        # b 是会话成员 → 可访问
        assert can_access_media(b, media) is True
        # c 不是成员 → 不可访问
        assert can_access_media(c, media) is False

    def test_system_emoji_pack_visible_to_all(self, user_factory):
        owner = user_factory(username="acc_eo")
        other = user_factory(username="acc_eo2")
        media = self._mk_image_media(owner)
        pack = EmojiPack.objects.create(owner=None, name="系统包", is_system=True)
        from apps.emoji.models import EmojiItem
        EmojiItem.objects.create(pack=pack, media=media, tag="默认")
        assert can_access_media(other, media) is True

    def test_personal_emoji_pack_only_owner(self, user_factory):
        owner = user_factory(username="acc_po")
        other = user_factory(username="acc_po2")
        media = self._mk_image_media(owner)
        pack = EmojiPack.objects.create(owner=owner, name="我的收藏", is_system=False)
        from apps.emoji.models import EmojiItem
        EmojiItem.objects.create(pack=pack, media=media, tag="")
        assert can_access_media(owner, media) is True
        assert can_access_media(other, media) is False

    def test_unreferenced_media_403(self, user_factory):
        owner = user_factory(username="acc_u")
        other = user_factory(username="acc_u2")
        media = self._mk_image_media(owner)
        # 未被消息/表情包引用 → 非 owner 403
        assert can_access_media(other, media) is False

    def test_authenticated_user_avatar_content_download(self, user_factory):
        """头像 content 对带 Bearer 的真实媒体请求返回内容。"""
        owner = user_factory(username="acc_http_o")
        viewer = user_factory(username="acc_http_v")
        media = self._mk_image_media(owner)
        owner.avatar = f"/api/v1/media/{media.media_id}/content"
        owner.save(update_fields=["avatar"])

        response = auth_as(viewer).get(f"/api/v1/media/{media.media_id}/content")

        assert response.status_code == 200
        assert response["Content-Type"] == "image/png"
        assert response.content == make_png_bytes()

    def test_user_avatar_reference_visible_to_any(self, user_factory):
        """media 被某用户设为头像 → 任意登录用户可访问（头像公开展示）。"""
        owner = user_factory(username="acc_ua_o")
        other = user_factory(username="acc_ua_other")
        media = self._mk_image_media(owner)
        owner.avatar = f"/api/v1/media/{media.media_id}/content"
        owner.save()
        assert can_access_media(other, media) is True

    def test_group_avatar_reference_member_only(self, user_factory):
        """media 被某群设为头像 → 仅群成员可访问，非成员拒绝。"""
        owner = user_factory(username="acc_ga_o")
        member = user_factory(username="acc_ga_m")
        outsider = user_factory(username="acc_ga_out")
        media = self._mk_image_media(owner)
        conv = Conversation.objects.create(
            type=Conversation.TYPE_GROUP,
            title="头像测试群",
            owner=owner,
            avatar=f"/api/v1/media/{media.media_id}/content",
        )
        ConversationMember.objects.create(conversation=conv, user=owner, role="owner")
        ConversationMember.objects.create(conversation=conv, user=member)
        assert can_access_media(member, media) is True
        assert can_access_media(outsider, media) is False

    def test_group_avatar_cleared_revokes_access(self, user_factory):
        """清除群头像后，非 owner 不再可访问该媒体。"""
        owner = user_factory(username="acc_gc_o")
        member = user_factory(username="acc_gc_m")
        media = self._mk_image_media(owner)
        conv = Conversation.objects.create(
            type=Conversation.TYPE_GROUP,
            title="清理测试群",
            owner=owner,
            avatar=f"/api/v1/media/{media.media_id}/content",
        )
        ConversationMember.objects.create(conversation=conv, user=owner, role="owner")
        ConversationMember.objects.create(conversation=conv, user=member)
        assert can_access_media(member, media) is True
        conv.avatar = ""
        conv.save(update_fields=["avatar"])
        assert can_access_media(member, media) is False

    def test_forward_message_member_access(self, user_factory):
        """转发：a 发给 b 的图片，a 再发给 c；b、c 均可访问（都是消息引用）。"""
        a = user_factory(username="acc_fa")
        b = user_factory(username="acc_fb")
        c = user_factory(username="acc_fc")
        media = self._mk_image_media(a)
        conv1 = get_or_create_conversation(a, b)
        conv2 = get_or_create_conversation(a, c)
        from apps.chat.models import Message
        Message.objects.create(
            conversation=conv1, sender=a, type="image", media_id=media.media_id,
            content="pic", idempotency_key="acc-fk1", seq=1,
        )
        Message.objects.create(
            conversation=conv2, sender=a, type="image", media_id=media.media_id,
            content="pic", idempotency_key="acc-fk2", seq=1,
        )
        assert can_access_media(b, media) is True
        assert can_access_media(c, media) is True
