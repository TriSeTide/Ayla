import type { CSSProperties, ReactNode } from "react";
import type { LiveCardData } from "../cards/cardData";
import { cardVisibilityLabels } from "../cards/cardData";
import { FavoriteButton } from "../FavoriteButton";
import { ScrollingText } from "../ScrollingText";
import { ScrollingTags } from "../ScrollingTags";
import { IconVideo } from "../icons";
import { ResourceImage } from "../ResourceImage";

/** The same cover/title/source card serves the hall and read-only directory projections. */
export function LiveChannelCard({ channel, onEnter, ownerName, isElysia = false, revealDelay, action }: {
  channel: LiveCardData;
  onEnter: () => void;
  ownerName?: string;
  isElysia?: boolean;
  revealDelay?: number;
  /** undefined keeps the scene's favorite control; null removes it. */
  action?: ReactNode;
}) {
  const labels = cardVisibilityLabels(channel);
  const owner = channel.owner_nickname || ownerName;
  const status = channel.status === "live" ? { className: "live-badge-live", label: "直播中" }
    : channel.status === "ended" ? { className: "live-badge-ended", label: "已结束" }
    : channel.status === "idle" ? { className: "live-badge-idle", label: "未开播" } : null;
  return <div className={`live-card-wrap${revealDelay != null ? " reveal-item" : ""}`}
    style={revealDelay != null ? ({ "--reveal-delay": `${revealDelay}ms` } as CSSProperties) : undefined}>
    <button type="button" className="live-card" onClick={onEnter}>
      <div className="live-card-cover">
        {channel.cover ? <ResourceImage src={channel.cover} alt="" className="live-card-cover-image" />
          : <IconVideo width={28} height={28} aria-hidden="true" />}
        <span className="live-card-cover-badge">
          {status && <span className={`live-badge ${status.className}`}>{status.label}</span>}
          {isElysia && <span className="live-badge live-badge-elysia">爱莉</span>}
        </span>
      </div>
      <div className="live-card-title"><ScrollingText text={channel.title} /></div>
      {(owner || labels.length > 0) && <div className="live-card-meta">
        {owner && <ScrollingText text={owner} className="live-card-owner" />}
        <ScrollingTags labels={labels} tagClassName="live-badge live-badge-source" className="live-card-source-tags" />
      </div>}
    </button>
    {action === undefined ? <FavoriteButton targetType="live" targetId={channel.id} compact /> : action}
  </div>;
}
