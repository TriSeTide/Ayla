/**
 * ServerRail —— 宽屏服务器栏（design.md §12.3，布局文档 §3.2）。
 *
 * 72px 玻璃列：纵向我的群头像（48px 圆形带光环 + 状态角标），点击切换当前群；
 * 当前群左侧 3px --glow-500 指示条 + 头像微放大；底部用户卡（头像 + 在线点，进个人页）。
 *
 * F3 只落地切换群 + 未读角标（数据已有）；直播/语音/桌游角标随 F4/F5/F7 接入。
 */
import { Link } from "react-router-dom";
import { Avatar } from "../components/Avatar";
import { useAuthStore } from "../stores/auth";
import type { ConversationSummary } from "../api/types";

export function ServerRail({
  groups,
  currentGroupId,
  onSelectGroup,
}: {
  groups: ConversationSummary[];
  currentGroupId: string | null;
  onSelectGroup: (id: string) => void;
}) {
  const currentUser = useAuthStore((s) => s.currentUser);

  return (
    <nav className="server-rail" aria-label="我的群">
      <ul className="server-rail-list">
        {groups.map((g) => (
          <li key={g.id} className={`server-item ${g.id === currentGroupId ? "is-active" : ""}`}>
            <button
              type="button"
              className="server-item-btn"
              onClick={() => onSelectGroup(g.id)}
              aria-label={`切换到群聊 ${g.title}`}
              aria-current={g.id === currentGroupId ? "true" : undefined}
            >
              <span className="server-item-avatar">
                <Avatar label={g.title} size={48} online />
                {g.unread_count > 0 && (
                  <span className="server-item-badge">{g.unread_count > 99 ? "99+" : g.unread_count}</span>
                )}
              </span>
            </button>
          </li>
        ))}
      </ul>
      <div className="server-rail-foot">
        {currentUser && (
          <Link to="/profile" className="server-user" aria-label="打开个人页">
            <Avatar
              label={currentUser.nickname || currentUser.username}
              size={40}
              online={currentUser.online}
              imageUrl={currentUser.avatar || null}
            />
            <span className="server-user-dot" aria-hidden="true" />
          </Link>
        )}
      </div>
    </nav>
  );
}
