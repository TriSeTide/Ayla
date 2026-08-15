/**
 * LiveChannelRail —— 直播间频道封面侧栏（需求）。
 *
 * 一列直播间封面（16:9 渐变占位 + 标题），点击切换当前直播间，当前项高亮。
 * - 宽屏：完整侧栏含顶部操作区（返回 + 收起按钮）；collapsed 时折叠为窄条
 *   （保留返回 + 展开按钮 + 当前封面）。
 * - 窄屏覆盖层：只渲染封面列表（showBack=false 时无返回键，返回键在左上角）。
 */
import type { LiveChannelDescriptor } from "../../api/types";
import { IconBack, IconClose, IconVideo } from "../icons";

export function LiveChannelRail({
  channels,
  currentId,
  onSelect,
  collapsed,
  onToggle,
  onBack,
  showBack,
}: {
  channels: LiveChannelDescriptor[];
  currentId: number;
  onSelect: (channelId: number) => void;
  /** 宽屏收起态（窄条）；窄屏覆盖层恒 false */
  collapsed: boolean;
  /** 收起/展开切换（宽屏）；窄屏覆盖层点击关闭 */
  onToggle: () => void;
  onBack: () => void;
  /** 是否在侧栏内渲染返回键（宽屏 true；窄屏 false，返回键在左上角） */
  showBack: boolean;
}) {
  // 收起态：窄条只显示当前封面 + 展开 + 返回
  if (collapsed) {
    return (
      <nav className="live-rail live-rail-collapsed" aria-label="直播间列表">
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
            aria-label="展开直播间列表"
            aria-expanded={false}
          >
            <IconVideo width={18} height={18} />
          </button>
        </div>
        <div className="live-rail-collapsed-current">
          <div className="live-rail-cover small">
            <IconVideo width={16} height={16} aria-hidden="true" />
          </div>
        </div>
      </nav>
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
          <IconClose width={18} height={18} />
        </button>
      </div>
      <ul className="live-rail-list">
        {channels.map((ch) => {
          const active = ch.id === currentId;
          return (
            <li key={ch.id}>
              <button
                type="button"
                className={`live-rail-item ${active ? "is-active" : ""}`}
                onClick={() => onSelect(ch.id)}
                aria-current={active ? "true" : undefined}
                aria-label={`切换到直播间 ${ch.title}`}
              >
                <div className="live-rail-cover">
                  <IconVideo width={18} height={18} aria-hidden="true" />
                  {ch.status === "live" && (
                    <span className="live-rail-live-dot" aria-label="直播中" />
                  )}
                </div>
                <span className="live-rail-item-title">{ch.title}</span>
              </button>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}
