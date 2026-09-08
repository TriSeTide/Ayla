/**
 * VoiceChannelList —— 语音频道卡片网格（需求：宽屏窄屏统一卡片布局）。
 * 每张卡片（与 LiveHall / games-grid 同构）：来源标识（公开/好友/群名）+ 名称 +
 * 人数 + 进房按钮；进房走 useVoiceChannel.join（幂等）。
 * 卡片整体可点击进房（加大触达目标）；按钮文案区分语义：
 *   - 我在其中（mine）→「进入」（回到频道）
 *   - 不在频道 →「加入」
 * 窄屏 2 列 / 宽屏 3-4 列（voice.css 网格）。
 */
import type { VoiceChannelDescriptor } from "../../api/types";
import { staggerDelay } from "../../hooks/useRevealOnEnter";
import { VoiceChannelCard } from "./VoiceChannelCard";

export function VoiceChannelList({
  channels,
  currentChannelId,
  joining,
  onJoin,
  revealItems = false,
}: {
  channels: VoiceChannelDescriptor[];
  currentChannelId: string | null;
  joining: boolean;
  onJoin: (channelId: string) => void;
  /** 列表逐条浮入（A2 扩展至群内/群外语音列表；active 接 !loading） */
  revealItems?: boolean;
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
      {channels.map((channel, index) => <VoiceChannelCard key={channel.id} channel={channel}
        active={channel.id === currentChannelId} joining={joining} onEnter={() => onJoin(channel.id)}
        revealDelay={revealItems ? staggerDelay(index) : undefined} />)}
    </div>
  );
}
