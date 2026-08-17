/**
 * GroupListItem —— 群列表项（窄屏主页列表布局，design.md §12.6，需求 R-H4）。
 *
 * 行高 64px 玻璃底：左群头像 44px（右下状态角标）、中群名 + 消息预览、
 * 右未读徽标。消息预览（最新一条摘要）需后端会话列表补 last_message 字段，
 * 本期契约缺失，preview 为可选（不传则不渲染预览行，显示成员数兜底）。
 */
import { Avatar } from "../Avatar";
import type { GroupStatus } from "./badges";
import { badgeIcon, resolveBadges } from "./badges";

export function GroupListItem({
  group,
  status,
  preview,
  onOpen,
}: {
  group: { id: string; title: string; avatar?: string; memberCount?: number };
  status: GroupStatus;
  /** 最新一条消息摘要；后端未提供时 undefined（显示成员数） */
  preview?: string;
  onOpen: () => void;
}) {
  const badges = resolveBadges(status);

  return (
    <button type="button" className="group-list-item" onClick={onOpen} aria-label={`进入群聊 ${group.title}`}>
      <span className="group-list-avatar">
        <Avatar label={group.title} size={44} online imageUrl={group.avatar || null} />
        {badges.slice(0, 1).map((b) => {
          const Icon = badgeIcon(b.kind);
          if (b.kind === "unread" || !Icon) return null;
          return (
            <span key={b.kind} className={`group-list-status group-badge-${b.kind}`}>
              <Icon width={10} height={10} />
            </span>
          );
        })}
      </span>
      <span className="group-list-body">
        <span className="group-list-title">{group.title}</span>
        <span className="group-list-sub">
          {preview ?? `${group.memberCount ?? 0} 人`}
        </span>
      </span>
      {status.unread != null && status.unread > 0 && (
        <span className="group-badge group-badge-unread">
          {status.unread > 99 ? "99+" : status.unread}
        </span>
      )}
    </button>
  );
}
