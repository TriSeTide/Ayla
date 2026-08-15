/**
 * VoiceChannelList —— 语音频道卡片网格（需求：宽屏窄屏统一卡片布局）。
 * 每张卡片（与 LiveHall / games-grid 同构）：来源标识（公开/好友/群名）+ 名称 +
 * 人数 + 加入按钮；加入走 useVoiceChannel.join。
 * 窄屏 2 列 / 宽屏 3-4 列（voice.css 网格）。
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
            <div className="voice-card-head">
              <span className="voice-source-tag">{sourceLabel(ch)}</span>
              {ch.mine && <span className="voice-mine-tag">我在其中</span>}
            </div>
            <div className="voice-card-title">
              <IconMic width={14} height={14} /> {ch.name}
            </div>
            <div className="voice-card-foot">
              <span className="voice-card-meta">{ch.member_count} 人在频道</span>
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
          </div>
        );
      })}
    </div>
  );
}
