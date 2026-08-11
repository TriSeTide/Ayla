/**
 * ConversationList：会话列表（文档 §2 components/chat/ConversationList.tsx）。
 *
 * - 私聊展示对方昵称/头像/在线状态；群聊展示群名/公告/成员数；
 * - 未读徽标。
 */
import type { ConversationSummary } from "../../api/types";
import { usePresenceStore } from "../../stores/presence";

export function ConversationList({
  conversations,
  activeId,
  onSelect,
}: {
  conversations: ConversationSummary[];
  activeId: string | null;
  onSelect: (id: string) => void;
}) {
  const onlineUsers = usePresenceStore((s) => s.users);

  if (conversations.length === 0) {
    return <div className="conv-empty">暂无会话，点击右上角发起</div>;
  }

  return (
    <ul className="conversation-list">
      {conversations.map((conv) => {
        const isPrivate = conv.type === "private";
        const peerOnline = conv.peer ? onlineUsers[conv.peer.id] != null : false;
        return (
          <li key={conv.id}>
            <button
              className={`conversation-item ${conv.id === activeId ? "active" : ""}`}
              onClick={() => onSelect(conv.id)}
            >
              <span className={`conv-avatar ${isPrivate ? "private" : "group"}`}>
                {isPrivate
                  ? (conv.peer?.nickname?.[0] ?? conv.peer?.username?.[0] ?? "?")
                  : (conv.title?.[0] ?? "群")}
                {isPrivate && <i className={`presence-dot ${peerOnline ? "online" : ""}`} />}
              </span>
              <span className="conv-main">
                <span className="conv-title">{conv.title || "未命名会话"}</span>
                {conv.type === "group" && conv.announcement && (
                  <span className="conv-announcement">{conv.announcement}</span>
                )}
                {conv.type === "group" && (
                  <span className="conv-meta">{conv.member_count} 人</span>
                )}
              </span>
              {conv.unread_count > 0 && (
                <span className="conv-unread">{conv.unread_count > 99 ? "99+" : conv.unread_count}</span>
              )}
            </button>
          </li>
        );
      })}
    </ul>
  );
}
