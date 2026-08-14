/**
 * VoiceChannelList —— 语音频道卡片列表（M5-3 §1）。
 * 每张卡片：名称 / 人数 / 我是否在其中；点击"加入"走 useVoiceChannel.join。
 */
import type { VoiceChannelDescriptor } from "../../api/types";
import { IconMic } from "../icons";

/** 来源标识（R-V1）：公开 / 好友 / 群名（design.md §12.10 Micro Tag） */
function sourceLabel(ch: VoiceChannelDescriptor): string {
  if (ch.visibility === "group" && ch.group_name) return ch.group_name;
  if (ch.visibility === "friends") return "好友";
  return "公开";
}

export function VoiceChannelList({
  channels,
  currentChannelId,
  joining,
  onJoin,
}: {
  channels: VoiceChannelDescriptor[];
  currentChannelId: string | null;
  joining: boolean;
  onJoin: (channelId: string) => void;
}) {
  if (channels.length === 0) {
    return (
      <div className="voice-list-empty">
        <h3 className="placeholder-title">还没有语音房</h3>
        <p className="placeholder-desc">点右下角 + 建一个吧</p>
      </div>
    );
  }
  return (
    <div className="voice-channel-list">
      {channels.map((ch) => {
        const active = ch.id === currentChannelId;
        return (
          <div key={ch.id} className={`voice-channel-card ${active ? "active" : ""}`}>
            <div className="voice-channel-info">
              <span className="voice-channel-name">
                <IconMic width={14} height={14} /> {ch.name}
              </span>
              <span className="voice-channel-meta">
                {ch.member_count} 人在频道
                <span className="voice-source-tag">{sourceLabel(ch)}</span>
                {ch.mine && <span className="voice-mine-tag">我在其中</span>}
              </span>
            </div>
            {!active && (
              <button
                type="button"
                className="btn btn-primary voice-join-btn"
                disabled={joining}
                onClick={() => onJoin(ch.id)}
              >
                {joining ? "加入中…" : "加入"}
              </button>
            )}
          </div>
        );
      })}
    </div>
  );
}
