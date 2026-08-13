/**
 * LiveRoomPage —— 直播间（路由 /live/:channelId，M5-4）。
 *
 * 布局：左侧播放器（三态渲染）+ 主播面板（owner）；右侧弹幕区（列表 + 输入）。
 * 进房/退房编排、状态轮询、WS 生命周期全部由 useLiveRoom 收口；
 * 弹幕发送/滚动由 useDanmaku 收口。
 */
import { useEffect } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { DanmakuInput } from "../components/live/DanmakuInput";
import { DanmakuList } from "../components/live/DanmakuList";
import { LiveOwnerPanel } from "../components/live/LiveOwnerPanel";
import { LivePlayer } from "../components/live/LivePlayer";
import { useDanmaku } from "../hooks/useDanmaku";
import { useLiveRoom } from "../hooks/useLiveRoom";
import { useLiveStore } from "../stores/live";

export function LiveRoomPage() {
  const navigate = useNavigate();
  const params = useParams<{ channelId: string }>();
  const channelId = Number(params.channelId);
  const validId = Number.isInteger(channelId) && channelId > 0;

  const channel = useLiveStore((s) => s.current.channel);
  const srsStatus = useLiveStore((s) => s.current.srsStatus);
  const wsConnection = useLiveStore((s) => s.wsConnection);

  // 非法 id 直接回大厅（effect 中导航避免渲染期副作用）
  useEffect(() => {
    if (!validId) navigate("/live", { replace: true });
  }, [validId, navigate]);

  if (!validId) return null;
  return (
    <LiveRoomInner
      channelId={channelId}
      channel={channel}
      srsStatus={srsStatus}
      wsConnection={wsConnection}
      onBack={() => navigate("/live")}
      onDeleted={() => navigate("/live")}
    />
  );
}

function LiveRoomInner({
  channelId,
  channel,
  srsStatus,
  wsConnection,
  onBack,
  onDeleted,
}: {
  channelId: number;
  channel: ReturnType<typeof useLiveStore.getState>["current"]["channel"];
  srsStatus: ReturnType<typeof useLiveStore.getState>["current"]["srsStatus"];
  wsConnection: ReturnType<typeof useLiveStore.getState>["wsConnection"];
  onBack: () => void;
  onDeleted: () => void;
}) {
  const { loading, error, playerError, retryPlayer, videoRef } =
    useLiveRoom(channelId);
  const {
    sending,
    sendError,
    send,
    listRef,
    hasNewBelow,
    scrollToBottom,
  } = useDanmaku(channelId);
  const danmaku = useLiveStore((s) => s.current.danmaku);

  if (error) {
    return (
      <div className="live-room-error">
        <p>{error}</p>
        <button type="button" className="btn btn-glow" onClick={onBack}>
          返回大厅
        </button>
      </div>
    );
  }

  return (
    <div className="live-room">
      <main className="live-room-main">
        <div className="live-room-head">
          <button
            type="button"
            className="msg-action-btn"
            onClick={onBack}
            aria-label="返回大厅"
          >
            ← 大厅
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

        <LivePlayer
          srsStatus={srsStatus}
          optimisticStatus={channel?.status ?? null}
          playerError={playerError}
          videoRef={videoRef}
          onRetry={retryPlayer}
        />

        {channel?.is_owner && (
          <LiveOwnerPanel
            channel={channel}
            srsStatus={srsStatus}
            onDeleted={onDeleted}
          />
        )}
      </main>

      <aside className="live-room-side">
        <DanmakuList
          danmaku={danmaku}
          listRef={listRef}
          hasNewBelow={hasNewBelow}
          onScrollToBottom={scrollToBottom}
        />
        <DanmakuInput sending={sending} error={sendError} onSend={send} />
      </aside>
    </div>
  );
}
