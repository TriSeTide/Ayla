"""faststart 重排契约测试（moov 前置 + stco/co64 偏移修正）。

覆盖：
- 尾置 moov → 重排后 ftyp/moov/其余原序、stco/co64 chunk 偏移整体 +moov_size、
  总字节数不变；
- 已 faststart（moov 在 mdat 前）幂等跳过；无 moov 跳过；非 ISO-BMFF 拒绝；
- services.ensure_video_faststart：FakeStorage 上替换 original 并更新
  content_hash，size 不变校验；非 mp4 家族跳过；调度入口起后台线程。
"""

import io
import struct

import pytest

from apps.media.faststart import FastStartError, iter_top_level_boxes, remux_file_faststart


def _box(btype: bytes, payload: bytes) -> bytes:
    return (8 + len(payload)).to_bytes(4, "big") + btype + payload


def make_tail_moov_mp4(chunk_offsets, *, co64=False):
    """构造 moov 尾置的最小 mp4（ftyp+free+mdat+moov(trak>mdia>minf>stbl>stco/co64)）。"""
    ftyp = _box(b"ftyp", b"isom\x00\x00\x02\x00isomiso2")
    free = _box(b"free", b"\x00" * 8)
    mdat_payload = bytes(range(64))
    mdat = _box(b"mdat", mdat_payload)
    entry_fmt = ">Q" if co64 else ">I"
    stco_body = struct.pack(">I", len(chunk_offsets)) + b"".join(
        struct.pack(entry_fmt, o) for o in chunk_offsets
    )
    stco_box = _box(b"co64" if co64 else b"stco", stco_body)
    moov = _box(
        b"moov",
        _box(b"trak", _box(b"mdia", _box(b"minf", _box(b"stbl", stco_box)))),
    )
    return ftyp + free + mdat + moov


def _read_chunk_entries(data: bytes, btype: bytes) -> list[int]:
    """从完整 mp4 字节里递归找 stco/co64 box 并读 entry 列表。"""

    def find(buf: bytes, is_root: bool):
        pos = 8 if is_root else 0  # 根层跳过 moov header；子层从 body 开始
        while pos + 8 <= len(buf):
            size = int.from_bytes(buf[pos : pos + 4], "big")
            child = buf[pos + 4 : pos + 8]
            if child == btype:
                return buf[pos : pos + size]
            if child in (b"trak", b"mdia", b"minf", b"stbl"):
                hit = find(buf[pos + 8 : pos + size], False)  # 子层去掉容器 header
                if hit is not None:
                    return hit
            pos += size
        return None

    boxes = dict((b[0], data[b[1] : b[1] + b[2]]) for b in iter_top_level_boxes(io.BytesIO(data)))
    target = find(boxes[b"moov"], True)
    assert target is not None, f"{btype} not found"
    count = int.from_bytes(target[8:12], "big")
    fmt = ">Q" if btype == b"co64" else ">I"
    return [struct.unpack_from(fmt, target, 12 + i * struct.calcsize(fmt))[0] for i in range(count)]


class TestRemuxFaststart:
    def test_tail_moov_reordered_and_offsets_patched(self):
        mdat_data_start = 24 + 16 + 8  # ftyp(24) + free(16) + mdat header(8)
        offsets = [mdat_data_start, mdat_data_start + 16, mdat_data_start + 31]
        src = make_tail_moov_mp4(offsets)
        dst = io.BytesIO()
        assert remux_file_faststart(io.BytesIO(src), dst) is True
        out = dst.getvalue()
        # 总大小不变、box 序变为 ftyp/moov/free/mdat
        top = [(b.btype, b.pos) for b in iter_top_level_boxes(io.BytesIO(out))]
        assert [t for t, _ in top] == [b"ftyp", b"moov", b"free", b"mdat"]
        assert len(out) == len(src)
        # chunk offset 整体 +moov_size（mdat 后移）
        moov_size = int.from_bytes(out[top[1][1] : top[1][1] + 4], "big")
        patched = _read_chunk_entries(out, b"stco")
        assert patched == [o + moov_size for o in offsets]

    def test_co64_variant_patched(self):
        mdat_data_start = 24 + 16 + 8
        offsets = [mdat_data_start + 8]
        src = make_tail_moov_mp4(offsets, co64=True)
        dst = io.BytesIO()
        assert remux_file_faststart(io.BytesIO(src), dst) is True
        out = dst.getvalue()
        moov_pos = next(p for t, p in [(b.btype, b.pos) for b in iter_top_level_boxes(io.BytesIO(out))] if t == b"moov")
        moov_size = int.from_bytes(out[moov_pos : moov_pos + 4], "big")
        assert _read_chunk_entries(out, b"co64") == [offsets[0] + moov_size]

    def test_already_faststart_is_noop(self):
        # moov 已在 mdat 前（ftyp+moov+free+mdat）
        tail = make_tail_moov_mp4([40])  # 先造一份拿 moov
        boxes = list(iter_top_level_boxes(io.BytesIO(tail)))
        by_type = {b.btype: tail[b.pos : b.pos + b.size] for b in boxes}
        fast = by_type[b"ftyp"] + by_type[b"moov"] + by_type[b"free"] + by_type[b"mdat"]
        dst = io.BytesIO()
        assert remux_file_faststart(io.BytesIO(fast), dst) is False
        assert dst.getvalue() == b""  # 未写任何字节

    def test_no_moov_skipped(self):
        ftyp = _box(b"ftyp", b"isom\x00\x00\x02\x00isomiso2")
        mdat = _box(b"mdat", bytes(32))
        dst = io.BytesIO()
        assert remux_file_faststart(io.BytesIO(ftyp + mdat), dst) is False

    def test_non_isobmff_rejected(self):
        with pytest.raises(FastStartError):
            remux_file_faststart(io.BytesIO(b"\x1a\x45\xdf\xa3webm-placeholder-bytes"), io.BytesIO())

    def test_truncated_structure_rejected(self):
        src = make_tail_moov_mp4([48])[:-4]  # 截断尾部
        with pytest.raises(FastStartError):
            remux_file_faststart(io.BytesIO(src), io.BytesIO())


@pytest.mark.django_db
class TestEnsureVideoFaststart:
    def _make_media(self, db_data: bytes, mime="video/mp4", owner_id=None):
        from apps.media import storage as media_storage
        from apps.media.models import MediaObject

        media = MediaObject.objects.create(
            media_id="fs" + "0" * 30,
            owner_id=owner_id,
            kind=MediaObject.KIND_VIDEO,
            content_hash="oldhash",
            mime_type=mime,
            size=len(db_data),
            storage_path=media_storage.original_key("video", "fs" + "0" * 30),
            status=MediaObject.STATUS_READY,
        )
        store = media_storage.get_storage()
        store.put(media.storage_path, db_data, content_type=mime)
        return media, store

    def test_remux_replaces_original_and_updates_hash(self, user_factory):
        from apps.media import services

        mdat_data_start = 24 + 16 + 8
        src = make_tail_moov_mp4([mdat_data_start])
        media, store = self._make_media(src, owner_id=user_factory().id)
        assert services.ensure_video_faststart(media.media_id) is True
        replaced = store.get(media.storage_path)
        types = [b.btype for b in iter_top_level_boxes(io.BytesIO(replaced))]
        assert types[:2] == [b"ftyp", b"moov"]
        # content_hash 更新为替换后内容指纹（FakeStorage stat etag = md5）
        import hashlib

        media.refresh_from_db()
        assert media.content_hash == hashlib.md5(replaced).hexdigest()

    def test_already_faststart_keeps_object(self, user_factory):
        from apps.media import services

        tail_src = make_tail_moov_mp4([48])
        boxes = list(iter_top_level_boxes(io.BytesIO(tail_src)))
        by_type = {b.btype: tail_src[b.pos : b.pos + b.size] for b in boxes}
        fast = by_type[b"ftyp"] + by_type[b"moov"] + by_type[b"free"] + by_type[b"mdat"]
        media, store = self._make_media(fast, owner_id=user_factory().id)
        assert services.ensure_video_faststart(media.media_id) is False
        assert store.get(media.storage_path) == fast  # 原对象未动

    def test_non_mp4_mime_skipped(self, user_factory):
        from apps.media import services

        src = make_tail_moov_mp4([48])
        media, store = self._make_media(src, mime="video/webm", owner_id=user_factory().id)
        assert services.ensure_video_faststart(media.media_id) is False
        assert store.get(media.storage_path) == src  # EBML 容器绝不重排

    def test_schedule_spawns_background_thread(self, monkeypatch):
        import threading

        from apps.media import services

        src = make_tail_moov_mp4([48])
        media, _ = self._make_media(src)

        started = {}
        real_thread = threading.Thread

        class FakeThread(real_thread):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                started["target"] = kwargs.get("target")

            def start(self):
                started["target"]()  # 同步执行便于断言

        monkeypatch.setattr(threading, "Thread", FakeThread)
        services.schedule_video_faststart(media)
        assert "target" in started
