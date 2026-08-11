"""
媒体 REST 视图（M4-3，挂 /api/v1/media/）。

- 三步上传：POST /uploads 创建会话 → PUT /uploads/{id} 传二进制 → POST /uploads/{id}:complete；
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

from django.http import HttpResponse, StreamingHttpResponse
from django.utils import timezone
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from . import services, storage
from .models import MediaObject, MediaUploadSession
from .serializers import MediaObjectSerializer

logger = logging.getLogger(__name__)


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
        return Response(
            {
                "upload_id": session.upload_id,
                "kind": session.kind,
                "max_bytes": services._max_bytes(session.kind),
                "expires_at": session.expires_at.isoformat(),
            },
            status=status.HTTP_201_CREATED,
        )


class UploadBinaryView(APIView):
    """PUT /media/uploads/{upload_id} —— 上传二进制（body 原始字节）。"""

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
        data = request.body
        if len(data) > services._max_bytes(session.kind):
            return Response(
                {"detail": "payload_too_large"},
                status=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            )
        storage.get_storage().put(storage.tmp_key(session.upload_id), data)
        return Response({"detail": "ok"}, status=status.HTTP_200_OK)


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


class MediaContentView(APIView):
    """GET /media/{media_id}/content —— 流式下载原对象（Range/ETag/Cache-Control: private）。"""

    def get(self, request, media_id):
        media = _media_or_404(media_id)
        if media is None:
            return Response({"detail": "媒体不存在"}, status=status.HTTP_404_NOT_FOUND)
        if not services.can_access_media(request.user, media):
            return Response({"detail": "无权访问"}, status=status.HTTP_403_FORBIDDEN)

        store = storage.get_storage()
        key = media.storage_path
        size = store.head(key)
        etag = f'"{media.content_hash}"'
        headers = {
            "Content-Type": media.mime_type or "application/octet-stream",
            "Accept-Ranges": "bytes",
            "ETag": etag,
            "Cache-Control": "private, no-store",
        }

        range_header = request.headers.get("Range")
        if range_header:
            try:
                start_s, _, end_s = range_header.replace("bytes=", "").partition("-")
                start = int(start_s) if start_s else 0
                end = int(end_s) if end_s else size - 1
                if start < 0 or end >= size or start > end:
                    raise ValueError
            except ValueError:
                resp = HttpResponse(status=status.HTTP_416_REQUESTED_RANGE_NOT_SATISFIABLE)
                resp["Content-Range"] = f"bytes */{size}"
                return resp
            data = store.get_range(key, start, end)
            resp = HttpResponse(
                data,
                status=status.HTTP_206_PARTIAL_CONTENT,
                content_type=media.mime_type or "application/octet-stream",
            )
            resp["Content-Range"] = f"bytes {start}-{end}/{size}"
            resp["Content-Length"] = str(len(data))
        else:
            try:
                data = store.get(key)
            except Exception:
                return Response(
                    {"detail": "媒体内容不可用"}, status=status.HTTP_404_NOT_FOUND
                )
            resp = HttpResponse(
                data, content_type=media.mime_type or "application/octet-stream"
            )
            resp["Content-Length"] = str(len(data))
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
    resp["Cache-Control"] = "private, no-store"
    return resp


class MediaThumbnailView(APIView):
    """GET /media/{media_id}/thumbnail —— 下载缩略图（无 → 404）。"""

    def get(self, request, media_id):
        media = _media_or_404(media_id)
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
