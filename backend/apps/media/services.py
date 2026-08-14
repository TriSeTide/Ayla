"""
媒体领域服务 —— 上传会话生命周期、complete 校验、派生生成、访问鉴权。

设计（步骤文件 3.2 / 4 / 5.3）：
- 受控上传三步：创建会话（服务端策略校验）→ PUT 二进制（临时前缀）→ :complete（权威动作）；
- complete：读回临时对象 → sha256 → 比对 size/MIME/文件头嗅探 → 按需去重 → 原子建 MediaObject → 触发派生；
- 幂等：同 upload 重复 complete 返回同一 media_id，不重复建对象/不重复派生；
- 访问控制（can_access_media）：owner / 消息引用（会话成员）/ 表情包（系统包或本人个人包）→ 可访问，否则 403/404；
- 派生失败（缩略图/波形）不把 MediaObject 置 failed，只记录 warning（失败路径留日志）。

硬约束（AGENTS.md / 阶段三 §10）：
- 媒体访问控制是工程硬约束：未授权绝不静默放行；
- 只允许已登记 media_id 下载，禁止 path traversal（storage_path 由内部构造，不接受外部输入）；
- 派生失败不伪装成媒体失败或空结果。
"""
import hashlib
import io
import logging
import uuid
from datetime import timedelta

from django.conf import settings
from django.db import transaction
from django.utils import timezone

from . import derivatives, storage
from .models import MediaObject, MediaUploadSession

logger = logging.getLogger(__name__)

# 允许的 MIME 类型（allowlist）；文件头嗅探与声明 MIME 同时检查
ALLOWED_MIME = {
    "image": {
        "image/png", "image/jpeg", "image/gif", "image/webp",
    },
    "emoji": {
        "image/png", "image/jpeg", "image/gif", "image/webp",
    },
    "voice": {
        "audio/wav", "audio/x-wav", "audio/wave", "audio/mpeg",
        "audio/mp4", "audio/ogg", "audio/x-m4a", "audio/webm", "application/octet-stream",
    },
    "file": {
        "application/pdf", "application/zip", "application/x-zip-compressed",
        "text/plain", "text/csv", "text/markdown", "application/json",
        "application/msword", "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.ms-excel",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.ms-powerpoint",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/x-tar", "application/gzip", "application/x-7z-compressed",
        "application/octet-stream",
    },
}

# 文件头嗅探（魔数）——按 MIME 分类
_SNIFFERS = [
    # (kind, magic_bytes, mime_guess)
    ("image", b"\x89PNG\r\n\x1a\n", "image/png"),
    ("image", b"\xff\xd8\xff", "image/jpeg"),
    ("image", b"GIF87a", "image/gif"),
    ("image", b"GIF89a", "image/gif"),
    ("image", b"RIFF", "image/webp"),  # WebP 头 RIFF....WEBP
    ("voice", b"RIFF", "audio/x-wav"),  # WAV
    ("voice", b"ID3", "audio/mpeg"),  # MP3 带 ID3
    ("voice", b"\xff\xfb", "audio/mpeg"),  # MP3 无标签
    ("voice", b"OggS", "audio/ogg"),
    ("voice", b"fLaC", "audio/flac"),
    ("file", b"%PDF", "application/pdf"),
    ("file", b"PK\x03\x04", "application/zip"),
]


def _max_bytes(kind: str) -> int:
    mapping = {
        MediaObject.KIND_IMAGE: getattr(settings, "MEDIA_MAX_IMAGE_BYTES", 10 * 1024 * 1024),
        MediaObject.KIND_VOICE: getattr(settings, "MEDIA_MAX_VOICE_BYTES", 30 * 1024 * 1024),
        MediaObject.KIND_FILE: getattr(settings, "MEDIA_MAX_FILE_BYTES", 50 * 1024 * 1024),
        MediaObject.KIND_EMOJI: getattr(settings, "MEDIA_MAX_EMOJI_BYTES", 5 * 1024 * 1024),
    }
    return mapping.get(kind, 50 * 1024 * 1024)


def _ttl_seconds() -> int:
    return int(getattr(settings, "MEDIA_TMP_TTL_SECONDS", 600))


def _mime_allowed(kind: str, mime_type: str) -> bool:
    return mime_type in ALLOWED_MIME.get(kind, set())


def _sniff_kind(data: bytes, declared_kind: str) -> bool:
    """文件头嗅探：数据开头的魔数是否与声明的 kind 匹配。

    emoji 与 image 一样是位图（PNG/JPEG/GIF/WebP），复用同一魔数集校验。
    """
    if declared_kind == MediaObject.KIND_FILE:
        # 文件类型不做强魔数约束（任意合法 MIME 均可），但至少要有内容
        return len(data) > 0
    for _kind, magic, _mime in _SNIFFERS:
        if _kind == declared_kind and data.startswith(magic):
            return True
        # emoji 与 image 共用位图魔数集
        if (
            declared_kind == MediaObject.KIND_EMOJI
            and _kind == MediaObject.KIND_IMAGE
            and data.startswith(magic)
        ):
            return True
    # 兜底：允许的 image/emoji 都需有魔数；voice 若既非 WAV 又非已知，交由 MIME 判断
    return False


def _content_hash(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def create_upload_session(user, *, kind: str, expected_size: int, mime_type: str) -> MediaUploadSession:
    """创建受控上传会话（步骤文件 5.1 POST /uploads）。

    - 服务端策略校验（不信任客户端最终声明）：kind 合法、MIME 在 allowlist、大小不超过该 kind 上限；
    - 返回会话，owner 仅上传者本人。
    """
    if kind not in dict(MediaObject.KIND_CHOICES):
        raise ValueError("unsupported_media_kind")
    if not _mime_allowed(kind, mime_type):
        raise ValueError("unsupported_media_type")
    if expected_size <= 0:
        raise ValueError("invalid_expected_size")
    if expected_size > _max_bytes(kind):
        raise ValueError("payload_too_large")

    session = MediaUploadSession.objects.create(
        upload_id=uuid.uuid4().hex,
        owner=user,
        kind=kind,
        expected_size=expected_size,
        mime_type=mime_type,
        status=MediaUploadSession.STATUS_PENDING,
        expires_at=timezone.now() + timedelta(seconds=_ttl_seconds()),
    )
    return session


def _session_expired(session: MediaUploadSession) -> bool:
    if session.status == MediaUploadSession.STATUS_EXPIRED:
        return True
    if timezone.now() > session.expires_at:
        # 惰性清理：查询即置过期（与 cleanup 管理命令互补）
        MediaUploadSession.objects.filter(pk=session.pk).update(
            status=MediaUploadSession.STATUS_EXPIRED
        )
        return True
    return False


def put_session_binary(user, session, data: bytes) -> None:
    """PUT 二进制：写入临时前缀 tmp/{upload_id}，不产生正式 media_id。"""
    if session.owner_id != user.id:
        raise PermissionError("仅上传者可上传")
    if _session_expired(session):
        raise TimeoutError("上传会话已过期")
    storage.get_storage().put(storage.tmp_key(session.upload_id), data)


def complete_upload(user, session) -> MediaObject:
    """:complete 权威动作：校验 → 去重 → 建 MediaObject → 派生（尽力而为）。

    幂等：同 upload 重复 complete 返回同一 media_id。
    """
    if session.owner_id != user.id:
        raise PermissionError("仅上传者可完成")
    if _session_expired(session):
        raise TimeoutError("上传会话已过期")

    # 幂等优先：同一 upload_id 已 complete 过 → 返回既有 media（不重复建对象/不重复派生）。
    # 用 session.media_id 锚点（complete 成功后回填），必须先于临时对象检查——
    # 第一次 complete 会删除临时对象，重复 complete 时 tmp 已不存在。
    if session.media_id:
        existing = MediaObject.objects.filter(media_id=session.media_id).first()
        if existing is not None:
            return existing

    store = storage.get_storage()
    tmp_key = storage.tmp_key(session.upload_id)
    if not store.exists(tmp_key):
        raise ValueError("media_data_missing")

    data = store.get(tmp_key)
    # 完整性：sha256 + size + MIME
    digest = _content_hash(data)
    if len(data) != session.expected_size:
        raise ValueError("media_size_mismatch")
    if not _mime_allowed(session.kind, session.mime_type):
        raise ValueError("unsupported_media_type")
    if not _sniff_kind(data, session.kind):
        raise ValueError("media_integrity_failed")

    with transaction.atomic():
        # 去重：同 content_hash 已存在则复用既有 media_id（不改变 owner 语义）
        dup = MediaObject.objects.filter(content_hash=digest).first()
        if dup is not None:
            media = dup
        else:
            media_id = uuid.uuid4().hex
            media = MediaObject.objects.create(
                media_id=media_id,
                owner=user,
                kind=session.kind,
                content_hash=digest,
                mime_type=session.mime_type,
                size=len(data),
                storage_path=storage.original_key(session.kind, media_id),
                status=MediaObject.STATUS_PROCESSING,
            )
            store.put(
                media.storage_path, data,
                content_type=session.mime_type or "application/octet-stream",
            )
            # 清除临时对象（owner 已确认，cleanup 兜底）
            try:
                store.delete(tmp_key)
            except Exception as exc:
                logger.warning("delete tmp %s failed: %s", tmp_key, exc)
        # 派生（尽力而为，失败不阻塞/不置 failed）
        _generate_derivatives(media, data)
        if media.status == MediaObject.STATUS_PROCESSING:
            media.status = MediaObject.STATUS_READY
            media.save(update_fields=["status"])

    # 幂等标记：upload 会话已 completed，并回填生成的 media_id 作为幂等锚点
    MediaUploadSession.objects.filter(pk=session.pk).update(
        status=MediaUploadSession.STATUS_COMPLETED,
        media_id=media.media_id,
    )
    return media


def _generate_derivatives(media: MediaObject, data: bytes) -> None:
    """派生资源生成（尽力而为，失败只留 warning，不把媒体置 failed）。"""
    store = storage.get_storage()
    if media.kind in (MediaObject.KIND_IMAGE, MediaObject.KIND_EMOJI):
        try:
            thumb_bytes, width, height = derivatives.generate_thumbnail(
                data, media.mime_type
            )
            thumb_key = storage.thumbnail_key(media.kind, media.media_id)
            store.put(thumb_key, thumb_bytes, content_type="image/jpeg")
            media.thumbnail_path = thumb_key
            media.width = width
            media.height = height
            media.save(update_fields=["thumbnail_path", "width", "height"])
        except Exception:
            logger.warning(
                "thumbnail derivation failed for media %s (media stays ready)", media.media_id,
                exc_info=True,
            )
    elif media.kind == MediaObject.KIND_VOICE:
        try:
            wave_bytes, duration = derivatives.generate_waveform(data)
            wave_key = storage.waveform_key(media.kind, media.media_id)
            store.put(wave_key, wave_bytes, content_type="image/png")
            media.waveform_path = wave_key
            media.duration = duration
            media.save(update_fields=["waveform_path", "duration"])
        except Exception:
            logger.warning(
                "waveform derivation failed for media %s (media stays ready)", media.media_id,
                exc_info=True,
            )


# ---------- 访问控制（工程硬约束，步骤文件 5.3） ----------

def can_access_media(user, media: MediaObject) -> bool:
    """媒体访问权判定。

    1. owner：上传者本人永远可访问；
    2. 消息引用：media 被某条 Message 引用，且 user 是该消息所在会话的成员；
    3. 帖子配图：media 被某 PostImage 引用，且 user 能查看该帖子（S3）；
    4. 表情包：media 属于某 EmojiItem，且该包是系统包（全员）或用户自己的个人包；
    5. 其他情况：拒绝（403/404）。
    """
    if media.owner_id == user.id:
        return True

    # 消息引用路径（核心："在聊天里收到图片/文件，就能打开它"）
    # 同一媒体可能被转发进多个会话，任一会话成员均可访问，故查全部引用消息
    from apps.chat.models import Message
    from apps.chat.services import user_can_access as chat_user_can_access

    msgs = Message.objects.filter(media_id=media.media_id).select_related("conversation")
    for msg in msgs:
        if chat_user_can_access(user, msg.conversation):
            return True

    # 帖子配图路径（S3）：media 被帖子配图引用，且 user 能查看该帖子
    from apps.posts.models import PostImage
    from apps.common.visibility import can_view as _post_can_view

    post_img = PostImage.objects.filter(media=media).select_related("post").first()
    if post_img is not None and _post_can_view(user, post_img.post):
        return True

    # 表情包路径
    from apps.emoji.models import EmojiItem

    item = EmojiItem.objects.filter(media=media).select_related("pack").first()
    if item is not None:
        if item.pack.is_system:
            return True
        if item.pack.owner_id == user.id:
            return True

    return False


def get_media_or_none(media_id: str) -> MediaObject | None:
    return MediaObject.objects.filter(media_id=media_id).first()
