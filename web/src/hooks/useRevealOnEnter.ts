/**
 * useRevealOnEnter —— 统一内容入场动画原语（design.md §7 浮入）。
 *
 * 直播间/语音房/帖子详情/列表等所有异步界面共用的进场动画 hook。
 * 语义：首次挂载后进入两步（双 rAF 确保首帧以隐藏态渲染，再触发过渡到显示），
 * 或 `active` 变为 true 后重新开始；`step` 供调用方映射为 `.reveal.is-in`。
 *
 * 与 `useEnterRoomAnimation`（底栏/输入框位移）不同：本 hook 只管**内容块本身**
 * 的浮入淡入（translateY 8px + opacity），是让"主体内容温和显现"的统一节奏。
 *
 * `prefers-reduced-motion` 下直接置 step=1（跳过位移，保留透明度渐变）。
 */
import { useEffect, useState } from "react";

export function useRevealOnEnter(active = true) {
  const [step, setStep] = useState(0);

  useEffect(() => {
    if (!active) {
      setStep(0);
      return;
    }
    if (
      typeof window.matchMedia === "function" &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches
    ) {
      setStep(1);
      return;
    }
    let raf2 = 0;
    setStep(0);
    const raf1 = requestAnimationFrame(() => {
      raf2 = requestAnimationFrame(() => setStep(1));
    });
    return () => {
      cancelAnimationFrame(raf1);
      cancelAnimationFrame(raf2);
    };
  }, [active]);

  return { step, revealed: step === 1 };
}

/**
 * 给一组子项生成 stagger 延迟（每项 +gap 毫秒，总在 cap 内），
 * 用于评论/列表逐条浮现的节奏（与直播间浮入一致，控制在 300ms 内）。
 */
export function staggerDelay(index: number, gap = 40, cap = 300): number {
  return Math.min(index * gap, cap);
}
