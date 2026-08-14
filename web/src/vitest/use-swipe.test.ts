/**
 * useSwipe / createSwipeTracker 测试：方向锁、阈值、取消、快速滑动补定轴。
 * 状态机为纯函数，直接驱动（不依赖 jsdom Touch 对象）。
 */
import { describe, expect, it, vi } from "vitest";
import type { SwipeCallbacks } from "../hooks/useSwipe";
import { createSwipeTracker } from "../hooks/useSwipe";

function spyCallbacks() {
  const cbs: SwipeCallbacks = {
    onStart: vi.fn(),
    onMove: vi.fn(),
    onEnd: vi.fn(),
    onCancel: vi.fn(),
  };
  return cbs;
}

describe("createSwipeTracker", () => {
  it("水平左滑达到阈值 → direction=left、axis=x", () => {
    const cbs = spyCallbacks();
    const t = createSwipeTracker(cbs);
    t.start(100, 100);
    t.move(80, 102); // 定轴 x（|dx|>|dy| 且 >lockSlop）
    t.move(40, 104);
    t.end(40, 104);
    expect(cbs.onEnd).toHaveBeenCalledWith({ dx: -60, dy: 4, axis: "x", direction: "left" });
    expect(cbs.onCancel).not.toHaveBeenCalled();
  });

  it("水平右滑达到阈值 → direction=right", () => {
    const cbs = spyCallbacks();
    const t = createSwipeTracker(cbs);
    t.start(0, 0);
    t.move(40, 0);
    t.end(60, 0);
    expect(cbs.onEnd).toHaveBeenCalledWith({ dx: 60, dy: 0, axis: "x", direction: "right" });
  });

  it("位移不足阈值 → direction=null（松手吸附）", () => {
    const cbs = spyCallbacks();
    const t = createSwipeTracker(cbs);
    t.start(0, 0);
    t.move(30, 0);
    t.end(30, 0);
    expect(cbs.onEnd).toHaveBeenCalledWith({ dx: 30, dy: 0, axis: "x", direction: null });
  });

  it("垂直位移占优 → axis=y，水平方向不误触发（方向锁 + 滚动让位）", () => {
    const cbs = spyCallbacks();
    const t = createSwipeTracker(cbs);
    t.start(0, 0);
    t.move(-8, -20); // 定轴 y
    t.move(-10, -60);
    t.end(-10, -60);
    expect(cbs.onEnd).toHaveBeenCalledWith({ dx: -10, dy: -60, axis: "y", direction: "up" });
  });

  it("lockSlop 内不定轴，onMove 不触发", () => {
    const cbs = spyCallbacks();
    const t = createSwipeTracker(cbs);
    t.start(0, 0);
    t.move(3, 2);
    expect(cbs.onMove).not.toHaveBeenCalled();
  });

  it("cancel 触发 onCancel、不触发 onEnd，且此后 move 无效", () => {
    const cbs = spyCallbacks();
    const t = createSwipeTracker(cbs);
    t.start(0, 0);
    t.move(30, 0);
    t.cancel();
    expect(cbs.onCancel).toHaveBeenCalledTimes(1);
    expect(cbs.onEnd).not.toHaveBeenCalled();

    t.move(60, 0);
    expect(cbs.onMove).toHaveBeenCalledTimes(1); // cancel 前那一次
  });

  it("快速滑动（无超 lockSlop 的 move）end 补定轴 → direction=left", () => {
    const cbs = spyCallbacks();
    const t = createSwipeTracker(cbs);
    t.start(0, 0);
    t.end(-100, 0);
    expect(cbs.onEnd).toHaveBeenCalledWith({ dx: -100, dy: 0, axis: "x", direction: "left" });
  });

  it("tracking 标记跟踪状态", () => {
    const t = createSwipeTracker({});
    expect(t.tracking()).toBe(false);
    t.start(0, 0);
    expect(t.tracking()).toBe(true);
    t.end(0, 0);
    expect(t.tracking()).toBe(false);
  });
});
