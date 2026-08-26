/**
 * useMasonryColumns 测试（方案 §4-U2）：双列等宽错排瀑布流分配。
 * - 单列：全部进一列；
 * - 双列：新 item 交错（预估增量）分配到两列；
 * - 追加不重排已有 item（稳定性，滚动恢复前提）；
 * - 跨挂载记忆恢复（同 memoryKey）；
 * - 不同 memoryKey 隔离；
 * - 断点切换（columnCount 变化）越界重分配；
 * - ResizeObserver 量高后新 item 插较矮列。
 */
import { act, renderHook } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { clearMasonryMemory, useMasonryColumns } from "../hooks/useMasonryColumns";

type Item = number;

beforeEach(() => {
  clearMasonryMemory();
  vi.unstubAllGlobals();
});

function renderMasonry(items: Item[], columnCount: number, memoryKey = "feed") {
  return renderHook(
    ({ items, columnCount }) =>
      useMasonryColumns<Item>(items, columnCount, (p) => p, memoryKey),
    { initialProps: { items, columnCount } },
  );
}

describe("useMasonryColumns", () => {
  it("单列：全部进一列，columnRefs 长度 1", () => {
    const { result } = renderMasonry([1, 2, 3], 1);
    expect(result.current.columns).toHaveLength(1);
    expect(result.current.columns[0]).toEqual([1, 2, 3]);
    expect(result.current.columnRefs).toHaveLength(1);
  });

  it("双列：新 item 交错分配（预估增量）", () => {
    const { result } = renderMasonry([1, 2, 3, 4], 2);
    expect(result.current.columns).toHaveLength(2);
    expect(result.current.columns[0]).toEqual([1, 3]);
    expect(result.current.columns[1]).toEqual([2, 4]);
  });

  it("追加 item 不重排已有 item（稳定性）", () => {
    const { result, rerender } = renderMasonry([1, 2, 3, 4], 2);
    expect(result.current.columns[0]).toEqual([1, 3]);
    expect(result.current.columns[1]).toEqual([2, 4]);

    rerender({ items: [1, 2, 3, 4, 5, 6], columnCount: 2 });
    // 已有 item 列归属不变，新 item 5/6 交错续插
    expect(result.current.columns[0].slice(0, 2)).toEqual([1, 3]);
    expect(result.current.columns[1].slice(0, 2)).toEqual([2, 4]);
    expect(result.current.columns[0]).toHaveLength(3);
    expect(result.current.columns[1]).toHaveLength(3);
  });

  it("跨挂载记忆恢复：同 memoryKey 重挂载分配一致", () => {
    const first = renderMasonry([1, 2, 3, 4], 2, "posts-feed");
    const before = first.result.current.columns.map((c) => [...c]);
    first.unmount();

    const second = renderMasonry([1, 2, 3, 4], 2, "posts-feed");
    expect(second.result.current.columns).toEqual(before);
  });

  it("不同 memoryKey 隔离记忆", () => {
    const first = renderMasonry([1, 2], 2, "feed");
    first.unmount();

    const second = renderMasonry([1, 2], 2, "other");
    // 新 key 无记忆，从 [0,0] 起交错 → 1→col0, 2→col1（与 feed 键首次一致，但验证不抛错且可重分配）
    expect(second.result.current.columns[0]).toContain(1);
    expect(second.result.current.columns[1]).toContain(2);
  });

  it("移除 item 后剩余 item 列归属不变", () => {
    const { result, rerender } = renderMasonry([1, 2, 3, 4], 2);
    rerender({ items: [1, 3], columnCount: 2 });
    // 1、3 原在 col0，移除 2/4 后仍应保持
    expect(result.current.columns[0]).toEqual([1, 3]);
    expect(result.current.columns[1]).toEqual([]);
  });

  it("断点切换（columnCount 2→1）越界 item 重分配到有效列", () => {
    const { result, rerender } = renderMasonry([1, 2, 3, 4], 2);
    rerender({ items: [1, 2, 3, 4], columnCount: 1 });
    expect(result.current.columns).toHaveLength(1);
    expect(result.current.columns[0]).toEqual([1, 2, 3, 4]);
  });

  it("ResizeObserver 量高后新 item 插较矮列", () => {
    class MockRO {
      static instances: MockRO[] = [];
      cb: ResizeObserverCallback;
      els: Element[] = [];
      constructor(cb: ResizeObserverCallback) {
        this.cb = cb;
        MockRO.instances.push(this);
      }
      observe(el: Element) {
        this.els.push(el);
      }
      unobserve() {}
      disconnect() {}
    }
    vi.stubGlobal("ResizeObserver", MockRO);

    const { result, rerender } = renderMasonry([1, 2], 2, "feed");
    // 手动挂载两个列容器并 stub 高度
    const col0 = document.createElement("div");
    const col1 = document.createElement("div");
    Object.defineProperty(col0, "offsetHeight", { value: 1000, configurable: true });
    Object.defineProperty(col1, "offsetHeight", { value: 500, configurable: true });
    act(() => {
      result.current.columnRefs[0](col0);
      result.current.columnRefs[1](col1);
    });

    // 触发 RO 量高 → colHeights = [1000, 500]
    act(() => {
      const ro = MockRO.instances[0];
      ro.cb([], ro);
    });

    // 追加新 item 3 → 应插较矮列 col1
    rerender({ items: [1, 2, 3], columnCount: 2 });
    expect(result.current.columns[1]).toContain(3);
  });
});
