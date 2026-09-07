import { act, cleanup, render, screen } from "@testing-library/react";
import { StrictMode, useEffect, useRef, useState } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useListEntryMotion } from "../hooks/useListEntryMotion";

type AnimationRecord = {
  node: HTMLElement;
  options: KeyframeAnimationOptions;
  cancel: ReturnType<typeof vi.fn>;
  onfinish: (() => void) | null;
};

const originalAnimate = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "animate");
let animations: AnimationRecord[];
let setReduced: (next: boolean) => void;
let preferenceListeners: Set<() => void>;

beforeEach(() => {
  let reduced = false;
  preferenceListeners = new Set();
  vi.stubGlobal("matchMedia", vi.fn(() => ({
    get matches() { return reduced; },
    addEventListener: (_event: string, listener: () => void) => preferenceListeners.add(listener),
    removeEventListener: (_event: string, listener: () => void) => preferenceListeners.delete(listener),
  })));
  setReduced = (next) => act(() => {
    reduced = next;
    [...preferenceListeners].forEach((listener) => listener());
  });
  animations = [];
  Object.defineProperty(HTMLElement.prototype, "animate", {
    configurable: true,
    value: function (this: HTMLElement, _keyframes: Keyframe[], options: KeyframeAnimationOptions) {
      const record: AnimationRecord = { node: this, options, cancel: vi.fn(), onfinish: null };
      animations.push(record);
      return record;
    },
  });
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  if (originalAnimate) Object.defineProperty(HTMLElement.prototype, "animate", originalAnimate);
  else Reflect.deleteProperty(HTMLElement.prototype, "animate");
});

function List({ ids, suppressed = false, label = "" }: { ids: string[]; suppressed?: boolean; label?: string }) {
  const ref = useRef<HTMLDivElement>(null);
  useListEntryMotion(ref, ".list-item", suppressed);
  return (
    <div ref={ref} data-testid="list">
      {ids.map((id) => <button key={id} className="list-item" data-testid={id}>{id}{label}</button>)}
    </div>
  );
}

function AsyncList({ page, label = "" }: { page: Promise<string[]>; label?: string }) {
  const [ids, setIds] = useState<string[]>([]);
  useEffect(() => {
    let current = true;
    void page.then((next) => { if (current) setIds(next); });
    return () => { current = false; };
  }, [page]);
  return <List ids={ids} label={label} />;
}

function deferredPage() {
  let resolve!: (ids: string[]) => void;
  const promise = new Promise<string[]>((done) => { resolve = done; });
  return { promise, resolve };
}

function activeFor(node: HTMLElement) {
  return animations.filter((animation) => animation.node === node && animation.cancel.mock.calls.length === 0);
}

describe("列表入场动画只属于本批新增节点", () => {
  it("StrictMode 的首次清理后，同步首屏仍有有效动画且普通更新不重播", () => {
    const { rerender, unmount } = render(<StrictMode><List ids={["a", "b"]} /></StrictMode>);
    const first = screen.getByTestId("a"), second = screen.getByTestId("b");
    // StrictMode 会取消第一次 setup。若 seen 集合未清理，第二次 setup 就会漏掉首屏。
    expect(animations.some((animation) => animation.cancel.mock.calls.length > 0)).toBe(true);
    expect(activeFor(first)).toHaveLength(1);
    expect(activeFor(second)).toHaveLength(1);
    const running = [...activeFor(first), ...activeFor(second)];
    const count = animations.length;
    rerender(<StrictMode><List ids={["a", "b"]} label="更新" /></StrictMode>);
    expect(screen.getByTestId("a")).toBe(first);
    expect(animations).toHaveLength(count);
    unmount();
    running.forEach((animation) => expect(animation.cancel).toHaveBeenCalledTimes(1));
    expect(preferenceListeners.size).toBe(0);
  });

  it("异步首批和追加分别播放，旧卡片保持节点、焦点及滚动，追加延迟从零开始", async () => {
    const firstPage = deferredPage(), secondPage = deferredPage();
    const { rerender } = render(<AsyncList page={firstPage.promise} />);
    expect(animations).toHaveLength(0);
    await act(async () => { firstPage.resolve(["a", "b"]); await firstPage.promise; });
    const first = screen.getByTestId("a"), second = screen.getByTestId("b"), list = screen.getByTestId("list");
    expect(activeFor(first)).toHaveLength(1);
    expect(activeFor(second)).toHaveLength(1);
    act(() => [...animations].forEach((animation) => animation.onfinish?.()));
    const firstBatchCount = animations.length;
    first.focus();
    list.scrollTop = 237;

    rerender(<AsyncList page={secondPage.promise} />);
    expect(screen.getByTestId("a")).toBe(first);
    expect(animations).toHaveLength(firstBatchCount);
    await act(async () => { secondPage.resolve(["a", "b", "c", "d"]); await secondPage.promise; });
    expect(screen.getByTestId("a")).toBe(first);
    expect(screen.getByTestId("b")).toBe(second);
    expect(first).toHaveFocus();
    expect(list.scrollTop).toBe(237);
    const appended = animations.slice(firstBatchCount);
    expect(appended.map((animation) => animation.node)).toEqual([screen.getByTestId("c"), screen.getByTestId("d")]);
    expect(appended.map((animation) => animation.options.delay)).toEqual([0, 50]);
    rerender(<AsyncList page={secondPage.promise} label="点赞数更新" />);
    expect(animations).toHaveLength(firstBatchCount + 2);
  });

  it("运行中切换 reduced-motion 会取消含 stagger 等待的整批，恢复偏好不重播旧项", () => {
    const { rerender, unmount } = render(<List ids={["a", "b", "c"]} />);
    const pendingBatch = [...animations];
    expect(pendingBatch.some((animation) => Number(animation.options.delay) > 0)).toBe(true);
    setReduced(true);
    pendingBatch.forEach((animation) => expect(animation.cancel).toHaveBeenCalledTimes(1));
    rerender(<List ids={["a", "b", "c", "d"]} />);
    expect(animations).toHaveLength(pendingBatch.length);
    expect(screen.getByTestId("d")).toBeVisible();
    setReduced(false);
    expect(animations).toHaveLength(pendingBatch.length);
    rerender(<List ids={["a", "b", "c", "d", "e"]} />);
    expect(animations.slice(pendingBatch.length).map((animation) => animation.node)).toEqual([screen.getByTestId("e")]);
    expect(animations.at(-1)?.options.delay).toBe(0);
    unmount();
    animations.forEach((animation) => expect(animation.cancel).toHaveBeenCalledTimes(1));
    expect(preferenceListeners.size).toBe(0);
  });

  it("滚动恢复期间直接显示内容，解除抑制只动画后来新增项", () => {
    const { rerender, unmount } = render(<List ids={["a", "b"]} suppressed />);
    const first = screen.getByTestId("a"), list = screen.getByTestId("list");
    list.scrollTop = 480;
    expect(animations).toHaveLength(0);
    rerender(<List ids={["a", "b"]} />);
    expect(screen.getByTestId("a")).toBe(first);
    expect(list.scrollTop).toBe(480);
    expect(animations).toHaveLength(0);
    rerender(<List ids={["a", "b", "c"]} />);
    expect(animations.map((animation) => animation.node)).toEqual([screen.getByTestId("c")]);
    rerender(<List ids={["a", "b", "c"]} suppressed />);
    expect(animations[0].cancel).toHaveBeenCalledTimes(1);
    expect(screen.getByTestId("c")).toBeVisible();
    unmount();
    expect(animations[0].cancel).toHaveBeenCalledTimes(1);
  });

  it("移除的卡片立即取消，已完成动画不在卸载时重复清理", () => {
    const { rerender, unmount } = render(<List ids={["a", "b"]} />);
    const [first, second] = animations;
    rerender(<List ids={["a"]} />);
    expect(second.node.isConnected).toBe(false);
    expect(second.cancel).toHaveBeenCalledTimes(1);
    expect(first.cancel).not.toHaveBeenCalled();
    act(() => first.onfinish?.());
    expect(first.cancel).toHaveBeenCalledTimes(1);
    unmount();
    expect(first.cancel).toHaveBeenCalledTimes(1);
    expect(second.cancel).toHaveBeenCalledTimes(1);
  });

  it("缺少 Web Animations API 时异步新增内容仍直接可见", () => {
    Reflect.deleteProperty(HTMLElement.prototype, "animate");
    const { rerender } = render(<List ids={[]} />);
    rerender(<List ids={["a"]} />);
    expect(screen.getByTestId("a")).toBeVisible();
    expect(screen.getByTestId("a").style.opacity).toBe("");
    expect(screen.getByTestId("a").style.transform).toBe("");
    expect(animations).toHaveLength(0);
  });
});
