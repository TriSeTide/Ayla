/**
 * LiveHall —— 直播大厅频道列表（M5-4，文档 §1）。
 *
 * 频道卡片：封面占位（16:9 渐变 + 状态徽章覆盖）+ 标题 / 主播昵称 /
 * 来源标识（公开/好友/群名）+ 爱莉角标。封面图资源未接入 → 渐变占位
 * （需求：卡片显示直播间封面，暂未实现就只占位）。
 * 徽章基于乐观 status（列表无 /status/ 实时判定）；owner 是爱莉 user 的频道
 * 加"爱莉"角标（普通频道渲染，无特殊数据通道）。
 */
import type { LiveChannelDescriptor } from "../../api/types";
import { FavoriteButton } from "../FavoriteButton";
import { IconVideo } from "../icons";
import { ResourceImage } from "../ResourceImage";
import { getVisibilityLabels } from "../../utils/visibility";
import { staggerDelay } from "../../hooks/useRevealOnEnter";
import type { CSSProperties } from "react";

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
  revealItems = false,
}: {
  channels: LiveChannelDescriptor[];
  /** 爱莉 profile 的 user id（用于"爱莉"角标）；null 则不标注 */
  elysiaUserId: string | null;
  /** owner_id → 展示昵称（大厅列表不带主播信息，由页面层补齐） */
  ownerNames: Record<string, string>;
  onEnter: (channelId: number) => void;
  /** 列表逐条浮入（stagger，active 接 !loading，方案 §5-A2） */
  revealItems?: boolean;
}) {
  if (channels.length === 0) {
    return (
      <div className="live-hall-empty">
        <h3 className="placeholder-title">还没有直播间</h3>
        <p className="placeholder-desc">点右下角 + 发起第一场直播吧</p>
      </div>
    );
  }
  return (
    <div className="live-hall-grid">
      {channels.map((ch, idx) => {
        const badge = statusBadge(ch.status);
        const isElysia = elysiaUserId != null && ch.owner_id === elysiaUserId;
        const labels = getVisibilityLabels(ch);
        const delay = revealItems ? staggerDelay(idx) : 0;
        return (
          <div
            key={ch.id}
            className={`live-card-wrap${revealItems ? " reveal-item" : ""}`}
            style={revealItems ? ({ ["--reveal-delay" as string]: `${delay}ms` } as CSSProperties) : undefined}
          >
            <button
              type="button"
              className="live-card"
              onClick={() => onEnter(ch.id)}
            >
              <div className={`live-card-cover ${ch.status === "live" ? "is-live" : ""}`}>
              {ch.cover ? (
                <ResourceImage src={ch.cover} alt="" className="live-card-cover-image" />
              ) : (
                <IconVideo width={28} height={28} aria-hidden="true" />
              )}
              <span className="live-card-cover-badge">
                <span className={badge.className}>{badge.label}</span>
                {isElysia && <span className="live-badge live-badge-elysia">爱莉</span>}
              </span>
              </div>
              <div className="live-card-title">{ch.title}</div>
              <div className="live-card-meta">
              <span className="live-card-owner">
                {ch.owner_nickname ?? ownerNames[ch.owner_id] ?? "未知主播"}
              </span>
              <div className="live-card-source-tags">
                {labels.map((label, idx) => (
                  <span key={idx} className="live-badge live-badge-source">{label}</span>
                ))}
              </div>
              </div>
            </button>
            <FavoriteButton targetType="live" targetId={ch.id} compact />
          </div>
        );
      })}
    </div>
  );
}
