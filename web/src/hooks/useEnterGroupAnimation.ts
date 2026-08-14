/**
 * useEnterGroupAnimation —— 进群动画（窄屏，R-G1）独立封装。
 *
 * 语义（开发文档 §2.2 动画方向纪律）：底栏**整体上移到视口顶部**（不是滑出底部）；
 * 本 hook 只提供"上移"的进入态标志，导航条样式据此从底部 translateY 到顶部
 * （250ms ease-out），与进直播间/语音房动画（F4 底栏下滑走）方向相反，不得共用。
 *
 * 返回：
 * - entered：是否已进入（false = 还停在底部位置，触发过渡到顶部）；
 * - inputEntered：输入框滑入标志（250ms 延迟 100ms，R-G1 时序）。
 *
 * `prefers-reduced-motion` 下直接置 entered（跳过位移，保留透明度渐变）。
 */
import { useEffect, useState } from "react";

export function useEnterGroupAnimation() {
  const [entered, setEntered] = useState(false);
  const [inputEntered, setInputEntered] = useState(false);

  useEffect(() => {
    // reduced-motion：跳过位移动画
    if (typeof window.matchMedia === "function" && window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      setEntered(true);
      setInputEntered(true);
      return;
    }
    // 双 rAF 确保首帧以"底部位置"渲染后再触发过渡
    let raf2 = 0;
    const raf1 = requestAnimationFrame(() => {
      raf2 = requestAnimationFrame(() => setEntered(true));
    });
    // 输入框延迟 100ms 滑入（R-G1）
    const inputTimer = window.setTimeout(() => setInputEntered(true), 100);
    return () => {
      cancelAnimationFrame(raf1);
      cancelAnimationFrame(raf2);
      window.clearTimeout(inputTimer);
    };
  }, []);

  return { entered, inputEntered };
}
