/**
 * usePagerTouchRouter —— 直播间上下滑的触摸路由器（视频区/弹幕区分治）。
 *
 * 背景（2026-08-26 弹幕区手势需求）：`.live-room-swipe` 此前由 framer-motion
 * drag="y" 整块接管并设 inline `touch-action: pan-x`，导致触点链交集后浏览器
 * **禁止在弹幕列表垂直滚动**——划弹幕区只会整体切台，列表永远滚不动。
 *
 * 本路由器把竖向触摸按起手区域与列表滚动状态分流：
 * - 视频区起手 → 直接交给 drag（跟手切台）；
 * - 弹幕区起手 → 列表在该方向还能滚（未到底/顶）→ 放行给浏览器滚动；
 *   已到底仍上拉 / 已到顶仍下拉 → 接力交给 drag（继续划切下一个/上一个直播间）。
 *
 * 实现要点：
 * - 容器 motion.div 必须 `dragListener={false}` + 显式 `style={{touchAction:"pan-y"}}`
 *   （framer-motion 仅在 dragListener!==false 时自动写 touchAction，见
 *   render/html/use-props.mjs；pan-y 让浏览器获得弹幕列表的垂直滚动权）；
 * - 监听必须 non-passive（React 合成 onTouchMove 为 passive 委托，无法 preventDefault）；
 * - slop(8px) 定轴要求主轴明显占优；横轴手势直接放弃（水平让位）；
 * - dragControls.start 需 PointerEvent 形状（framer-motion extractEventInfo 只读
 *   pageX/pageY），从 Touch 合成最小兼容对象；
 * - 一旦放行浏览器滚动，本次触摸不再接力（iOS 同款：第二次拖动才触发父级），
 *   避免「惯性滚到底手指还压着」造成误切；
 * - drag 启动后持续 preventDefault 压制浏览器，直至松手。
 */
import { useEffect } from "react";
import type { DragControls } from "framer-motion";
import type { RefObject } from "react";

/** 定轴起步位移（px）：主轴位移达到该值且占优才判定 */
export const PAGER_AXIS_SLOP = 8;

/** 触摸路由结果：drag=交给 framer-motion 跟手切台、scroll=放行浏览器滚列表、idle=继续观察 */
export type PagerRoute = "drag" | "scroll" | "idle";

/**
 * 路由判定（纯函数，供单测）。
 *
 * @param dy 竖向净位移（下正上负）；dx 同理
 * @param startInDanmaku 起手点是否落在弹幕区
 * @param canScrollUp 列表当前能否向上滚（scrollTop > 边界ε）
 * @param canScrollDown 列表当前能否向下滚（未到底）
 */
export function decidePagerRoute(
  dx: number,
  dy: number,
  startInDanmaku: boolean,
  canScrollUp: boolean,
  canScrollDown: boolean,
  slop: number = PAGER_AXIS_SLOP,
): PagerRoute {
  // 未达 slop：继续观察
  if (Math.abs(dy) < slop) return "idle";
  // 主轴不明显占优（横向意图）：放弃，不做任何路由（水平让位）
  if (Math.abs(dx) >= Math.abs(dy)) return "idle";
  if (!startInDanmaku) return "drag"; // 视频区：直接跟手切台
  // 弹幕区：手势方向上列表还能滚 → 先滚
  if (dy < 0 && canScrollDown) return "scroll"; // 上拉且未到底 → 滚动
  if (dy > 0 && canScrollUp) return "scroll"; // 下拉且未到顶 → 滚动
  return "drag"; // 到底/顶后的继续同向拉动 → 接力切台
}

/** 由列表元素计算两个方向的滚动余量（纯函数，供单测） */
export function listScrollState(
  scrollTop: number,
  scrollHeight: number,
  clientHeight: number,
  epsilon: number = 2,
): { canScrollUp: boolean; canScrollDown: boolean } {
  const maxScroll = Math.max(scrollHeight - clientHeight, 0);
  return {
    canScrollUp: scrollTop > epsilon,
    canScrollDown: scrollTop < maxScroll - epsilon,
  };
}

interface PagerTouchRouterOptions {
  /** 滑动容器（.live-room-swipe），监听挂在其上 */
  containerRef: RefObject<HTMLElement | null>;
  /** 当前弹幕列表元素获取器（present 实例的 .danmaku-list） */
  getListEl: () => HTMLElement | null;
  /** framer-motion 手动 drag 控制器 */
  controls: DragControls;
  /** 是否启用（窄屏沉浸式 + 非 reduced-motion 才启用） */
  enabled: boolean;
}

/** 从 Touch 合成 framer-motion 可用的最小 PointerEvent 形状（extractEventInfo 只读 pageX/pageY） */
function toSyntheticPointer(t: Touch): PointerEvent {
  return {
    pageX: t.pageX,
    pageY: t.pageY,
    clientX: t.clientX,
    clientY: t.clientY,
    pointerId: t.identifier,
    isPrimary: true,
    type: "pointerdown",
  } as unknown as PointerEvent;
}

export function usePagerTouchRouter({
  containerRef,
  getListEl,
  controls,
  enabled,
}: PagerTouchRouterOptions): void {
  useEffect(() => {
    const el = containerRef.current;
    if (!el || !enabled) return;

    let startX = 0;
    let startY = 0;
    let startInDanmaku = false;
    /** null=未定轴；false=已放弃（横轴/放行）；true=drag 已接管 */
    let decided: boolean | null = null;
    let started = false;

    const onStart = (e: TouchEvent) => {
      const t = e.touches[0];
      if (!t) return;
      startX = t.clientX;
      startY = t.clientY;
      startInDanmaku = e.target instanceof Element && !!e.target.closest(".danmaku-wrap");
      decided = null;
      started = false;
    };

    const onMove = (e: TouchEvent) => {
      if (started) {
        // drag 已接管：持续压制浏览器手势直至松手
        e.preventDefault();
        return;
      }
      if (decided !== null) return; // 已放弃或已放行
      const t = e.touches[0];
      if (!t) return;
      const dy = t.clientY - startY;
      const dx = t.clientX - startX;
      const listEl = getListEl();
      const state = listEl
        ? listScrollState(listEl.scrollTop, listEl.scrollHeight, listEl.clientHeight)
        : { canScrollUp: false, canScrollDown: false };
      const route = decidePagerRoute(dx, dy, startInDanmaku, state.canScrollUp, state.canScrollDown);
      if (route === "idle") return;
      decided = route !== "scroll";
      if (route === "drag") {
        e.preventDefault(); // 压制浏览器滚动（pan-y 下必须显式拦）
        controls.start(toSyntheticPointer(t));
        started = true;
      }
      // route === "scroll"：放行，本次触摸不再干预
    };

    const onEnd = () => {
      decided = null;
      started = false;
    };

    el.addEventListener("touchstart", onStart, { passive: true });
    el.addEventListener("touchmove", onMove, { passive: false });
    el.addEventListener("touchend", onEnd, { passive: true });
    el.addEventListener("touchcancel", onEnd, { passive: true });
    return () => {
      el.removeEventListener("touchstart", onStart);
      el.removeEventListener("touchmove", onMove);
      el.removeEventListener("touchend", onEnd);
      el.removeEventListener("touchcancel", onEnd);
    };
  }, [containerRef, getListEl, controls, enabled]);
}
