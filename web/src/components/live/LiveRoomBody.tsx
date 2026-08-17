/**
 * LiveRoomBody —— 直播间核心（F4，供一级直播 tab LiveRoomPage 与群内直播 GroupLive 复用）。
 *
 * 职责：播放器三态渲染 + 弹幕（列表/输入）+ 频道侧栏（封面列切换）；
 * 主播面板只由开播控制台显式开启。
 *
 * 频道切换（需求）：取消宽屏上下键/窄屏上下滑的"上一/下一个"按钮——统一改为
 * 左侧**频道封面列**（LiveChannelRail）点击切换：
 * - 宽屏：侧栏默认展开（返回键在侧栏顶部 + 收起/展开按钮）；收起后窄条保留返回 + 展开。
 * - 窄屏：默认无侧栏（左上角返回键），点右上「频道列表」按钮打开侧栏覆盖层；
 *   侧栏内**不出现第二个返回键**（返回键只在左上角）。
 *
 * 切换范围由**外层传入的有序频道列表**决定（一级 = 全部可见；群内 = 仅该群）。
 */
import { useState } from "react";
import type { LiveChannelDescriptor } from "../../api/types";
import { DanmakuInput } from "./DanmakuInput";
import { DanmakuList } from "./DanmakuList";
import { LiveChannelRail } from "./LiveChannelRail";
import { LiveOwnerPanel } from "./LiveOwnerPanel";
import { LivePlayer } from "./LivePlayer";
import { LiveStreamAddresses } from "./LiveStreamAddresses";
import { useDanmaku } from "../../hooks/useDanmaku";
import { useLiveRoom } from "../../hooks/useLiveRoom";
import { IconList } from "../icons";
import { useLiveStore } from "../../stores/live";

export function LiveRoomBody({
  channelId,
  channel,
  isNarrow,
  channels,
  onSelect,
  onBack,
  inputEntered,
  showOwnerPanel = false,
  activityRoute,
  keepLiveActivity = false,
  onDeleteChannel,
  onCreateNewChannel,
  deletingChannelId = null,
}: {
  channelId: number;
  channel: LiveChannelDescriptor | null;
  isNarrow: boolean;
  /** 有序频道列表（切换范围；一级 = 全部可见，群内 = 仅该群） */
  channels: LiveChannelDescriptor[];
  /** 点击封面切换直播间 */
  onSelect: (channelId: number) => void;
  onBack: () => void;
  inputEntered: boolean;
  /** 仅开播控制台显示主播面板，普通直播间保持观看 + 弹幕。 */
  showOwnerPanel?: boolean;
  /** 跨页面返回入口的目标路由。 */
  activityRoute?: string;
  /** 主播控制台离开页面后，直播中仍保留活动态入口。 */
  keepLiveActivity?: boolean;
  /** 侧栏每项删除直播间（仅开播控制台提供）。 */
  onDeleteChannel?: (channelId: number) => void;
  /** 侧栏底部加号：新建直播间并进入控制台。 */
  onCreateNewChannel?: () => void;
  /** 正在删除的频道 id（侧栏该项禁用）。 */
  deletingChannelId?: number | null;
}) {
  const { loading, error, playerError, retryPlayer, videoRef } = useLiveRoom(channelId, {
    activityRoute,
    keepLiveActivity,
  });
  const { sending, sendError, send, listRef, hasNewBelow, scrollToBottom } = useDanmaku(channelId);
  const danmaku = useLiveStore((s) => s.current.danmaku);
  const srsStatus = useLiveStore((s) => s.current.srsStatus);
  const wsConnection = useLiveStore((s) => s.wsConnection);

  // 宽屏侧栏：默认展开，可收起（窄条）；窄屏侧栏：默认关闭（覆盖层）
  const [railCollapsed, setRailCollapsed] = useState(false);
  const [railOpen, setRailOpen] = useState(false);

  if (error) {
    return (
      <div className={`live-room live-room-body ${showOwnerPanel ? "is-studio" : ""} ${isNarrow ? "is-narrow" : "is-wide"}`}>
        {/* 出错时仍保留侧栏与弹幕区，主区显示错误，避免用户卡在"只有返回键"的死页面 */}
        {!isNarrow && (
          <LiveChannelRail
            channels={channels}
            currentId={channelId}
            onSelect={onSelect}
            collapsed={railCollapsed}
            onToggle={() => setRailCollapsed((v) => !v)}
            onBack={onBack}
            showBack
            onDeleteChannel={showOwnerPanel ? onDeleteChannel : undefined}
            onCreateNewChannel={onCreateNewChannel}
            deletingChannelId={deletingChannelId}
          />
        )}
        <main className="live-room-main">
          <div className="live-room-error">
            <p>{error}</p>
            <button type="button" className="btn btn-glow" onClick={onBack}>
              返回
            </button>
          </div>
        </main>
        <aside className="live-room-side">
          <DanmakuList
            danmaku={danmaku}
            listRef={listRef}
            hasNewBelow={hasNewBelow}
            onScrollToBottom={scrollToBottom}
          />
        </aside>
      </div>
    );
  }

  return (
    <div className={`live-room live-room-body ${showOwnerPanel ? "is-studio" : ""} ${isNarrow ? "is-narrow" : "is-wide"}`}>
      {/* 宽屏：频道封面侧栏（返回键在侧栏内 + 收起/展开） */}
      {!isNarrow && (
        <LiveChannelRail
          channels={channels}
          currentId={channelId}
          onSelect={onSelect}
          collapsed={railCollapsed}
          onToggle={() => setRailCollapsed((v) => !v)}
          onBack={onBack}
          showBack
          onDeleteChannel={showOwnerPanel ? onDeleteChannel : undefined}
          onCreateNewChannel={onCreateNewChannel}
          deletingChannelId={deletingChannelId}
        />
      )}

      <main className="live-room-main">
        {/* 开播控制台：宽屏头部整行隐藏（侧栏已有返回/标题），窄屏只留返回 + 列表按钮 */}
        {(isNarrow || !showOwnerPanel) && (
          <div className="live-room-head">
            {isNarrow ? (
              <>
                <button
                  type="button"
                  className="msg-action-btn"
                  onClick={onBack}
                  aria-label="返回"
                >
                  ← 返回
                </button>
                {!showOwnerPanel && (
                  <span className="live-room-title">
                    {loading ? "加载中…" : (channel?.title ?? "直播间")}
                  </span>
                )}
                <button
                  type="button"
                  className="live-room-rail-toggle"
                  onClick={() => setRailOpen(true)}
                  aria-label="打开直播间列表"
                  aria-expanded={railOpen}
                >
                  <IconList width={20} height={20} />
                </button>
              </>
            ) : (
              <>
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
              </>
            )}
          </div>
        )}

        {showOwnerPanel && channel?.is_owner && (
          <div className="live-studio-owner-panel">
            <LiveOwnerPanel channel={channel} />
          </div>
        )}

        {/* 中间：直播视频 */}
        <div className="live-room-stage">
          <div className="live-room-player-wrap">
            <LivePlayer
              srsStatus={srsStatus}
              optimisticStatus={channel?.status ?? null}
              playerError={playerError}
              videoRef={videoRef}
              onRetry={retryPlayer}
            />
          </div>
        </div>

        {/* 下面：推流密钥（服务器 / 串流密钥 / FLV） */}
        {showOwnerPanel && channel?.is_owner && (
          <LiveStreamAddresses channel={channel} />
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

      {/* 窄屏：频道侧栏覆盖层（默认关闭；点开无返回键，返回键只在左上角） */}
      {isNarrow && railOpen && (
        <div className="live-room-rail-overlay">
          <div className="live-room-rail-mask" onClick={() => setRailOpen(false)} aria-hidden="true" />
          <LiveChannelRail
            channels={channels}
            currentId={channelId}
            onSelect={(id) => {
              onSelect(id);
              setRailOpen(false);
            }}
            collapsed={false}
            onToggle={() => setRailOpen(false)}
            onBack={() => setRailOpen(false)}
            showBack={false}
            onDeleteChannel={showOwnerPanel ? onDeleteChannel : undefined}
            onCreateNewChannel={onCreateNewChannel}
            deletingChannelId={deletingChannelId}
          />
        </div>
      )}
    </div>
  );
}
