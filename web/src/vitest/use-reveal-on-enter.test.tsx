/**
 * useRevealOnEnter 测试：统一内容入场原语。
 * - reduced-motion 下直接 revealed；
 * - 正常路径：初始隐藏，双 rAF 后 revealed；
 * - staggerDelay：递增但封顶。
 */
import { act, renderHook } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { staggerDelay, useRevealOnEnter } from "../hooks/useRevealOnEnter";

function mockReduced(reduced: boolean) {
  let matches = reduced;
  const mql = {
    get matches() {
      return matches;
    },
    addEventListener: () => {},
    removeEventListener: () => {},
  };
  vi.stubGlobal("matchMedia", vi.fn(() => mql));
}

function mockRaf() {
  const rafs: Array<() => void> = [];
  vi.stubGlobal("requestAnimationFrame", (cb: () => void) => {
    rafs.push(cb);
    return rafs.length;
  });
  vi.stubGlobal("cancelAnimationFrame", () => {});
  return rafs;
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("useRevealOnEnter", () => {
  it("reduced-motion 下直接 revealed", () => {
    mockReduced(true);
    const { result } = renderHook(() => useRevealOnEnter());
    expect(result.current.revealed).toBe(true);
    expect(result.current.step).toBe(1);
  });

  it("正常路径：初始隐藏，双 rAF 后 revealed", async () => {
    mockReduced(false);
    const rafs = mockRaf();
    const { result } = renderHook(() => useRevealOnEnter());
    expect(result.current.step).toBe(0);
    // 第一步 rAF
    await act(async () => {
      rafs[0]();
    });
    expect(result.current.step).toBe(0);
    // 第二步 rAF 才置为可见
    await act(async () => {
      rafs[1]();
    });
    expect(result.current.step).toBe(1);
  });

  it("active=false 时归零", () => {
    mockReduced(false);
    const rafs = mockRaf();
    const { result, rerender } = renderHook(({ active }) => useRevealOnEnter(active), {
      initialProps: { active: true },
    });
    act(() => {
      rafs[0]();
      rafs[1]();
    });
    expect(result.current.step).toBe(1);
    rerender({ active: false });
    expect(result.current.step).toBe(0);
  });
});

describe("staggerDelay", () => {
  it("逐项递增且封顶", () => {
    expect(staggerDelay(0)).toBe(0);
    expect(staggerDelay(1)).toBe(40);
    expect(staggerDelay(10)).toBe(300); // 封顶
  });
});
