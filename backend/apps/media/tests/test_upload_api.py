"""三步上传契约测试（8.1 清单：闭环、幂等、MIME/大小/hash 校验、越权、过期）。

大小上限策略（产品要求）：图片/语音默认不设上限（MEDIA_MAX_*_BYTES=0 → None），
file/emoji 仍保留配置上限；新图片格式（AVIF/HEIC/BMP/TIFF/SVG 等）走扩充后的
allowlist 与魔数嗅探。
"""
import pytest

from apps.media.models import MediaObject
from django.conf import settings

from .conftest import (
    make_avif_bytes,
    make_bmp_bytes,
    make_mp4_bytes,
    make_png_bytes,
    make_svg_bytes,
    make_tiff_bytes,
    make_wav_bytes,
    make_webm_video_bytes,
    upload_image,
)


@pytest.mark.django_db
class TestUploadClosedLoop:
    def test_full_closed_loop_image(self, auth_client):
        client, user = auth_client(username="up_a")
        media_id, desc = upload_image(client)
        assert media_id
        assert desc["kind"] == "image"
        assert desc["status"] == "ready"
        assert desc["size"] == len(make_png_bytes())
        assert desc["mime_type"] == "image/png"
        # 缩略图派生存在
        assert desc["thumbnail"].startswith("/api/v1/media/")
        # 原对象已入库，content_hash 为 sha256（M4-3 完整性契约）
        obj = MediaObject.objects.get(media_id=media_id)
        assert obj.owner_id == user.id
        import hashlib
        assert obj.content_hash == hashlib.sha256(make_png_bytes()).hexdigest()

    def test_complete_idempotent_same_media(self, auth_client):
        client, _ = auth_client(username="up_b")
        data = make_png_bytes()
        resp = client.post(
            "/api/v1/media/uploads",
            {"kind": "image", "expected_size": len(data), "mime_type": "image/png"},
            format="json",
        )
        upload_id = resp.json()["upload_id"]
        client.put(
            f"/api/v1/media/uploads/{upload_id}", data=data, content_type="application/octet-stream"
        )
        r1 = client.post(f"/api/v1/media/uploads/{upload_id}:complete", format="json")
        r2 = client.post(f"/api/v1/media/uploads/{upload_id}:complete", format="json")
        assert r1.status_code == 201
        assert r2.status_code == 201
        assert r1.json()["media_id"] == r2.json()["media_id"]
        # 不重复建对象
        assert MediaObject.objects.filter(media_id=r1.json()["media_id"]).count() == 1

    def test_wav_upload_generates_waveform_and_duration(self, auth_client):
        client, _ = auth_client(username="up_c")
        data = make_wav_bytes(duration=1.0)
        resp = client.post(
            "/api/v1/media/uploads",
            {"kind": "voice", "expected_size": len(data), "mime_type": "audio/wav"},
            format="json",
        )
        upload_id = resp.json()["upload_id"]
        client.put(
            f"/api/v1/media/uploads/{upload_id}", data=data, content_type="application/octet-stream"
        )
        resp = client.post(f"/api/v1/media/uploads/{upload_id}:complete", format="json")
        assert resp.status_code == 201
        desc = resp.json()["descriptor"]
        assert desc["kind"] == "voice"
        assert desc["status"] == "ready"
        assert desc["duration"] is not None
        assert desc["waveform"].startswith("/api/v1/media/")


@pytest.mark.django_db
class TestUploadValidation:
    def test_upload_declared_mime_not_allowed(self, auth_client):
        client, _ = auth_client(username="up_v1")
        resp = client.post(
            "/api/v1/media/uploads",
            {"kind": "image", "expected_size": 100, "mime_type": "application/x-msdownload"},
            format="json",
        )
        assert resp.status_code == 400

    def test_upload_exceeds_max_bytes(self, auth_client):
        # emoji 未放开上限，超限仍 413（保护未变更类别的契约）
        client, _ = auth_client(username="up_v2")
        resp = client.post(
            "/api/v1/media/uploads",
            {"kind": "emoji", "expected_size": 999 * 1024 * 1024, "mime_type": "image/png"},
            format="json",
        )
        assert resp.status_code == 413

    def test_file_kind_still_capped(self, auth_client):
        # file 类别保留 50MB 上限：图片/语音放开不影响其他类别
        client, _ = auth_client(username="up_v2b")
        resp = client.post(
            "/api/v1/media/uploads",
            {"kind": "file", "expected_size": 51 * 1024 * 1024, "mime_type": "application/pdf"},
            format="json",
        )
        assert resp.status_code == 413

    @pytest.mark.parametrize(
        "kind,size_mb",
        [("image", 64), ("image", 512), ("voice", 256), ("video", 512)],
    )
    def test_image_voice_video_have_no_size_cap(self, auth_client, kind, size_mb):
        """图片/语音/视频默认不设上限：远超旧上限的会话声明也应创建成功。"""
        assert settings.MEDIA_MAX_IMAGE_BYTES == 0
        assert settings.MEDIA_MAX_VOICE_BYTES == 0
        assert settings.MEDIA_MAX_VIDEO_BYTES == 0
        client, _ = auth_client(username=f"up_nocap_{kind}_{size_mb}")
        mime = {
            "image": "image/png",
            "voice": "audio/wav",
            "video": "video/mp4",
        }[kind]
        resp = client.post(
            "/api/v1/media/uploads",
            {"kind": kind, "expected_size": size_mb * 1024 * 1024, "mime_type": mime},
            format="json",
        )
        assert resp.status_code == 201, resp.content
        body = resp.json()
        assert body["max_bytes"] is None

    @pytest.mark.parametrize(
        "make_bytes,mime",
        [
            (lambda: make_mp4_bytes(b"isom"), "video/mp4"),
            (lambda: make_mp4_bytes(b"mp42"), "video/mp4"),
            (make_webm_video_bytes, "video/webm"),
        ],
    )
    def test_complete_sniff_accepts_video(self, auth_client, make_bytes, mime):
        """视频上传闭环：MP4（isom/mp42 brand）与 WebM（EBML）文件头嗅探通过。"""
        client, _ = auth_client(username=f"up_video_{mime.replace('/', '_')}")
        data = make_bytes()
        resp = client.post(
            "/api/v1/media/uploads",
            {"kind": "video", "expected_size": len(data), "mime_type": mime},
            format="json",
        )
        upload_id = resp.json()["upload_id"]
        client.put(
            f"/api/v1/media/uploads/{upload_id}", data=data, content_type="application/octet-stream"
        )
        resp = client.post(f"/api/v1/media/uploads/{upload_id}:complete", format="json")
        assert resp.status_code == 201, resp.content
        desc = resp.json()["descriptor"]
        assert desc["status"] == "ready"
        obj = MediaObject.objects.get(media_id=resp.json()["media_id"])
        assert obj.kind == "video"
        assert obj.mime_type == mime

    def test_video_declared_as_image_rejected(self, auth_client):
        """MP4 字节声明 kind=image → 文件头嗅探失败（kind 级隔离）。"""
        client, _ = auth_client(username="up_video_mismatch")
        data = make_mp4_bytes()
        resp = client.post(
            "/api/v1/media/uploads",
            {"kind": "image", "expected_size": len(data), "mime_type": "image/png"},
            format="json",
        )
        upload_id = resp.json()["upload_id"]
        client.put(
            f"/api/v1/media/uploads/{upload_id}", data=data, content_type="application/octet-stream"
        )
        resp = client.post(f"/api/v1/media/uploads/{upload_id}:complete", format="json")
        assert resp.status_code == 400

    def test_zero_and_negative_size_still_rejected(self, auth_client):
        client, _ = auth_client(username="up_v5")
        resp = client.post(
            "/api/v1/media/uploads",
            {"kind": "image", "expected_size": 0, "mime_type": "image/png"},
            format="json",
        )
        assert resp.status_code == 400

    @pytest.mark.parametrize(
        "mime",
        [
            "image/avif", "image/heic", "image/heif",
            "image/bmp", "image/tiff", "image/x-icon", "image/svg+xml",
        ],
    )
    def test_extended_image_mimes_allowed(self, auth_client, mime):
        client, _ = auth_client(username=f"up_ext_{mime.replace('/', '_').replace('+', '_')}")
        resp = client.post(
            "/api/v1/media/uploads",
            {"kind": "image", "expected_size": 100, "mime_type": mime},
            format="json",
        )
        assert resp.status_code == 201

    @pytest.mark.parametrize(
        "make_bytes,mime",
        [
            (make_bmp_bytes, "image/bmp"),
            (make_tiff_bytes, "image/tiff"),
            (lambda: make_avif_bytes(b"avif"), "image/avif"),
            (lambda: make_avif_bytes(b"heic"), "image/heic"),
            (make_svg_bytes, "image/svg+xml"),
        ],
    )
    def test_complete_sniff_accepts_new_formats(self, auth_client, make_bytes, mime):
        """新格式文件头嗅探通过：BMP/TIFF 真图 + AVIF/HEIC ftyp 头 + SVG 文本。"""
        client, _ = auth_client(username=f"up_sniff_{mime.replace('/', '_').replace('+', '_')}")
        data = make_bytes()
        resp = client.post(
            "/api/v1/media/uploads",
            {"kind": "image", "expected_size": len(data), "mime_type": mime},
            format="json",
        )
        upload_id = resp.json()["upload_id"]
        client.put(
            f"/api/v1/media/uploads/{upload_id}", data=data, content_type="application/octet-stream"
        )
        resp = client.post(f"/api/v1/media/uploads/{upload_id}:complete", format="json")
        assert resp.status_code == 201, resp.content
        desc = resp.json()["descriptor"]
        assert desc["status"] == "ready"
        obj = MediaObject.objects.get(media_id=resp.json()["media_id"])
        assert obj.mime_type == mime

    def test_complete_size_mismatch(self, auth_client):
        client, _ = auth_client(username="up_v3")
        data = make_png_bytes()
        resp = client.post(
            "/api/v1/media/uploads",
            {"kind": "image", "expected_size": len(data) + 100, "mime_type": "image/png"},
            format="json",
        )
        upload_id = resp.json()["upload_id"]
        client.put(
            f"/api/v1/media/uploads/{upload_id}", data=data, content_type="application/octet-stream"
        )
        resp = client.post(f"/api/v1/media/uploads/{upload_id}:complete", format="json")
        assert resp.status_code == 400

    def test_complete_content_sniff_mismatch(self, auth_client):
        client, _ = auth_client(username="up_v4")
        # 声明 image/png 但传文本字节 → 文件头嗅探失败
        data = b"this is not an image at all, definitely not png"
        resp = client.post(
            "/api/v1/media/uploads",
            {"kind": "image", "expected_size": len(data), "mime_type": "image/png"},
            format="json",
        )
        upload_id = resp.json()["upload_id"]
        client.put(
            f"/api/v1/media/uploads/{upload_id}", data=data, content_type="application/octet-stream"
        )
        resp = client.post(f"/api/v1/media/uploads/{upload_id}:complete", format="json")
        assert resp.status_code == 400


@pytest.mark.django_db
class TestUploadAuthz:
    def test_non_owner_cannot_put_or_complete(self, auth_client, user_factory):
        owner_client, owner = auth_client(username="up_o")
        data = make_png_bytes()
        resp = owner_client.post(
            "/api/v1/media/uploads",
            {"kind": "image", "expected_size": len(data), "mime_type": "image/png"},
            format="json",
        )
        upload_id = resp.json()["upload_id"]
        other = user_factory(username="up_intruder")
        from .helpers import auth_as
        intruder = auth_as(other)
        # PUT 越权
        r = intruder.put(
            f"/api/v1/media/uploads/{upload_id}", data=data, content_type="application/octet-stream"
        )
        assert r.status_code == 403
        # complete 越权
        r = intruder.post(f"/api/v1/media/uploads/{upload_id}:complete", format="json")
        assert r.status_code == 403

    def test_expired_session_gone(self, auth_client):
        client, _ = auth_client(username="up_exp")
        data = make_png_bytes()
        resp = client.post(
            "/api/v1/media/uploads",
            {"kind": "image", "expected_size": len(data), "mime_type": "image/png"},
            format="json",
        )
        upload_id = resp.json()["upload_id"]
        from apps.media.models import MediaUploadSession
        from django.utils import timezone
        from datetime import timedelta

        MediaUploadSession.objects.filter(upload_id=upload_id).update(
            expires_at=timezone.now() - timedelta(seconds=1)
        )
        r = client.put(
            f"/api/v1/media/uploads/{upload_id}", data=data, content_type="application/octet-stream"
        )
        assert r.status_code == 410

    def test_unauthenticated_cannot_create(self, api_client):
        resp = api_client.post(
            "/api/v1/media/uploads",
            {"kind": "image", "expected_size": 100, "mime_type": "image/png"},
            format="json",
        )
        assert resp.status_code == 401
