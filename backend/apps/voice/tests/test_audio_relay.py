"""房间音频总线（audio_relay）契约测试。

覆盖：slot 分配/复用、转发裁决（speaking + muted）、Top-K 上限、房间回收。

刻意不依赖 pytest-asyncio —— 用同步用例包 `asyncio.run`，这样无论测试环境有没有装
asyncio 插件都能跑。本模块是纯内存状态（无 DB、无 channel layer），所以也不需要
`django_db`。
"""
import asyncio

import pytest

from apps.voice import audio_relay

CH = 42


@pytest.fixture(autouse=True)
def _clean_rooms():
    """每个用例都从空状态开始 —— _ROOMS 是模块级字典，会跨用例残留。"""
    audio_relay._ROOMS.clear()
    yield
    audio_relay._ROOMS.clear()


def _run(coro):
    return asyncio.run(coro)


def test_slot_allocation_starts_at_one_and_is_unique():
    async def main():
        a, before_a = await audio_relay.join(CH, "cn_a", "alice")
        b, before_b = await audio_relay.join(CH, "cn_b", "bob")
        return a, before_a, b, before_b

    a, before_a, b, before_b = _run(main())

    assert a.slot == audio_relay.SLOT_MIN == 1
    assert b.slot == 2
    # 先到的人没有"已存在成员"；后到的人能看到前面的人
    assert before_a == []
    assert [m["identity"] for m in before_b] == ["alice"]


def test_slot_is_reused_after_leave():
    async def main():
        a, _ = await audio_relay.join(CH, "cn_a", "alice")
        b, _ = await audio_relay.join(CH, "cn_b", "bob")
        left = await audio_relay.leave(CH, "cn_a")
        c, _ = await audio_relay.join(CH, "cn_c", "carol")
        return a, b, left, c

    a, b, left, c = _run(main())

    assert left is not None and left.slot == a.slot
    # 复用最小空位，而不是继续往后排
    assert c.slot == a.slot
    assert c.slot != b.slot


def test_relay_requires_speaking_flag():
    async def main():
        a, _ = await audio_relay.join(CH, "cn_a", "alice")
        assert await audio_relay.may_relay(CH, "cn_a") is None
        await audio_relay.set_speaking(CH, "cn_a", True)
        allowed = await audio_relay.may_relay(CH, "cn_a")
        await audio_relay.set_speaking(CH, "cn_a", False)
        return a.slot, allowed, await audio_relay.may_relay(CH, "cn_a")

    slot, allowed, after = _run(main())

    assert allowed == slot
    assert after is None


def test_mute_blocks_relay_and_clears_speaking():
    async def main():
        await audio_relay.join(CH, "cn_a", "alice")
        await audio_relay.set_speaking(CH, "cn_a", True)
        member = await audio_relay.set_muted(CH, "cn_a", True)
        return member, await audio_relay.may_relay(CH, "cn_a")

    member, relayed = _run(main())

    assert member is not None
    assert member.muted is True
    assert member.speaking is False, "静音必须同时把 speaking 清掉，否则 UI 会显示还在说话"
    assert relayed is None


def test_top_k_caps_concurrent_forwarding():
    """8 个人同时说话，只放行 MAX_ACTIVE_SPEAKERS 个 —— 这是下行带宽的兜底。"""

    async def main():
        for i in range(8):
            await audio_relay.join(CH, f"cn_{i}", f"u{i}")
            await audio_relay.set_speaking(CH, f"cn_{i}", True)
        room = audio_relay._ROOMS[CH]
        return room.active_slots(), audio_relay.MAX_ACTIVE_SPEAKERS

    active, cap = _run(main())

    assert len(active) == cap
    # 最近开始说话的必须被放行（seq 越大越优先）
    assert 8 in active


def test_room_is_reclaimed_when_empty():
    async def main():
        await audio_relay.join(CH, "cn_a", "alice")
        await audio_relay.join(CH, "cn_b", "bob")
        await audio_relay.leave(CH, "cn_a")
        still_there = CH in audio_relay._ROOMS
        await audio_relay.leave(CH, "cn_b")
        return still_there, CH in audio_relay._ROOMS

    still_there, gone = _run(main())

    assert still_there is True
    assert gone is False


def test_operations_on_missing_room_are_noops():
    """房间不存在时不应抛异常（断连清理可能晚于其他人全部离开）。"""

    async def main():
        return (
            await audio_relay.leave(CH, "cn_a"),
            await audio_relay.set_speaking(CH, "cn_a", True),
            await audio_relay.set_muted(CH, "cn_a", True),
            await audio_relay.may_relay(CH, "cn_a"),
        )

    left, speaking, muted, relayed = _run(main())

    assert left is None
    assert speaking is None
    assert muted is None
    assert relayed is None


def test_stats_snapshot_shape():
    async def main():
        await audio_relay.join(CH, "cn_a", "alice")
        await audio_relay.set_speaking(CH, "cn_a", True)
        return audio_relay.stats()

    s = _run(main())

    assert s["rooms"] == 1
    assert s["members"] == 1
    assert s["detail"][CH] == {"members": 1, "active": 1}
