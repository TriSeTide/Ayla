/**
 * LiveMiniPlayer —— 手机端 App 内浮动小窗（任务 05：直播适配手机端小窗）。
 *
 * 窄屏离开直播间页面且直播中时出现（live store miniPlayer 非空）：fixed 右下角
 * 迷你播放器，复用 liveSessionRuntime 持有的同一 video 元素（HLS 不断流不黑屏）。
 *
 * 交互：
 * - 点击小窗主体 → 回到直播间大窗（navigate sourceRoute，页面接管后小窗让位）；
 * - 右上关闭按钮 → 完整销毁会话（hls → WS → 轮询 → store → 活动态）；
 *   **按钮位于小窗右上角外侧**，不遮挡直播画面；
 * - 单指拖动（pointer 位移超阈值判定拖动，拖动结束抑制合成 click）；
 * - 双指缩放（pinch）：调整小窗尺寸（保持 16:9，120–320px 宽，右下角锚定）；
 * - 键盘可达：role=button + Enter/Space 打开。
 *
 * 唯一 owner：store miniPlayer 同一时间至多一个（AGENTS.md 工程约束）。
 */
import { useLayoutEffect, useRef, useState } from "react";
import type { PointerEvent as ReactPointerEvent } from "react";
import { useNavigate } from "react-router-dom";
import { IconClose } from "../icons";
import { useLiveStore } from "../../stores/live";
import { liveSessionRuntime } from "../../runtime/liveSessionRuntime";

/** 拖动判定阈值：pointer 位移超过该值视为拖动而非点击（px） */
const DRAG_THRESHOLD = 5;
/** 小窗可拖到的视口边缘最小间距（px），避免被拖出屏幕外 */
const DRAG_MARGIN = 8;
/** 小窗默认尺寸（16:9，design.md §12.7.4） */
const MINI_WIDTH = 168;
const MINI_HEIGHT = 94;
/** 双指缩放范围（宽，px；高按 16:9 跟随） */
const MIN_SCALE_WIDTH = 120;
const MAX_SCALE_WIDTH = 320;

/** 默认位置：右下角（未拖动时） */
function defaultLeft(): number {
  return Math.max(DRAG_MARGIN, window.innerWidth - MINI_WIDTH - DRAG_MARGIN);
}
function defaultTop(): number {
  return Math.max(DRAG_MARGIN, window.innerHeight - MINI_HEIGHT - DRAG_MARGIN);
}

export function LiveMiniPlayer() {
  const navigate = useNavigate();
  const mini = useLiveStore((s) => s.miniPlayer);
  const containerRef = useRef<HTMLDivElement | null>(null);
  // 用户拖动后的绝对位置（px）；null = 未拖动，走 CSS 默认（右下角）
  const [pos, setPos] = useState<{ left: number; top: number } | null>(null);
  // 双指缩放后的尺寸（px）；null = 默认尺寸
  const [size, setSize] = useState<{ w: number; h: number } | null>(null);
  // 拖动会话：active=正在拖动；moved=位移已超阈值（判定为拖动而非点击）
  const dragRef = useRef({
    active: false,
    moved: false,
    startX: 0,
    startY: 0,
    startLeft: 0,
    startTop: 0,
  });
  // 双指缩放会话：初始距离 + 初始尺寸/位置（右下角锚定）
  const pinchRef = useRef<{
    dist: number;
    w: number;
    h: number;
    left: number;
    top: number;
  } | null>(null);
  // 活动 pointer 集合（拖动/缩放共用）
  const pointersRef = useRef(new Map<number, { x: number; y: number }>());
  // 拖动结束后置 true，让随后触发的合成 click 只消费标记、不触发返回直播间
  const suppressClickRef = useRef(false);

  // video 由 runtime 持有：挂载时原子移入小窗容器；卸载时（DOM 移除前）
  // 移交给已挂载的大窗宿主（点回直播间）或移回暂存（防脱离）
  useLayoutEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    liveSessionRuntime.attachVideoTo(container);
    return () => liveSessionRuntime.detachMiniPlayer();
  }, [mini?.channelId]);

  if (!mini) return null;

  const openRoom = () => {
    // 拖动/缩放结束后的合成 click：仅消费抑制标记，不触发返回
    if (suppressClickRef.current) {
      suppressClickRef.current = false;
      return;
    }
    navigate(mini.sourceRoute);
  };

  const close = () => {
    // 完整销毁（含清 miniPlayer → 本组件卸载）；幂等
    liveSessionRuntime.leave();
  };

  // ---- 拖动 + 双指缩放（参考 SessionActivityIndicator 把手拖动模式） ----
  const onPointerDown = (e: ReactPointerEvent<HTMLDivElement>) => {
    // 仅主按键触发（鼠标左键）；触摸/触控笔无 button 概念，直接通过
    if (e.pointerType === "mouse" && e.button !== 0) return;
    // 关闭按钮不启动拖动/缩放（独立点击目标）
    if ((e.target as HTMLElement).closest(".live-mini-player-close")) return;
    const el = e.currentTarget;
    if (typeof el.setPointerCapture === "function") {
      el.setPointerCapture(e.pointerId);
    }
    pointersRef.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pointersRef.current.size === 2) {
      // 第二根手指落下 → 进入双指缩放（取消拖动）
      dragRef.current.active = false;
      const [a, b] = [...pointersRef.current.values()];
      const rect = el.getBoundingClientRect();
      pinchRef.current = {
        dist: Math.hypot(a.x - b.x, a.y - b.y),
        w: rect.width,
        h: rect.height,
        left: rect.left,
        top: rect.top,
      };
      return;
    }
    dragRef.current = {
      active: true,
      moved: false,
      startX: e.clientX,
      startY: e.clientY,
      startLeft: pos?.left ?? defaultLeft(),
      startTop: pos?.top ?? defaultTop(),
    };
  };

  const onPointerMove = (e: ReactPointerEvent<HTMLDivElement>) => {
    if (pointersRef.current.has(e.pointerId)) {
      pointersRef.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
    }
    // 双指缩放：以初始右下角为锚点，保持 16:9，clamp 尺寸范围
    const pinch = pinchRef.current;
    if (pinch && pointersRef.current.size === 2) {
      const [a, b] = [...pointersRef.current.values()];
      const dist = Math.hypot(a.x - b.x, a.y - b.y);
      if (dist <= 0) return;
      const w = Math.min(
        Math.max(pinch.w * (dist / pinch.dist), MIN_SCALE_WIDTH),
        MAX_SCALE_WIDTH,
      );
      const h = Math.round((w * 9) / 16);
      const right = pinch.left + pinch.w;
      const bottom = pinch.top + pinch.h;
      setPos({ left: right - w, top: bottom - h });
      setSize({ w, h });
      return;
    }
    // 单指拖动
    const drag = dragRef.current;
    if (!drag.active) return;
    const dx = e.clientX - drag.startX;
    const dy = e.clientY - drag.startY;
    // 未超阈值前不判定为拖动，也不移动（保留点击语义）
    if (!drag.moved && Math.abs(dx) < DRAG_THRESHOLD && Math.abs(dy) < DRAG_THRESHOLD) {
      return;
    }
    drag.moved = true;
    const w = size?.w ?? MINI_WIDTH;
    const h = size?.h ?? MINI_HEIGHT;
    const maxLeft = Math.max(DRAG_MARGIN, window.innerWidth - w - DRAG_MARGIN);
    const maxTop = Math.max(DRAG_MARGIN, window.innerHeight - h - DRAG_MARGIN);
    setPos({
      left: Math.min(Math.max(drag.startLeft + dx, DRAG_MARGIN), maxLeft),
      top: Math.min(Math.max(drag.startTop + dy, DRAG_MARGIN), maxTop),
    });
  };

  const onPointerUp = (e: ReactPointerEvent<HTMLDivElement>) => {
    pointersRef.current.delete(e.pointerId);
    if (pointersRef.current.size < 2) {
      pinchRef.current = null;
    }
    const drag = dragRef.current;
    if (!drag.active) return;
    drag.active = false;
    // 若本次是拖动（位移超阈值），抑制随后的合成 click，避免误触返回直播间
    suppressClickRef.current = drag.moved;
    if (typeof e.currentTarget.releasePointerCapture === "function") {
      e.currentTarget.releasePointerCapture(e.pointerId);
    }
  };

  return (
    <div
      className="live-mini-player"
      role="button"
      tabIndex={0}
      aria-label="返回直播间"
      title={mini.channel?.title ?? "直播间"}
      onClick={openRoom}
      onKeyDown={(e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          openRoom();
        }
      }}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      onPointerCancel={onPointerUp}
      style={{
        ...(pos ? { left: pos.left, top: pos.top } : {}),
        ...(size ? { width: size.w, height: size.h } : {}),
      }}
    >
      {/* 视频容器：圆角裁剪由内层负责，外层不 overflow:hidden 以便关闭按钮突出在外 */}
      <div className="live-mini-player-video-wrap" ref={containerRef} />
      <button
        type="button"
        className="live-mini-player-close"
        aria-label="关闭小窗"
        title="关闭小窗"
        onClick={(e) => {
          e.stopPropagation();
          close();
        }}
      >
        <IconClose width={14} height={14} />
      </button>
    </div>
  );
}
