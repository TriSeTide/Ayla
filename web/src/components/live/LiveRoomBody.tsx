/**
 * LiveRoomBody —— 直播间核心（F4，供一级直播 tab LiveRoomPage 与群内直播 GroupLive 复用）。
 *
 * 职责：播放器三态渲染 + 弹幕（列表/输入）+ 主播面板 + 切换控件（窄屏上下滑 /
 * 宽屏两侧按钮 + 键盘 ↑↓）+ 输入框滑入动画。
 *
 * 切换范围由**外层传入的有序频道列表**决定（一级 = 全部可见；群内 = 仅该群，
 * 需求 R-L3/R-G7）——本组件只负责"当前直播间 + 上一个/下一个" UI 与手势。
 *
 * 布局：复用 M5-4 的 .live-room（主区播放器 + 弹幕侧列）；窄屏弹幕侧列改为
 * 底部浮层（沉浸式），宽屏侧列 360px（验收要求的弹幕侧列）。
 */
import { useEffect } from "react";
import type { LiveChannelDescriptor } from "../../api/types";
import { DanmakuInput } from "./DanmakuInput";
import { DanmakuList } from "./DanmakuList";
import { LiveOwnerPanel } from "./LiveOwnerPanel";
import { LivePlayer } from "./LivePlayer";
import { useDanmaku } from "../../hooks/useDanmaku";
import { useLiveRoom } from "../../hooks/useLiveRoom";
import { useSwipe } from "../../hooks/useSwipe";
import { useLiveStore } from "../../stores/live";

export function LiveRoomBody({
  channelId,
  channel,
  isNarrow,
  hasPrev,
  hasNext,
  onPrev,
  onNext,
  onBack,
  onDeleted,
  inputEntered,
}: {
  channelId: number;
  channel: LiveChannelDescriptor | null;
  isNarrow: boolean;
  hasPrev: boolean;
  hasNext: boolean;
  onPrev: () => void;
  onNext: () => void;
  onBack: () => void;
  onDeleted: () => void;
  inputEntered: boolean;
}) {
  const { loading, error, playerError, retryPlayer, videoRef } = useLiveRoom(channelId);
  const { sending, sendError, send, listRef, hasNewBelow, scrollToBottom } = useDanmaku(channelId);
  const danmaku = useLiveStore((s) => s.current.danmaku);
  const srsStatus = useLiveStore((s) => s.current.srsStatus);
  const wsConnection = useLiveStore((s) => s.wsConnection);

  // 宽屏键盘切换（↑↓）
  useEffect(() => {
    if (isNarrow) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "ArrowUp") {
        e.preventDefault();
        if (hasPrev) onPrev();
      } else if (e.key === "ArrowDown") {
        e.preventDefault();
        if (hasNext) onNext();
      }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [isNarrow, hasPrev, hasNext, onPrev, onNext]);

  // 窄屏上下滑切换（范围 = 外层传入列表；弹幕输入框保持）
  const swipe = useSwipe(
    {
      onEnd: (e) => {
        if (e.direction === "up" && hasNext) onNext();
        else if (e.direction === "down" && hasPrev) onPrev();
      },
    },
    { threshold: 60 },
  );

  if (error) {
    return (
      <div className="live-room-error">
        <p>{error}</p>
        <button type="button" className="btn btn-glow" onClick={onBack}>
          返回
        </button>
      </div>
    );
  }

  return (
    <div
      className={`live-room live-room-body ${isNarrow ? "is-narrow" : "is-wide"}`}
      {...swipe.handlers}
    >
      <main className="live-room-main">
        <div className="live-room-head">
          <button
            type="button"
            className="msg-action-btn"
            onClick={onBack}
            aria-label="返回"
          >
            ← 返回
          </button>
          <span className="live-room-title">
            {loading ? "加载中…" : (channel?.title ?? "直播间")}
          </span>
          <span className={`live-ws-state live-ws-${wsConnection}`}>
            {wsConnection === "online"
              ? "弹幕已连接"
              : wsConnection === "connecting"
                ? "弹幕连接中…"
                : "弹幕已断开"}
          </span>
        </div>

        <div className="live-room-stage">
          {!isNarrow && (
            <button
              type="button"
              className="live-switch-btn"
              onClick={onPrev}
              disabled={!hasPrev}
              aria-label="上一个直播间"
            >
              ↑
            </button>
          )}
          <div className="live-room-player-wrap">
            <LivePlayer
              srsStatus={srsStatus}
              optimisticStatus={channel?.status ?? null}
              playerError={playerError}
              videoRef={videoRef}
              onRetry={retryPlayer}
            />
          </div>
          {!isNarrow && (
            <button
              type="button"
              className="live-switch-btn"
              onClick={onNext}
              disabled={!hasNext}
              aria-label="下一个直播间"
            >
              ↓
            </button>
          )}
        </div>

        {channel?.is_owner && (
          <LiveOwnerPanel channel={channel} srsStatus={srsStatus} onDeleted={onDeleted} />
        )}
      </main>

      <aside className="live-room-side">
        <DanmakuList
          danmaku={danmaku}
          listRef={listRef}
          hasNewBelow={hasNewBelow}
          onScrollToBottom={scrollToBottom}
        />
        <div
          className="live-room-input"
          style={{
            transform: inputEntered ? "translateY(0)" : "translateY(100%)",
            transition: "transform 250ms var(--ease-out)",
          }}
        >
          <DanmakuInput sending={sending} error={sendError} onSend={send} />
        </div>
      </aside>
    </div>
  );
}
