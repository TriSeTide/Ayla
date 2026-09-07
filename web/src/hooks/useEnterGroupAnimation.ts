/**
 * useEnterGroupAnimation —— 进群动画（窄屏，R-G1）独立封装。
 *
 * 导航条从原底栏位置连续升至顶部，输入区由自身的底部面板动画负责。
 * 本 hook 保留双 rAF 的进入态，导航用独立 translate 300ms ease-out，始终可见；
 * 手势跟手与手势退场仍由 GroupPage 的 transform 单独拥有。
 *
 * 返回：
 * - entered：是否已触发导航从底栏位置上移；
 * - inputEntered：兼容旧调用者的输入就绪标志；当前 GroupChat 自己持有面板动画。
 *
 * `prefers-reduced-motion` 下直接置 entered，在顶部呈现最终状态。
 */
import { useEffect, useState } from "react";
import { usePrefersReducedMotion } from "./usePrefersReducedMotion";

export function useEnterGroupAnimation() {
  const reduced = usePrefersReducedMotion();
  const [entered, setEntered] = useState(reduced);
  const [inputEntered, setInputEntered] = useState(reduced);

  useEffect(() => {
    // reduced-motion：跳过位移动画
    if (reduced) {
      setEntered(true);
      setInputEntered(true);
      return;
    }
    // 双 rAF 确保首帧在原底栏位置可见后，再触发上移过渡。
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
  }, [reduced]);

  return { entered, inputEntered };
}
