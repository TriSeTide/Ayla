/**
 * LiveHall —— 直播大厅频道列表（M5-4，文档 §1）。
 *
 * 频道卡片：标题 / 主播昵称 / 状态徽章（直播中 / 未开播 / 已结束）；
 * 徽章基于乐观 status（列表无 /status/ 实时判定）；owner 是爱莉 user 的频道加"爱莉"角标
 * （普通频道渲染，无特殊数据通道）。
 */
import type { LiveChannelDescriptor } from "../../api/types";

function statusBadge(status: LiveChannelDescriptor["status"]): {
  className: string;
  label: string;
} {
  switch (status) {
    case "live":
      return { className: "live-badge live-badge-live", label: "直播中" };
    case "ended":
      return { className: "live-badge live-badge-ended", label: "已结束" };
    default:
      return { className: "live-badge live-badge-idle", label: "未开播" };
  }
}

export function LiveHall({
  channels,
  elysiaUserId,
  ownerNames,
  onEnter,
}: {
  channels: LiveChannelDescriptor[];
  /** 爱莉 profile 的 user id（用于"爱莉"角标）；null 则不标注 */
  elysiaUserId: string | null;
  /** owner_id → 展示昵称（大厅列表不带主播信息，由页面层补齐） */
  ownerNames: Record<string, string>;
  onEnter: (channelId: number) => void;
}) {
  if (channels.length === 0) {
    return <div className="live-hall-empty">暂时没有直播间，来开第一个吧</div>;
  }
  return (
    <div className="live-hall-grid">
      {channels.map((ch) => {
        const badge = statusBadge(ch.status);
        const isElysia = elysiaUserId != null && ch.owner_id === elysiaUserId;
        return (
          <button
            key={ch.id}
            type="button"
            className="live-card"
            onClick={() => onEnter(ch.id)}
          >
            <div className="live-card-head">
              <span className={badge.className}>{badge.label}</span>
              {isElysia && <span className="live-badge live-badge-elysia">爱莉</span>}
            </div>
            <div className="live-card-title">{ch.title}</div>
            <div className="live-card-owner">
              {ownerNames[ch.owner_id] ?? "未知主播"}
            </div>
          </button>
        );
      })}
    </div>
  );
}
