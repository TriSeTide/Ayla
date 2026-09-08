import type { CSSProperties, KeyboardEvent, ReactNode } from "react";
import type { VoiceCardData } from "../cards/cardData";
import { cardVisibilityLabels } from "../cards/cardData";
import { FavoriteButton } from "../FavoriteButton";
import { ScrollingText } from "../ScrollingText";
import { ScrollingTags } from "../ScrollingTags";
import { IconMic } from "../icons";

export function VoiceChannelCard({ channel, active = false, joining = false, onEnter, revealDelay, action, browsing = false }: {
  channel: VoiceCardData;
  active?: boolean;
  joining?: boolean;
  onEnter: () => void;
  revealDelay?: number;
  action?: ReactNode;
  /** Directories navigate to the room route; they do not open an RTC connection here. */
  browsing?: boolean;
}) {
  const label = browsing ? "查看" : channel.mine ? "进入" : "加入";
  const enter = () => { if (!joining) onEnter(); };
  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.target !== event.currentTarget) return;
    if (event.key === "Enter" || event.key === " ") { event.preventDefault(); enter(); }
  };
  return <div className={`voice-channel-card-wrap${revealDelay != null ? " reveal-item" : ""}`}
    style={revealDelay != null ? ({ "--reveal-delay": `${revealDelay}ms` } as CSSProperties) : undefined}>
    <div className={`voice-channel-card ${active ? "active" : ""}`} role="button" tabIndex={0}
      aria-disabled={joining} aria-label={`${label}语音频道 ${channel.name}`} onClick={enter} onKeyDown={onKeyDown}>
      <div className="voice-card-head">
        <ScrollingTags labels={cardVisibilityLabels(channel)} tagClassName="voice-source-tag" className="voice-source-tags" />
        {action === undefined ? <FavoriteButton targetType="voice" targetId={channel.id} compact /> : action}
      </div>
      <div className="voice-card-title">
        <IconMic width={14} height={14} className="voice-card-title-icon" />
        <ScrollingText text={channel.name} className="voice-card-title-text" />
      </div>
      {channel.owner_nickname && <span className="voice-card-owner">{channel.owner_nickname}</span>}
      <div className="voice-card-foot">
        {typeof channel.member_count === "number" && <span className="voice-card-meta">{channel.member_count} 人</span>}
        {channel.mine && !browsing ? <span className="voice-mine-btn">我在其中</span> : <button type="button"
          className="btn btn-primary voice-join-btn" disabled={joining} onClick={(event) => { event.stopPropagation(); enter(); }}>
          {joining ? "加入中…" : browsing ? "查看语音房" : "加入"}
        </button>}
      </div>
    </div>
  </div>;
}
