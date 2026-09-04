/**
 * useEdgeSwipeBack 测试（方案 §2.6）：
 * - 纯函数：isEdgeStart（边缘起手判定）/ resolveEdgeSwipe（位移阈值 + 速度判定）；
 * - hook 集成（reduced-motion，避开 framer-motion animate 与 timer 的不确定性）：
 *   边缘起手过阈值 onBack / 不足阈值回弹 / 非边缘起手不触发 / 垂直滚动不误触发 / enabled 关闭。
 */
import { act, renderHook } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { TouchEvent as ReactTouchEvent } from "react";
import {
  isEdgeStart,
  resolveEdgeSwipe,
  useEdgeSwipeBack,
} from "../hooks/useEdgeSwipeBack";

function mockReduced(reduced: boolean) {
  vi.stubGlobal(
    "matchMedia",
    vi.fn(() => ({
      get matches() {
        return reduced;
      },
      addEventListener: () => {},
      removeEventListener: () => {},
    })),
  );
}

afterEach(() => {
  vi.unstubAllGlobals();
});

/** 构造触摸事件（touchstart 有 touches；touchmove/touchend 走 changedTouches） */
function touchStart(x: number, y: number): ReactTouchEvent {
  return { touches: [{ clientX: x, clientY: y }] } as unknown as ReactTouchEvent;
}
function touchMove(x: number, y: number): ReactTouchEvent {
  return { touches: [{ clientX: x, clientY: y }] } as unknown as ReactTouchEvent;
}
function touchEnd(x: number, y: number): ReactTouchEvent {
  return { touches: [], changedTouches: [{ clientX: x, clientY: y }] } as unknown as ReactTouchEvent;
}

describe("isEdgeStart", () => {
  it("起点在边缘带内（≤ edgeWidth）→ true", () => {
    expect(isEdgeStart(0, 24)).toBe(true);
    expect(isEdgeStart(24, 24)).toBe(true);
  });

  it("起点超出边缘带 → false", () => {
    expect(isEdgeStart(25, 24)).toBe(false);
    expect(isEdgeStart(100, 24)).toBe(false);
  });
});

describe("resolveEdgeSwipe", () => {
  it("右滑位移达阈值 → 退出", () => {
    expect(resolveEdgeSwipe(120, 0, 120, 0.3)).toBe(true);
    expect(resolveEdgeSwipe(200, 0, 120, 0.3)).toBe(true);
  });

  it("速度达标（位移不足阈值）→ 退出", () => {
    expect(resolveEdgeSwipe(60, 0.5, 120, 0.3)).toBe(true);
  });

  it("位移不足阈值且速度不达标 → 回弹", () => {
    expect(resolveEdgeSwipe(60, 0.1, 120, 0.3)).toBe(false);
  });

  it("非右滑（dx≤0）→ 回弹", () => {
    expect(resolveEdgeSwipe(0, 0.5, 120, 0.3)).toBe(false);
    expect(resolveEdgeSwipe(-50, 0.5, 120, 0.3)).toBe(false);
  });
});

describe("useEdgeSwipeBack（reduced-motion）", () => {
  it("边缘起手 + 右滑过阈值 → 调用 onBack", () => {
    mockReduced(true);
    const onBack = vi.fn();
    const { result } = renderHook(() => useEdgeSwipeBack({ onBack }));
    act(() => result.current.handlers.onTouchStart(touchStart(0, 0)));
    act(() => result.current.handlers.onTouchMove(touchMove(60, 0)));
    act(() => result.current.handlers.onTouchEnd(touchEnd(130, 0)));
    expect(onBack).toHaveBeenCalledTimes(1);
  });

  it("边缘起手 + 右滑不足阈值 → 不调用 onBack（回弹）", () => {
    mockReduced(true);
    const onBack = vi.fn();
    const { result } = renderHook(() => useEdgeSwipeBack({ onBack }));
    act(() => result.current.handlers.onTouchStart(touchStart(0, 0)));
    act(() => result.current.handlers.onTouchMove(touchMove(30, 0)));
    act(() => result.current.handlers.onTouchEnd(touchEnd(60, 0)));
    expect(onBack).not.toHaveBeenCalled();
  });

  it("非边缘起手（clientX > edgeWidth）→ 不触发（滚动/点击照常）", () => {
    mockReduced(true);
    const onBack = vi.fn();
    const { result } = renderHook(() => useEdgeSwipeBack({ onBack }));
    act(() => result.current.handlers.onTouchStart(touchStart(30, 0)));
    act(() => result.current.handlers.onTouchMove(touchMove(80, 0)));
    act(() => result.current.handlers.onTouchEnd(touchEnd(140, 0)));
    expect(onBack).not.toHaveBeenCalled();
  });

  it("边缘起手 + 垂直滑动 → 不触发（方向锁，垂直滚动优先）", () => {
    mockReduced(true);
    const onBack = vi.fn();
    const { result } = renderHook(() => useEdgeSwipeBack({ onBack }));
    act(() => result.current.handlers.onTouchStart(touchStart(0, 0)));
    act(() => result.current.handlers.onTouchMove(touchMove(0, 80)));
    act(() => result.current.handlers.onTouchEnd(touchEnd(0, 130)));
    expect(onBack).not.toHaveBeenCalled();
  });

  it("enabled=false → 完全不响应", () => {
    mockReduced(true);
    const onBack = vi.fn();
    const { result } = renderHook(() => useEdgeSwipeBack({ onBack, enabled: false }));
    act(() => result.current.handlers.onTouchStart(touchStart(0, 0)));
    act(() => result.current.handlers.onTouchMove(touchMove(60, 0)));
    act(() => result.current.handlers.onTouchEnd(touchEnd(130, 0)));
    expect(onBack).not.toHaveBeenCalled();
  });

  describe("from:'full'（全屏任意位置右滑返回）", () => {
    it("非边缘（屏幕中部）起手 + 右滑过阈值 → 调用 onBack", () => {
      mockReduced(true);
      const onBack = vi.fn();
      const { result } = renderHook(() =>
        useEdgeSwipeBack({ onBack, from: "full" }),
      );
      act(() => result.current.handlers.onTouchStart(touchStart(187, 400)));
      act(() => result.current.handlers.onTouchMove(touchMove(260, 400)));
      act(() => result.current.handlers.onTouchEnd(touchEnd(330, 400)));
      expect(onBack).toHaveBeenCalledTimes(1);
    });

    it("全屏起手 + 右滑不足阈值 → 不调用 onBack（回弹）", () => {
      mockReduced(true);
      const onBack = vi.fn();
      const { result } = renderHook(() =>
        useEdgeSwipeBack({ onBack, from: "full" }),
      );
      act(() => result.current.handlers.onTouchStart(touchStart(187, 400)));
      act(() => result.current.handlers.onTouchMove(touchMove(220, 400)));
      act(() => result.current.handlers.onTouchEnd(touchEnd(240, 400)));
      expect(onBack).not.toHaveBeenCalled();
    });

    it("全屏起手 + 垂直滑动 → 不触发（方向锁，垂直滚动优先）", () => {
      mockReduced(true);
      const onBack = vi.fn();
      const { result } = renderHook(() =>
        useEdgeSwipeBack({ onBack, from: "full" }),
      );
      act(() => result.current.handlers.onTouchStart(touchStart(187, 400)));
      act(() => result.current.handlers.onTouchMove(touchMove(190, 500)));
      act(() => result.current.handlers.onTouchEnd(touchEnd(192, 560)));
      expect(onBack).not.toHaveBeenCalled();
    });

    it("全屏起手 + 原地点按（无位移）→ 不触发", () => {
      mockReduced(true);
      const onBack = vi.fn();
      const { result } = renderHook(() =>
        useEdgeSwipeBack({ onBack, from: "full" }),
      );
      act(() => result.current.handlers.onTouchStart(touchStart(187, 400)));
      act(() => result.current.handlers.onTouchEnd(touchEnd(187, 400)));
      expect(onBack).not.toHaveBeenCalled();
    });
  });
});
