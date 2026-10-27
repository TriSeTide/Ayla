"""房间音频总线（audio_relay）契约测试。

覆盖：slot 分配/复用、转发裁决（**仅 muted**，2026-10-27 起 speaking 不参与）、
Top-K 作为观测量、房间回收。

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


def test_relay_does_not_depend_on_speaking_flag():
    """2026-10-27 设计缺陷修复：音频转发**不得**以 speaking 为门控。

    旧用例 `test_relay_requires_speaking_flag` 断言「未标记 speaking ⇒ 不转发、
    标记后 ⇒ 转发、取消标记 ⇒ 又不转发」。那正是用户实报的「有声音才连上去，
    声音小了就跟断了一样」的根因：人说话的正常停顿/句尾降调/换气都会让峰值
    跌破阈值 ⇒ 停止发帧 ⇒ 服务端丢弃 ⇒ 对端只收到有声片段。

    speaking 是**纯 UI 事实**（成员行高亮），不参与媒体裁决。
    """

    async def main():
        a, _ = await audio_relay.join(CH, "cn_a", "alice")
        # 刚进房、从未说过话 ⇒ 音频照样要转发
        fresh = await audio_relay.may_relay(CH, "cn_a")
        await audio_relay.set_speaking(CH, "cn_a", True)
        talking = await audio_relay.may_relay(CH, "cn_a")
        # 说完一句、停止说话 ⇒ 仍要转发（否则对方就听不到环境音与停顿）
        await audio_relay.set_speaking(CH, "cn_a", False)
        silent = await audio_relay.may_relay(CH, "cn_a")
        return a.slot, fresh, talking, silent

    slot, fresh, talking, silent = _run(main())

    assert fresh == slot, "未说过话也必须转发（否则对方永远听不到第一声之前的声音）"
    assert talking == slot
    assert silent == slot, "说完了也必须继续转发（这是本次修复的核心）"


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


def test_top_k_is_observational_not_a_relay_gate():
    """Top-K（active_slots）已降级为**观测量**，不再参与转发裁决。

    旧用例断言「8 人同时说话只放行 MAX_ACTIVE_SPEAKERS 个」——那是把「谁在说话」
    当成下行裁剪依据，同样会让其余人的声音整体消失。经实测持续转发每人仅 ~2 KB/s、
    20 人房间总吞吐 ~6.3 Mbps，远低于隧道上限 ⇒ 带宽兜底的前提不成立。
    """

    async def main():
        for i in range(8):
            await audio_relay.join(CH, f"cn_{i}", f"u{i}")
            await audio_relay.set_speaking(CH, f"cn_{i}", True)
        room = audio_relay._ROOMS[CH]
        # 观测量仍按 Top-K 截断（供 stats/运维看并发说话数）
        active = room.active_slots()
        # 但转发裁决对每个成员都必须放行
        relayed = [await audio_relay.may_relay(CH, f"cn_{i}") for i in range(8)]
        return active, relayed, audio_relay.MAX_ACTIVE_SPEAKERS

    active, relayed, cap = _run(main())

    assert len(active) == cap, "观测量仍按 Top-K 截断"
    assert all(r is not None for r in relayed), "转发裁决不得因 Top-K 丢人"
    assert len(relayed) == 8

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
