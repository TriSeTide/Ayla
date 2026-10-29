"""资产引用边界契约测试（docs/architecture/media-retention-boundaries.md §3/§6/§7）。

覆盖本次边界修正的 3 项缺陷：

1. **保护集合补齐 A5/A7**（P0）：User.avatar / LiveChannel.cover 引用的媒体
   绝不能被过期命令删除；同时反向确认 E3 Danmaku / E4 VoiceChatMessage 仍是
   「可过期」类——它们没有被误加进保护集合（生产曾因漏判把封面/语音房图片删掉）。
2. **Q1 表情包永不过期**：kind=emoji 超 30 天也不删，且是显式跳过（命令输出可见）。
3. **Q2 资产引用必须原图完好**：6 处资产校验对 `original_expired_at` /
   `expired_at` 非空的媒体返回 `media_expired`（410 语义），不得固化为永久资产；
   以及 `/content` 对已删对象返回 404 而非 500。

聊天类（E1-E4）**不加** Q2 校验：聊天本就允许发送即将过期的媒体。
"""
from datetime import timedelta

import pytest
from django.core.management import call_command
from django.utils import timezone

from apps.media import storage
from apps.media.models import MediaObject

from .conftest import make_png_bytes

NOW = timezone.now()


def _mk_media(user, media_id, kind="image", days_ago=None, with_thumb=True):
    """创建 ready 媒体（可选回拨 created_at 模拟超期），返回 MediaObject。

    与 test_expiration.py 的同名 helper 语义一致；本文件独立一份，避免
    测试模块之间互相 import（pytest 收集顺序不该成为依赖）。
    """
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


def _mark_expired(media, *, stage=1):
    """把媒体推进到指定过期阶段（只打标记，对象删除由清理命令负责）。"""
    if stage == 1:
        MediaObject.objects.filter(pk=media.pk).update(
            original_expired_at=NOW - timedelta(days=1)
        )
    else:
        MediaObject.objects.filter(pk=media.pk).update(
            original_expired_at=NOW - timedelta(days=30),
            expired_at=NOW - timedelta(days=1),
        )
    media.refresh_from_db()
    return media


def _run_expire():
    """执行清理命令（--expire-chat-media），返回 stdout 文本。"""
    from io import StringIO

    out = StringIO()
    call_command("cleanup_media", "--expire-chat-media", stdout=out)
    return out.getvalue()


def _avatar_url(media):
    return f"/api/v1/media/{media.media_id}/content"


@pytest.mark.django_db
class TestProtectedAssetReferences:
    """A5/A7 补齐：新增的两类资产引用必须进入保护集合。"""

    def test_user_avatar_protected(self, user_factory):
        """A5 User.avatar 引用的媒体超期 40 天也不被删（本次 P0 修复）。"""
        user = user_factory(username="ret_a5")
        media = _mk_media(user, "ret-a5", days_ago=40)
        user.avatar = _avatar_url(media)
        user.save(update_fields=["avatar"])
        _run_expire()
        media.refresh_from_db()
        assert media.expired_at is None
        assert media.original_expired_at is None
        assert storage.get_storage().exists(media.storage_path) is True
        assert storage.get_storage().exists(media.thumbnail_path) is True

    def test_live_channel_cover_protected(self, user_factory):
        """A7 LiveChannel.cover 引用的媒体超期 40 天也不被删（生产已实证的误删）。"""
        from apps.live.models import LiveChannel

        user = user_factory(username="ret_a7")
        media = _mk_media(user, "ret-a7", days_ago=40)
        LiveChannel.objects.create(
            owner=user, title="test", cover=_avatar_url(media), stream_key="ret-a7-key"
        )
        _run_expire()
        media.refresh_from_db()
        assert media.expired_at is None
        assert media.original_expired_at is None
        assert storage.get_storage().exists(media.storage_path) is True

    def test_other_user_avatar_protected_before_access_check(self, user_factory):
        """保护集合是「按数据库全量引用」判定，不依赖调用方/owner。

        头像引用者不是媒体 owner 时同样必须保护（生产漏判的另一面：
        保护集合若按 owner 过滤就会漏掉他人设为头像的媒体）。
        """
        owner = user_factory(username="ret_a5_owner")
        other = user_factory(username="ret_a5_other")
        media = _mk_media(owner, "ret-a5-other", days_ago=40)
        other.avatar = _avatar_url(media)
        other.save(update_fields=["avatar"])
        _run_expire()
        media.refresh_from_db()
        assert media.expired_at is None
        assert storage.get_storage().exists(media.storage_path) is True

    def test_mixed_user_avatar_and_chat_reference(self, user_factory):
        """同一媒体既在聊天里被引用、又被设为头像 → 资产引用优先，永不过期。"""
        from apps.chat.models import Message
        from apps.chat.services import get_or_create_conversation

        a = user_factory(username="ret_mix_a")
        b = user_factory(username="ret_mix_b")
        media = _mk_media(a, "ret-mix", days_ago=40)
        conv = get_or_create_conversation(a, b)
        Message.objects.create(
            conversation=conv, sender=a, type="image", media_id=media.media_id,
            content="pic", idempotency_key="ret-mix-k", seq=1,
        )
        a.avatar = _avatar_url(media)
        a.save(update_fields=["avatar"])
        _run_expire()
        media.refresh_from_db()
        assert media.expired_at is None
        assert storage.get_storage().exists(media.storage_path) is True


@pytest.mark.django_db
class TestChatClassesStillExpire:
    """反向约束：E3/E4 是可过期类，绝不能被误加入保护集合。"""

    def test_danmaku_media_expires(self, user_factory):
        """E3 Danmaku.media_id 引用的图片 → 8 天走阶段 1（删原图留缩略图）。"""
        from apps.live.models import Danmaku, LiveChannel

        sender = user_factory(username="ret_e3")
        media = _mk_media(sender, "ret-e3", days_ago=8)
        channel = LiveChannel.objects.create(
            owner=sender, title="dm", stream_key="ret-e3-key"
        )
        Danmaku.objects.create(
            channel=channel, sender=sender, content="看图", media_id=media.media_id
        )
        _run_expire()
        media.refresh_from_db()
        assert media.original_expired_at is not None
        assert storage.get_storage().exists(media.storage_path) is False
        assert storage.get_storage().exists(media.thumbnail_path) is True

    def test_voice_chat_message_media_expires(self, user_factory):
        """E4 VoiceChatMessage.media_id 引用的图片 → 31 天两级全过期。"""
        from apps.voice.models import VoiceChannel, VoiceChatMessage

        sender = user_factory(username="ret_e4")
        media = _mk_media(sender, "ret-e4", days_ago=31)
        channel = VoiceChannel.objects.create(
            owner=sender, name="voice", room_name="ret-e4-room"
        )
        VoiceChatMessage.objects.create(
            channel=channel, sender=sender, content="看图", media_id=media.media_id
        )
        _run_expire()
        media.refresh_from_db()
        assert media.expired_at is not None
        assert storage.get_storage().exists(media.storage_path) is False
        assert storage.get_storage().exists(media.thumbnail_path) is False


@pytest.mark.django_db
class TestEmojiNeverExpires:
    """Q1：表情包永不过期，且必须是显式跳过（不靠 TTL 表巧合）。"""

    def test_emoji_media_beyond_full_ttl_not_deleted(self, user_factory):
        user = user_factory(username="ret_q1")
        media = _mk_media(user, "ret-q1", kind="emoji", days_ago=40)
        out = _run_expire()
        media.refresh_from_db()
        assert media.expired_at is None
        assert media.original_expired_at is None
        assert storage.get_storage().exists(media.storage_path) is True
        # 显式跳过：命令输出单独计数（防止未来重构 TTL 表时把 emoji 当单级媒体删掉）
        assert "表情包跳过 1 个" in out


@pytest.mark.django_db
class TestAssetReferenceRejectsExpiredMedia:
    """Q2：6 处资产校验必须拒绝已过期媒体（`media_expired`，410 语义）。"""

    def _mk_expired_image(self, user, media_id, stage=2):
        media = _mk_media(user, media_id, days_ago=40)
        return _mark_expired(media, stage=stage)

    # --- A1 发帖配图 / 更新帖配图 -------------------------------------------

    def test_create_post_rejects_expired_media(self, auth_client):
        client, user = auth_client(username="ret_q2_post")
        media = self._mk_expired_image(user, "ret-q2-post")
        r = client.post(
            "/api/v1/posts/",
            {"title": "t", "body": "b", "images": [media.media_id]},
            format="json",
        )
        assert r.status_code == 400
        assert r.json()["images"] == ["media_expired"]

    def test_create_post_rejects_stage1_media(self, auth_client):
        """阶段 1（原图已删、缩略图在）同样拒绝——缩略图不是可用的资产内容。"""
        client, user = auth_client(username="ret_q2_post_s1")
        media = self._mk_expired_image(user, "ret-q2-post-s1", stage=1)
        r = client.post(
            "/api/v1/posts/",
            {"title": "t", "body": "b", "images": [media.media_id]},
            format="json",
        )
        assert r.status_code == 400
        assert r.json()["images"] == ["media_expired"]

    def test_update_post_rejects_expired_media(self, auth_client):
        from apps.posts.models import Post

        client, user = auth_client(username="ret_q2_upd")
        post = Post.objects.create(owner=user, title="t", body="b")
        media = self._mk_expired_image(user, "ret-q2-upd")
        r = client.patch(
            f"/api/v1/posts/{post.id}/",
            {"images": [media.media_id]},
            format="json",
        )
        assert r.status_code == 400
        assert r.json()["images"] == ["media_expired"]

    # --- A3/A4 评论图片 ------------------------------------------------------

    def test_comment_rejects_expired_media(self, auth_client):
        from apps.posts.models import Post

        client, user = auth_client(username="ret_q2_cmt")
        post = Post.objects.create(owner=user, title="t", body="b")
        media = self._mk_expired_image(user, "ret-q2-cmt")
        r = client.post(
            f"/api/v1/posts/{post.id}/comments/",
            {"body": "c", "images": [media.media_id]},
            format="json",
        )
        assert r.status_code == 400
        assert r.json()["media_id"] == ["media_expired"]

    # --- A2 收藏表情 --------------------------------------------------------

    def test_emoji_add_item_rejects_expired_media(self, auth_client):
        from apps.emoji.models import EmojiPack

        client, user = auth_client(username="ret_q2_emoji")
        pack = EmojiPack.objects.create(owner=user, name="p")
        media = _mk_media(user, "ret-q2-emoji", kind="emoji", days_ago=40)
        _mark_expired(media, stage=2)
        r = client.post(
            f"/api/v1/emoji/packs/{pack.id}/items/add/",
            {"media_id": media.media_id},
            format="json",
        )
        assert r.status_code == 400
        assert r.json()["detail"] == "media_expired"

    # --- A5/A6 用户/群头像 --------------------------------------------------

    def test_user_avatar_rejects_expired_media(self, auth_client):
        client, user = auth_client(username="ret_q2_a5")
        media = self._mk_expired_image(user, "ret-q2-a5")
        r = client.patch(
            "/api/v1/me/profile/", {"avatar": _avatar_url(media)}, format="json"
        )
        assert r.status_code == 400
        assert r.json()["avatar"] == ["media_expired"]

    def test_group_avatar_rejects_expired_media(self, auth_client):
        from apps.chat.models import Conversation, ConversationMember

        client, user = auth_client(username="ret_q2_a6")
        conv = Conversation.objects.create(
            type=Conversation.TYPE_GROUP, title="g", owner=user
        )
        # PATCH 要求群主/管理员（can_manage_group 看 ConversationMember.role），
        # 直接 create 不会自动建成员行，这里显式补一条群主成员。
        ConversationMember.objects.create(
            conversation=conv, user=user, role=ConversationMember.ROLE_OWNER
        )
        media = self._mk_expired_image(user, "ret-q2-a6")
        r = client.patch(
            f"/api/v1/chat/conversations/{conv.id}/",
            {"avatar": _avatar_url(media)},
            format="json",
        )
        assert r.status_code == 400
        assert r.json()["detail"] == "media_expired"

    # --- A7 直播间封面 ------------------------------------------------------

    def test_live_cover_rejects_expired_media(self, auth_client):
        client, user = auth_client(username="ret_q2_a7")
        media = self._mk_expired_image(user, "ret-q2-a7")
        r = client.post(
            "/api/v1/live/channels/",
            {"title": "room", "cover": _avatar_url(media)},
            format="json",
        )
        assert r.status_code == 400
        assert r.json()["detail"] == "media_expired"

    # --- 反例：完好媒体仍然接受 ---------------------------------------------

    def test_intact_media_still_accepted(self, auth_client):
        """未过期的完好图片照常可设为头像（新校验不能误伤正常链路）。"""
        client, user = auth_client(username="ret_q2_ok")
        media = _mk_media(user, "ret-q2-ok", days_ago=1)
        r = client.patch(
            "/api/v1/me/profile/", {"avatar": _avatar_url(media)}, format="json"
        )
        assert r.status_code == 200, r.content
        assert r.json()["avatar"] == _avatar_url(media)


@pytest.mark.django_db
class TestContentEndpointObjectMissing:
    """P1：对象已删时 /content 必须 404，不能冒成 500（调查报告 §4.6）。"""

    def test_content_missing_object_returns_404(self, auth_client):
        client, user = auth_client(username="ret_ct")
        media = _mk_media(user, "ret-ct")
        # 模拟清理命令已删对象（DB 记录仍在，这是本机制的正常形态）
        storage.get_storage().delete(media.storage_path)
        r = client.get(f"/api/v1/media/{media.media_id}/content")
        assert r.status_code == 404
        assert r.json()["detail"] == "media_content_unavailable"

    def test_content_existing_object_still_200(self, auth_client):
        client, user = auth_client(username="ret_ct_ok")
        media = _mk_media(user, "ret-ct-ok")
        r = client.get(f"/api/v1/media/{media.media_id}/content")
        assert r.status_code == 200

    def test_voice_like_media_expired_returns_410_not_500(self, auth_client):
        """语音单级过期后（对象全删）走 content 端点：**410** 而非 500/404。

        2026-10-29 契约统一（用户拍板）：已知过期的媒体一律 410 `media_expired`，
        与 `:sign` 端点同语义 —— 前端只按状态码判定「已过期」。
        未标记过期但对象缺失（运维态）仍返回 404 `media_content_unavailable`
        （见 test_content_missing_object_returns_404）。
        """
        client, user = auth_client(username="ret_ct_voice")
        media = _mk_media(user, "ret-ct-voice", kind="voice")
        _mark_expired(media, stage=2)
        storage.get_storage().delete(media.storage_path)
        r = client.get(f"/api/v1/media/{media.media_id}/content")
        assert r.status_code == 410
        assert r.json()["detail"] == "media_expired"
