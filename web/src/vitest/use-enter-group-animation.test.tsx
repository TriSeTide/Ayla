/**
 * useEnterGroupAnimation 测试：entered 由 rAF 触发；reduced-motion 直接 entered。
 */
import { act, renderHook } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { useEnterGroupAnimation } from "../hooks/useEnterGroupAnimation";

function mockReduced(reduced: boolean) {
  let matches = reduced;
  const listeners = new Set<(e: { matches: boolean }) => void>();
  const mql = {
    get matches() {
      return matches;
    },
    addEventListener: (_t: string, cb: (e: { matches: boolean }) => void) => listeners.add(cb),
    removeEventListener: (_t: string, cb: (e: { matches: boolean }) => void) => listeners.delete(cb),
  };
  vi.stubGlobal("matchMedia", vi.fn(() => mql));
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("useEnterGroupAnimation", () => {
  it("reduced-motion 下直接 entered + inputEntered", () => {
    mockReduced(true);
    const { result } = renderHook(() => useEnterGroupAnimation());
    expect(result.current.entered).toBe(true);
    expect(result.current.inputEntered).toBe(true);
  });

  it("正常路径：初始未进入，rAF 两帧后 entered", async () => {
    mockReduced(false);
    const { result } = renderHook(() => useEnterGroupAnimation());
    expect(result.current.entered).toBe(false);
    // flush 两层 rAF
    await act(async () => {
      await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => r(null))));
    });
    expect(result.current.entered).toBe(true);
  });
});
