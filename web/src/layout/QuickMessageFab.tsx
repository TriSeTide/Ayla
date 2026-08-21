/**
 * QuickMessageFab —— 红点快捷消息按钮（R-QM，窄屏非导航页左下角）。
 *
 * 与 MessageFAB 同外观（复用 .message-fab），但点击**不跳 /messages**，
 * 而是通过 shell store 打开 QuickMessagesSheet（底部 70% 快捷消息栏）。
 *
 * 快捷消息栏的开关存在 shell store（不存本组件）：红点归零会卸载本按钮，
 * 但快捷栏由 AppShell 独立渲染、只随手动关闭（R-QM bug 修复）。
 *
 * 半贴交互：出现后若 4s 内不点击，则侧边半贴左侧屏幕（translateX(-44px)，
 * 仅露 28px 右半）；半贴态点击「点出来」展开，展开态点击打开快捷消息栏。
 * reduced-motion 下关闭位移动画（保留功能）。
 */
import { useEffect, useState } from "react";
import { IconMessage } from "../components/icons";
import { useShellStore } from "../stores/shell";

/** 展开后无交互自动半贴的等待时长 */
const COLLAPSE_DELAY_MS = 4000;

export function QuickMessageFab({ unread = 0 }: { unread?: number }) {
  /** true = 半贴（侧边只露半截）；false = 完整展开 */
  const [collapsed, setCollapsed] = useState(false);
  const quickMessagesOpen = useShellStore((s) => s.quickMessagesOpen);
  const setQuickMessagesOpen = useShellStore((s) => s.setQuickMessagesOpen);

  // 展开态停留超过 COLLAPSE_DELAY_MS 无点击 → 半贴；半贴/快捷栏打开态不启动计时
  useEffect(() => {
    if (quickMessagesOpen || collapsed) return;
    const timer = setTimeout(() => setCollapsed(true), COLLAPSE_DELAY_MS);
    return () => clearTimeout(timer);
  }, [collapsed, quickMessagesOpen]);

  // 半贴态点击 → 点出来（展开）；展开态点击 → 打开快捷消息栏
  const handleClick = () => {
    if (collapsed) {
      setCollapsed(false);
    } else {
      setQuickMessagesOpen(true);
    }
  };

  return (
    <button
      type="button"
      className={`message-fab quick-message-fab ${collapsed ? "is-collapsed" : ""}`}
      aria-label={collapsed ? "展开消息" : unread > 0 ? `消息，${unread} 条未读` : "消息"}
      onClick={handleClick}
    >
      <IconMessage width={24} height={24} />
      {unread > 0 && <span className="tab-badge">{unread > 99 ? "99+" : unread}</span>}
    </button>
  );
}
