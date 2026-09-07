import { act, cleanup, fireEvent, render } from "@testing-library/react";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import OverlayScrollbar from "../components/overlay/OverlayScrollbar";

// Vitest css:false会清空CSS模块；注入真实文件以验证隐藏态的命中契约。
const baseCss = readFileSync(resolve(process.cwd(), "src/styles/base.css"), "utf8");

const hosts: HTMLElement[] = [];
let styles: HTMLStyleElement;

function makeScroller(left = 0): HTMLDivElement {
  const host = document.createElement("div");
  Object.defineProperties(host, {
    clientHeight: { value: 200 },
    scrollHeight: { value: 1000 },
    clientWidth: { value: 320 },
    scrollWidth: { value: 320 },
  });
  host.getBoundingClientRect = () => ({
    x: left, y: 40, left, top: 40, right: left + 320, bottom: 240,
    width: 320, height: 200, toJSON() { return {}; },
  });
  document.body.appendChild(host);
  hosts.push(host);
  return host;
}

function showThumb(host: HTMLElement): HTMLDivElement {
  fireEvent.scroll(host);
  const allThumbs = document.querySelectorAll<HTMLDivElement>(".ov-scrollbar-thumb");
  const thumb = allThumbs[allThumbs.length - 1];
  if (!thumb) throw new Error("滚动后未生成thumb");
  return thumb;
}

beforeEach(() => {
  vi.useFakeTimers();
  vi.stubGlobal("matchMedia", vi.fn(() => ({ matches: false })));
  styles = document.createElement("style");
  styles.textContent = baseCss;
  document.head.appendChild(styles);
});

afterEach(() => {
  cleanup();
  for (const host of hosts.splice(0)) host.remove();
  styles.remove();
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe("OverlayScrollbar owner与命中生命周期", () => {
  it("owner卸载时移除其thumb和timer，其他活动owner保留", async () => {
    render(<OverlayScrollbar />);
    const first = makeScroller();
    const second = makeScroller(400);
    const removedThumb = showThumb(first);
    const retainedThumb = showThumb(second);
    fireEvent.mouseOver(first);
    expect(vi.getTimerCount()).toBe(2);

    await act(async () => { first.remove(); });

    expect(removedThumb).not.toBeInTheDocument();
    expect(first).not.toHaveAttribute("data-ov-scrollbar");
    expect(retainedThumb).toBeInTheDocument();
    expect(retainedThumb).toHaveClass("is-visible");
    expect(second).toHaveAttribute("data-ov-scrollbar");
    expect(vi.getTimerCount()).toBe(1);
    fireEvent.scroll(second);
    expect(document.querySelectorAll(".ov-scrollbar-thumb")).toHaveLength(1);
  });

  it("同批DOM移动仍连接的owner不被回收", async () => {
    render(<OverlayScrollbar />);
    const host = makeScroller();
    const thumb = showThumb(host);

    await act(async () => {
      host.remove();
      document.body.appendChild(host);
    });

    expect(thumb).toBeInTheDocument();
    expect(host).toHaveAttribute("data-ov-scrollbar");
    expect(document.querySelectorAll(".ov-scrollbar-thumb")).toHaveLength(1);
  });

  it("移除后重新挂载同一owner会生成新thumb，不保留旧hover状态", async () => {
    render(<OverlayScrollbar />);
    const host = makeScroller();
    const oldThumb = showThumb(host);
    fireEvent.mouseOver(host);
    await act(async () => { host.remove(); });

    document.body.appendChild(host);
    const newThumb = showThumb(host);
    expect(newThumb).not.toBe(oldThumb);
    act(() => { vi.advanceTimersByTime(600); });
    expect(newThumb).not.toHaveClass("is-visible");
    expect(vi.getTimerCount()).toBe(0);
  });

  it("隐藏thumb不接收指针，悬停owner可再次显示", () => {
    render(<OverlayScrollbar />);
    const host = makeScroller();
    const thumb = showThumb(host);
    expect(thumb).toHaveClass("is-visible");

    act(() => { vi.advanceTimersByTime(600); });
    expect(thumb).not.toHaveClass("is-visible");
    expect(getComputedStyle(thumb).pointerEvents).toBe("none");

    fireEvent.mouseOver(host);
    expect(thumb).toHaveClass("is-visible");
  });

  it("拖动中不被隐藏，owner卸载后清除拖拽状态", async () => {
    render(<OverlayScrollbar />);
    const host = makeScroller();
    const thumb = showThumb(host);
    expect(getComputedStyle(thumb).pointerEvents).toBe("auto");
    thumb.setPointerCapture = vi.fn();
    const down = new MouseEvent("pointerdown", { bubbles: true, clientX: 316, clientY: 42 });
    Object.defineProperty(down, "pointerId", { value: 1 });
    fireEvent(thumb, down);

    act(() => { vi.advanceTimersByTime(600); });
    expect(thumb).toHaveClass("is-visible");
    await act(async () => { host.remove(); });
    document.body.appendChild(host);
    const nextThumb = showThumb(host);
    act(() => { vi.advanceTimersByTime(600); });
    expect(nextThumb).not.toHaveClass("is-visible");
  });

  it("全局卸载清理全部timer，重新挂载时能给原owner创建新投影", () => {
    const view = render(<OverlayScrollbar />);
    const host = makeScroller();
    const oldThumb = showThumb(host);
    expect(vi.getTimerCount()).toBe(1);
    view.unmount();

    expect(vi.getTimerCount()).toBe(0);
    expect(oldThumb).not.toBeInTheDocument();
    expect(host).not.toHaveAttribute("data-ov-scrollbar");
    render(<OverlayScrollbar />);
    expect(showThumb(host)).not.toBe(oldThumb);
  });
});
