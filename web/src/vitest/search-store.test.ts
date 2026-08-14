/**
 * search store 测试（F9）：历史记录去重置顶、上限 10、清空。
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useSearchStore } from "../stores/search";

function mockLocalStorage() {
  let store: Record<string, string> = {};
  vi.stubGlobal("localStorage", {
    getItem: (k: string) => store[k] ?? null,
    setItem: (k: string, v: string) => {
      store[k] = String(v);
    },
    removeItem: (k: string) => {
      delete store[k];
    },
  });
  return () => store;
}

beforeEach(() => {
  mockLocalStorage();
  useSearchStore.setState({ history: [] });
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("search store", () => {
  it("pushHistory 去重置顶", () => {
    useSearchStore.getState().pushHistory("a");
    useSearchStore.getState().pushHistory("b");
    useSearchStore.getState().pushHistory("a");
    expect(useSearchStore.getState().history).toEqual(["a", "b"]);
  });

  it("空词不记录", () => {
    useSearchStore.getState().pushHistory("   ");
    expect(useSearchStore.getState().history).toEqual([]);
  });

  it("上限 10 条", () => {
    for (let i = 0; i < 12; i++) useSearchStore.getState().pushHistory(`q${i}`);
    expect(useSearchStore.getState().history).toHaveLength(10);
    expect(useSearchStore.getState().history[0]).toBe("q11");
  });

  it("clearHistory 清空", () => {
    useSearchStore.getState().pushHistory("a");
    useSearchStore.getState().clearHistory();
    expect(useSearchStore.getState().history).toEqual([]);
  });
});
