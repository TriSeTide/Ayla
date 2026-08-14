/**
 * useSwipe —— 窄屏手势基座：方向锁 / 阈值 / 取消（开发文档 §2.2）。
 *
 * 语义：
 * - 方向锁：位移达到 lockSlop 后锁定主轴（x/y），此后事件只沿主轴解释；
 *   垂直位移占优时 axis="y"，水平翻页类回调不会误触发（滚动让位系统，永不 preventDefault）。
 * - 阈值：松手时主轴位移 ≥ threshold 才给出 direction，否则 direction=null（吸附回原页）。
 * - 取消：touchcancel 复位并回调 onCancel，不触发 onEnd。
 *
 * 状态机抽成纯函数 createSwipeTracker（单测直接驱动，不依赖 jsdom Touch 对象）；
 * React 绑定层只负责从 TouchEvent 取坐标。F3 下拉回主页、F4 直播间上下滑、
 * 群内五子界面横滑均基于此 hook。
 */
import { useMemo, useRef } from "react";
import type { TouchEvent as ReactTouchEvent } from "react";

export type SwipeAxis = "x" | "y" | null;
export type SwipeDirection = "left" | "right" | "up" | "down" | null;

export interface SwipeMoveEvent {
  dx: number;
  dy: number;
  axis: SwipeAxis;
}

export interface SwipeEndEvent extends SwipeMoveEvent {
  /** 主轴位移达到 threshold 时给出方向，否则 null */
  direction: SwipeDirection;
}

export interface SwipeCallbacks {
  onStart?: () => void;
  onMove?: (e: SwipeMoveEvent) => void;
  onEnd?: (e: SwipeEndEvent) => void;
  onCancel?: () => void;
}

export interface SwipeOptions {
  /** 触发方向判定的主轴位移（px），默认 48 */
  threshold?: number;
  /** 方向锁判定的起步位移（px），默认 12 */
  lockSlop?: number;
}

export interface SwipeTracker {
  start: (x: number, y: number) => void;
  move: (x: number, y: number) => void;
  end: (x: number, y: number) => void;
  cancel: () => void;
  /** 是否正处于一次跟踪中（测试与调试锚点） */
  tracking: () => boolean;
}

export function createSwipeTracker(
  callbacks: SwipeCallbacks,
  options: SwipeOptions = {},
): SwipeTracker {
  const threshold = options.threshold ?? 48;
  const lockSlop = options.lockSlop ?? 12;
  let startX = 0;
  let startY = 0;
  let axis: SwipeAxis = null;
  let active = false;

  const lockAxis = (dx: number, dy: number): SwipeAxis =>
    Math.abs(dx) >= Math.abs(dy) ? "x" : "y";

  const reset = () => {
    active = false;
    axis = null;
  };

  return {
    start(x, y) {
      startX = x;
      startY = y;
      axis = null;
      active = true;
      callbacks.onStart?.();
    },
    move(x, y) {
      if (!active) return;
      const dx = x - startX;
      const dy = y - startY;
      if (axis === null) {
        if (Math.max(Math.abs(dx), Math.abs(dy)) < lockSlop) return;
        axis = lockAxis(dx, dy);
      }
      callbacks.onMove?.({ dx, dy, axis });
    },
    end(x, y) {
      if (!active) return;
      const dx = x - startX;
      const dy = y - startY;
      // 快速滑动（未经历超 lockSlop 的 move）在 end 补一次定轴
      let finalAxis = axis;
      if (finalAxis === null && Math.max(Math.abs(dx), Math.abs(dy)) >= lockSlop) {
        finalAxis = lockAxis(dx, dy);
      }
      let direction: SwipeDirection = null;
      if (finalAxis === "x") {
        if (dx <= -threshold) direction = "left";
        else if (dx >= threshold) direction = "right";
      } else if (finalAxis === "y") {
        if (dy <= -threshold) direction = "up";
        else if (dy >= threshold) direction = "down";
      }
      callbacks.onEnd?.({ dx, dy, axis: finalAxis, direction });
      reset();
    },
    cancel() {
      if (!active) return;
      callbacks.onCancel?.();
      reset();
    },
    tracking: () => active,
  };
}

function firstPoint(e: ReactTouchEvent): { x: number; y: number } | null {
  const t = e.touches[0] ?? e.changedTouches[0];
  return t ? { x: t.clientX, y: t.clientY } : null;
}

export interface SwipeHandlers {
  onTouchStart: (e: ReactTouchEvent) => void;
  onTouchMove: (e: ReactTouchEvent) => void;
  onTouchEnd: (e: ReactTouchEvent) => void;
  onTouchCancel: () => void;
}

/**
 * React 绑定：把 handlers 展开到目标元素（如 <div {...swipe.handlers}>）。
 * threshold/lockSlop 在首次渲染固化（使用方均为静态配置）；回调经 ref 转发，无过期闭包。
 */
export function useSwipe(
  callbacks: SwipeCallbacks,
  options: SwipeOptions = {},
): { handlers: SwipeHandlers; tracker: SwipeTracker } {
  const cbRef = useRef(callbacks);
  cbRef.current = callbacks;

  const tracker = useMemo(
    () =>
      createSwipeTracker(
        {
          onStart: () => cbRef.current.onStart?.(),
          onMove: (e) => cbRef.current.onMove?.(e),
          onEnd: (e) => cbRef.current.onEnd?.(e),
          onCancel: () => cbRef.current.onCancel?.(),
        },
        { threshold: options.threshold, lockSlop: options.lockSlop },
      ),
    // 配置在挂载时固化，见 docstring
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [],
  );

  const handlers = useMemo<SwipeHandlers>(
    () => ({
      onTouchStart: (e) => {
        const p = firstPoint(e);
        if (p) tracker.start(p.x, p.y);
      },
      onTouchMove: (e) => {
        const p = firstPoint(e);
        if (p) tracker.move(p.x, p.y);
      },
      onTouchEnd: (e) => {
        const p = firstPoint(e);
        if (p) tracker.end(p.x, p.y);
      },
      onTouchCancel: () => tracker.cancel(),
    }),
    [tracker],
  );

  return { handlers, tracker };
}
