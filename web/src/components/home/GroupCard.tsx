/**
 * GroupCard —— 群卡片（窄屏主页卡片布局，design.md §12.6，需求 R-H4/R-H5）。
 *
 * 结构：4:3 状态轮播（消息+语音 / 直播 / 帖子 / 桌游）+ 底部群头像（带光环）+ 群名。
 * 交互：
 * - 点轮播区或底部行 → 进入群聊场景容器（/group/:id；onOpen）；轮播卡本身不再跳动态；
 * - 右下角 ⋯ 更多菜单 → 置顶/取消置顶（GroupCard 场景复用 ConversationMoreMenu，
 *   showDelete=false；置顶后左上角显示置顶小图标，图标绝对定位在卡片外，不挤压卡片空间）。
 * - 右上角未读徽标保留（未读 > 0 显示数字）；直播/语音/桌游小标签已移出卡片，
 *   改由列表布局与宽屏侧栏的群头像三位置角标展示。
 */
import { Avatar } from "../Avatar";
import { ConversationMoreMenu } from "../chat/ConversationMoreMenu";
import { IconPinFilled } from "../icons";
import type { GroupCarouselSlide } from "./groupActivity";
import { GroupCarousel } from "./GroupCarousel";

export function GroupCard({
  group,
  slides,
  unread,
  isPinned,
  onOpen,
  onError,
}: {
  group: { id: string; title: string; avatar?: string; memberCount?: number };
  /** 状态轮播卡片列表（消息+语音/直播/帖子/桌游） */
  slides: GroupCarouselSlide[];
  /** 未读数（>0 时右上角显示数字徽标） */
  unread: number;
  /** 置顶标识（M5 会话管理） */
  isPinned?: boolean;
  /** 进入群聊场景（点击轮播区或底部行） */
  onOpen: () => void;
  /** 置顶失败提示（父组件错误条）；缺省 alert 兜底 */
  onError?: (message: string) => void;
}) {
  return (
    <article className={`group-card ${isPinned ? "is-pinned" : ""}`}>
      {isPinned && (
        <span className="group-card-pin" aria-label="已置顶" title="已置顶">
          <IconPinFilled width={16} height={16} />
        </span>
      )}
      <div className="group-card-main" onClick={onOpen}>
        <GroupCarousel slides={slides} groupName={group.title} avatar={group.avatar} />
        {unread > 0 && (
          <span className="group-badge group-badge-unread group-card-unread">
            {unread > 99 ? "99+" : unread}
          </span>
        )}
      </div>
      <button
        type="button"
        className="group-card-foot"
        onClick={onOpen}
        aria-label={`进入群聊 ${group.title}`}
      >
        <Avatar label={group.title} size={24} online imageUrl={group.avatar || null} />
        <span className="group-card-title">{group.title}</span>
      </button>
      <ConversationMoreMenu
        conversation={{ id: group.id, title: group.title, is_pinned: isPinned }}
        showDelete={false}
        onError={onError}
      />
    </article>
  );
}
