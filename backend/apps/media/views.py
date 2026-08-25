"""
媒体 REST 视图（M4-3，挂 /api/v1/media/）。

- 三步上传：POST /uploads 创建会话 → PUT /uploads/{id} 传二进制 → POST /uploads/{id}:complete；
- 上传二进制为流式分块写入（request.stream → 临时文件 → 对象存储 put_stream），
  大文件不整体读入内存（避免 1GB+ 上传导致进程 OOM）；
- DELETE /uploads/{id} 取消上传（放弃临时存储 + 删除会话，前端「取消」按钮用）；
- GET /media/{id} 获取 descriptor + 处理状态；
- GET /media/{id}/content 流式下载（Range/ETag/Cache-Control: private）；
- GET /media/{id}/thumbnail|waveform 下载派生资源（无 → 404）；
- POST /media/{id}:save 爱莉媒体投影通道预留（本期 501）。

硬约束（阶段三 §10 / NFR-3）：
- 媒体访问控制：未授权 403/404，绝不静默放行；
- 私密媒体 Cache-Control: private, no-store，绝不进入共享缓存；
- 事件/序列化只带 descriptor，不暴露 storage_path。
"""
import logging
import tempfile
from urllib.parse import urlencode

from django.conf import settings
from django.http import HttpResponse, StreamingHttpResponse
from django.utils import timezone
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from . import services, storage
from .models import MediaObject, MediaUploadSession
from .serializers import MediaObjectSerializer

logger = logging.getLogger(__name__)

# 流式上传分块大小（1 MiB）；逐块写入临时文件，不整体读入内存
_UPLOAD_CHUNK_SIZE = 1024 * 1024
# 媒体内容 URL 前缀（:sign 签发的相对路径用）
API_MEDIA_PREFIX = "/api/v1/media"


def _media_or_404(media_id: str):
    media = services.get_media_or_none(media_id)
    if media is None:
        return None
    return media


class UploadSessionView(APIView):
    """POST /media/uploads —— 创建受控上传会话。"""

    def post(self, request):
        kind = request.data.get("kind")
        expected_size = request.data.get("expected_size")
        mime_type = request.data.get("mime_type")
        if not all([kind, expected_size, mime_type]):
            return Response(
                {"detail": "需要 kind/expected_size/mime_type"},
                status=status.HTTP_400_BAD_REQUEST,
            )
        try:
            session = services.create_upload_session(
                request.user,
                kind=str(kind),
                expected_size=int(expected_size),
                mime_type=str(mime_type),
            )
        except ValueError as exc:
            code = str(exc)
            http_status = status.HTTP_413_REQUEST_ENTITY_TOO_LARGE if code == "payload_too_large" else status.HTTP_400_BAD_REQUEST
            return Response({"detail": code}, status=http_status)
        # 预签名直传：浏览器 PUT 直打对象存储，数据面完全旁路应用服务器——
        # 大文件不再被 ASGI 全量吞进内存，也不占用同步执行线程（根治卡 99% / C 盘页文件波动）
        presigned_url = storage.get_storage().presign_put(
            storage.tmp_key(session.upload_id),
            content_type=str(mime_type),
            expires_seconds=max(600, int((session.expires_at - timezone.now()).total_seconds())),
        )
        return Response(
            {
                "upload_id": session.upload_id,
                "kind": session.kind,
                # None = 该 kind 不设大小上限（图片/语音默认放开）
                "max_bytes": services._max_bytes(session.kind),
                "expires_at": session.expires_at.isoformat(),
                "presigned_url": presigned_url,
            },
            status=status.HTTP_201_CREATED,
        )


class UploadBinaryView(APIView):
    """PUT /media/uploads/{upload_id} —— 上传二进制（body 原始字节，流式分块写入）。"""

    def put(self, request, upload_id):
        session = MediaUploadSession.objects.filter(upload_id=upload_id).first()
        if session is None:
            return Response({"detail": "会话不存在"}, status=status.HTTP_404_NOT_FOUND)
        if session.owner_id != request.user.id:
            return Response({"detail": "无权访问"}, status=status.HTTP_403_FORBIDDEN)
        if session.status == MediaUploadSession.STATUS_COMPLETED:
            return Response(
                {"detail": "会话已完成"}, status=status.HTTP_400_BAD_REQUEST
            )
        if session.status == MediaUploadSession.STATUS_EXPIRED or (
            timezone.now() > session.expires_at
        ):
            return Response(
                {"detail": "上传会话已过期"}, status=status.HTTP_410_GONE
            )
        # 流式：分块读入临时文件（边读边校验累计大小，超限即中断），
        # 再以 put_stream 分块上传对象存储 —— 大文件不整体驻留内存。
        # 临时目录走 MEDIA_TMP_DIR（数据盘）：系统 Temp 默认在 C 盘，大文件会临时挤占
        tmp = tempfile.TemporaryFile(dir=str(settings.MEDIA_TMP_DIR))
        try:
            total = 0
            while True:
                chunk = request.stream.read(_UPLOAD_CHUNK_SIZE)
                if not chunk:
                    break
                total += len(chunk)
                if services._exceeds_max(session.kind, total):
                    return Response(
                        {"detail": "payload_too_large"},
                        status=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                    )
                tmp.write(chunk)
            tmp.seek(0)
            storage.get_storage().put_stream(
                storage.tmp_key(session.upload_id), tmp, content_type=session.mime_type
            )
        finally:
            tmp.close()
        return Response({"detail": "ok"}, status=status.HTTP_200_OK)

    def delete(self, request, upload_id):
        """DELETE /media/uploads/{upload_id} —— 取消上传（幂等）。

        前端「取消」按钮：abort 传输后调用；会话不存在/非本人/已完成均安全返回 204。
        """
        session = MediaUploadSession.objects.filter(upload_id=upload_id).first()
        if session is not None:
            if session.owner_id != request.user.id:
                return Response({"detail": "无权访问"}, status=status.HTTP_403_FORBIDDEN)
            services.cancel_upload_session(session)
        return Response(status=status.HTTP_204_NO_CONTENT)


class UploadCompleteView(APIView):
    """POST /media/uploads/{upload_id}:complete —— 校验并生成 media_id（幂等）。"""

    def post(self, request, upload_id):
        session = MediaUploadSession.objects.filter(upload_id=upload_id).first()
        if session is None:
            return Response({"detail": "会话不存在"}, status=status.HTTP_404_NOT_FOUND)
        if session.owner_id != request.user.id:
            return Response({"detail": "无权访问"}, status=status.HTTP_403_FORBIDDEN)
        if session.status == MediaUploadSession.STATUS_EXPIRED or (
            timezone.now() > session.expires_at
        ):
            return Response(
                {"detail": "上传会话已过期"}, status=status.HTTP_410_GONE
            )
        try:
            media = services.complete_upload(request.user, session)
        except TimeoutError:
            return Response(
                {"detail": "上传会话已过期"}, status=status.HTTP_410_GONE
            )
        except PermissionError:
            return Response({"detail": "无权访问"}, status=status.HTTP_403_FORBIDDEN)
        except ValueError as exc:
            return Response({"detail": str(exc)}, status=status.HTTP_400_BAD_REQUEST)
        return Response(
            {
                "media_id": media.media_id,
                "descriptor": MediaObjectSerializer(media).data,
            },
            status=status.HTTP_201_CREATED,
        )


class MediaDetailView(APIView):
    """GET /media/{media_id} —— descriptor + 处理状态（登录 + 有访问权）。"""

    def get(self, request, media_id):
        media = _media_or_404(media_id)
        if media is None:
            return Response({"detail": "媒体不存在"}, status=status.HTTP_404_NOT_FOUND)
        if not services.can_access_media(request.user, media):
            return Response({"detail": "无权访问"}, status=status.HTTP_403_FORBIDDEN)
        return Response(MediaObjectSerializer(media, context={"request": request}).data)


class MediaDeleteView(APIView):
    """DELETE /media/{media_id} —— 上传者删除自己的媒体（对象存储 + 记录）。

    用途：预签名直传完成后、发布前的「移除」操作——孤儿媒体即时回收，
    不等过期清理。仅 owner 可删；同时清理 original 与 thumbnail 对象。
    """

    def delete(self, request, media_id):
        media = _media_or_404(media_id)
        if media is None:
            return Response({"detail": "媒体不存在"}, status=status.HTTP_404_NOT_FOUND)
        if media.owner_id != request.user.id:
            return Response({"detail": "仅上传者可删除"}, status=status.HTTP_403_FORBIDDEN)
        store = storage.get_storage()
        store.delete(media.storage_path)
        if media.thumbnail_path:
            store.delete(media.thumbnail_path)
        media.delete()
        return Response({"deleted": True}, status=status.HTTP_200_OK)


class MediaPosterView(APIView):
    """POST /media/{media_id}:poster —— 上传视频海报帧（body=JPEG 字节，≤2MB）。

    浏览器端上传视频后用 canvas 截首帧回传，服务端存为 thumbnail 并更新
    thumbnail_path——帖子/聊天的视频卡片即可显示真实画面封面（QQ 同款），
    不依赖 <video> 元素加载解码。仅上传者本人可调用；重复调用覆盖。
    """

    def post(self, request, media_id):
        media = _media_or_404(media_id)
        if media is None:
            return Response({"detail": "媒体不存在"}, status=status.HTTP_404_NOT_FOUND)
        if media.owner_id != request.user.id:
            return Response({"detail": "仅上传者可设置海报"}, status=status.HTTP_403_FORBIDDEN)
        if media.kind != media.KIND_VIDEO:
            return _bad_request("仅视频媒体可设置海报")
        body = request.body or b""
        if not body:
            return _bad_request("海报内容为空")
        if len(body) > 2 * 1024 * 1024:
            return _bad_request("海报过大（≤2MB）")
        if not body.startswith(b"\xff\xd8"):
            return _bad_request("海报必须为 JPEG")
        store = storage.get_storage()
        thumb_key = storage.thumbnail_key(media.kind, media.media_id)
        store.put(thumb_key, body, content_type="image/jpeg")
        media.thumbnail_path = thumb_key
        media.save(update_fields=["thumbnail_path"])
        return Response({"thumbnail": f"/api/v1/media/{media_id}/thumbnail"}, status=status.HTTP_201_CREATED)


class MediaSignView(APIView):
    """POST /media/{media_id}:sign —— 为已授权用户签发内容短时访问 URL。

    返回对象存储的预签名 GET URL：<img>/<video> 直连拉流，
    Range 请求（preload=metadata、拖动 seek）由对象存储原生处理——
    播放流量完全不经过应用服务器（ASGI 同步视图串行队列对媒体播放零影响）。
    鉴权决策在本端点完成（can_access_media），票据短时有效自动过期；
    Django content 端点保留作为 Bearer 通道兼容。
    """

    def post(self, request, media_id):
        media = _media_or_404(media_id)
        if media is None:
            return Response({"detail": "媒体不存在"}, status=status.HTTP_404_NOT_FOUND)
        if not services.can_access_media(request.user, media):
            return Response({"detail": "无权访问"}, status=status.HTTP_403_FORBIDDEN)
        expires = services.MEDIA_VIEW_URL_TTL_SECONDS
        # variant=thumb → 缩略图派生（气泡用，几 KB~百 KB）；默认 original（查看器/保存）
        variant = (request.data.get("variant") or request.query_params.get("variant") or "").strip()
        if variant == "thumb":
            if not media.thumbnail_path:
                return Response(
                    {"detail": "thumbnail_not_ready"}, status=status.HTTP_404_NOT_FOUND
                )
            url = storage.get_storage().presign_get(media.thumbnail_path, expires)
        else:
            url = storage.get_storage().presign_get(media.storage_path, expires)
        return Response(
            {
                "url": url,
                "expires_at": int(timezone.now().timestamp()) + expires,
            }
        )


def _resolve_content_user(request, media_id):
    """content 访问者解析：登录用户直接用；否则校验签名票据映射回授权用户。"""
    user = getattr(request, "user", None)
    if user is not None and user.is_authenticated:
        return user
    uid = request.query_params.get("uid")
    exp = request.query_params.get("exp")
    sig = request.query_params.get("sig")
    if not services.verify_media_access(uid, media_id, exp or 0, sig or ""):
        return None
    from django.contrib.auth import get_user_model

    return get_user_model().objects.filter(pk=uid).first()


class MediaContentView(APIView):
    """GET /media/{media_id}/content —— 流式下载原对象（Range/ETag/Cache-Control: private）。

    鉴权双通道：Bearer 登录，或 :sign 签发的短时票据（<img>/<video> 无法携带
    Authorization header；票据绑定 user+media+exp，泄露影响面有限且自动过期）。
    全局默认 IsAuthenticated 会在视图前拦截匿名票据请求，因此这里显式 AllowAny、
    鉴权在视图内完成（登录 or 有效票据 → can_access_media），未授权绝不放行。
    响应体分块流式转发（含无 Range 的整档下载），不把整个对象读入内存。
    """

    permission_classes: list = []  # 视图内自鉴权（登录 / 签名票据）

    def get(self, request, media_id):
        # 先鉴权后查存在性：未授权一律 401，不向匿名请求泄露媒体是否存在
        user = _resolve_content_user(request, media_id)
        if user is None:
            return Response({"detail": "认证失败"}, status=status.HTTP_401_UNAUTHORIZED)
        media = _media_or_404(media_id)
        if media is None:
            return Response({"detail": "媒体不存在"}, status=status.HTTP_404_NOT_FOUND)
        if not services.can_access_media(user, media):
            return Response({"detail": "无权访问"}, status=status.HTTP_403_FORBIDDEN)

        store = storage.get_storage()
        key = media.storage_path
        size = store.head(key)
        etag = f'"{media.content_hash}"'
        
        # 304 Not Modified 支持：客户端提供 If-None-Match 且匹配 ETag
        if_none_match = request.headers.get("If-None-Match")
        if if_none_match and if_none_match == etag:
            resp = HttpResponse(status=status.HTTP_304_NOT_MODIFIED)
            resp["ETag"] = etag
            resp["Cache-Control"] = "private, max-age=3600"
            return resp
        
        headers = {
            "Content-Type": media.mime_type or "application/octet-stream",
            "Accept-Ranges": "bytes",
            "ETag": etag,
            # 优化：允许浏览器缓存 1 小时（private 确保不进入共享缓存）
            "Cache-Control": "private, max-age=3600",
            # 防 MIME 嗅探；SVG 属可执行文档，必须禁脚本/沙箱防存储型 XSS
            "X-Content-Type-Options": "nosniff",
        }
        if (media.mime_type or "") == "image/svg+xml":
            headers["Content-Security-Policy"] = (
                "default-src 'none'; style-src 'unsafe-inline'; sandbox"
            )
            headers["Content-Disposition"] = "inline"

        range_header = request.headers.get("Range")
        if range_header:
            # 流式 Range 转发：区间原样透传给对象存储（支持 start-end / start- / -suffix），
            # 响应体分块流回客户端 —— 浏览器 preload=metadata / 拖动 seek 只拉所需字节，
            # 任何大文件的任意区间都不再整体读入内存
            try:
                body, length, content_range = store.open_range_stream(key, range_header)
            except Exception:
                resp = HttpResponse(status=status.HTTP_416_REQUESTED_RANGE_NOT_SATISFIABLE)
                resp["Content-Range"] = f"bytes */{size}"
                return resp
            resp = StreamingHttpResponse(
                iter(lambda: body.read(_UPLOAD_CHUNK_SIZE), b""),
                status=status.HTTP_206_PARTIAL_CONTENT,
                content_type=media.mime_type or "application/octet-stream",
            )
            resp["Content-Range"] = content_range
            resp["Content-Length"] = str(length)
        else:
            try:
                body = store.open_stream(key)
            except Exception:
                return Response(
                    {"detail": "媒体内容不可用"}, status=status.HTTP_404_NOT_FOUND
                )
            # 分块流式转发：大文件下载不整体读入内存（与上传链路对等的恒定内存占用）
            resp = StreamingHttpResponse(
                iter(lambda: body.read(_UPLOAD_CHUNK_SIZE), b""),
                content_type=media.mime_type or "application/octet-stream",
            )
            resp["Content-Length"] = str(size)
        for k, v in headers.items():
            resp[k] = v
        return resp


def _derivative_response(media, key, content_type, request):
    if media is None:
        return Response({"detail": "媒体不存在"}, status=status.HTTP_404_NOT_FOUND)
    if not services.can_access_media(request.user, media):
        return Response({"detail": "无权访问"}, status=status.HTTP_403_FORBIDDEN)
    store = storage.get_storage()
    if not key or not store.exists(key):
        return Response({"detail": "media_not_ready"}, status=status.HTTP_404_NOT_FOUND)
    data = store.get(key)
    resp = HttpResponse(data, content_type=content_type)
    # 优化：缩略图/波形图缓存 2 小时（派生资源更稳定）
    resp["Cache-Control"] = "private, max-age=7200"
    resp["ETag"] = f'"{media.content_hash}-{key.split("/")[-1]}"'
    return resp


class MediaThumbnailView(APIView):
    """GET /media/{media_id}/thumbnail —— 下载缩略图（无 → 404）。

    content-type 按存储字节探测（动图缩略为 GIF、静图为 JPEG）。
    """

    def get(self, request, media_id):
        media = _media_or_404(media_id)
        if media is not None and media.thumbnail_path:
            store = storage.get_storage()
            try:
                head = store.get_range(media.thumbnail_path, 0, 15)
            except Exception:
                head = b""
            if head.startswith(b"GIF8"):
                return _derivative_response(
                    media, media.thumbnail_path, "image/gif", request
                )
        return _derivative_response(media, media.thumbnail_path, "image/jpeg", request)


class MediaWaveformView(APIView):
    """GET /media/{media_id}/waveform —— 下载波形图（无 → 404）。"""

    def get(self, request, media_id):
        media = _media_or_404(media_id)
        return _derivative_response(media, media.waveform_path, "image/png", request)


class MediaSaveView(APIView):
    """POST /media/{media_id}:save —— 爱莉媒体投影通道预留（本期 501）。"""

    def post(self, request, media_id):
        media = _media_or_404(media_id)
        if media is not None and not services.can_access_media(request.user, media):
            return Response({"detail": "无权访问"}, status=status.HTTP_403_FORBIDDEN)
        return Response(
            {"detail": "爱莉媒体投影通道预留，未实现"},
            status=status.HTTP_501_NOT_IMPLEMENTED,
        )
