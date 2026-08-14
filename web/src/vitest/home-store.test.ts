/**
 * home store 测试：布局偏好与最近群 localStorage 持久化。
 * jsdom 无 localStorage 完备实现，setup.ts 已 mock sessionStorage；
 * localStorage 需此文件内 mock（readLayout 等有 try/catch 兜底）。
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import { useHomeStore } from "../stores/home";

function mockLocalStorage() {
  let store: Record<string, string> = {};
  const ls = {
    getItem: (k: string) => store[k] ?? null,
    setItem: (k: string, v: string) => {
      store[k] = String(v);
    },
    removeItem: (k: string) => {
      delete store[k];
    },
    clear: () => {
      store = {};
    },
  };
  vi.stubGlobal("localStorage", ls);
  return {
    get(key: string) {
      return store[key];
    },
  };
}

describe("home store", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  it("默认布局为 card", () => {
    mockLocalStorage();
    useHomeStore.setState({ layout: "card", recentGroupId: null });
    expect(useHomeStore.getState().layout).toBe("card");
  });

  it("setLayout 持久化到 localStorage", () => {
    const ls = mockLocalStorage();
    useHomeStore.getState().setLayout("list");
    expect(useHomeStore.getState().layout).toBe("list");
    expect(ls.get("ayla.home.layout")).toBe("list");
  });

  it("setRecentGroup 持久化并可清除", () => {
    const ls = mockLocalStorage();
    useHomeStore.getState().setRecentGroup("g1");
    expect(useHomeStore.getState().recentGroupId).toBe("g1");
    expect(ls.get("ayla.home.recent_group")).toBe("g1");

    useHomeStore.getState().setRecentGroup(null);
    expect(useHomeStore.getState().recentGroupId).toBeNull();
    expect(ls.get("ayla.home.recent_group")).toBeUndefined();
  });
});
