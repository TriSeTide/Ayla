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

function List({ ids, suppressed = false, label = "", replayKey }: { ids: string[]; suppressed?: boolean; label?: string; replayKey?: number }) {
  const ref = useRef<HTMLDivElement>(null);
  useListEntryMotion(ref, ".list-item", suppressed, replayKey);
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
    // 进入抑制期不中途取消已开始的动画（节点仍在文档中 → 动画继续跑完）；
    // 刷新重播动画可能正在运行，中途取消会让它卡住。
    rerender(<List ids={["a", "b", "c"]} suppressed />);
    expect(animations[0].cancel).not.toHaveBeenCalled();
    expect(screen.getByTestId("c")).toBeVisible();
    unmount();
    // 卸载时统一清理
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

describe("刷新重播（replayKey）", () => {
  it("replayKey 变化时已入场卡片整批重播，新增卡片只入场一次", () => {
    const { rerender } = render(<List ids={["a", "b"]} replayKey={0} />);
    const first = screen.getByTestId("a"), second = screen.getByTestId("b");
    expect(activeFor(first)).toHaveLength(1);
    expect(activeFor(second)).toHaveLength(1);
    act(() => [...animations].forEach((animation) => animation.onfinish?.()));
    const beforeReplay = animations.length;

    // 刷新：保留 a/b，新增 c；replayKey 递增 → a/b 重播、c 只入场一次
    rerender(<List ids={["a", "b", "c"]} replayKey={1} />);
    expect(screen.getByTestId("a")).toBe(first);
    expect(screen.getByTestId("b")).toBe(second);
    const replayed = animations.slice(beforeReplay);
    // 先重播已入场 a/b（0、50 错峰），主 effect 随后让新增 c 入场（delay 0）
    expect(replayed.map((animation) => animation.node)).toEqual([first, second, screen.getByTestId("c")]);
    expect(replayed.map((animation) => animation.options.delay)).toEqual([0, 50, 0]);
    expect(activeFor(first)).toHaveLength(1);
    expect(activeFor(second)).toHaveLength(1);
    expect(activeFor(screen.getByTestId("c"))).toHaveLength(1);
  });

  it("replayKey 不变时普通更新不重播；再次变化才重播", () => {
    const { rerender } = render(<List ids={["a", "b"]} replayKey={0} />);
    act(() => [...animations].forEach((animation) => animation.onfinish?.()));
    const count = animations.length;
    rerender(<List ids={["a", "b"]} replayKey={0} label="更新" />);
    expect(animations).toHaveLength(count);
    rerender(<List ids={["a", "b"]} replayKey={1} />);
    expect(animations.length).toBeGreaterThan(count);
    expect(animations.slice(count).map((animation) => animation.node)).toEqual([screen.getByTestId("a"), screen.getByTestId("b")]);
  });

  it("首次挂载不因初始 replayKey 重播", () => {
    render(<List ids={["a", "b"]} replayKey={7} />);
    expect(activeFor(screen.getByTestId("a"))).toHaveLength(1);
    expect(activeFor(screen.getByTestId("b"))).toHaveLength(1);
  });

  it("抑制期仍重播（切换选项卡后刷新动画不失效）；只有 reduced-motion 阻止", () => {
    const { rerender } = render(<List ids={["a", "b"]} replayKey={0} />);
    act(() => [...animations].forEach((animation) => animation.onfinish?.()));
    const count = animations.length;
    // suppressed = 命中历史滚动位置。切换分类选项卡时 onChange 会写入位置记录，
    // 切回该 tab 后 restoring 持续为真；若用它抑制重播，切 tab 后刷新将永远无动画。
    rerender(<List ids={["a", "b"]} replayKey={1} suppressed />);
    expect(animations).toHaveLength(count + 2);
    // reduced-motion 仍关闭重播
    setReduced(true);
    rerender(<List ids={["a", "b"]} replayKey={2} suppressed />);
    expect(animations).toHaveLength(count + 2);
    setReduced(false);
    rerender(<List ids={["a", "b"]} replayKey={3} suppressed />);
    expect(animations.slice(count + 2).map((animation) => animation.node))
      .toEqual([screen.getByTestId("a"), screen.getByTestId("b")]);
  });

  it("抑制期不中途取消刷新重播动画（避免刷新动画卡住）", () => {
    const { rerender } = render(<List ids={["a", "b"]} replayKey={0} />);
    act(() => [...animations].forEach((animation) => animation.onfinish?.()));
    const count = animations.length;
    // 刷新重播启动（suppressed 同时为真，模拟切 tab 后命中历史位置时刷新）
    rerender(<List ids={["a", "b"]} replayKey={1} suppressed />);
    const replayed = animations.slice(count);
    expect(replayed).toHaveLength(2);
    // 后续渲染（主 effect 每次 commit 都跑）不得取消正在跑的刷新重播动画
    rerender(<List ids={["a", "b"]} replayKey={1} suppressed label="再渲染" />);
    replayed.forEach((animation) => expect(animation.cancel).not.toHaveBeenCalled());
    rerender(<List ids={["a", "b"]} replayKey={1} suppressed label="再渲染二" />);
    replayed.forEach((animation) => expect(animation.cancel).not.toHaveBeenCalled());
    // 动画完成时仍按原语义清理
    act(() => replayed.forEach((animation) => animation.onfinish?.()));
    replayed.forEach((animation) => expect(animation.cancel).toHaveBeenCalledTimes(1));
  });

  it("重播会取消该节点仍在运行的旧动画，卸载时统一清理", () => {
    const { rerender, unmount } = render(<List ids={["a", "b"]} replayKey={0} />);
    const [first, second] = animations;
    rerender(<List ids={["a", "b"]} replayKey={1} />);
    expect(first.cancel).toHaveBeenCalledTimes(1);
    expect(second.cancel).toHaveBeenCalledTimes(1);
    const replayed = animations.slice(2);
    expect(replayed.map((animation) => animation.node)).toEqual([screen.getByTestId("a"), screen.getByTestId("b")]);
    unmount();
    replayed.forEach((animation) => expect(animation.cancel).toHaveBeenCalledTimes(1));
  });
});
