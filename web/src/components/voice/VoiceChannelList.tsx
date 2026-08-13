/**
 * VoiceChannelList —— 语音频道卡片列表（M5-3 §1）。
 * 每张卡片：名称 / 人数 / 我是否在其中；点击"加入"走 useVoiceChannel.join。
 */
import type { VoiceChannelDescriptor } from "../../api/types";
import { IconMic } from "../icons";

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
    return <div className="voice-list-empty">还没有语音频道，建一个吧</div>;
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
