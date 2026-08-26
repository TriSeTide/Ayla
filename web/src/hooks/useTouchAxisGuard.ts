/**
 * useTouchAxisGuard —— 触摸轴竞速守卫（配合 framer-motion drag 使用）。
 *
 * 背景（2026-08-26 二次修复）：framer-motion drag="x" 自动给容器设
 * `touch-action: pan-y`（把垂直让给浏览器滚动）。真机上人手横滑起步必然带
 * 十余 px 的垂直抖动，起步窗口内浏览器先判定为「垂直滚动意图」→ 接管手势并
 * 发 pointercancel → framer-motion session 提前结束 → 横滑既不跟手也无法松手
 * 判定。竖向 drag="y"（touch-action: pan-x）不受此影响，因此直播间上下滑正常、
 * 两处横向 pager 全灭。
 *
 * 本守卫在 drag 容器上挂 non-passive touchstart/touchmove：起步 slop 内按
 * 「主轴占优」定轴，若与 drag 轴一致则对后续 touchmove 持续 preventDefault，
 * 阻止浏览器启动滚动（pointer 事件流保持完整，drag 正常跟手到松手）；交叉轴
 * 占优则完全不拦，浏览器正常滚动（随后 pointercancel 由调用方的松手判定过滤
 * 为回弹）。等价 iOS UIScrollView 单一手势识别器的方向锁语义。
 *
 * 注意：
 * - 必须 non-passive（React 合成 onTouchMove 是 passive 委托，无法 preventDefault）；
 * - slop(6px) 必须小于浏览器手势 slop（约 8–10px），否则竞速必败；
 * - 仅需用于横向 drag（axis="x"）；纵向 drag="y" 的 pan-x 不会被竖滑触发，无需挂载。
 */
import { useEffect } from "react";
import type { RefObject } from "react";

/** 定轴起步位移（px）：小于浏览器手势 slop，保证抢在浏览器接管前定轴 */
export const AXIS_GUARD_SLOP = 6;

/**
 * 守卫判定（纯函数，供单测）：给定当前累计位移与受保护轴，
 * 返回是否应当 preventDefault（true=本手势归 JS drag 管，拦下浏览器）。
 * 返回 null 表示尚未达 slop、暂不定轴。
 */
export function decideAxisPreventDefault(
  dx: number,
  dy: number,
  axis: "x" | "y",
  slop: number = AXIS_GUARD_SLOP,
): boolean | null {
  const adx = Math.abs(dx);
  const ady = Math.abs(dy);
  if (Math.max(adx, ady) < slop) return null;
  const dominant: "x" | "y" = adx >= ady ? "x" : "y";
  return dominant === axis;
}

/**
 * 挂载到 drag 容器（或其祖先）的触摸轴守卫。
 * @param ref 容器 ref（touch 事件冒泡，可挂 drag 元素的任一祖先）
 * @param axis 受保护的 drag 轴："x"（横向 pager）/ "y"
 */
export function useTouchAxisGuard(
  ref: RefObject<HTMLElement | null>,
  axis: "x" | "y",
): void {
  useEffect(() => {
    const el = ref.current;
    if (!el) return;

    let startX = 0;
    let startY = 0;
    /** null=未定轴；true/false=本手势已判定是否属于 drag 轴 */
    let decision: boolean | null = null;

    const onStart = (e: TouchEvent) => {
      const t = e.touches[0];
      if (!t) return;
      startX = t.clientX;
      startY = t.clientY;
      decision = null;
    };

    const onMove = (e: TouchEvent) => {
      if (decision === false) return; // 已让位给浏览器滚动，不再干预
      const t = e.touches[0];
      if (!t) return;
      if (decision === null) {
        const result = decideAxisPreventDefault(
          t.clientX - startX,
          t.clientY - startY,
          axis,
        );
        if (result === null) return; // 未达 slop，继续观察
        decision = result;
        if (!decision) return; // 交叉轴手势：让位，浏览器接管滚动
      }
      // 已判定为本轴手势：持续压制浏览器滚动直至松手
      e.preventDefault();
    };

    const onEnd = () => {
      decision = null;
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
  }, [ref, axis]);
}
