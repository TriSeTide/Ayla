/**
 * ConversationList —— 会话列表（私信/群聊共用）。
 *
 * 视觉（design.md §11 示例配方）：玻璃底、左头像带在线光环、
 * 昵称 Nunito 700 15px、预览 13px slate、未读 pink 徽标、选中 ice 胶囊底。
 *
 * M5 会话管理（本页需求）：
 * - 在线状态移入名字行：昵称后跟「在线/离线」小状态（头像光环保留为第二通道）；
 * - 原预览行改为显示最新一条消息摘要（last_message，实时由 WS message.new 刷新）；
 * - 每行右侧「更多」(⋯) 菜单：置顶/取消置顶、删除（软删除，仅隐藏本人列表），
 *   菜单逻辑抽为 ConversationMoreMenu（GroupCard/GroupListItem/ServerRail 共用）。
 */
import type { ConversationSummary } from "../../api/types";
import { useAuthStore } from "../../stores/auth";
import { usePresenceStore } from "../../stores/presence";
import { goUserProfile } from "../../utils/navigation";
import { staggerDelay } from "../../hooks/useRevealOnEnter";
import { Avatar } from "../Avatar";
import { ConversationMoreMenu } from "./ConversationMoreMenu";
import type { CSSProperties } from "react";

/** 非文本消息类型 → 预览占位 */
const TYPE_PLACEHOLDER: Record<string, string> = {
  image: "[图片]",
  voice: "[语音]",
  file: "[文件]",
  emoji: "[表情]",
  video: "[视频]",
  system: "[系统消息]",
};

/** 最新一条消息的列表预览文案 */
function previewLabel(conv: ConversationSummary): string {
  const lm = conv.last_message;
  if (!lm) return "暂无消息";
  let body = "";
  if (lm.status === "recalled") {
    body = "[已撤回]";
  } else {
    // 后端统一生成混排摘要（preview）；旧后端/旧缓存无 preview 时前端兜底
    body = lm.preview || lm.content || TYPE_PLACEHOLDER[lm.type] || "[消息]";
  }
  // 群聊：带发送者名；私聊对端名即会话标题，不再重复
  if (conv.type === "group" && lm.sender_id && lm.sender_name) {
    body = `${lm.sender_name}: ${body}`;
  }
  return body;
}

export function ConversationList({
  conversations,
  activeId,
  elysiaUserId,
  onSelect,
  onError,
  disableAvatarNav = false,
  revealItems = false,
}: {
  conversations: ConversationSummary[];
  activeId: string | null;
  elysiaUserId?: string | null;
  onSelect: (id: string) => void;
  /** 操作失败提示（父组件错误条）；缺省时用 alert 兜底 */
  onError?: (message: string) => void;
  /** 快捷消息栏内：头像不可点（不跳个人主页，R-QM） */
  disableAvatarNav?: boolean;
  /** 列表逐条浮入（stagger，active 接 !loading，方案 §5-A2） */
  revealItems?: boolean;
}) {
  const onlineUsers = usePresenceStore((s) => s.users);
  const currentUserId = useAuthStore((s) => s.currentUser?.id);

  if (conversations.length === 0) {
    return <div className="conv-empty">暂无会话，点击上方「新会话」发起</div>;
  }

  return (
    <ul>
      {conversations.map((conv, idx) => {
        const isPrivate = conv.type === "private";
        const peerOnline = conv.peer ? onlineUsers[conv.peer.id] != null : false;
        const isElysia = elysiaUserId != null && conv.peer?.id === elysiaUserId;
        const title = isPrivate
          ? conv.peer?.nickname || conv.peer?.username || conv.title || "未命名会话"
          : conv.title || "未命名群聊";
        const isOnline = isPrivate && (peerOnline || isElysia);
        const delay = revealItems ? staggerDelay(idx) : 0;
        return (
          <li
            key={conv.id}
            className={`conv-li${revealItems ? " reveal-item" : ""}`}
            style={revealItems ? ({ ["--reveal-delay" as string]: `${delay}ms` } as CSSProperties) : undefined}
          >
            <button
              type="button"
              className={`conv-item ${conv.id === activeId ? "active" : ""} ${conv.is_pinned ? "is-pinned" : ""}`}
              onClick={() => onSelect(conv.id)}
              aria-current={conv.id === activeId ? "true" : undefined}
            >
              <Avatar
                label={title}
                size={40}
                online={isPrivate ? peerOnline || isElysia : false}
                isElysia={isElysia}
                imageUrl={isPrivate ? (conv.peer?.avatar || null) : (conv.avatar || null)}
                onClick={
                  !disableAvatarNav && isPrivate && conv.peer
                    ? (e) => {
                        e.stopPropagation();
                        goUserProfile(currentUserId, conv.peer!.id);
                      }
                    : undefined
                }
                ariaLabel={!disableAvatarNav && isPrivate ? `查看 ${title} 的个人主页` : undefined}
              />
              <span className="conv-item-body">
                <span className="conv-item-title-row">
                  <span className="conv-item-title">{title}</span>
                  {isPrivate && (
                    <span className={`conv-item-status ${isOnline ? "is-online" : ""}`}>
                      {isOnline ? "在线" : "离线"}
                    </span>
                  )}
                </span>
                <span className="conv-item-sub">{previewLabel(conv)}</span>
              </span>
              {conv.unread_count > 0 && (
                <span className="conv-unread" aria-label={`${conv.unread_count} 条未读`}>
                  {conv.unread_count > 99 ? "99+" : conv.unread_count}
                </span>
              )}
            </button>
            <ConversationMoreMenu conversation={conv} onError={onError} />
          </li>
        );
      })}
    </ul>
  );
}
