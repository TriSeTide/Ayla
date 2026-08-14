/**
 * useEnterRoomAnimation 测试（F4）：输入框滑入（100ms 延迟）+ reduced-motion 直入。
 */
import { act, renderHook } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { useEnterRoomAnimation } from "../hooks/useEnterRoomAnimation";

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
  vi.clearAllTimers();
});

describe("useEnterRoomAnimation", () => {
  it("reduced-motion 下直接 inputEntered", () => {
    mockReduced(true);
    const { result } = renderHook(() => useEnterRoomAnimation());
    expect(result.current.inputEntered).toBe(true);
  });

  it("正常路径：初始 false，100ms 后 inputEntered", async () => {
    mockReduced(false);
    vi.useFakeTimers();
    const { result } = renderHook(() => useEnterRoomAnimation());
    expect(result.current.inputEntered).toBe(false);
    await act(async () => {
      vi.advanceTimersByTime(100);
    });
    expect(result.current.inputEntered).toBe(true);
    vi.useRealTimers();
  });
});
