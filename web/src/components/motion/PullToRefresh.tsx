/**
 * PullToRefresh —— 列表顶部下拉刷新（方案 §3.3 / design.md §7）。
 *
 * 交互：列表已在顶部时下拉 → 跟手位移（阻尼递增）→ 过阈值松手触发 onRefresh
 * （指示器转 spinner）→ 完成后收起；不足阈值回弹。仅在滚动容器已在顶部时响应
 * （方向锁天然满足：scrollTop > 0 时 canPull=false，滚动让位系统，永不 preventDefault，
 * 与 useSwipe 同一哲学）。
 *
 * 指示器：玻璃圆点 + 旋转 spinner（frost-pulse 同族语言）。状态机
 * idle / pulling / refreshing / done；跟手位移由 framer-motion `useMotionValue`
 * 驱动（不触发 React 重渲染），`prefers-reduced-motion` 下跳过位移动画、直接置位。
 *
 * 手势状态机抽成纯函数 `createPullTracker`（同 useSwipe 的 createSwipeTracker），
 * 单测直接驱动；React 绑定层只负责从 TouchEvent 取坐标 + 驱动 motion value。
 */
import {
  animate,
  motion,
  useMotionValue,
  useReducedMotion,
  useTransform,
} from "framer-motion";
import { useCallback, useMemo, useRef, useState } from "react";
import type { ReactNode, TouchEvent as ReactTouchEvent } from "react";

export type PullStatus = "idle" | "pulling" | "refreshing" | "done";

/** 指示器/刷新停留的展开高度（px） */
const INDICATOR_SPACE = 52;
const REFRESH_OFFSET = 52;
/** 视觉最大下拉位移（阻尼上限） */
const MAX_PULL = 96;
/** 等价 tokens.css --ease-out（framer-motion ease 需 cubic-bezier 元组） */
const EASE_OUT: [number, number, number, number] = [0.22, 0.61, 0.36, 1];

/**
 * 视觉阻尼：手指位移 dy 越大，视觉位移增速越慢（阻尼递增），渐近逼近 maxPull。
 * 阈值判定仍用原始 dy（手指实际拉过 threshold 才触发），视觉位移用阻尼值。
 */
export function dampPull(dy: number, maxPull = MAX_PULL, dampFactor = 90): number {
  if (dy <= 0) return 0;
  return maxPull * (1 - Math.exp(-dy / dampFactor));
}

export interface PullTracker {
  start: (clientY: number) => void;
  move: (clientY: number) => void;
  end: (clientY: number) => void;
  cancel: () => void;
  /** 是否正处于一次下拉跟踪中 */
  isTracking: () => boolean;
  /** 最近一次阻尼后的视觉位移 */
  lastOffset: () => number;
}

interface PullTrackerOptions {
  /** 触发刷新的手指下拉阈值（px） */
  threshold: number;
  /** 滚动容器是否在顶部（允许开始下拉）；返回 false 则不响应 */
  canPull: () => boolean;
  /** 视觉位移变化（调用方驱动 motion value） */
  onOffsetChange: (offset: number) => void;
  /** 松手：shouldRefresh 表示是否达到阈值应触发刷新 */
  onPullEnd: (shouldRefresh: boolean) => void;
  onPullCancel: () => void;
}

export function createPullTracker(opts: PullTrackerOptions): PullTracker {
  const { threshold, canPull, onOffsetChange, onPullEnd, onPullCancel } = opts;
  let startY = 0;
  let tracking = false;
  let offset = 0;

  const setOffset = (v: number) => {
    offset = v;
    onOffsetChange(v);
  };

  return {
    start(clientY) {
      if (!canPull()) return;
      startY = clientY;
      tracking = true;
      setOffset(0);
    },
    move(clientY) {
      if (!tracking) return;
      const dy = clientY - startY;
      if (dy <= 0) {
        setOffset(0);
        return;
      }
      // 已开始下拉但此刻滚动容器不在顶（快速甩动/内容回弹）→ 放弃本次下拉
      if (!canPull()) {
        setOffset(0);
        return;
      }
      setOffset(dampPull(dy));
    },
    end(clientY) {
      if (!tracking) return;
      tracking = false;
      const dy = clientY - startY;
      onPullEnd(dy >= threshold);
    },
    cancel() {
      if (!tracking) return;
      tracking = false;
      onPullCancel();
    },
    isTracking: () => tracking,
    lastOffset: () => offset,
  };
}

export function PullToRefresh({
  onRefresh,
  isAtTop,
  threshold = 64,
  disabled = false,
  className = "",
  children,
}: {
  onRefresh: () => Promise<void> | void;
  /** 滚动容器是否在顶部；缺省视为始终可下拉（调用方应传入真实判定） */
  isAtTop?: () => boolean;
  /** 触发刷新的手指下拉阈值（px） */
  threshold?: number;
  /** 禁用（如非窄屏 / 非列表场景） */
  disabled?: boolean;
  className?: string;
  children: ReactNode;
}) {
  const y = useMotionValue(0);
  const reduced = useReducedMotion() ?? false;
  const indicatorY = useTransform(y, (v) => v - INDICATOR_SPACE);

  const [status, setStatus] = useState<PullStatus>("idle");
  const statusRef = useRef<PullStatus>("idle");
  const refreshingRef = useRef(false);
  const disabledRef = useRef(disabled);
  disabledRef.current = disabled;

  const setStatusBoth = useCallback((s: PullStatus) => {
    statusRef.current = s;
    setStatus(s);
  }, []);

  const animateTo = useCallback(
    (target: number) => {
      if (reduced) {
        y.set(target);
        return;
      }
      animate(y, target, { duration: 0.2, ease: EASE_OUT });
    },
    [reduced, y],
  );

  const reset = useCallback(() => {
    animateTo(0);
    setStatusBoth("idle");
  }, [animateTo, setStatusBoth]);

  const doRefresh = useCallback(async () => {
    if (refreshingRef.current) return;
    refreshingRef.current = true;
    setStatusBoth("refreshing");
    animateTo(REFRESH_OFFSET);
    try {
      await onRefresh();
    } finally {
      refreshingRef.current = false;
      setStatusBoth("done");
      if (reduced) {
        y.set(0);
        setStatusBoth("idle");
      } else {
        // done 短暂停留后收起（让用户看到「已刷新」反馈）
        window.setTimeout(() => {
          animateTo(0);
          setStatusBoth("idle");
        }, 300);
      }
    }
  }, [animateTo, onRefresh, reduced, setStatusBoth, y]);

  // 回调经 ref 转发，tracker 在首次渲染固化（同 useSwipe 模式，无过期闭包）。
  const cbRef = useRef({
    canPull: () => true as boolean,
    onOffsetChange: (_o: number) => {},
    onPullEnd: (_r: boolean) => {},
    onPullCancel: () => {},
  });
  cbRef.current = {
    canPull: () => !disabledRef.current && (isAtTop ? isAtTop() : true),
    onOffsetChange: (offset: number) => {
      y.set(offset);
      if (statusRef.current === "idle") {
        setStatusBoth("pulling");
      }
    },
    onPullEnd: (shouldRefresh: boolean) => {
      if (shouldRefresh) {
        void doRefresh();
      } else {
        reset();
      }
    },
    onPullCancel: () => reset(),
  };

  const tracker = useMemo(
    () =>
      createPullTracker({
        threshold,
        canPull: () => cbRef.current.canPull(),
        onOffsetChange: (o) => cbRef.current.onOffsetChange(o),
        onPullEnd: (r) => cbRef.current.onPullEnd(r),
        onPullCancel: () => cbRef.current.onPullCancel(),
      }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [threshold],
  );

  const onTouchStart = useCallback(
    (e: ReactTouchEvent) => {
      if (refreshingRef.current) return;
      const t = e.touches[0];
      if (t) tracker.start(t.clientY);
    },
    [tracker],
  );

  const onTouchMove = useCallback(
    (e: ReactTouchEvent) => {
      const t = e.touches[0];
      if (t) tracker.move(t.clientY);
    },
    [tracker],
  );

  const onTouchEnd = useCallback(
    (e: ReactTouchEvent) => {
      const t = e.changedTouches[0];
      if (t) tracker.end(t.clientY);
    },
    [tracker],
  );

  const onTouchCancel = useCallback(() => tracker.cancel(), [tracker]);

  return (
    <div
      className={`pull-to-refresh${status !== "idle" ? ` is-${status}` : ""}${className ? ` ${className}` : ""}`}
      onTouchStart={onTouchStart}
      onTouchMove={onTouchMove}
      onTouchEnd={onTouchEnd}
      onTouchCancel={onTouchCancel}
    >
      <motion.div className="pull-refresh-indicator" style={{ y: indicatorY }} aria-hidden="true">
        <span className="pull-refresh-dot">
          {status === "refreshing" ? (
            <span className="pull-refresh-spinner" />
          ) : status === "done" ? (
            <svg className="pull-refresh-check" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
              <path d="M3 8.5l3.2 3.2L13 5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          ) : (
            <svg className="pull-refresh-arrow" viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
              <path d="M3.5 6l4.5 4.5L12.5 6" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          )}
        </span>
      </motion.div>
      <motion.div className="pull-refresh-content" style={{ y }}>
        {children}
      </motion.div>
    </div>
  );
}
