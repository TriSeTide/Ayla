/**
 * useEdgeSwipeBack —— 私聊页右滑返回手势（方案 §2.6，视差按用户拍板废弃）。
 *
 * 语义：
 * - 起手模式：'edge' 仅左边缘带起手（iOS 式，历史默认）；'full' 全屏任意位置右滑返回。
 * - 跟手：水平定轴（axis=x，方向锁保证垂直滚动优先）后右滑 dx 1:1 驱动上层位移；
 *   底层（/messages 本体）**静止不动**（iOS 导航栈 pop 式，用户拍板 2026-08-26，
 *   原方案「0.3 倍速视差」实测观感奇怪废弃）。
 * - 退出/回弹：松手时 dx ≥ exitThreshold（默认 120px）或速度 ≥ flickVelocity（默认
 *   0.3px/ms ≈ 300px/s）→ 上层滑出右屏（200ms ease-out）后 onBack；否则回弹（200ms）。
 * - 垂直滚动让位：方向锁判定 axis="y" 时完全不跟手，原生滚动照常，不 preventDefault。
 * - prefers-reduced-motion：关闭跟手与位移，松手直切返回（仅保留语义，无动画）。
 *
 * 与 useSwipe 关系：复用其 createSwipeTracker（方向锁 / 阈值 / 取消状态机），
 * 在其上封装「起手判定（edge 边缘 / full 全屏）」与「velocity 估算」（useSwipe 的 onEnd 无速度字段）。
 * 时长/曲线对齐 tokens.css --ease-out（framer-motion 用等价 4 元组），遵守 design.md §7。
 */
import { useEffect, useMemo, useRef, useState } from "react";
import { animate, useMotionValue } from "framer-motion";
import type { MotionValue } from "framer-motion";
import type { TouchEvent as ReactTouchEvent } from "react";
import type { SwipeHandlers } from "./useSwipe";
import { useSwipe } from "./useSwipe";

/** 等价 tokens.css --ease-out（cubic-bezier(.22,.61,.36,1)） */
const EASE_OUT: [number, number, number, number] = [0.22, 0.61, 0.36, 1];

/** 退出/回弹时长（design.md §7 面板进出 200–300ms；方案 §2.6 滑出 200ms） */
const EXIT_DURATION = 0.2;
const SPRING_BACK_DURATION = 0.2;

export interface EdgeSwipeBackOptions {
  /** 滑出返回回调（一般 navigate 回消息中心） */
  onBack: () => void;
  /** 起手模式：'edge' 仅左边缘带起手（iOS 式，默认）；'full' 全屏任意位置右滑返回。
      两种模式都靠方向锁（垂直滚动优先）与位移阈值判定，点击/滚动照常不误触。 */
  from?: "edge" | "full";
  /** 边缘起手带宽度（px），仅 'edge' 模式生效，默认 24 */
  edgeWidth?: number;
  /** 退出阈值（px），默认 120 */
  exitThreshold?: number;
  /** 快速滑速度阈值（px/ms），默认 0.3（≈300px/s，与群内横滑同款） */
  flickVelocity?: number;
  /** 是否启用（调用方传 isNarrow，宽屏禁用），默认 true */
  enabled?: boolean;
}

export interface EdgeSwipeBackResult {
  /** 绑到上层聊天容器（整页）的 touch handlers */
  handlers: SwipeHandlers;
  /** 上层（聊天页）位移 motion value，1:1 跟手；底层不绑位移（静止） */
  x: MotionValue<number>;
}

/** 边缘起手判定：触摸起点是否落在左边缘带内（纯函数，供单测） */
export function isEdgeStart(clientX: number, edgeWidth: number): boolean {
  return clientX <= edgeWidth;
}

/** 退出判定：右滑位移达阈值或速度达标（纯函数，供单测） */
export function resolveEdgeSwipe(
  dx: number,
  velocity: number,
  exitThreshold: number,
  flickVelocity: number,
): boolean {
  return dx > 0 && (dx >= exitThreshold || velocity >= flickVelocity);
}

function firstPoint(e: ReactTouchEvent): { x: number; y: number } | null {
  const t = e.touches[0] ?? e.changedTouches[0];
  return t ? { x: t.clientX, y: t.clientY } : null;
}

function prefersReducedMotion(): boolean {
  return (
    typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches
  );
}

export function useEdgeSwipeBack(options: EdgeSwipeBackOptions): EdgeSwipeBackResult {
  const {
    onBack,
    from = "edge",
    edgeWidth = 24,
    exitThreshold = 120,
    flickVelocity = 0.3,
    enabled = true,
  } = options;

  const x = useMotionValue(0);

  // 惰性同步读取 reduced-motion（非 effect）：reduced 用户在首帧即无位移，避免闪跳
  const [reduced] = useState(prefersReducedMotion);

  // 回调经 ref 转发，避免退出动画 setTimeout 里的过期闭包
  const onBackRef = useRef(onBack);
  onBackRef.current = onBack;
  const exitTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // 是否已进入跟踪（起手判定通过）：edge 起手判定或 full 全屏起手都置位。
  const startedRef = useRef(false);
  const lastSampleRef = useRef<{ dx: number; t: number } | null>(null);

  const exitToBack = useMemo(
    () => () => {
      const width = typeof window !== "undefined" ? window.innerWidth : 375;
      if (reduced) {
        x.set(width);
        onBackRef.current();
        return;
      }
      animate(x, width, { duration: EXIT_DURATION, ease: EASE_OUT });
      exitTimerRef.current = setTimeout(() => onBackRef.current(), EXIT_DURATION * 1000);
    },
    [reduced, x],
  );

  const springBack = useMemo(
    () => () => {
      if (reduced) {
        x.set(0);
        return;
      }
      animate(x, 0, { duration: SPRING_BACK_DURATION, ease: EASE_OUT });
    },
    [reduced, x],
  );

  const swipe = useSwipe(
    {
      onMove: (e) => {
        if (reduced || !enabled) return;
        if (e.axis !== "x") return; // 垂直滚动优先（方向锁），不跟手
        x.set(Math.max(0, e.dx));
        lastSampleRef.current = { dx: e.dx, t: performance.now() };
      },
      onEnd: (e) => {
        if (!enabled) return;
        const sample = lastSampleRef.current;
        const velocity = (() => {
          if (!sample) return 0;
          const dt = performance.now() - sample.t;
          return dt > 0 ? (e.dx - sample.dx) / dt : 0;
        })();
        lastSampleRef.current = null;
        startedRef.current = false;
        const shouldExit =
          e.axis === "x" && resolveEdgeSwipe(e.dx, velocity, exitThreshold, flickVelocity);
        if (shouldExit) {
          exitToBack();
        } else {
          springBack();
        }
      },
      onCancel: () => {
        lastSampleRef.current = null;
        startedRef.current = false;
        springBack();
      },
    },
    { threshold: exitThreshold, lockSlop: 12 },
  );

  // 退出动画 timer 清理（组件卸载时避免对已卸载路由调用 navigate）
  useEffect(() => {
    return () => {
      if (exitTimerRef.current) clearTimeout(exitTimerRef.current);
    };
  }, []);

  // 自定义 handlers：'edge' 限定左边缘起手；'full' 全屏任意位置起手。
  // 非起手区直接不 start（滚动/点击照常）；full 模式靠方向锁 + 阈值判定，
  // 垂直滚动（axis=y）不跟手，点击无位移不误触。都遵循 useSwipe「不 preventDefault」。
  const handlers = useMemo<SwipeHandlers>(() => {
    const { tracker } = swipe;
    return {
      onTouchStart: (e) => {
        if (!enabled) return;
        const p = firstPoint(e);
        if (!p) return;
        if (from === "edge" && !isEdgeStart(p.x, edgeWidth)) {
          startedRef.current = false;
          return;
        }
        startedRef.current = true;
        lastSampleRef.current = null;
        tracker.start(p.x, p.y);
      },
      onTouchMove: (e) => {
        if (!startedRef.current) return;
        const p = firstPoint(e);
        if (p) tracker.move(p.x, p.y);
      },
      onTouchEnd: (e) => {
        if (!startedRef.current) return;
        const p = firstPoint(e);
        if (p) tracker.end(p.x, p.y);
      },
      onTouchCancel: () => {
        if (!startedRef.current) return;
        tracker.cancel();
      },
    };
  }, [swipe, enabled, edgeWidth, from]);

  return { handlers, x };
}
