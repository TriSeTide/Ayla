/**
 * VoiceChannelList —— 语音频道卡片网格（需求：宽屏窄屏统一卡片布局）。
 * 每张卡片（与 LiveHall / games-grid 同构）：来源标识（公开/好友/群名）+ 名称 +
 * 人数 + 进房按钮；进房走 useVoiceChannel.join（幂等）。
 * 卡片整体可点击进房（加大触达目标）；按钮文案区分语义：
 *   - 我在其中（mine）→「进入」（回到频道）
 *   - 不在频道 →「加入」
 * 窄屏 2 列 / 宽屏 3-4 列（voice.css 网格）。
 */
import type { CSSProperties, KeyboardEvent } from "react";
import type { VoiceChannelDescriptor } from "../../api/types";
import { staggerDelay } from "../../hooks/useRevealOnEnter";
import { FavoriteButton } from "../FavoriteButton";
import { ScrollingText } from "../ScrollingText";
import { ScrollingTags } from "../ScrollingTags";
import { IconMic } from "../icons";
import { getVisibilityLabels } from "../../utils/visibility";

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
      {channels.map((ch, idx) => {
        const active = ch.id === currentChannelId;
        const delay = revealItems ? staggerDelay(idx) : 0;
        // 已在频道（mine）：卡片整体点击「进入」（回到频道，aria-label），
        // foot 右侧用「我在其中」按钮标识占位（与非成员「加入」按钮等高对齐）。
        // 非成员：显示「加入」按钮。join 幂等，重复进入安全。
        const label = ch.mine ? "进入" : "加入";
        const labels = getVisibilityLabels(ch);
        const enter = () => {
          if (!joining) onJoin(ch.id);
        };
        const onKeyDown = (e: KeyboardEvent<HTMLDivElement>) => {
          if (e.key === "Enter" || e.key === " ") {
            e.preventDefault();
            enter();
          }
        };
        return (
          /* 动画挂在 grid item 外层，避免 .reveal-item 的 transform 动画压过卡片 hover 位移。 */
          <div
            key={ch.id}
            className={`voice-channel-card-wrap${revealItems ? " reveal-item" : ""}`}
            style={revealItems ? ({ ["--reveal-delay" as string]: `${delay}ms` } as CSSProperties) : undefined}
          >
            <div
              className={`voice-channel-card ${active ? "active" : ""}`}
              role="button"
              tabIndex={0}
              aria-disabled={joining}
              aria-label={`${label}语音频道 ${ch.name}`}
              onClick={enter}
              onKeyDown={onKeyDown}
            >
              <div className="voice-card-head">
                <ScrollingTags labels={labels} tagClassName="voice-source-tag" className="voice-source-tags" />
                <FavoriteButton targetType="voice" targetId={ch.id} compact />
              </div>
              <div className="voice-card-title">
                <IconMic width={14} height={14} className="voice-card-title-icon" />
                <ScrollingText text={ch.name} className="voice-card-title-text" />
              </div>
              <div className="voice-card-foot">
                <span className="voice-card-meta">{ch.member_count} 人</span>
                {ch.mine ? (
                  <span className="voice-mine-btn">我在其中</span>
                ) : (
                  <button
                    type="button"
                    className="btn btn-primary voice-join-btn"
                    disabled={joining}
                    onClick={(e) => {
                      e.stopPropagation();
                      enter();
                    }}
                  >
                    {joining ? "加入中…" : "加入"}
                  </button>
                )}
              </div>
            </div>
          </div>
        );
      })}
    </div>
  );
}
