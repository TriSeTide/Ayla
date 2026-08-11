"""派生资源契约测试（8.1 清单：缩略图/波形生成、派生失败媒体仍 ready）。"""
import io

import pytest
from PIL import Image

from apps.media import derivatives


class TestThumbnail:
    def test_generates_thumbnail_with_dimensions(self):
        img = Image.new("RGB", (800, 600), (10, 200, 30))
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        thumb, width, height = derivatives.generate_thumbnail(buf.getvalue())
        assert width == 800
        assert height == 600
        # 缩略图长边不超过 MEDIA_THUMB_MAX(320)
        t = Image.open(io.BytesIO(thumb))
        assert max(t.size) <= 320
        assert t.format == "JPEG"

    def test_small_image_keeps_size(self):
        img = Image.new("RGB", (100, 50), (1, 2, 3))
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        thumb, width, height = derivatives.generate_thumbnail(buf.getvalue())
        assert width == 100
        assert height == 50
        t = Image.open(io.BytesIO(thumb))
        assert t.size == (100, 50)


class TestWaveform:
    def test_generates_waveform_png(self):
        import struct
        import wave

        buf = io.BytesIO()
        with wave.open(buf, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(8000)
            frames = struct.pack("<8000h", *([3000] * 8000))
            wf.writeframes(frames)
        data = buf.getvalue()
        png, duration = derivatives.generate_waveform(data)
        assert duration == 1.0
        assert len(png) > 0
        img = Image.open(io.BytesIO(png))
        assert img.format == "PNG"

    def test_non_wav_raises(self):
        with pytest.raises(Exception):
            derivatives.generate_waveform(b"not a wav file at all")
