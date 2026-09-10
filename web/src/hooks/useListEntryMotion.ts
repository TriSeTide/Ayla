import { useLayoutEffect, useRef, type RefObject } from "react";
import { AURORAQUA_MOTION } from "../components/motion/auroraquaMotion";
import { staggerDelay } from "./useRevealOnEnter";
import { usePrefersReducedMotion } from "./usePrefersReducedMotion";

/**
 * Reveal only DOM items newly committed in this batch; existing items never restart.
 *
 * `replayKey`（可选）：变化时对**已入场**的节点重播一次浮入（刷新反馈），不重挂 DOM、
 * 不动 seen——保留滚动位置/焦点，新增节点仍由主 effect 单独入场，避免重复播放。
 *
 * 抑制语义（2026-09-09 修正）：
 * - `suppressed`（滚动恢复命中历史位置的抑制期）只阻止**启动新的入场动画**；
 * - **刷新重播不受 suppressed 影响**：restoring 在切换分类选项卡后会持续为真
 *   （onChange 会写入当前位置记录），若用它抑制重播，切 tab 后手动刷新/自动刷新
 *   将永远没有动画；
 * - 已开始的动画也不因 suppressed 被取消（中途取消会让刷新动画卡在半途）；
 *   只有 `prefers-reduced-motion` 与节点断开才取消/阻止动画。
 */
export function useListEntryMotion<T extends HTMLElement>(
  root: RefObject<T | null>,
  selector: string,
  suppressed = false,
  replayKey?: unknown,
) {
  const seen = useRef(new WeakSet<HTMLElement>());
  const running = useRef(new Map<HTMLElement, Animation>());
  const reduced = usePrefersReducedMotion();
  const lastReplayKey = useRef(replayKey);

  // replayKey 变化：已入场的卡片整批重播（刷新后第一页也有动画）。声明在主 effect
  // 之前：先重播保留节点，主 effect 随后只让本批新增节点入场，互不重复。
  // 只有 prefers-reduced-motion 关闭重播，suppressed 不参与（见上方抑制语义）。
  useLayoutEffect(() => {
    if (lastReplayKey.current === replayKey) return;
    lastReplayKey.current = replayKey;
    if (reduced) return;
    let index = 0;
    for (const node of root.current?.querySelectorAll<HTMLElement>(selector) ?? []) {
      if (!seen.current.has(node) || typeof node.animate !== "function") continue;
      running.current.get(node)?.cancel();
      const animation = node.animate(
        [
          { opacity: 0, transform: `translateY(${AURORAQUA_MOTION.distance}px)` },
          { opacity: 1, transform: "translateY(0)" },
        ],
        { duration: 300, delay: staggerDelay(index++), easing: "ease-out", fill: "backwards" },
      );
      running.current.set(node, animation);
      animation.onfinish = () => {
        running.current.delete(node);
        animation.cancel();
      };
    }
  }, [replayKey]);

  // Run after every commit: async pages, masonry columns and WS additions share the
  // same boundary. No loading flag can remove/re-add animation on retained cards.
  useLayoutEffect(() => {
    // 只清理 reduced-motion 与已断开节点；不因 suppressed 取消已开始的动画
    // （刷新重播可能在 suppressed 期间启动，中途取消会让动画卡住）。
    for (const [node, animation] of running.current) {
      if (reduced || !node.isConnected) {
        animation.cancel();
        running.current.delete(node);
      }
    }
    let index = 0;
    for (const node of root.current?.querySelectorAll<HTMLElement>(selector) ?? []) {
      if (seen.current.has(node)) continue;
      seen.current.add(node);
      // 恢复滚动位置期间仍直接显示（不启动入场动画）——这是 suppressed 的唯一作用。
      if (reduced || suppressed || typeof node.animate !== "function") continue;
      const animation = node.animate(
        [
          { opacity: 0, transform: `translateY(${AURORAQUA_MOTION.distance}px)` },
          { opacity: 1, transform: "translateY(0)" },
        ],
        { duration: 300, delay: staggerDelay(index++), easing: "ease-out", fill: "backwards" },
      );
      running.current.set(node, animation);
      animation.onfinish = () => {
        running.current.delete(node);
        animation.cancel();
      };
    }
  });

  useLayoutEffect(() => () => {
    for (const animation of running.current.values()) animation.cancel();
    running.current.clear();
    seen.current = new WeakSet<HTMLElement>();
  }, []);
}
