"""聊天媒体两级过期契约测试（docs/architecture/media-storage-expiration.md §9）。

覆盖：
- 7/30 天边界（恰好超期 vs 未到）；
- 五类保护引用（PostImage/EmojiItem/Comment 两种形态/Conversation.avatar）超期不删；
- 聊天类引用（Message.media_id / segments）与孤儿按两级流程删；
- 幂等重跑、DB 记录保留、配置禁用；
- :sign 端点对过期媒体返回 410 引导前端降级。
"""
from datetime import timedelta

import pytest
from django.core.management import call_command
from django.test import override_settings
from django.utils import timezone

from apps.media import storage
from apps.media.models import MediaObject

from .conftest import make_png_bytes

NOW = timezone.now()


def _mk_media(user, media_id, kind="image", days_ago=None, with_thumb=True):
    """创建 ready 媒体（可选回拨 created_at 模拟超期），返回 MediaObject。"""
    store = storage.get_storage()
    media = MediaObject.objects.create(
        media_id=media_id,
        owner=user,
        kind=kind,
        content_hash=f"h-{media_id}",
        mime_type="image/png",
        size=100,
        storage_path=storage.original_key(kind, media_id),
        status=MediaObject.STATUS_READY,
    )
    store.put(media.storage_path, make_png_bytes(), "image/png")
    if with_thumb:
        media.thumbnail_path = storage.thumbnail_key(kind, media_id)
        store.put(media.thumbnail_path, make_png_bytes(), "image/jpeg")
        media.save(update_fields=["thumbnail_path"])
    if days_ago is not None:
        MediaObject.objects.filter(pk=media.pk).update(
            created_at=NOW - timedelta(days=days_ago)
        )
        media.refresh_from_db()
    return media


def _run_expire():
    """执行清理命令（--expire-chat-media），返回 stdout 文本。"""
    from io import StringIO

    out = StringIO()
    call_command("cleanup_media", "--expire-chat-media", stdout=out)
    return out.getvalue()


@pytest.mark.django_db
class TestTtlBoundaries:
    """7/30 天边界：恰好超期 → 过期；未到 → 不过期。"""

    def test_original_ttl_boundary(self, user_factory):
        user = user_factory(username="exp_b1")
        # 恰好 7 天前 → 阶段 1 过期
        m7 = _mk_media(user, "exp-b1-7d", days_ago=7)
        # 6 天 23 小时前 → 不过期
        m6 = _mk_media(user, "exp-b1-6d", days_ago=6.95)
        _run_expire()
        m7.refresh_from_db()
        m6.refresh_from_db()
        assert m7.original_expired_at is not None
        assert m7.expired_at is None  # 未到 30 天，阶段 2 不执行
        assert storage.get_storage().exists(m7.storage_path) is False
        assert storage.get_storage().exists(m7.thumbnail_path) is True
        assert m6.original_expired_at is None
        assert storage.get_storage().exists(m6.storage_path) is True

    def test_full_ttl_boundary(self, user_factory):
        user = user_factory(username="exp_b2")
        # 恰好 30 天前 → 完全过期
        m30 = _mk_media(user, "exp-b2-30d", days_ago=30)
        # 29 天 23 小时前 → 仅阶段 1
        m29 = _mk_media(user, "exp-b2-29d", days_ago=29.95)
        _run_expire()
        m30.refresh_from_db()
        m29.refresh_from_db()
        assert m30.expired_at is not None
        assert m30.original_expired_at is not None
        assert storage.get_storage().exists(m30.storage_path) is False
        assert storage.get_storage().exists(m30.thumbnail_path) is False
        assert m29.expired_at is None
        assert m29.original_expired_at is not None
        assert storage.get_storage().exists(m29.thumbnail_path) is True


@pytest.mark.django_db
class TestProtectedReferences:
    """五类永久保留引用：超期媒体被引用即不删（本方案最高风险点）。"""

    def _mk_post(self, user):
        from apps.posts.models import Post

        return Post.objects.create(owner=user, title="t", body="b")

    def test_post_image_fk_protected(self, user_factory):
        from apps.posts.models import PostImage

        user = user_factory(username="exp_p1")
        media = _mk_media(user, "exp-p1", days_ago=40)
        PostImage.objects.create(post=self._mk_post(user), media=media, order=0)
        _run_expire()
        media.refresh_from_db()
        assert media.expired_at is None
        assert storage.get_storage().exists(media.storage_path) is True

    def test_emoji_item_fk_protected(self, user_factory):
        from apps.emoji.models import EmojiItem, EmojiPack

        user = user_factory(username="exp_p2")
        media = _mk_media(user, "exp-p2", days_ago=40)
        pack = EmojiPack.objects.create(owner=user, name="p2")
        EmojiItem.objects.create(pack=pack, media=media)
        _run_expire()
        media.refresh_from_db()
        assert media.expired_at is None
        assert storage.get_storage().exists(media.storage_path) is True

    def test_comment_media_id_protected(self, user_factory):
        from apps.posts.models import Comment

        user = user_factory(username="exp_p3")
        media = _mk_media(user, "exp-p3", days_ago=40)
        Comment.objects.create(post=self._mk_post(user), author=user, body="c", media_id=media.media_id)
        _run_expire()
        media.refresh_from_db()
        assert media.expired_at is None
        assert storage.get_storage().exists(media.storage_path) is True

    def test_comment_images_json_protected(self, user_factory):
        from apps.posts.models import Comment

        user = user_factory(username="exp_p4")
        media = _mk_media(user, "exp-p4", days_ago=40)
        Comment.objects.create(
            post=self._mk_post(user), author=user, body="c",
            images=[media.media_id, "other-media"],
        )
        _run_expire()
        media.refresh_from_db()
        assert media.expired_at is None
        assert storage.get_storage().exists(media.storage_path) is True

    def test_conversation_avatar_protected(self, user_factory):
        from apps.chat.models import Conversation

        user = user_factory(username="exp_p5")
        media = _mk_media(user, "exp-p5", days_ago=40)
        Conversation.objects.create(
            type=Conversation.TYPE_GROUP, title="g",
            avatar=f"/api/v1/media/{media.media_id}/content",
        )
        _run_expire()
        media.refresh_from_db()
        assert media.expired_at is None
        assert storage.get_storage().exists(media.storage_path) is True

    def test_mixed_references_only_chat_expires(self, user_factory):
        """同一媒体被聊天引用 + 资产引用 → 保护类优先，永不过期。"""
        from apps.posts.models import PostImage

        user = user_factory(username="exp_p6")
        media = _mk_media(user, "exp-p6", days_ago=40)
        PostImage.objects.create(post=self._mk_post(user), media=media, order=0)
        _run_expire()
        media.refresh_from_db()
        assert media.expired_at is None


@pytest.mark.django_db
class TestChatAndOrphanExpiration:
    """聊天类引用（Message.media_id / segments）与孤儿媒体按两级流程删。"""

    def _mk_conv(self, a, b):
        from apps.chat.services import get_or_create_conversation

        return get_or_create_conversation(a, b)

    def test_message_media_id_expires(self, user_factory):
        from apps.chat.models import Message

        a = user_factory(username="exp_c1a")
        b = user_factory(username="exp_c1b")
        media = _mk_media(a, "exp-c1", days_ago=8)
        conv = self._mk_conv(a, b)
        Message.objects.create(
            conversation=conv, sender=a, type="image", media_id=media.media_id,
            content="pic", idempotency_key="exp-c1-k", seq=1,
        )
        _run_expire()
        media.refresh_from_db()
        assert media.original_expired_at is not None
        assert storage.get_storage().exists(media.storage_path) is False
        assert storage.get_storage().exists(media.thumbnail_path) is True

    def test_message_segments_expires(self, user_factory):
        from apps.chat.models import Message

        a = user_factory(username="exp_c2a")
        b = user_factory(username="exp_c2b")
        media = _mk_media(a, "exp-c2", days_ago=31)
        conv = self._mk_conv(a, b)
        Message.objects.create(
            conversation=conv, sender=a, type="mixed",
            segments=[{"type": "text", "text": "看"}, {"type": "image", "media_id": media.media_id}],
            content="看", idempotency_key="exp-c2-k", seq=1,
        )
        _run_expire()
        media.refresh_from_db()
        assert media.expired_at is not None
        assert storage.get_storage().exists(media.storage_path) is False
        assert storage.get_storage().exists(media.thumbnail_path) is False

    def test_orphan_expires_two_stage(self, user_factory):
        user = user_factory(username="exp_c3")
        m8 = _mk_media(user, "exp-c3-8d", days_ago=8)
        m31 = _mk_media(user, "exp-c3-31d", days_ago=31)
        _run_expire()
        m8.refresh_from_db()
        m31.refresh_from_db()
        # 8 天：阶段 1 完成，阶段 2 未到
        assert m8.original_expired_at is not None
        assert m8.expired_at is None
        assert storage.get_storage().exists(m8.thumbnail_path) is True
        # 31 天：两级完成
        assert m31.expired_at is not None
        assert storage.get_storage().exists(m31.thumbnail_path) is False

    def test_db_record_kept_after_expire(self, user_factory):
        """过期后 DB 记录保留（只标记，不删行）。"""
        user = user_factory(username="exp_c4")
        media = _mk_media(user, "exp-c4", days_ago=31)
        _run_expire()
        media.refresh_from_db()
        assert media.expired_at is not None
        assert MediaObject.objects.filter(media_id="exp-c4").exists() is True

    def test_idempotent_rerun(self, user_factory):
        """同一命令跑两次：第二次无动作、不报错。"""
        user = user_factory(username="exp_c5")
        media = _mk_media(user, "exp-c5", days_ago=31)
        out1 = _run_expire()
        media.refresh_from_db()
        assert media.expired_at is not None
        out2 = _run_expire()
        media.refresh_from_db()
        assert media.expired_at is not None
        # 第二次不再出现删除动作（幂等）
        assert "阶段1 删除" not in out2
        assert "阶段2 删除" not in out2

    def test_no_delete_preview(self, user_factory):
        """--no-delete 预览：输出删除动作但不删对象、不标记 DB。"""
        from io import StringIO

        user = user_factory(username="exp_c6")
        m8 = _mk_media(user, "exp-c6-8d", days_ago=8)
        m31 = _mk_media(user, "exp-c6-31d", days_ago=31)
        out = StringIO()
        call_command("cleanup_media", "--expire-chat-media", "--no-delete", stdout=out)
        text = out.getvalue()
        m8.refresh_from_db()
        m31.refresh_from_db()
        assert "阶段1 删除" in text
        assert "阶段2 删除" in text
        assert m8.original_expired_at is None
        assert m31.expired_at is None
        assert storage.get_storage().exists(m8.storage_path) is True
        assert storage.get_storage().exists(m31.storage_path) is True
        assert storage.get_storage().exists(m31.thumbnail_path) is True


@pytest.mark.django_db
class TestConfigDisabled:
    """TTL<=0 禁用对应阶段。"""

    def test_all_disabled_no_action(self, user_factory):
        user = user_factory(username="exp_d1")
        media = _mk_media(user, "exp-d1", days_ago=40)
        with override_settings(
            MEDIA_CHAT_IMAGE_ORIGINAL_TTL_DAYS=0,
            MEDIA_CHAT_IMAGE_FULL_TTL_DAYS=0,
            MEDIA_CHAT_VOICE_TTL_DAYS=0,
            MEDIA_CHAT_FILE_TTL_DAYS=0,
            MEDIA_CHAT_VIDEO_TTL_DAYS=0,
        ):
            out = _run_expire()
        media.refresh_from_db()
        assert "均已禁用" in out
        assert media.expired_at is None
        assert storage.get_storage().exists(media.storage_path) is True

    def test_original_disabled_full_enabled(self, user_factory):
        """图片阶段 1 禁用、阶段 2 启用：超 FULL_TTL 的媒体直接完全过期。"""
        user = user_factory(username="exp_d2")
        media = _mk_media(user, "exp-d2", days_ago=40)
        with override_settings(
            MEDIA_CHAT_IMAGE_ORIGINAL_TTL_DAYS=0, MEDIA_CHAT_IMAGE_FULL_TTL_DAYS=30
        ):
            _run_expire()
        media.refresh_from_db()
        assert media.expired_at is not None
        assert storage.get_storage().exists(media.storage_path) is False

    def test_image_full_less_than_original_raises(self, user_factory):
        """图片 FULL < ORIGINAL 报配置错误（显式失败）。"""
        from django.core.management.base import CommandError

        user = user_factory(username="exp_d3")
        _mk_media(user, "exp-d3", days_ago=40)
        with override_settings(
            MEDIA_CHAT_IMAGE_ORIGINAL_TTL_DAYS=30, MEDIA_CHAT_IMAGE_FULL_TTL_DAYS=7
        ):
            with pytest.raises(CommandError):
                _run_expire()

    def test_single_kind_disabled_keeps_others(self, user_factory):
        """语音 TTL=0 禁用，图片/文件/视频仍按各自 TTL 过期。"""
        user = user_factory(username="exp_d4")
        voice = _mk_media(user, "exp-d4-voice", kind="voice", days_ago=40)
        image = _mk_media(user, "exp-d4-image", days_ago=40)
        with override_settings(MEDIA_CHAT_VOICE_TTL_DAYS=0):
            _run_expire()
        voice.refresh_from_db()
        image.refresh_from_db()
        assert voice.expired_at is None
        assert storage.get_storage().exists(voice.storage_path) is True
        assert image.expired_at is not None
        assert storage.get_storage().exists(image.storage_path) is False


@pytest.mark.django_db
class TestSingleStageKinds:
    """语音/文件/视频：单级过期，TTL 到期直接删除全部对象（无缩略图阶段）。"""

    def _mk_single(self, user, media_id, kind, days_ago, with_waveform=False):
        media = _mk_media(user, media_id, kind=kind, days_ago=days_ago)
        if with_waveform:
            store = storage.get_storage()
            media.waveform_path = storage.waveform_key(kind, media_id)
            store.put(media.waveform_path, make_png_bytes(), "image/png")
            media.save(update_fields=["waveform_path"])
        return media

    def test_voice_expires_directly(self, user_factory):
        """语音 7 天直接删除：original + waveform 全删，expired_at 标记。"""
        user = user_factory(username="exp_v1")
        media = self._mk_single(user, "exp-v1", "voice", days_ago=8, with_waveform=True)
        _run_expire()
        media.refresh_from_db()
        assert media.expired_at is not None
        assert media.original_expired_at is None  # 单级媒体无「原图过期」阶段
        assert storage.get_storage().exists(media.storage_path) is False
        assert storage.get_storage().exists(media.waveform_path) is False

    def test_file_expires_directly(self, user_factory):
        user = user_factory(username="exp_v2")
        media = self._mk_single(user, "exp-v2", "file", days_ago=8)
        _run_expire()
        media.refresh_from_db()
        assert media.expired_at is not None
        assert storage.get_storage().exists(media.storage_path) is False

    def test_video_expires_directly(self, user_factory):
        """视频 7 天直接删除：original + 海报帧（thumbnail）全删。"""
        user = user_factory(username="exp_v3")
        media = self._mk_single(user, "exp-v3", "video", days_ago=8)
        _run_expire()
        media.refresh_from_db()
        assert media.expired_at is not None
        assert storage.get_storage().exists(media.storage_path) is False
        assert storage.get_storage().exists(media.thumbnail_path) is False

    def test_single_kind_boundary(self, user_factory):
        """单级媒体边界：恰好 7 天前 → 过期；6 天 23 小时 → 不过期。"""
        user = user_factory(username="exp_v4")
        m7 = self._mk_single(user, "exp-v4-7d", "voice", days_ago=7)
        m6 = self._mk_single(user, "exp-v4-6d", "voice", days_ago=6.95)
        _run_expire()
        m7.refresh_from_db()
        m6.refresh_from_db()
        assert m7.expired_at is not None
        assert storage.get_storage().exists(m7.storage_path) is False
        assert m6.expired_at is None
        assert storage.get_storage().exists(m6.storage_path) is True

    def test_single_kind_protected_by_asset_reference(self, user_factory):
        """单级媒体被资产类引用（如帖子配图）→ 永不过期。"""
        from apps.posts.models import Post, PostImage

        user = user_factory(username="exp_v5")
        media = self._mk_single(user, "exp-v5", "video", days_ago=40)
        PostImage.objects.create(
            post=Post.objects.create(owner=user, title="t", body="b"),
            media=media, order=0,
        )
        _run_expire()
        media.refresh_from_db()
        assert media.expired_at is None
        assert storage.get_storage().exists(media.storage_path) is True

    def test_sign_single_kind_expired_returns_410(self, auth_client):
        """单级媒体过期后 :sign original 返回 410 media_expired（前端显示「已过期」）。"""
        client, user = auth_client(username="exp_v6")
        media = self._mk_single(user, "exp-v6", "file", days_ago=8)
        _run_expire()
        media.refresh_from_db()
        assert media.expired_at is not None
        r = client.post(f"/api/v1/media/{media.media_id}:sign", format="json")
        assert r.status_code == 410
        assert r.json()["detail"] == "media_expired"


@pytest.mark.django_db
class TestSignExpired:
    """:sign 端点对过期媒体返回 410 引导前端降级。"""

    def test_sign_original_expired_returns_410(self, auth_client):
        client, user = auth_client(username="exp_s1")
        media = _mk_media(user, "exp-s1", days_ago=8)
        _run_expire()
        media.refresh_from_db()
        assert media.original_expired_at is not None
        r = client.post(f"/api/v1/media/{media.media_id}:sign", format="json")
        assert r.status_code == 410
        assert r.json()["detail"] == "original_expired"

    def test_sign_thumb_after_full_expire_returns_410(self, auth_client):
        client, user = auth_client(username="exp_s2")
        media = _mk_media(user, "exp-s2", days_ago=31)
        _run_expire()
        media.refresh_from_db()
        assert media.expired_at is not None
        r = client.post(
            f"/api/v1/media/{media.media_id}:sign",
            {"variant": "thumb"},
            format="json",
        )
        assert r.status_code == 410
        assert r.json()["detail"] == "media_expired"

    def test_sign_thumb_still_ok_after_stage1(self, auth_client):
        """阶段 1 后 thumb 变体仍可签发（缩略图保留）。"""
        client, user = auth_client(username="exp_s3")
        media = _mk_media(user, "exp-s3", days_ago=8)
        _run_expire()
        media.refresh_from_db()
        r = client.post(
            f"/api/v1/media/{media.media_id}:sign",
            {"variant": "thumb"},
            format="json",
        )
        assert r.status_code == 200
        assert r.json()["url"].startswith("http://fake-storage/")
