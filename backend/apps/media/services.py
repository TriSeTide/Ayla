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
import hmac
import io
import logging
import time
import uuid
from datetime import timedelta

from django.conf import settings
from django.db import transaction
from django.utils import timezone

from . import derivatives, storage
from .models import MediaObject, MediaUploadSession

logger = logging.getLogger(__name__)

# 媒体内容签名 URL 默认有效期（秒）：覆盖一次完整播放/浏览窗口即可，
# 过期由前端在到期前 60s 重新签发（getSignedMediaUrl 缓存）
MEDIA_VIEW_URL_TTL_SECONDS = 600


def _media_view_signing_key() -> bytes:
    """媒体内容签名密钥：由 Django SECRET_KEY 派生（独立域，不与密码哈希混用）。"""
    return hashlib.sha256(f"media-view-url:{settings.SECRET_KEY}".encode()).digest()


def sign_media_access(user_id, media_id: str, ttl_seconds: int = MEDIA_VIEW_URL_TTL_SECONDS) -> dict:
    """为已授权用户签发媒体内容的短时访问票据（HMAC-SHA256）。

    返回 {"uid", "exp", "sig"}；票据绑定 user+media+过期时间，泄露后影响范围
    限于单个媒体、且 exp 后自动失效。供 <img>/<video> 直接 src 引用——
    浏览器原生 Range 流式播放/渐进加载，前端不再全量下载 blob（内存恒定）。
    user_id 为用户主键原样值（UUID hex 字符串），签名串不做数值规范化。
    """
    exp = int(time.time()) + max(60, int(ttl_seconds))
    msg = f"{user_id}:{media_id}:{exp}".encode()
    sig = hmac.new(_media_view_signing_key(), msg, hashlib.sha256).hexdigest()
    return {"uid": user_id, "exp": exp, "sig": sig}


def verify_media_access(uid, media_id, exp, sig) -> bool:
    """校验签名票据：参数齐全、未过期、HMAC 匹配（常数时间比较）。

    uid 为用户主键原样字符串；exp 十进制秒级时间戳。msg 构造与 sign 完全一致
    （原样嵌入、不做数值规范化，杜绝等价形式绕签）。
    """
    try:
        if not uid or not media_id or not exp or not sig:
            return False
        if int(exp) < time.time():
            return False
        msg = f"{uid}:{media_id}:{exp}".encode()
        expect = hmac.new(_media_view_signing_key(), msg, hashlib.sha256).hexdigest()
        return hmac.compare_digest(expect, str(sig))
    except (TypeError, ValueError):
        return False

# 允许的 MIME 类型（allowlist）；文件头嗅探与声明 MIME 同时检查。
# image 除常见位图外，覆盖现代格式（AVIF/HEIC/HEIF）与传统格式（BMP/TIFF/ICO），
# 以及浏览器/系统可能上报的别名（image/jpg、image/pjpeg）；SVG 见下方安全说明。
ALLOWED_MIME = {
    "image": {
        "image/png", "image/jpeg", "image/jpg", "image/pjpeg",
        "image/gif", "image/webp",
        "image/avif", "image/heic", "image/heif", "image/heix",
        "image/bmp", "image/x-ms-bmp",
        "image/tiff",
        "image/x-icon", "image/vnd.microsoft.icon", "image/x-win-bitmap",
        # SVG 属于 XML 文档：仅配合 content 端点的 CSP sandbox + nosniff 头放行，
        # 直接内嵌/打开时脚本不执行（见 views.MediaContentView）。
        "image/svg+xml",
    },
    # emoji 与 image 同为位图（魔数嗅探共用同一套），白名单对齐 image：
    # 群表情包应支持用户上传的所有图片格式（含 HEIC/AVIF/BMP/TIFF/ICO/SVG）。
    "emoji": {
        "image/png", "image/jpeg", "image/jpg", "image/pjpeg",
        "image/gif", "image/webp",
        "image/avif", "image/heic", "image/heif", "image/heix",
        "image/bmp", "image/x-ms-bmp",
        "image/tiff",
        "image/x-icon", "image/vnd.microsoft.icon", "image/x-win-bitmap",
        "image/svg+xml",
    },
    "voice": {
        "audio/wav", "audio/x-wav", "audio/wave", "audio/mpeg",
        "audio/mp4", "audio/ogg", "audio/x-m4a", "audio/webm", "application/octet-stream",
    },
    # 视频常见容器：MP4/MOV/M4V（ISOBMFF）、WebM/MKV（EBML）；浏览器可内联播放优先
    "video": {
        "video/mp4", "video/webm", "video/quicktime", "video/x-m4v",
        "video/x-matroska", "video/3gpp", "video/3gpp2",
    },
    # 文件类型的常见格式白名单（用于记录/文档）；实际校验走黑名单模式
    # （_mime_allowed 对 KIND_FILE 除可执行文档外一律放行，见 _FILE_BLOCKED_MIMES），
    # 满足「任意格式」传输需求；浏览器对未知扩展名通常上报 octet-stream 兜底。
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

# 文件类型禁用的可执行文档 MIME：上传后可能被浏览器直接打开执行脚本的
# 文档类型（HTML/SVG/XML/JS）。「任意格式」的工程安全边界——下载/预览
# 场景（<a download> + nosniff + CSP）已有防护，此处再排除可执行文档双保险。
_FILE_BLOCKED_MIMES = {
    "text/html", "application/xhtml+xml",
    "image/svg+xml",
    "application/javascript", "text/javascript", "application/x-javascript",
    "application/xml", "text/xml",
}

# 文件头嗅探（魔数）——按 MIME 分类
_SNIFFERS = [
    # (kind, magic_bytes, mime_guess)
    ("image", b"\x89PNG\r\n\x1a\n", "image/png"),
    ("image", b"\xff\xd8\xff", "image/jpeg"),
    ("image", b"GIF87a", "image/gif"),
    ("image", b"GIF89a", "image/gif"),
    ("image", b"RIFF", "image/webp"),  # WebP 头 RIFF....WEBP
    ("image", b"BM", "image/bmp"),  # BMP（BITMAPINFOHEADER 等均以 BM 开头）
    ("image", b"II*\x00", "image/tiff"),  # TIFF 小端
    ("image", b"MM\x00*", "image/tiff"),  # TIFF 大端
    ("image", b"\x00\x00\x01\x00", "image/x-icon"),  # ICO/CUR
    ("voice", b"RIFF", "audio/x-wav"),  # WAV
    ("voice", b"ID3", "audio/mpeg"),  # MP3 带 ID3
    ("voice", b"\xff\xfb", "audio/mpeg"),  # MP3 无标签
    ("voice", b"OggS", "audio/ogg"),
    ("voice", b"fLaC", "audio/flac"),
    ("voice", b"\x1a\x45\xdf\xa3", "audio/webm"),  # WebM/EBML（浏览器 MediaRecorder 默认输出）
    ("voice", b"\x1a\x45\xdf\xa3\x93\x42\x82\x88matroska", "audio/webm"),  # MKV 容器（部分录制器）
    ("video", b"\x1a\x45\xdf\xa3", "video/webm"),  # WebM/MKV（EBML 容器，音视频同魔数）
    ("file", b"%PDF", "application/pdf"),
    ("file", b"PK\x03\x04", "application/zip"),
]


def _max_bytes(kind: str) -> int | None:
    """该 kind 的大小上限（字节）；配置为 <=0 时返回 None 表示不设上限。"""
    mapping = {
        MediaObject.KIND_IMAGE: getattr(settings, "MEDIA_MAX_IMAGE_BYTES", 0),
        MediaObject.KIND_VOICE: getattr(settings, "MEDIA_MAX_VOICE_BYTES", 0),
        MediaObject.KIND_VIDEO: getattr(settings, "MEDIA_MAX_VIDEO_BYTES", 0),
        MediaObject.KIND_FILE: getattr(settings, "MEDIA_MAX_FILE_BYTES", 50 * 1024 * 1024),
        MediaObject.KIND_EMOJI: getattr(settings, "MEDIA_MAX_EMOJI_BYTES", 5 * 1024 * 1024),
    }
    value = mapping.get(kind, 0)
    if value is None or int(value) <= 0:
        return None
    return int(value)


def _exceeds_max(kind: str, size: int) -> bool:
    """size 是否超过该 kind 上限；无上限（None）时恒为 False。"""
    max_bytes = _max_bytes(kind)
    return max_bytes is not None and size > max_bytes


def _ttl_seconds() -> int:
    return int(getattr(settings, "MEDIA_TMP_TTL_SECONDS", 600))


def _mime_allowed(kind: str, mime_type: str) -> bool:
    if kind == MediaObject.KIND_FILE:
        # 文件类型不做 MIME 白名单约束（魔数仅要求非空），只排除可执行文档；
        # 其余任意 MIME（含 octet-stream 兜底）放行，满足「任意格式」需求。
        return mime_type not in _FILE_BLOCKED_MIMES
    return mime_type in ALLOWED_MIME.get(kind, set())


def _sniff_isobmff_still_image(data: bytes) -> bool:
    """识别 ISOBMFF 容器静态图（AVIF / HEIC / HEIF）。

    头部为 4 字节 box size + b"ftyp" + 4 字节 major brand：
    avif/avis=AVIF；heic/heix/hevc/hevx/mif1/msf1/heim/heis/micl=HEIF/HEIC 家族。
    """
    if len(data) < 12 or data[4:8] != b"ftyp":
        return False
    brand = data[8:12]
    return brand in {
        b"avif", b"avis",
        b"heic", b"heix", b"hevc", b"hevx",
        b"mif1", b"msf1", b"heim", b"heis", b"micl",
    }


def _sniff_isobmff_video(data: bytes) -> bool:
    """识别 ISOBMFF 容器视频（MP4/MOV/M4V/3GP）。

    与静态图共用 ftyp 结构但 brand 集合不同：isom/mp42/mp41/avc1/dash 等。
    """
    if len(data) < 12 or data[4:8] != b"ftyp":
        return False
    brand = data[8:12]
    return brand in {
        b"isom", b"iso2", b"mp41", b"mp42", b"avc1",
        b"dash", b"mmdb", b"mp71", b"msnv", b"xavc",
        b"jvt", b"hev1", b"hvc1", b"3gp4", b"3gp5", b"3gp6", b"3ge6",
    }


def _sniff_svg(data: bytes) -> bool:
    """识别 SVG（XML 文本）：BOM/空白后以 <?xml 或 <svg 开头，或前缀含 <svg 元素。"""
    text = data.lstrip(b"\xef\xbb\xbf \t\r\n")[:512]
    lowered = text.lower()
    return lowered.startswith(b"<?xml") or b"<svg" in lowered


def _sniff_kind(data: bytes, declared_kind: str) -> bool:
    """文件头嗅探：数据开头的魔数是否与声明的 kind 匹配。

    emoji 与 image 一样是位图（PNG/JPEG/GIF/WebP 等），复用同一魔数集校验；
    AVIF/HEIC/HEIF（ISOBMFF）与 SVG 的头部形态特殊，走专用分支。
    """
    if declared_kind == MediaObject.KIND_FILE:
        # 文件类型不做强魔数约束（任意合法 MIME 均可），但至少要有内容
        return len(data) > 0

    is_image_like = declared_kind in (MediaObject.KIND_IMAGE, MediaObject.KIND_EMOJI)
    if is_image_like and (_sniff_isobmff_still_image(data) or _sniff_svg(data)):
        return True
    if declared_kind == MediaObject.KIND_VIDEO and (
        _sniff_isobmff_video(data) or data.startswith(b"\x1a\x45\xdf\xa3")
    ):
        # 视频：ISOBMFF（MP4/MOV/M4V/3GP）或 EBML（WebM/MKV）
        return True
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


# 分块哈希/嗅探的块大小（1 MiB）
_HASH_CHUNK_SIZE = 1024 * 1024
# 嗅探只需头部几十字节（ftyp/SVG/magic），取 64 字节足够
_SNIFF_HEAD_BYTES = 64


def _content_hash_stream(fileobj) -> str:
    """分块计算 sha256（fileobj 需支持 read/seek）；大文件不整体进内存。"""
    h = hashlib.sha256()
    fileobj.seek(0)
    while True:
        chunk = fileobj.read(_HASH_CHUNK_SIZE)
        if not chunk:
            break
        h.update(chunk)
    return h.hexdigest()


def create_upload_session(user, *, kind: str, expected_size: int, mime_type: str) -> MediaUploadSession:
    """创建受控上传会话（步骤文件 5.1 POST /uploads）。

    - 服务端策略校验（不信任客户端最终声明）：kind 合法、MIME 在 allowlist、
      大小不超过该 kind 上限（图片/语音默认 0=不设上限）；
    - 返回会话，owner 仅上传者本人。
    """
    if kind not in dict(MediaObject.KIND_CHOICES):
        raise ValueError("unsupported_media_kind")
    if not _mime_allowed(kind, mime_type):
        raise ValueError("unsupported_media_type")
    if expected_size <= 0:
        raise ValueError("invalid_expected_size")
    if _exceeds_max(kind, expected_size):
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


def cancel_upload_session(session: MediaUploadSession) -> None:
    """取消上传：删除临时对象并删除会话记录（幂等；前端「取消」按钮）。

    取消后 upload_id 立即失效（后续 PUT/complete 均 404），临时存储即刻释放；
    不会影响已 complete 生成的 MediaObject（它们走正式 storage_path）。
    """
    store = storage.get_storage()
    store.delete(storage.tmp_key(session.upload_id))
    MediaUploadSession.objects.filter(pk=session.pk).delete()


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
    """:complete 权威动作：轻校验 → 去重 → 建 MediaObject → 派生（尽力而为）。

    幂等：同 upload 重复 complete 返回同一 media_id。
    预签名直传架构下数据面不经过应用服务器：此处只做 head 元信息校验
    （size 对齐 expected_size）+ 服务端对象复制（copy），大文件字节流
    不再流入 Django 进程（内存吞噬 / 同步线程阻塞的根治）。
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

    try:
        stat = store.stat(tmp_key)
    except Exception as exc:
        logger.warning("stat tmp %s failed: %s", tmp_key, exc)
        raise ValueError("media_data_missing")
    total = int(stat["size"])
    if total != session.expected_size:
        raise ValueError("media_size_mismatch")
    if not _mime_allowed(session.kind, session.mime_type):
        raise ValueError("unsupported_media_type")
    # 魔数嗅探只需头部：Range 读头部 64 字节（直传架构下代替全量流嗅探）
    head = store.get_range(tmp_key, 0, min(_SNIFF_HEAD_BYTES - 1, max(total - 1, 0)))
    if not _sniff_kind(head, session.kind):
        raise ValueError("media_integrity_failed")
    # 直传（单次 PUT）对象的 ETag 即内容 MD5，可作 content_hash；
    # 异常形态（空 etag 等）兜底随机值——去重退化为不命中，不影响正确性
    digest = stat.get("etag") or uuid.uuid4().hex

    with transaction.atomic():
        # 去重：同 content_hash 且同 kind 已存在则复用既有 media_id（不改变 owner 语义）。
        # 必须带 kind 条件：同一张图先以 image 发过、再以 emoji 传群表情包时，
        # 若跨 kind 复用会得到 kind=image 的 media，群表情包 add_item 校验
        # media.kind != KIND_EMOJI 会报 media_type_mismatch（任务 03 实测）。
        dup = MediaObject.objects.filter(
            content_hash=digest, kind=session.kind
        ).first()
        if dup is not None:
            media = dup
            # 复用去重对象时不移动 tmp（tmp 由 cleanup 兜底过期清理）
        else:
            media_id = uuid.uuid4().hex
            media = MediaObject.objects.create(
                media_id=media_id,
                owner=user,
                kind=session.kind,
                content_hash=digest,
                mime_type=session.mime_type,
                size=total,
                storage_path=storage.original_key(session.kind, media_id),
                status=MediaObject.STATUS_PROCESSING,
            )
            # 服务端复制 tmp → 正式 key（数据面在对象存储内部完成）
            store.copy(
                tmp_key, media.storage_path,
                content_type=session.mime_type or "application/octet-stream",
            )
            # 清除临时对象（owner 已确认，cleanup 兜底）
            try:
                store.delete(tmp_key)
            except Exception as exc:
                logger.warning("delete tmp %s failed: %s", tmp_key, exc)
        # 派生（尽力而为，失败不阻塞/不置 failed；大文件跳过派生）
        _generate_derivatives(media, total)
        if media.status == MediaObject.STATUS_PROCESSING:
            media.status = MediaObject.STATUS_READY
            media.save(update_fields=["status"])

    # 幂等标记：upload 会话已 completed，并回填生成的 media_id 作为幂等锚点
    MediaUploadSession.objects.filter(pk=session.pk).update(
        status=MediaUploadSession.STATUS_COMPLETED,
        media_id=media.media_id,
    )
    return media


# 派生输入上限：超过该大小的媒体读入内存处理前需走临时文件路径（防 OOM）。
# 图片缩略图对气泡性能是刚需（无缩略图 = 气泡拉原图 = 卡顿），大图也必须生成；
# 音频 waveform 需全量解码，大文件仍跳过（前端回退原音频播放）。
_DERIVATIVE_MAX_INPUT_BYTES = 64 * 1024 * 1024
# 解码后像素保护：超过该像素数的图片跳过缩略图（极端大图解码内存不可控）
_DERIVATIVE_MAX_PIXELS = 150_000_000


def _generate_derivatives(media: MediaObject, size: int) -> None:
    """派生资源生成（尽力而为，失败只留 warning，不把媒体置 failed）。

    小文件（≤ _DERIVATIVE_MAX_INPUT_BYTES）直接从对象存储读取处理；
    大文件分两种：
      - 图片/表情：流式下载到 MEDIA_TMP_DIR 临时文件后用 PIL 打开生成
        缩略图（带解码像素保护），避免「大图无缩略图 → 气泡拉原图卡顿」；
      - 音频：跳过波形派生（全量解码内存风险，前端回退原音频）。
    """
    store = storage.get_storage()
    if size > _DERIVATIVE_MAX_INPUT_BYTES:
        if media.kind not in (MediaObject.KIND_IMAGE, MediaObject.KIND_EMOJI):
            logger.info(
                "skip derivatives for large media %s (%d bytes > %d)",
                media.media_id, size, _DERIVATIVE_MAX_INPUT_BYTES,
            )
            return
        # 大图：下载到数据盘临时文件再派生（不整块进内存）
        import tempfile

        tmp = tempfile.TemporaryFile(dir=str(settings.MEDIA_TMP_DIR))
        try:
            total = store.download_to(media.storage_path, tmp)
            if total != size:
                logger.warning(
                    "derivative download size mismatch for %s (%d != %d), skip",
                    media.media_id, total, size,
                )
                return
            tmp.seek(0)
            self_generate_thumbnail_from_file(media, tmp, store)
        except Exception:
            logger.warning(
                "large-image thumbnail derivation failed for media %s (media stays ready)",
                media.media_id,
                exc_info=True,
            )
        finally:
            tmp.close()
        return
    data = store.get(media.storage_path)
    if media.kind in (MediaObject.KIND_IMAGE, MediaObject.KIND_EMOJI):
        try:
            from io import BytesIO

            from PIL import Image

            with Image.open(BytesIO(data)) as im:
                width, height = im.size
                thumb_bytes, content_type = _encode_thumbnail(im)
            thumb_key = storage.thumbnail_key(media.kind, media.media_id)
            store.put(thumb_key, thumb_bytes, content_type=content_type)
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


# 缩略图规格：720px / q88（用户反馈 320px/q82 过糊）；动图保留动画输出 GIF
_THUMB_MAX_SIDE = 720
_THUMB_JPEG_QUALITY = 88
_THUMB_MAX_FRAMES = 64


def _encode_thumbnail(im, max_side: int = _THUMB_MAX_SIDE) -> tuple[bytes, str]:
    """从 PIL Image 编码缩略图字节。

    动图（GIF/动 WebP）→ 动画 GIF（保动画；帧数上限 _THUMB_MAX_FRAMES）；
    静图 → JPEG。返回 (bytes, content_type)。JPEG 走 draft 降采样解码
    （巨图内存峰值几 MB）。调用方需先做像素保护。
    """
    import io as _io

    from PIL import Image

    animated = getattr(im, "is_animated", False)
    if not animated:
        if im.format == "JPEG":
            im.draft("RGB", (max_side, max_side))
        im.thumbnail((max_side, max_side))
        buf = _io.BytesIO()
        im.convert("RGB").save(buf, format="JPEG", quality=_THUMB_JPEG_QUALITY)
        return buf.getvalue(), "image/jpeg"

    # 动图：逐帧缩放后合成动画 GIF
    try:
        frame_count = min(im.n_frames, _THUMB_MAX_FRAMES)
    except AttributeError:
        frame_count = 1
    frames = []
    durations = []
    for i in range(frame_count):
        im.seek(i)
        frame = im.convert("RGB").copy()
        frame.thumbnail((max_side, max_side))
        frames.append(frame)
        durations.append(int(im.info.get("duration", 80)) or 80)
    buf = _io.BytesIO()
    frames[0].save(
        buf, format="GIF", save_all=True, append_images=frames[1:],
        duration=durations[: len(frames)], loop=0,
    )
    return buf.getvalue(), "image/gif"


def self_generate_thumbnail_from_file(media: MediaObject, fileobj, store) -> None:
    """从本地临时文件生成缩略图并上传（大图专用路径，动图保动画）。

    带解码像素保护：Image.open 只读头部拿尺寸，超大图跳过（防解码 OOM）。
    """
    from PIL import Image

    fileobj.seek(0)
    with Image.open(fileobj) as im:
        width, height = im.size
        if width * height > _DERIVATIVE_MAX_PIXELS:
            logger.info(
                "skip thumbnail for %s: %dx%d exceeds pixel guard",
                media.media_id, width, height,
            )
            return
        thumb_bytes, content_type = _encode_thumbnail(im)
    thumb_key = storage.thumbnail_key(media.kind, media.media_id)
    store.put(thumb_key, thumb_bytes, content_type=content_type)
    media.thumbnail_path = thumb_key
    media.width = width
    media.height = height
    media.save(update_fields=["thumbnail_path", "width", "height"])


# ---------- 访问控制（工程硬约束，步骤文件 5.3） ----------

def parse_avatar_media_id(url: str) -> str | None:
    """从头像 content URL（/api/v1/media/<media_id>/content）解析 media_id。

    非该格式返回 None。头像只接受内部媒体地址（禁止把外部 URL 当头像引用）。
    """
    if not url:
        return None
    prefix = "/api/v1/media/"
    if not url.startswith(prefix):
        return None
    rest = url[len(prefix):]
    media_id, sep, suffix = rest.partition("/")
    if not sep or not media_id or suffix != "content":
        return None
    return media_id


def validate_avatar_url(user, url: str) -> str | None:
    """校验头像 content URL（用户头像/群头像共用）。

    空串允许（表示清除头像）；否则必须是 /api/v1/media/<id>/content 格式、
    对应媒体存在且为图片、且请求者有访问权。返回错误文案，合法返回 None。
    """
    url = (url or "").strip()
    if not url:
        return None
    media_id = parse_avatar_media_id(url)
    if media_id is None:
        return "头像必须是有效的媒体地址"
    media = MediaObject.objects.filter(media_id=media_id).first()
    if media is None:
        return "头像媒体不存在"
    if media.kind != MediaObject.KIND_IMAGE:
        return "头像必须是图片"
    if user is not None and not can_access_media(user, media):
        return "无权使用该媒体作为头像"
    return None


def can_access_media(user, media: MediaObject) -> bool:
    """媒体访问权判定。

    1. owner：上传者本人永远可访问；
    2. 消息引用：media 被某条 Message 引用，且 user 是该消息所在会话的成员；
    3. 帖子配图：media 被某 PostImage 引用，且 user 能查看该帖子（S3）；
    4. 表情包：media 属于某 EmojiItem，且该包是系统包（全员）、用户自己的个人包，
       或用户所在的群表情包（任务 03）；
    5. 头像引用：media 被某用户设为头像 → 登录用户可见；
       被某群设为头像 → 该群成员可见（M5-2.1 头像资源路径）；
    6. 其他情况：拒绝（403/404）。
    """
    if media.owner_id == user.id:
        return True

    # 消息引用路径（核心："在聊天里收到图片/文件，就能打开它"）
    # 同一媒体可能被转发进多个会话，任一会话成员均可访问，故查全部引用消息。
    # 两种引用形态：
    #   a) 单媒体消息：Message.media_id 列；
    #   b) 图文混排消息（第四轮重构）：segments JSON 内的 {"type": ..., "media_id": ...}
    #      —— DB 层用 JSON contains 粗筛（引号包裹精确匹配 media_id 文本），
    #      Python 层再精确校验 segments 结构，避免文本误命中放权。
    from apps.chat.models import Message
    from apps.chat.services import user_can_access as chat_user_can_access

    msgs = Message.objects.filter(media_id=media.media_id).select_related("conversation")
    for msg in msgs:
        if chat_user_can_access(user, msg.conversation):
            return True

    seg_msgs = (
        # SQLite JSONField 无 contains 支持；icontains 对序列化文本做 LIKE 粗筛，
        # Python 层再精确校验 segments 结构，避免文本误命中放权。
        Message.objects.filter(segments__icontains=media.media_id)
        .select_related("conversation")
    )
    for msg in seg_msgs:
        segs = msg.segments
        if isinstance(segs, str):  # 防御：历史/异常数据可能存为 JSON 文本
            try:
                import json as _json

                segs = _json.loads(segs)
            except Exception:
                continue
        if not isinstance(segs, list):
            continue
        referenced = any(
            isinstance(seg, dict) and seg.get("media_id") == media.media_id
            for seg in segs
        )
        if referenced and chat_user_can_access(user, msg.conversation):
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
        # 群表情包（任务 03）：media 属于某群表情包 → 该群成员可见
        if item.pack.group_id is not None:
            from apps.chat.services import user_can_access as chat_user_can_access

            if chat_user_can_access(user, item.pack.group):
                return True

    # 头像引用路径（M5-2.1）：
    # - 用户头像：被任意 User.avatar 引用 → 登录用户可见（头像出现在公开卡片/成员列表/搜索等）；
    # - 群头像：被某群 Conversation.avatar 引用 → 仅该群成员可见。
    from apps.accounts.models import User

    if User.objects.filter(avatar__contains=media.media_id).exists():
        return True

    from apps.chat.models import Conversation

    if Conversation.objects.filter(
        avatar__contains=media.media_id, members__user=user
    ).exists():
        return True

    # 直播间封面：按直播间可见性复用 can_view，避免封面 URL 暴露后变成越权入口。
    from apps.live.models import Danmaku, LiveChannel
    from apps.common.visibility import can_view as _live_can_view

    for channel in LiveChannel.objects.filter(cover__contains=media.media_id):
        if _live_can_view(user, channel):
            return True

    # 弹幕图片：仅该弹幕所属直播间的可见观众可访问。
    for danmaku in Danmaku.objects.filter(media_id=media.media_id).select_related("channel"):
        if _live_can_view(user, danmaku.channel):
            return True

    # 语音房独立聊天图片：仅该语音房可见成员可访问。
    from apps.voice.models import VoiceChatMessage
    from apps.common.visibility import can_view as _voice_can_view

    for message in VoiceChatMessage.objects.filter(media_id=media.media_id).select_related("channel"):
        if _voice_can_view(user, message.channel):
            return True

    return False


def get_media_or_none(media_id: str) -> MediaObject | None:
    return MediaObject.objects.filter(media_id=media_id).first()


# faststart 重排适用容器（ISO-BMFF mp4 家族；WebM/MKV 是 EBML 结构绝不能进）
FASTSTART_MIMES = ("video/mp4", "video/x-m4v")


def _is_faststart_candidate(media: MediaObject) -> bool:
    return (
        media.kind == MediaObject.KIND_VIDEO
        and (media.mime_type or "").split(";")[0].strip().lower() in FASTSTART_MIMES
        and bool(media.storage_path)
    )


def ensure_video_faststart(media_id: str) -> bool:
    """对 mp4 视频做 faststart 重排（moov 前置），替换 original 对象。

    起播性能根治：moov 尾置的视频浏览器起播前需 2~3 次 Range 往返（读头→
    读尾拿元数据→回头缓冲）；重排后一次顺序读即可边下边播。纯容器级平移，
    总字节数与编码不变（apps/media/faststart.py）。

    幂等：已是 faststart 的对象直接跳过（False）。失败语义：任何异常只留
    warning 并保留原对象——播放可用性永远不受影响，绝不抛出到调用链上层。
    替换采用「写 tmp key → stat 校验 → 服务端 copy → 删 tmp」与 complete
    相同的原子模式，content_hash 同步更新为替换后的 etag。
    """
    from .faststart import remux_file_faststart

    try:
        media = MediaObject.objects.filter(media_id=media_id).first()
        if media is None or not _is_faststart_candidate(media):
            return False
        store = storage.get_storage()
        original_key = media.storage_path
        if not store.exists(original_key):
            return False
        old_size = store.head(original_key)

        import tempfile

        with tempfile.TemporaryFile(dir=str(settings.MEDIA_TMP_DIR)) as src:
            store.download_to(original_key, src)
            src.seek(0)
            with tempfile.TemporaryFile(dir=str(settings.MEDIA_TMP_DIR)) as dst:
                if not remux_file_faststart(src, dst):
                    return False  # 已是 faststart / 无 moov，无需处理
                dst.seek(0, 2)
                new_size = dst.tell()
                if new_size != old_size:
                    logger.warning(
                        "faststart: size mismatch for %s (%d != %d), keep original",
                        media_id, new_size, old_size,
                    )
                    return False
                dst.seek(0)
                tmp_key = storage.tmp_key(f"faststart-{media_id}")
                try:
                    content_type = media.mime_type or "video/mp4"
                    store.put_stream(tmp_key, dst, content_type=content_type)
                    stat = store.stat(tmp_key)
                    if stat["size"] != old_size:
                        logger.warning(
                            "faststart: stored size mismatch for %s, keep original", media_id
                        )
                        return False
                    store.copy(tmp_key, original_key, content_type=content_type)
                    media.content_hash = stat["etag"] or media.content_hash
                    media.save(update_fields=["content_hash"])
                    logger.info(
                        "faststart remux done for %s (%d bytes)", media_id, new_size
                    )
                    return True
                finally:
                    store.delete(tmp_key)
    except Exception:
        logger.warning(
            "faststart remux failed for %s (original kept)", media_id, exc_info=True
        )
        return False


def schedule_video_faststart(media: MediaObject) -> None:
    """后台线程触发 faststart 重排（poster 上传后调用）。

    重排涉及全量下载/上传对象（大视频秒级~十秒级），绝不占用同步请求线程
    （channels thread_sensitive 串行队列）；daemon 线程失败只留日志。
    非 mp4 视频直接跳过。
    """
    import threading

    if not _is_faststart_candidate(media):
        return

    def _run():
        ensure_video_faststart(media.media_id)

    threading.Thread(
        target=_run, daemon=True, name=f"faststart-{media.media_id[:12]}"
    ).start()
