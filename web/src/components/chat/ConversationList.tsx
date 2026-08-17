/**
 * ConversationList —— 会话列表。
 *
 * 视觉（design.md §11 示例配方）：玻璃底、左头像带在线光环、
 * 昵称 Nunito 700 15px、预览 13px slate、未读 pink 徽标、选中 ice 胶囊底。
 * 在线状态双通道：光环 + 「在线/离线」文字（design.md §10）。
 */
import type { ConversationSummary } from "../../api/types";
import { usePresenceStore } from "../../stores/presence";
import { Avatar } from "../Avatar";

export function ConversationList({
  conversations,
  activeId,
  elysiaUserId,
  onSelect,
}: {
  conversations: ConversationSummary[];
  activeId: string | null;
  elysiaUserId?: string | null;
  onSelect: (id: string) => void;
}) {
  const onlineUsers = usePresenceStore((s) => s.users);

  if (conversations.length === 0) {
    return <div className="conv-empty">暂无会话，点击上方「新会话」发起</div>;
  }

  return (
    <ul>
      {conversations.map((conv) => {
        const isPrivate = conv.type === "private";
        const peerOnline = conv.peer ? onlineUsers[conv.peer.id] != null : false;
        const isElysia = elysiaUserId != null && conv.peer?.id === elysiaUserId;
        const title = isPrivate
          ? conv.peer?.nickname || conv.peer?.username || conv.title || "未命名会话"
          : conv.title || "未命名群聊";
        const sub = isPrivate
          ? isElysia
            ? "爱莉 · 数字生命"
            : peerOnline
              ? "在线"
              : "离线"
          : conv.announcement || `${conv.member_count} 人`;
        return (
          <li key={conv.id}>
            <button
              type="button"
              className={`conv-item ${conv.id === activeId ? "active" : ""}`}
              onClick={() => onSelect(conv.id)}
              aria-current={conv.id === activeId ? "true" : undefined}
            >
              <Avatar
                label={title}
                size={40}
                online={isPrivate ? peerOnline || isElysia : false}
                isElysia={isElysia}
                imageUrl={isPrivate ? (conv.peer?.avatar || null) : (conv.avatar || null)}
              />
              <span className="conv-item-body">
                <span className="conv-item-title">{title}</span>
                <span className="conv-item-sub">{sub}</span>
              </span>
              {conv.unread_count > 0 && (
                <span className="conv-unread" aria-label={`${conv.unread_count} 条未读`}>
                  {conv.unread_count > 99 ? "99+" : conv.unread_count}
                </span>
              )}
            </button>
          </li>
        );
      })}
    </ul>
  );
}
