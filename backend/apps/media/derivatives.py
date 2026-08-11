"""
派生资源生成（M4-3，步骤文件 4.2）。

- 缩略图（image/emoji）：Pillow 等比缩到 MEDIA_THUMB_MAX 长边，JPEG(白底, quality=80)；
- 波形（voice）：wave 模块解析 WAV（PCM 16bit），分 N 段取峰值/均方根，Pillow 画深色柱图；
  本期只支持 WAV 波形；MP3/M4A 等不生成波形，如实降级为"无波形"（不伪造）。

派生失败语义（阶段三 §10.2）：元数据已提交（status=ready）、派生单独标记；
派生失败不把 MediaObject 置 failed、不回滚完整上传。
"""
import io
import logging
import math
import wave

from django.conf import settings
from PIL import Image, ImageDraw

logger = logging.getLogger(__name__)

WAVEFORM_BARS = 48  # 波形柱数量
WAVEFORM_WIDTH = 480
WAVEFORM_HEIGHT = 120


def _thumb_max() -> int:
    return int(getattr(settings, "MEDIA_THUMB_MAX", 320))


def generate_thumbnail(data: bytes, mime_type: str = "") -> tuple[bytes, int, int]:
    """生成缩略图 JPEG。返回 (jpeg_bytes, width, height)；失败抛异常由调用方降级。"""
    try:
        img = Image.open(io.BytesIO(data))
        img.load()
    except Exception as exc:
        logger.warning("thumbnail: cannot open image: %s", exc)
        raise
    width, height = img.size
    thumb = img.convert("RGB")
    max_edge = _thumb_max()
    if max(width, height) > max_edge:
        ratio = max_edge / max(width, height)
        new_size = (max(1, int(width * ratio)), max(1, int(height * ratio)))
        thumb = thumb.resize(new_size, Image.LANCZOS)
    out = io.BytesIO()
    thumb.save(out, format="JPEG", quality=80, background=(255, 255, 255))
    return out.getvalue(), width, height


def _wave_duration(sample_count: int, frame_rate: int) -> float:
    if not frame_rate:
        return 0.0
    return sample_count / frame_rate


def _parse_wav(data: bytes) -> dict:
    """解析 WAV，返回 {samples, sample_rate}；仅支持 PCM16；其它格式抛 ValueError。"""
    with wave.open(io.BytesIO(data), "rb") as wf:
        if wf.getsampwidth() != 2:
            raise ValueError("仅支持 PCM 16bit WAV 波形")
        frame_rate = wf.getframerate()
        channels = wf.getnchannels()
        n_frames = wf.getnframes()
        raw = wf.readframes(n_frames)
    import struct

    sample_count = n_frames * channels
    if sample_count <= 0:
        return {"samples": [], "sample_rate": frame_rate}
    fmt = "<%dh" % sample_count
    samples = struct.unpack(fmt, raw[: sample_count * 2])
    # 取绝对值（多声道合并取均值便于画图）
    return {"samples": samples, "sample_rate": frame_rate}


def generate_waveform(data: bytes) -> tuple[bytes, float]:
    """生成波形图 PNG。返回 (png_bytes, duration_seconds)；不支持/失败抛异常由调用方降级。"""
    parsed = _parse_wav(data)
    samples = parsed["samples"]
    sample_rate = parsed["sample_rate"]
    duration = _wave_duration(len(samples), sample_rate)

    img = Image.new("RGBA", (WAVEFORM_WIDTH, WAVEFORM_HEIGHT), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    bar_w = max(1, WAVEFORM_WIDTH // WAVEFORM_BARS)
    gap = max(1, bar_w // 4)
    step = max(1, len(samples) // WAVEFORM_BARS) if samples else 1

    peak = 0
    for s in samples:
        peak = max(peak, abs(s))
    peak = max(peak, 1)

    for i in range(WAVEFORM_BARS):
        chunk = samples[i * step : (i + 1) * step]
        if not chunk:
            continue
        amp = max(abs(s) for s in chunk) / peak
        bar_h = max(2, int(amp * (WAVEFORM_HEIGHT - 8)))
        x = i * bar_w + gap // 2
        y0 = (WAVEFORM_HEIGHT - bar_h) // 2
        draw.rectangle(
            [x, y0, x + bar_w - gap, y0 + bar_h], fill=(70, 90, 120, 255)
        )
    out = io.BytesIO()
    img.save(out, format="PNG")
    return out.getvalue(), duration
