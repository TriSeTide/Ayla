import { act, render, renderHook, waitFor } from "@testing-library/react";
import { AnimatePresence, motion } from "framer-motion";
import type { PanInfo } from "framer-motion";
import { afterEach, describe, expect, it, vi } from "vitest";
import { useMotionDrag } from "../hooks/useMotionDrag";

const releaseInfo: PanInfo = {
  point: { x: 0, y: 400 },
  delta: { x: 0, y: 30 },
  offset: { x: 0, y: 400 },
  velocity: { x: 0, y: 900 },
};
const start = new MouseEvent("pointerdown");
const end = new MouseEvent("pointerup");

function preference() {
  let matches = false;
  const listeners = new Set<() => void>();
  vi.stubGlobal("matchMedia", vi.fn(() => ({
    get matches() { return matches; },
    addEventListener: (_event: string, listener: () => void) => listeners.add(listener),
    removeEventListener: (_event: string, listener: () => void) => listeners.delete(listener),
  })));
  return (reduced: boolean) => act(() => {
    matches = reduced;
    listeners.forEach((listener) => listener());
  });
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("motion drag owner cancellation", () => {
  it("正常离场保留当帧位移，快速返回连续归位且不提交旧松手", async () => {
    preference();
    const owners = new Map<string, ReturnType<typeof useMotionDrag>>();
    const commit = vi.fn();
    function Surface({ id }: { id: string }) {
      const owner = useMotionDrag(true, commit);
      owners.set(id, owner);
      return <motion.div exit={{ opacity: 0, transition: { duration: 1 } }}>{id}</motion.div>;
    }
    const { rerender } = render(<AnimatePresence><Surface key="a" id="a" /></AnimatePresence>);
    const old = owners.get("a")!;
    act(() => {
      old.onDragStart(start, releaseInfo);
      old.offset.set(137);
    });
    rerender(<AnimatePresence><Surface key="b" id="b" /></AnimatePresence>);
    expect(owners.get("a")?.present).toBe(false);
    expect(old.offset.get()).toBe(137);
    expect(owners.get("b")?.offset.get()).toBe(0);
    rerender(<AnimatePresence><Surface key="a" id="a" /></AnimatePresence>);
    expect(owners.get("a")?.allowed).toBe(true);
    // 返场第一帧也不能跳到 0；从离场时的位置平滑恢复，随后必须准确居中。
    expect(owners.get("a")?.offset.get()).toBe(137);
    act(() => old.onDragEnd(end, releaseInfo));
    expect(commit).not.toHaveBeenCalled();
    await waitFor(() => expect(owners.get("a")?.offset.get()).toBe(0), { timeout: 2000 });
  });

  it("关闭拖拽立即取消并清零外层位移；旧松手即使重新启用后也不能切台", () => {
    preference();
    const commit = vi.fn();
    const { result, rerender } = renderHook(({ enabled }) => useMotionDrag(enabled, commit), {
      initialProps: { enabled: true },
    });
    const cancel = vi.spyOn(result.current.controls, "cancel");
    const stop = vi.spyOn(result.current.offset, "stop");
    const staleEnd = result.current.onDragEnd;
    act(() => {
      result.current.onDragStart(start, releaseInfo);
      result.current.offset.set(172);
    });
    rerender({ enabled: false });
    expect(cancel).toHaveBeenCalledTimes(1);
    expect(stop).toHaveBeenCalled();
    expect(result.current.offset.get()).toBe(0);
    act(() => staleEnd(end, releaseInfo));
    rerender({ enabled: true });
    act(() => staleEnd(end, releaseInfo));
    expect(commit).not.toHaveBeenCalled();
    act(() => {
      result.current.onDragStart(start, releaseInfo);
      result.current.onDragEnd(end, releaseInfo);
    });
    expect(commit).toHaveBeenCalledTimes(1);
  });

  it("退出中的面板即使父级enabled属性不再更新，也响应实时reduced-motion", () => {
    const reduce = preference();
    const commit = vi.fn();
    let owner: ReturnType<typeof useMotionDrag>;
    function Surface() {
      owner = useMotionDrag(true, commit);
      return <motion.div exit={{ opacity: 0, transition: { duration: 1 } }}>surface</motion.div>;
    }
    const { rerender } = render(<AnimatePresence><Surface key="panel" /></AnimatePresence>);
    const cancel = vi.spyOn(owner!.controls, "cancel");
    act(() => {
      owner.onDragStart(start, releaseInfo);
      owner.offset.set(-90);
    });
    rerender(<AnimatePresence>{null}</AnimatePresence>);
    expect(owner!.present).toBe(false);
    expect(owner!.offset.get()).toBe(-90);
    reduce(true);
    expect(owner!.allowed).toBe(false);
    expect(owner!.reduced).toBe(true);
    expect(cancel).toHaveBeenCalledTimes(2);
    expect(owner!.offset.get()).toBe(0);
    act(() => owner.onDragEnd(end, releaseInfo));
    expect(commit).not.toHaveBeenCalled();
  });

  it("新旧场景的拖拽owner互不污染，卸载只取消自己的资源", () => {
    preference();
    const first = renderHook(({ enabled }) => useMotionDrag(enabled, vi.fn()), {
      initialProps: { enabled: true },
    });
    const second = renderHook(() => useMotionDrag(true, vi.fn()));
    const secondCancel = vi.spyOn(second.result.current.controls, "cancel");
    act(() => {
      first.result.current.offset.set(45);
      second.result.current.offset.set(-70);
    });
    first.rerender({ enabled: false });
    expect(first.result.current.offset.get()).toBe(0);
    expect(second.result.current.offset.get()).toBe(-70);
    first.unmount();
    expect(secondCancel).not.toHaveBeenCalled();
    second.unmount();
    expect(secondCancel).toHaveBeenCalledTimes(1);
  });

  it("系统pointercancel不作为松手提交，并结束该手势", () => {
    preference();
    const commit = vi.fn();
    const { result } = renderHook(() => useMotionDrag(true, commit));
    act(() => {
      result.current.onDragStart(start, releaseInfo);
      result.current.onDragEnd(new MouseEvent("pointercancel"), releaseInfo);
      result.current.onDragEnd(end, releaseInfo);
    });
    expect(commit).not.toHaveBeenCalled();
  });
});
