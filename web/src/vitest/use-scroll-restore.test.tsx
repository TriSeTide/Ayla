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

  it("显式记录顶部位置后返回也标记 restoring，调用方可跳过 stagger", () => {
    const el1 = document.createElement("div");
    const first = renderHook(() => useScrollRestore("feed", { current: el1 }));
    act(() => {
      el1.scrollTop = 0;
      el1.dispatchEvent(new Event("scroll"));
    });
    first.unmount();

    const el2 = document.createElement("div");
    const second = renderHook(() => useScrollRestore("feed", { current: el2 }));
    expect(second.result.current.restoring).toBe(true);
    expect(el2.scrollTop).toBe(0);
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

  it("退出动画把 DOM 归零但未发 scroll 时，不覆盖最后真实滚动值", () => {
    const el1 = document.createElement("div");
    const first = renderHook(() => useScrollRestore("feed", { current: el1 }));
    act(() => {
      el1.scrollTop = 360;
      el1.dispatchEvent(new Event("scroll"));
    });
    // AnimatePresence 退出阶段可能把已退出 DOM 归零，但不会产生用户 scroll 事件。
    el1.scrollTop = 0;
    first.unmount();

    const el2 = document.createElement("div");
    const second = renderHook(() => useScrollRestore("feed", { current: el2 }));
    expect(second.result.current.restoring).toBe(true);
    expect(el2.scrollTop).toBe(360);
  });

  it("active 列表→详情→列表：条件卸载/重建后恢复（GroupPosts 形态）", () => {
    const ref: { current: HTMLElement | null } = { current: document.createElement("div") };
    const hook = renderHook(
      ({ active, ready }) => useScrollRestore("group-posts:54", ref, { active, ready }),
      { initialProps: { active: true, ready: true } },
    );
    act(() => {
      if (!ref.current) throw new Error("missing list element");
      ref.current.scrollTop = 480;
      ref.current.dispatchEvent(new Event("scroll"));
    });

    act(() => {
      ref.current = null;
      hook.rerender({ active: false, ready: true });
    });
    const restored = document.createElement("div");
    act(() => {
      ref.current = restored;
      hook.rerender({ active: true, ready: true });
    });
    expect(hook.result.current.restoring).toBe(true);
    expect(restored.scrollTop).toBe(480);
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
