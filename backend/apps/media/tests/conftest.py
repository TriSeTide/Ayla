"""apps/media/tests 共享 fixtures：FakeStorage 注入 + 测试媒体字节生成。

- FakeStorage 已由 settings_test 的 S3_STORAGE_BACKEND=fake 生效（get_storage 返回 FakeStorage）；
- 这里提供图片/语音字节生成 helper，供 media/emoji/chat 测试复用；
- conftest 转发 backend/tests 通用工厂。
"""
import io
import struct
import wave

import pytest
from PIL import Image

from tests.conftest import api_client, auth_client, user_factory  # noqa: F401


@pytest.fixture(autouse=True)
def _reset_storage():
    """每个测试前重置存储单例，保证隔离。"""
    from apps.media import storage

    storage.reset_storage_cache()
    yield
    storage.reset_storage_cache()


def make_png_bytes(width=32, height=32, color=(200, 30, 30)):
    """生成一张真实 PNG 图片字节（Pillow 绘制）。"""
    img = Image.new("RGB", (width, height), color)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def make_jpeg_bytes(width=32, height=32):
    """生成一张真实 JPEG 图片字节。"""
    img = Image.new("RGB", (width, height), (30, 60, 200))
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=90)
    return buf.getvalue()


def make_bmp_bytes(width=32, height=32):
    """生成一张真实 BMP 图片字节（Pillow 原生支持读写）。"""
    img = Image.new("RGB", (width, height), (30, 160, 90))
    buf = io.BytesIO()
    img.save(buf, format="BMP")
    return buf.getvalue()


def make_tiff_bytes(width=32, height=32):
    """生成一张真实 TIFF 图片字节（Pillow 原生支持读写）。"""
    img = Image.new("RGB", (width, height), (120, 30, 200))
    buf = io.BytesIO()
    img.save(buf, format="TIFF")
    return buf.getvalue()


def make_avif_bytes(brand=b"avif"):
    """构造最小 ISOBMFF 静态图字节（ftyp box + mdat 占位），模拟 AVIF/HEIC 文件头。"""
    ftyp = b"\x00\x00\x00\x18ftyp" + brand + b"\x00\x00\x00\x00"
    mdat = b"\x00\x00\x00\x10mdat" + b"\x00" * 8
    return ftyp + mdat


def make_mp4_bytes(brand=b"isom"):
    """构造最小 MP4/ISOBMFF 视频字节（ftyp box + mdat 占位）。"""
    ftyp = b"\x00\x00\x00\x18ftyp" + brand + b"\x00\x00\x02\x00"
    mdat = b"\x00\x00\x00\x10mdat" + b"\x00" * 8
    return ftyp + mdat


def make_webm_video_bytes():
    """构造最小 WebM/EBML 视频字节（EBML 头占位）。"""
    return b"\x1a\x45\xdf\xa3" + b"\x01\x00\x00\x80" + b"\x42\x82\x88webm" + b"\x00" * 16


def make_svg_bytes():
    """生成最小 SVG 文本字节。"""
    return (
        b'<?xml version="1.0" encoding="UTF-8"?>\n'
        b'<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32">'
        b'<rect width="32" height="32" fill="#9dbfe6"/></svg>'
    )


def make_wav_bytes(duration=1.0, rate=8000):
    """生成 PCM16 WAV 字节（用于波形测试）。"""
    n_frames = int(rate * duration)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(rate)
        frames = struct.pack("<%dh" % n_frames, *([0] * n_frames))
        wf.writeframes(frames)
    return buf.getvalue()


def upload_image(client, data=None, kind="image", mime_type="image/png", size=None):
    """通过三步上传 API 上传图片，返回 (media_id, descriptor)。"""
    data = data or make_png_bytes()
    size = size or len(data)
    resp = client.post(
        "/api/v1/media/uploads",
        {"kind": kind, "expected_size": size, "mime_type": mime_type},
        format="json",
    )
    assert resp.status_code == 201, resp.content
    upload_id = resp.json()["upload_id"]
    resp = client.put(
        f"/api/v1/media/uploads/{upload_id}", data=data, content_type="application/octet-stream"
    )
    assert resp.status_code == 200, resp.content
    resp = client.post(f"/api/v1/media/uploads/{upload_id}:complete", format="json")
    assert resp.status_code == 201, resp.content
    body = resp.json()
    return body["media_id"], body["descriptor"]
