/**
 * GroupListItem —— 群列表项（窄屏主页列表布局，design.md §12.6，需求 R-H4）。
 *
 * 行高 64px 玻璃底：左群头像 44px（右下状态角标）、中群名 + 消息预览、
 * 右未读徽标 + ⋯ 更多菜单（M5：置顶/删除，复用 ConversationMoreMenu）。
 * 消息预览（最新一条摘要）需后端会话列表补 last_message 字段，
 * 本期契约缺失，preview 为可选（不传则不渲染预览行，显示成员数兜底）。
 * 置顶会话：标题转 grape 色 + 行内小 pin 图标。
 */
import { Avatar } from "../Avatar";
import { ConversationMoreMenu } from "../chat/ConversationMoreMenu";
import { IconPinFilled } from "../icons";
import type { GroupStatus } from "./badges";
import { AvatarStatusBadges } from "./AvatarStatusBadges";
import type { CSSProperties } from "react";

export function GroupListItem({
  group,
  status,
  preview,
  isPinned,
  newEventText,
  onOpen,
  onError,
  revealDelay,
}: {
  group: { id: string; title: string; avatar?: string; memberCount?: number };
  status: GroupStatus;
  /** 最新一条消息摘要；后端未提供时 undefined（显示成员数） */
  preview?: string;
  /** 置顶标识（M5 会话管理） */
  isPinned?: boolean;
  /** 最近"新内容"事件描述（如「小樱：今晚一起吃饭吗」/「阿蓝 创建了语音房 xxx」）；有则 sub 显示 */
  newEventText?: string;
  onOpen: () => void;
  /** 置顶/删除失败提示（父组件错误条）；缺省 alert 兜底 */
  onError?: (message: string) => void;
  /** 逐条浮入延迟（ms）；undefined 则不挂 reveal-item（方案 §5-A2） */
  revealDelay?: number;
}) {
  return (
    <div
      className={`group-list-item-wrap ${isPinned ? "is-pinned" : ""}${revealDelay != null ? " reveal-item" : ""}`}
      style={revealDelay != null ? ({ ["--reveal-delay" as string]: `${revealDelay}ms` } as CSSProperties) : undefined}
    >
      <button type="button" className="group-list-item" onClick={onOpen} aria-label={`进入群聊 ${group.title}`}>
        <span className="group-list-avatar">
          <Avatar label={group.title} size={44} online imageUrl={group.avatar || null} />
          <AvatarStatusBadges status={status} />
        </span>
        <span className="group-list-body">
          <span className="group-list-title">
            {isPinned && <IconPinFilled width={16} height={16} className="group-list-pin-icon" />}
            {group.title}
          </span>
          <span className={`group-list-sub ${newEventText ? "is-new" : ""}`}>
            {preview ?? (newEventText ? newEventText : `${group.memberCount ?? 0} 人`)}
          </span>
        </span>
        {status.unread != null && status.unread > 0 && (
          <span className="group-badge group-badge-unread">
            {status.unread > 99 ? "99+" : status.unread}
          </span>
        )}
      </button>
      <ConversationMoreMenu
        conversation={{ id: group.id, title: group.title, is_pinned: isPinned }}
        showDelete={false}
        onError={onError}
      />
    </div>
  );
}
