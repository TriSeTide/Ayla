/**
 * useEnterRoomAnimation —— 进直播间/语音房动画（窄屏，R-L2/R-V2）独立封装。
 *
 * 语义（开发文档 §2.2 动画方向纪律）：进房 = 底栏**向下滑走**（滑出视口底部）＋
 * 输入框 `translateY(100%→0)` 滑入（250ms ease-out 延迟 100ms）——与进群动画
 * （底栏上移到顶部）方向相反，**不得共用**。
 *
 * 返回：
 * - inputEntered：输入框（弹幕/房内打字）滑入标志；
 * - 底栏下滑走：由 LiveRoomPage 调 shell store setBottomTabsLeaving 驱动（AppShell 层）。
 *
 * `prefers-reduced-motion` 下直接置 inputEntered。
 */
import { useEffect, useState } from "react";

/**
 * 仅在房间路由真正激活后启动，避免语音大厅预挂载本 hook 时提前完成动画。
 * `active` 可反复切换；每次离房都会复位，下一次进入仍从底部滑入。
 */
export function useEnterRoomAnimation(active = true) {
  const [inputEntered, setInputEntered] = useState(false);

  useEffect(() => {
    if (!active) {
      setInputEntered(false);
      return;
    }
    if (typeof window.matchMedia === "function" && window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      setInputEntered(true);
      return;
    }
    // 输入框延迟 100ms 滑入；每次重进房均重新开始。
    setInputEntered(false);
    const timer = window.setTimeout(() => setInputEntered(true), 100);
    return () => window.clearTimeout(timer);
  }, [active]);

  return { inputEntered };
}
