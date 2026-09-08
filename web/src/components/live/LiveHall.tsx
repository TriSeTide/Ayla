/**
 * LiveHall —— 直播大厅频道列表（M5-4，文档 §1）。
 *
 * 频道卡片：真实封面（16:9 + 状态徽章覆盖）+ 标题 / 主播昵称 /
 * 来源标识（公开/好友/群名）+ 爱莉角标。未设置封面时显示透明占位与视频图标。
 * 徽章基于乐观 status（列表无 /status/ 实时判定）；owner 是爱莉 user 的频道
 * 加"爱莉"角标（普通频道渲染，无特殊数据通道）。
 */
import type { LiveChannelDescriptor } from "../../api/types";
import { LiveChannelCard } from "./LiveChannelCard";
import { staggerDelay } from "../../hooks/useRevealOnEnter";

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
      {channels.map((channel, index) => <LiveChannelCard key={channel.id} channel={channel}
        onEnter={() => onEnter(channel.id)} ownerName={ownerNames[channel.owner_id]}
        isElysia={elysiaUserId != null && channel.owner_id === elysiaUserId}
        revealDelay={revealItems ? staggerDelay(index) : undefined} />)}
    </div>
  );
}
