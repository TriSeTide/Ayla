/**
 * LivePlayer —— 播放器区域三态渲染（M5-4，文档 §4.3）。
 *
 * - live → video 播放器（muted autoplay 起播，用户手势后取消静音）；
 * - idle → "未开播"占位（乐观已开播但 SRS 无流时提示"等待推流信号…"）；
 * - degraded → "直播服务状态未知"中性提示（禁止渲染成"未开播"）；
 * - null（尚未查询）→ 加载中；
 * - 播放 fatal 错误与"未开播"严格区分：live 但播放失败 → "播放失败 + 重试"。
 */
import type { LiveSrsStatus } from "../../api/types";

export function LivePlayer({
  srsStatus,
  optimisticStatus,
  playerError,
  videoRef,
  onRetry,
}: {
  srsStatus: LiveSrsStatus | null;
  /** 频道乐观标记（idle 占位文案区分"等待推流信号"用） */
  optimisticStatus: "idle" | "live" | "ended" | null;
  playerError: string | null;
  videoRef: React.MutableRefObject<HTMLVideoElement | null>;
  onRetry: () => void;
}) {
  const renderOverlay = () => {
    if (srsStatus === null) {
      return <div className="live-player-placeholder">正在查询直播状态…</div>;
    }
    if (srsStatus === "degraded") {
      return (
        <div className="live-player-placeholder live-player-degraded">
          直播服务状态未知，请稍后再试
        </div>
      );
    }
    if (srsStatus === "idle") {
      // 乐观已开播但 SRS 无流：推流尚未到达（秒级延迟）
      const waiting = optimisticStatus === "live";
      return (
        <div className="live-player-placeholder">
          {waiting ? "等待推流信号…" : "主播未开播"}
        </div>
      );
    }
    // live：播放器可见；fatal 错误覆盖重试按钮
    if (playerError) {
      return (
        <div className="live-player-placeholder live-player-error">
          <span>播放失败</span>
          <button type="button" className="btn btn-glow" onClick={onRetry}>
            重试
          </button>
        </div>
      );
    }
    return null;
  };

  const showVideo = srsStatus === "live" && !playerError;

  return (
    <div className="live-player">
      <video
        ref={videoRef}
        className="live-player-video"
        style={{ display: showVideo ? "block" : "none" }}
        muted
        autoPlay
        playsInline
        controls
      />
      {!showVideo && renderOverlay()}
    </div>
  );
}
