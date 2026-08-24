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

    def test_segments_reference_member_access(self, user_factory):
        """图文混排（segments JSON）消息引用的媒体：会话成员可访问，外人拒绝。

        第四轮重构后 mixed 消息的 media 引用存在 segments JSON 里而非
        media_id 列——权限判定必须覆盖该形态（回归：B 看不到 A 发的视频）。
        """
        import json

        a = user_factory(username="acc_seg_a")
        b = user_factory(username="acc_seg_b")
        cc = user_factory(username="acc_seg_c")
        media = self._mk_image_media(a)
        conv = get_or_create_conversation(a, b)
        from apps.chat.models import Message
        Message.objects.create(
            conversation=conv, sender=a, type="mixed",
            segments=[
                {"type": "text", "text": "看看这个"},
                {"type": "image", "media_id": media.media_id},
            ],
            content="看看这个",
            idempotency_key="acc-seg-k1", seq=1,
        )
        from apps.media.tests.test_access import _dbg_segments_query
        from apps.chat.services import user_can_access as _cua

        print("DBG:", _dbg_segments_query(media.media_id))
        for _m in Message.objects.filter(segments__icontains=media.media_id).select_related("conversation"):
            print("DBG msg", _m.id, "conv", _m.conversation_id,
                  "segments_type:", type(_m.segments).__name__,
                  "ref:", any(isinstance(_s, dict) and _s.get("media_id") == media.media_id for _s in (_m.segments or [])),
                  "cua:", _cua(b, _m.conversation))
        assert can_access_media(b, media) is True
        assert can_access_media(cc, media) is False


def _dbg_segments_query(media_id):
    from apps.chat.models import Message as M

    return {
        "icontains": M.objects.filter(segments__icontains=media_id).count(),
        "raw_rows": [str(m.segments)[:120] for m in M.objects.filter(segments__icontains=media_id)],
    }

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
        # content 端点是 StreamingHttpResponse：拼接分块流断言完整字节
        assert b"".join(response.streaming_content) == make_png_bytes()

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


@pytest.mark.django_db
class TestSignedContentAccess:
    """签名票据直连 content（<img>/<video> 无法带 Authorization 的流式播放通道）。"""

    def _mk_media(self, user):
        return TestAccessControl()._mk_image_media(user)

    def test_sign_returns_presigned_get_url(self, auth_client):
        """直传架构对称设计：:sign 返回对象存储预签名 GET URL（播放流量旁路应用服务器）。"""
        client, user = auth_client(username="sign_owner")
        media = self._mk_media(user)
        r = client.post(f"/api/v1/media/{media.media_id}:sign", format="json")
        assert r.status_code == 200
        body = r.json()
        url = body["url"]
        # 伪存储实现下 URL 形态可断言；指向 media.storage_path 且带过期语义
        assert url.startswith("http://fake-storage/")
        assert "X-Amz-Expires" in url or "mode=get" in url
        assert body["expires_at"] > 0
        # Django content 端点（Bearer 通道）仍可用且内容完整
        resp = client.get(f"/api/v1/media/{media.media_id}/content")
        assert resp.status_code == 200
        assert b"".join(resp.streaming_content) == make_png_bytes()

    def test_forged_or_missing_ticket_rejected(self, auth_client):
        from rest_framework.test import APIClient

        from apps.media import services

        client, user = auth_client(username="sign_owner2")
        media = self._mk_media(user)
        client.post(f"/api/v1/media/{media.media_id}:sign", format="json")
        anon = APIClient()
        # 无票据匿名访问 Django content 端点 → 401
        assert anon.get(f"/api/v1/media/{media.media_id}/content").status_code == 401
        # 过期票据：verify 直接判 False（票据通道保留兼容）
        t = services.sign_media_access(user.id, media.media_id)
        assert services.verify_media_access(t["uid"], media.media_id, int(t["exp"]) - 3600, t["sig"]) is False

    def test_sign_requires_access(self, auth_client):
        """无访问权者不能签发（越权 403）。"""
        from apps.media import storage as st

        from apps.media.models import MediaObject

        stranger, _ = auth_client(username="sign_stranger")
        _, owner_user = auth_client(username="sign_owner3")
        media = MediaObject.objects.create(
            media_id="sign-denied",
            owner=owner_user,
            kind="image",
            content_hash="h-sign",
            mime_type="image/png",
            size=len(make_png_bytes()),
            storage_path=st.original_key("image", "sign-denied"),
            status=MediaObject.STATUS_READY,
        )
        assert stranger.post(f"/api/v1/media/{media.media_id}:sign", format="json").status_code == 403
