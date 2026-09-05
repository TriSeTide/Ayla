import "@testing-library/jest-dom/vitest";
import { afterEach, vi } from "vitest";
import { cleanup } from "@testing-library/react";

afterEach(() => {
  cleanup();
});

// 模拟 sessionStorage（jsdom 有实现；这里确保干净）
Object.defineProperty(window, "sessionStorage", {
  value: (() => {
    let store: Record<string, string> = {};
    return {
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
      key: (i: number) => Object.keys(store)[i] ?? null,
      get length() {
        return Object.keys(store).length;
      },
    };
  })(),
  configurable: true,
});

// 全局 fetch mock 辅助：测试各自注册
vi.stubGlobal("fetch", vi.fn());

// jsdom 未实现 Element.scrollTo（smooth 滚动在无布局引擎下无意义）：
// 点击触发 scrollTo 的组件（如 ChannelSidebar 点击场景行的吸顶定位）会抛
// Uncaught TypeError 污染测试输出。补 no-op，对齐 corner-fab-stack 的局部 stub 语义。
if (typeof Element !== "undefined" && !Element.prototype.scrollTo) {
  Element.prototype.scrollTo = () => {};
}
