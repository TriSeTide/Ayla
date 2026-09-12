"""房间音频总线 —— 方案 a：纯转发，不解码。

为什么是"纯转发"
----------------
本模块**不触碰音频内容**：收到的就是一个 20ms 的 Opus 包，原样转给同房间其他人。
好处：
  1. 后端零音频依赖（不需要 libopus / numpy），本地与 ARM 都能直接跑
  2. 延迟最低（不解码不重编码）
  3. 这是"服务端混音"（方案 b）的严格子集 —— 将来若上行带宽不够，
     只需在本模块里插入混音，consumer/协议/前端管线都不用改

转发策略
--------
- 只有 `speaking=True` 的连接发的音频才会被转发（客户端用 AudioWorklet 算音量上报，
  服务端只做裁决，不做 DSP）
- 同时说话的人超过 `MAX_ACTIVE_SPEAKERS` 时，只转发最近开始说话的前 K 个
  —— 这就是 Top-K 转发，用来给下行带宽兜底

进程内状态（已知限制，务必知情）
--------------------------------
`_ROOMS` 是模块级字典，**只在单进程内有效**。当前部署是单个 daphne 进程，可以工作。
一旦要横向扩展（多 daphne / gunicorn 多 worker），必须把 slot 分配与成员表搬到
Redis（例如 `channels_redis` 自带的连接计数 + 一个 per-channel 的 Redis Hash）。
届时改动范围仅限本文件。

协议（与 audio_consumer / web 侧严格一致）
------------------------------------------
C→S  binary : 一个 20ms Opus 包（仅 speaking 时发送）
C→S  text   : {"type":"speaking","on":bool}
              {"type":"mute","on":bool}
              {"type":"ping","ts":n}
S→C  binary : [1 字节 slot][Opus 包]        ← slot 由本模块分配，客户端据此分流解码
S→C  text   : {"type":"joined","slot":n,"members":[{"slot":k,"identity":str,"speaking":bool}]}
              {"type":"member_joined","slot":k,"identity":str}
              {"type":"member_left","slot":k}
              {"type":"speaking","slot":k,"on":bool}
              {"type":"muted","slot":k,"on":bool}
              {"type":"pong","ts":n}
              {"type":"error","detail":str}
"""
from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass, field

logger = logging.getLogger(__name__)

# slot 0 保留给未来的"服务端混音流"，成员从 1 开始
SLOT_MIN = 1
SLOT_MAX = 250
# Top-K 转发上限：同时真正被转发的说话人数量
MAX_ACTIVE_SPEAKERS = 6


class RoomFull(RuntimeError):
    """slot 用尽（超过 SLOT_MAX 人在线）。"""


@dataclass
class Member:
    channel_name: str
    identity: str
    slot: int
    speaking: bool = False
    muted: bool = False
    # 单调递增序号，用于 Top-K 排序（越大越新）
    seq: int = 0

    def public(self) -> dict:
        return {"slot": self.slot, "identity": self.identity, "speaking": self.speaking}


@dataclass
class Room:
    channel_id: int
    members: dict[str, Member] = field(default_factory=dict)
    seq: int = 0

    def _alloc_slot(self) -> int:
        used = {m.slot for m in self.members.values()}
        for slot in range(SLOT_MIN, SLOT_MAX + 1):
            if slot not in used:
                return slot
        raise RoomFull(f"voice room {self.channel_id} 槽位已用尽（>{SLOT_MAX} 人）")

    def add(self, channel_name: str, identity: str) -> Member:
        existing = self.members.get(channel_name)
        if existing is not None:
            return existing
        self.seq += 1
        member = Member(
            channel_name=channel_name,
            identity=identity,
            slot=self._alloc_slot(),
            seq=self.seq,
        )
        self.members[channel_name] = member
        return member

    def remove(self, channel_name: str) -> Member | None:
        return self.members.pop(channel_name, None)

    def touch_speaking(self, channel_name: str, speaking: bool) -> Member | None:
        """更新说话状态；开始说话时刷新 seq（Top-K 按最近说话优先）。"""
        member = self.members.get(channel_name)
        if member is None:
            return None
        if speaking and not member.speaking:
            self.seq += 1
            member.seq = self.seq
        member.speaking = speaking
        return member

    def active_slots(self) -> set[int]:
        """当前允许被转发的 slot 集合（Top-K）。"""
        speaking = [m for m in self.members.values() if m.speaking and not m.muted]
        speaking.sort(key=lambda m: m.seq, reverse=True)
        return {m.slot for m in speaking[:MAX_ACTIVE_SPEAKERS]}

    def roster(self) -> list[dict]:
        return [m.public() for m in self.members.values()]


_ROOMS: dict[int, Room] = {}
_LOCK = asyncio.Lock()


async def join(channel_id: int, channel_name: str, identity: str) -> tuple[Member, list[dict]]:
    """加入房间，返回 (自己, 加入前的成员快照)。"""
    async with _LOCK:
        room = _ROOMS.setdefault(int(channel_id), Room(channel_id=int(channel_id)))
        roster_before = room.roster()
        member = room.add(channel_name, identity)
        return member, roster_before


async def leave(channel_id: int, channel_name: str) -> Member | None:
    """离开房间；房间空了就回收。"""
    async with _LOCK:
        room = _ROOMS.get(int(channel_id))
        if room is None:
            return None
        member = room.remove(channel_name)
        if not room.members:
            _ROOMS.pop(int(channel_id), None)
        return member


async def set_speaking(channel_id: int, channel_name: str, speaking: bool) -> Member | None:
    async with _LOCK:
        room = _ROOMS.get(int(channel_id))
        if room is None:
            return None
        return room.touch_speaking(channel_name, speaking)


async def set_muted(channel_id: int, channel_name: str, muted: bool) -> Member | None:
    async with _LOCK:
        room = _ROOMS.get(int(channel_id))
        if room is None:
            return None
        member = room.members.get(channel_name)
        if member is None:
            return None
        member.muted = muted
        if muted:
            member.speaking = False
        return member


async def may_relay(channel_id: int, channel_name: str) -> int | None:
    """判断这条连接的音频是否应该被转发；是则返回它的 slot，否则 None。"""
    async with _LOCK:
        room = _ROOMS.get(int(channel_id))
        if room is None:
            return None
        member = room.members.get(channel_name)
        if member is None or member.muted or not member.speaking:
            return None
        if member.slot not in room.active_slots():
            return None
        return member.slot


def stats() -> dict:
    """给运维/测试看的快照。"""
    return {
        "rooms": len(_ROOMS),
        "members": sum(len(r.members) for r in _ROOMS.values()),
        "detail": {
            int(cid): {"members": len(r.members), "active": len(r.active_slots())}
            for cid, r in _ROOMS.items()
        },
    }
