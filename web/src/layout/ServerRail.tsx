/**
 * ServerRail —— 宽屏服务器栏（design.md §12.3，布局文档 §3.2）。
 *
 * 72px 玻璃列：纵向我的群头像（48px 圆形带光环 + 状态角标），点击切换当前群；
 * 当前群左侧 3px --glow-500 指示条 + 头像微放大；底部「创建群聊」加号按钮
 * （需求：原左下角头像键改加号，点击 onCreateGroup 打开建群对话框）。
 *
 * F3 只落地切换群 + 未读角标（数据已有）；直播/语音/桌游角标随 F4/F5/F7 接入。
 */
import { Avatar } from "../components/Avatar";
import { IconPlus } from "../components/icons";
import type { ConversationSummary } from "../api/types";

export function ServerRail({
  groups,
  currentGroupId,
  onSelectGroup,
  onCreateGroup,
}: {
  groups: ConversationSummary[];
  currentGroupId: string | null;
  onSelectGroup: (id: string) => void;
  /** 底部加号：创建群聊（打开建群对话框） */
  onCreateGroup: () => void;
}) {
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
                <Avatar label={g.title} size={48} online imageUrl={g.avatar || null} />
                {g.unread_count > 0 && (
                  <span className="server-item-badge">{g.unread_count > 99 ? "99+" : g.unread_count}</span>
                )}
              </span>
            </button>
          </li>
        ))}
      </ul>
      <div className="server-rail-foot">
        <button
          type="button"
          className="server-create-btn"
          onClick={onCreateGroup}
          aria-label="创建群聊"
          title="创建群聊"
        >
          <IconPlus width={22} height={22} />
        </button>
      </div>
    </nav>
  );
}
