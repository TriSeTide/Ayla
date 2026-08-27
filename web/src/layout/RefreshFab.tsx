/**
 * RefreshFab —— 右下角「刷新当前页」44px 玻璃圆钮（方案 §3.4 / design.md §12.5）。
 *
 * - 复用 PullToRefresh 的刷新通道：各列表页（主页/消息中心/直播）在 mount 时通过
 *   shell store 的 registerRefresh 注册自己的刷新回调，本组件点击时读取并调用。
 * - 无回调（非列表页）时点击无操作（保持纯外观与位置职责，刷新语义由页面提供）。
 * - 刷新期间图标旋转（复用 §3.3 spinner 同族语言），reduced-motion 关闭旋转。
 */
import { useState } from "react";
import { useShellStore } from "../stores/shell";
import { IconRetry } from "../components/icons";

export function RefreshFab({ position = "corner" }: { position?: "corner" | "bottom-left" }) {
  const [spinning, setSpinning] = useState(false);

  const handleClick = async () => {
    const fn = useShellStore.getState().refreshCallback;
    if (!fn) return;
    setSpinning(true);
    try {
      await fn();
    } finally {
      setSpinning(false);
    }
  };

  return (
    <button
      type="button"
      className={`corner-fab corner-fab-refresh${position === "bottom-left" ? " is-bottom-left" : ""}${spinning ? " is-spinning" : ""}`}
      onClick={() => void handleClick()}
      aria-label="刷新当前页"
    >
      <span className="corner-fab-icon">
        <IconRetry width={20} height={20} />
      </span>
    </button>
  );
}
