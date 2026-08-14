/**
 * MessageFAB —— 窄屏左下消息入口（design.md §12.5）。
 *
 * 56px 圆形玻璃底 + 消息线性图标；未读聚合徽标 --pink-500 右上角。
 * unread prop 为 F8 全站未读聚合（me/badges）预留，F1 恒 0 不渲染徽标。
 * 宽屏等效入口为 TopNav 消息项（布局文档 §4）。
 */
import { useNavigate } from "react-router-dom";
import { IconMessage } from "../components/icons";

export function MessageFab({ unread = 0 }: { unread?: number }) {
  const navigate = useNavigate();
  return (
    <button
      type="button"
      className="message-fab"
      aria-label={unread > 0 ? `消息，${unread} 条未读` : "消息"}
      onClick={() => navigate("/messages")}
    >
      <IconMessage width={24} height={24} />
      {unread > 0 && (
        <span className="tab-badge">{unread > 99 ? "99+" : unread}</span>
      )}
    </button>
  );
}
