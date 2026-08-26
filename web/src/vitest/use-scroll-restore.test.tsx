/**
 * useScrollRestore 测试：列表返回滚动位置恢复（方案 §4-U14）。
 * - 首次挂载（无记忆）：restoring=false，不恢复；
 * - 离开记录 scrollTop + 再挂载：restoring=true 并恢复；
 * - 滚动实时记录，卸载后最新值持久。
 */
import { act, renderHook } from "@testing-library/react";
import { beforeEach, describe, expect, it } from "vitest";
import { clearScrollMemory, useScrollRestore } from "../hooks/useScrollRestore";

beforeEach(() => clearScrollMemory());

describe("useScrollRestore", () => {
  it("首次挂载无记忆 → restoring=false，不恢复 scrollTop", () => {
    const el = document.createElement("div");
    const { result } = renderHook(() => useScrollRestore("feed", { current: el }));
    expect(result.current.restoring).toBe(false);
    expect(el.scrollTop).toBe(0);
  });

  it("离开记录 + 再挂载 → restoring=true 并恢复 scrollTop", () => {
    const el1 = document.createElement("div");
    const first = renderHook(() => useScrollRestore("feed", { current: el1 }));
    act(() => {
      el1.scrollTop = 300;
      el1.dispatchEvent(new Event("scroll"));
    });
    first.unmount();

    const el2 = document.createElement("div");
    const second = renderHook(() => useScrollRestore("feed", { current: el2 }));
    expect(second.result.current.restoring).toBe(true);
    expect(el2.scrollTop).toBe(300);
  });

  it("滚动实时记录，卸载后最新值持久", () => {
    const el = document.createElement("div");
    const { unmount } = renderHook(() => useScrollRestore("feed", { current: el }));
    act(() => {
      el.scrollTop = 120;
      el.dispatchEvent(new Event("scroll"));
      el.scrollTop = 240;
      el.dispatchEvent(new Event("scroll"));
    });
    unmount();

    const el2 = document.createElement("div");
    renderHook(() => useScrollRestore("feed", { current: el2 }));
    expect(el2.scrollTop).toBe(240);
  });

  it("不同 key 隔离记忆", () => {
    const el1 = document.createElement("div");
    const first = renderHook(() => useScrollRestore("live", { current: el1 }));
    act(() => {
      el1.scrollTop = 500;
      el1.dispatchEvent(new Event("scroll"));
    });
    first.unmount();

    const el2 = document.createElement("div");
    const second = renderHook(() => useScrollRestore("posts", { current: el2 }));
    expect(second.result.current.restoring).toBe(false);
    expect(el2.scrollTop).toBe(0);
  });
});
