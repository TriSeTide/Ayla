/**
 * LiveChannelRail —— 直播间频道封面侧栏（需求）。
 *
 * 一列直播间封面（16:9 渐变占位 + 标题横排），点击切换当前直播间，当前项高亮。
 * - 宽屏：完整侧栏含顶部操作区（返回 + 收起按钮），宽度 240px；
 *   collapsed 时**整个收成一个浮动按钮**（悬浮左上角，含返回 + 展开键，
 *   不占布局、不在左边留侧栏）。
 * - 窄屏覆盖层：只渲染封面列表（showBack=false 时无返回键，返回键在左上角）。
 *
 * 开播控制台（showOwnerPanel）额外提供：
 * - 每项右侧删除按钮（onDeleteChannel）；
 * - 底部加号键新建直播间（onCreateNewChannel）。
 */
import type { LiveChannelDescriptor } from "../../api/types";
import { IconBack, IconChevronLeft, IconChevronRight, IconClose, IconPlus, IconVideo } from "../icons";
import { ResourceImage } from "../ResourceImage";

export function LiveChannelRail({
  channels,
  currentId,
  onSelect,
  collapsed,
  onToggle,
  onBack,
  showBack,
  onDeleteChannel,
  onCreateNewChannel,
  deletingChannelId = null,
}: {
  channels: LiveChannelDescriptor[];
  currentId: number;
  onSelect: (channelId: number) => void;
  /** 宽屏收起态（收成一个浮动按钮）；窄屏覆盖层恒 false */
  collapsed: boolean;
  /** 收起/展开切换（宽屏）；窄屏覆盖层点击关闭 */
  onToggle: () => void;
  onBack: () => void;
  /** 是否渲染返回键（宽屏 true；窄屏 false，返回键在左上角） */
  showBack: boolean;
  /** 每项删除按钮（仅开播控制台提供） */
  onDeleteChannel?: (channelId: number) => void;
  /** 底部加号键新建直播间（仅开播控制台提供） */
  onCreateNewChannel?: () => void;
  /** 正在删除的频道 id（该项禁用） */
  deletingChannelId?: number | null;
}) {
  // 收起态：整个收成一个浮动按钮（返回 + 展开），不占布局、不留侧栏
  if (collapsed) {
    return (
      <div className="live-rail-float" role="group" aria-label="直播间列表控制">
        {showBack && (
          <button
            type="button"
            className="live-rail-icon-btn"
            onClick={onBack}
            aria-label="返回"
            title="返回"
          >
            <IconBack width={18} height={18} />
          </button>
        )}
        <button
          type="button"
          className="live-rail-icon-btn"
          onClick={onToggle}
          aria-label="展开直播间列表"
          aria-expanded={false}
          title="展开直播间列表"
        >
          <IconChevronRight width={18} height={18} />
        </button>
      </div>
    );
  }

  return (
    <nav className="live-rail" aria-label="直播间列表">
      <div className="live-rail-actions">
        {showBack && (
          <button
            type="button"
            className="live-rail-icon-btn"
            onClick={onBack}
            aria-label="返回"
            title="返回"
          >
            <IconBack width={18} height={18} />
          </button>
        )}
        <button
          type="button"
          className="live-rail-icon-btn"
          onClick={onToggle}
          aria-label="收起直播间列表"
          aria-expanded={true}
          title="收起"
        >
          <IconChevronLeft width={18} height={18} />
        </button>
      </div>
      <ul className="live-rail-list">
        {channels.map((ch) => {
          const active = ch.id === currentId;
          const deleting = ch.id === deletingChannelId;
          return (
            <li key={ch.id} className="live-rail-item-wrap">
              <button
                type="button"
                className={`live-rail-item ${active ? "is-active" : ""}`}
                onClick={() => onSelect(ch.id)}
                aria-current={active ? "true" : undefined}
                aria-label={`切换到直播间 ${ch.title}`}
              >
                <div className="live-rail-cover">
                  {ch.cover ? (
                    <ResourceImage src={ch.cover} alt="" className="live-rail-cover-image" />
                  ) : (
                    <IconVideo width={18} height={18} aria-hidden="true" />
                  )}
                  {ch.status === "live" && (
                    <span className="live-rail-live-dot" aria-label="直播中" />
                  )}
                </div>
                <span className="live-rail-item-title">{ch.title}</span>
              </button>
              {onDeleteChannel && (
                <button
                  type="button"
                  className="live-rail-del-btn"
                  onClick={() => onDeleteChannel(ch.id)}
                  disabled={deleting}
                  aria-label={`删除直播间 ${ch.title}`}
                  title="删除直播间"
                >
                  <IconClose width={14} height={14} />
                </button>
              )}
            </li>
          );
        })}
      </ul>
      {onCreateNewChannel && (
        <div className="live-rail-create">
          <button type="button" className="live-rail-create-btn" onClick={onCreateNewChannel}>
            <IconPlus width={16} height={16} />
            新建直播间
          </button>
        </div>
      )}
    </nav>
  );
}
