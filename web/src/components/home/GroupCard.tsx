/**
 * GroupCard —— 群卡片（窄屏主页卡片布局，design.md §12.6，需求 R-H4/R-H5）。
 *
 * 结构：4:3 封面轮播（右上状态角标列）+ 底部群头像（带光环）+ 群名。
 * 交互分层（避免 button 嵌套）：
 * - 点轮播封面 → 打开对应动态（直播/帖子/桌游，target_url；onOpenHighlight）；
 * - 点底部行（群头像 + 群名）→ 进入群聊场景容器（/group/:id；onOpen）。
 * 状态角标优先级 未读 > 直播 > 语音 > 桌游（home/badges.ts）。
 */
import type { GroupHighlight } from "../../api/types";
import { Avatar } from "../Avatar";
import type { GroupStatus } from "./badges";
import { badgeIcon, resolveBadges } from "./badges";
import { GroupCarousel } from "./GroupCarousel";

export function GroupCard({
  group,
  highlights,
  status,
  onOpen,
  onOpenHighlight,
}: {
  group: { id: string; title: string; avatar?: string; memberCount?: number };
  highlights: GroupHighlight[];
  status: GroupStatus;
  /** 进入群聊场景（点击底部行） */
  onOpen: () => void;
  /** 打开动态（点击轮播封面，跳 target_url） */
  onOpenHighlight?: (h: GroupHighlight) => void;
}) {
  const badges = resolveBadges(status);

  return (
    <article className="group-card">
      <div className="group-card-main">
        <GroupCarousel
          highlights={highlights}
          groupName={group.title}
          avatar={group.avatar}
          onOpen={onOpenHighlight}
        />
        {badges.length > 0 && (
          <div className="group-card-badges">
            {badges.map((b) => {
              const Icon = badgeIcon(b.kind);
              if (b.kind === "unread" || !Icon) {
                return (
                  <span key={b.kind} className="group-badge group-badge-unread" aria-label={b.ariaLabel}>
                    {b.label}
                  </span>
                );
              }
              return (
                <span
                  key={b.kind}
                  className={`group-badge group-badge-${b.kind}`}
                  aria-label={b.ariaLabel}
                >
                  <Icon width={10} height={10} />
                </span>
              );
            })}
          </div>
        )}
      </div>
      <button type="button" className="group-card-foot" onClick={onOpen} aria-label={`进入群聊 ${group.title}`}>
        <Avatar label={group.title} size={24} online imageUrl={group.avatar || null} />
        <span className="group-card-title">{group.title}</span>
      </button>
    </article>
  );
}
