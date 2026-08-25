"""
MP4 faststart 重排（moov box 前置）——消除视频起播前的多次 Range 往返。

手机/相机直出的 mp4 普遍把 moov（索引元数据）写在文件尾部（mdat 之后）：
浏览器 preload 时先 Range 读头部、发现元数据不在、再读尾部拿 moov、最后
回头缓冲起播段，起播前多 2~3 次往返——这就是「点开后要加载一会儿」的主因。
faststart 把 moov 平移到 ftyp 之后并同步修正 stco/co64 chunk 绝对偏移，
浏览器一次顺序读即可边下边播（B 站/抖音同款标准动作）。

实现为纯容器级重排（等价 ffmpeg -c copy -movflags +faststart）：不解码、
不转码，总字节数与音视频编码完全不变；无外部依赖（本机无 ffmpeg）。

安全边界：
- 首 box 必须是 ftyp（ISO-BMFF 标志），WebM/EBML 等其他容器显式拒绝；
- 已是 faststart（mdat 之前见到 moov）幂等跳过；
- 无 moov / 结构截断 / 偏移越界一律抛 FastStartError，调用方放弃处理
  保留原对象——播放可用性永远不受本模块影响。
"""

import logging

logger = logging.getLogger(__name__)

# moov 内部需要递归下钻的容器 box（stco/co64 位于 moov>trak>mdia>minf>stbl）
_CONTAINER_BOXES = frozenset({b"moov", b"trak", b"mdia", b"minf", b"stbl"})
_COPY_CHUNK = 1024 * 1024


class FastStartError(ValueError):
    """mp4 结构非法或不符合重排前置条件（调用方应放弃处理）。"""


class _Box:
    """顶层 box：类型、文件内偏移、总大小（含 header）、header 大小。"""

    __slots__ = ("btype", "pos", "size", "hdr")

    def __init__(self, btype: bytes, pos: int, size: int, hdr: int):
        self.btype = btype
        self.pos = pos
        self.size = size
        self.hdr = hdr

    def contains(self, offset: int) -> bool:
        return self.pos <= offset < self.pos + self.size


def iter_top_level_boxes(fileobj) -> list[_Box]:
    """解析顶层 box 索引。fileobj 需支持 seek/read（本地临时文件）。"""
    fileobj.seek(0, 2)
    file_size = fileobj.tell()
    boxes: list[_Box] = []
    pos = 0
    while pos < file_size:
        fileobj.seek(pos)
        header = fileobj.read(8)
        if len(header) < 8:
            raise FastStartError(f"truncated box header at {pos}")
        size = int.from_bytes(header[:4], "big")
        btype = header[4:8]
        hdr = 8
        if size == 1:  # largesize（64 位）
            large = fileobj.read(8)
            if len(large) < 8:
                raise FastStartError(f"truncated largesize at {pos}")
            size = int.from_bytes(large, "big")
            hdr = 16
        elif size == 0:  # box 延伸到文件尾
            size = file_size - pos
        if size < hdr or pos + size > file_size:
            raise FastStartError(f"box {btype!r} at {pos} size {size} out of bounds")
        boxes.append(_Box(btype, pos, size, hdr))
        pos += size
    return boxes


def needs_faststart(boxes: list[_Box]) -> bool:
    """True = 存在位于 mdat 之后的 moov（需要重排）；False = 已 faststart / 无 moov。"""
    if not boxes or boxes[0].btype != b"ftyp":
        raise FastStartError("not an ISO-BMFF file (first box is not ftyp)")
    if not any(box.btype == b"moov" for box in boxes):
        return False  # 无 moov 的结构无法处理也无法受益
    seen_moov = False
    for box in boxes:
        if box.btype == b"moov":
            seen_moov = True
        elif box.btype == b"mdat" and not seen_moov:
            return True
    return False


def remux_file_faststart(src_fileobj, dst_fileobj) -> bool:
    """把 mp4 重排为 faststart 并写入 dst。

    返回 True 表示已重排写出；False 表示源已是 faststart 或无可处理结构
    （dst 未写任何字节）；结构非法抛 FastStartError。
    src_fileobj 需支持 seek/read；dst_fileobj 需支持 write。
    """
    boxes = iter_top_level_boxes(src_fileobj)
    if not needs_faststart(boxes):
        return False

    file_size = sum(b.size for b in boxes)
    ftyp_box = boxes[0]
    moov_box = next((b for b in boxes if b.btype == b"moov"), None)
    others = [b for b in boxes[1:] if b is not moov_box]

    # 新布局：ftyp → moov → 其余按原序。逐 box 计算新旧位置差：
    # 原 moov 之前的 box 整体后移 moov_size；之后的 box 位置不变。
    new_pos: dict[int, int] = {}
    cursor = 0
    for box in (ftyp_box, moov_box, *others):
        new_pos[id(box)] = cursor
        cursor += box.size
    if cursor != file_size:
        raise FastStartError("layout size mismatch after reorder")

    def delta_for(offset: int) -> int:
        for box in boxes:
            if box.contains(offset):
                return new_pos[id(box)] - box.pos
        logger.warning("chunk offset %d not inside any top-level box; left as-is", offset)
        return 0

    # moov 读入内存原位修正 stco/co64（moov 通常几 MB 内）
    src_fileobj.seek(moov_box.pos)
    moov_bytes = bytearray(src_fileobj.read(moov_box.size))
    _patch_chunk_offsets(moov_bytes, moov_box.hdr, len(moov_bytes), delta_for)

    # 写出：ftyp 原样 → 修正后的 moov → 其余 box 流式 copy
    written = 0

    def emit(box: _Box, payload_override: bytearray | None = None) -> None:
        nonlocal written
        if payload_override is not None:
            dst_fileobj.write(payload_override)
            written += len(payload_override)
            return
        src_fileobj.seek(box.pos)
        remaining = box.size
        while remaining > 0:
            chunk = src_fileobj.read(min(_COPY_CHUNK, remaining))
            if not chunk:
                raise FastStartError(f"short read copying box {box.btype!r}")
            dst_fileobj.write(chunk)
            written += len(chunk)
            remaining -= len(chunk)

    emit(ftyp_box)
    emit(moov_box, payload_override=moov_bytes)
    for box in others:
        emit(box)

    if written != file_size:
        raise FastStartError(f"output size {written} != input size {file_size}")
    return True


def _patch_chunk_offsets(buf: bytearray, start: int, end: int, delta_for) -> None:
    """递归遍历 [start, end) 内的容器 box，原位修正 stco/co64 的 chunk 绝对偏移。"""
    pos = start
    while pos + 8 <= end:
        size = int.from_bytes(buf[pos : pos + 4], "big")
        btype = bytes(buf[pos + 4 : pos + 8])
        hdr = 8
        if size == 1:
            size = int.from_bytes(buf[pos + 8 : pos + 16], "big")
            hdr = 16
        elif size == 0:
            size = end - pos
        if size < hdr or pos + size > end:
            raise FastStartError(f"malformed child box {btype!r} at {pos}")
        if btype in _CONTAINER_BOXES:
            _patch_chunk_offsets(buf, pos + hdr, pos + size, delta_for)
        elif btype in (b"stco", b"co64"):
            entry_size = 4 if btype == b"stco" else 8
            count_off = pos + hdr
            count = int.from_bytes(bytes(buf[count_off : count_off + 4]), "big")
            first = count_off + 4
            last = first + count * entry_size
            if last > end:
                raise FastStartError(f"{btype!r} entries out of bounds")
            for i in range(count):
                off = first + i * entry_size
                value = int.from_bytes(bytes(buf[off : off + entry_size]), "big")
                delta = delta_for(value)
                if delta:
                    buf[off : off + entry_size] = (value + delta).to_bytes(entry_size, "big")
        pos += size
