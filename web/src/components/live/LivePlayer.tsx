/**
 * LivePlayer —— 播放器区域三态渲染（M5-4，文档 §4.3；直播体验增量）。
 *
 * - live → video 播放器（muted autoplay 起播，用户手势后取消静音）；**无原生控制条**
 *   （去进度条/倍速，B 站式纯直播观看），悬浮小按钮**非常态显示 + 无操作自动隐藏**：
 *   - 桌面：悬停/移动播放器显示、移出隐藏；触屏：点击视频显示；
 *   - 显示后 3s 无操作（鼠标静止/无点击）自动隐藏，鼠标移动或点按钮重置计时、不常驻；
 *   - 左下「刷新」：跳到直播最新画面（点击带旋转动画）；
 *   - 右下「画中画」+「全屏」：画中画保留小窗（支持才显示）；全屏对容器全屏，
 *     窄屏（手机）锁横屏、iOS 走原生视频全屏（webkitEnterFullscreen 自动横屏）。
 * - idle → "未开播"占位；degraded → "直播服务状态未知"；null → 加载中；
 * - 播放 fatal 错误与"未开播"严格区分：live 但播放失败 → "播放失败 + 重试"。
 */
import { useEffect, useRef, useState } from "react";
import type { LiveSrsStatus } from "../../api/types";
import { IconFullscreen, IconPip, IconRefresh } from "../icons";

/** 悬浮按钮无操作自动隐藏时长 */
const AUTO_HIDE_MS = 3000;

type SafariVideoElement = HTMLVideoElement & {
  webkitSetPresentationMode?: (mode: "picture-in-picture" | "inline") => Promise<void> | void;
  webkitPresentationMode?: "picture-in-picture" | "inline";
};

type FullscreenElement = HTMLDivElement & {
  webkitRequestFullscreen?: () => void;
};

type IosVideoElement = HTMLVideoElement & {
  webkitEnterFullscreen?: () => void;
};

/** 屏幕方向 API 的窄接口（TS lib.dom 的 ScreenOrientation 只有 unlock、无 lock，需自声明） */
type ScreenOrientationLike = {
  lock?: (orientation: string) => Promise<void>;
  unlock?: () => void;
};

/** 尝试锁横屏（窄屏全屏时）；桌面/不支持/权限拒绝时静默忽略 */
async function lockLandscape() {
  try {
    const so = (typeof screen !== "undefined" ? screen.orientation : undefined) as
      | ScreenOrientationLike
      | undefined;
    if (so && typeof so.lock === "function") {
      await so.lock("landscape");
    }
  } catch {
    // 锁屏失败（桌面浏览器 / 权限被拒）忽略
  }
}

/** 解锁屏幕方向（退出全屏时恢复） */
function unlockOrientation() {
  try {
    const so = (typeof screen !== "undefined" ? screen.orientation : undefined) as
      | ScreenOrientationLike
      | undefined;
    if (so && typeof so.unlock === "function") {
      so.unlock();
    }
  } catch {
    // 忽略
  }
}

export function LivePlayer({
  srsStatus,
  optimisticStatus,
  playerError,
  videoRef,
  onRetry,
  onRefresh,
}: {
  srsStatus: LiveSrsStatus | null;
  /** 频道乐观标记（idle 占位文案区分"等待推流信号"用） */
  optimisticStatus: "idle" | "live" | "ended" | null;
  playerError: string | null;
  videoRef: React.MutableRefObject<HTMLVideoElement | null>;
  onRetry: () => void;
  /** 跳到直播最新画面（左下角刷新键） */
  onRefresh: () => void;
}) {
  const [pipSupported, setPipSupported] = useState(false);
  const [controlsVisible, setControlsVisible] = useState(false);
  const [spinning, setSpinning] = useState(false);
  const containerRef = useRef<HTMLDivElement | null>(null);
  const spinTimer = useRef<number | null>(null);
  const hideTimer = useRef<number | null>(null);

  // 画中画支持检测（标准 API + Safari webkit 私有）：video 元素始终渲染（display 切换），
  // 挂载时即可读到；仅需检测一次。
  useEffect(() => {
    const video = videoRef.current as SafariVideoElement | null;
    if (!video) return;
    const supported =
      typeof document !== "undefined" &&
      (document.pictureInPictureEnabled === true ||
        typeof video.webkitSetPresentationMode === "function");
    setPipSupported(supported);
  }, [videoRef]);

  // 退出全屏（无论 ESC / 系统返回 / 点按钮）时解锁横屏
  useEffect(() => {
    const onFsChange = () => {
      if (!document.fullscreenElement) unlockOrientation();
    };
    document.addEventListener("fullscreenchange", onFsChange);
    return () => document.removeEventListener("fullscreenchange", onFsChange);
  }, []);

  // 卸载时清理刷新动画计时器 + 自动隐藏计时器
  useEffect(
    () => () => {
      if (spinTimer.current !== null) window.clearTimeout(spinTimer.current);
      if (hideTimer.current !== null) window.clearTimeout(hideTimer.current);
    },
    [],
  );

  // ---- 悬浮按钮显隐 + 无操作自动隐藏 ----
  const clearHideTimer = () => {
    if (hideTimer.current !== null) {
      window.clearTimeout(hideTimer.current);
      hideTimer.current = null;
    }
  };
  const armHideTimer = () => {
    clearHideTimer();
    hideTimer.current = window.setTimeout(() => setControlsVisible(false), AUTO_HIDE_MS);
  };
  const showControls = () => {
    setControlsVisible(true);
    armHideTimer();
  };
  const hideControls = () => {
    setControlsVisible(false);
    clearHideTimer();
  };

  const togglePip = async () => {
    armHideTimer(); // 点按钮 = 有动作，重置自动隐藏
    const video = videoRef.current as SafariVideoElement | null;
    if (!video) return;
    try {
      // Safari 私有画中画（无 requestPictureInPicture）：按当前呈现模式切换进入/退出
      if (typeof video.webkitSetPresentationMode === "function") {
        const inPip = video.webkitPresentationMode === "picture-in-picture";
        await video.webkitSetPresentationMode(inPip ? "inline" : "picture-in-picture");
        return;
      }
      // 标准画中画（Chrome/Firefox/Edge）
      if (document.pictureInPictureElement) {
        await document.exitPictureInPicture();
      } else if (video.requestPictureInPicture) {
        await video.requestPictureInPicture();
      }
    } catch {
      // 画中画被浏览器拒绝/不支持：静默降级，不打断观看
    }
  };

  const toggleFullscreen = async () => {
    armHideTimer(); // 点按钮 = 有动作，重置自动隐藏
    const el = containerRef.current as FullscreenElement | null;
    const video = videoRef.current as IosVideoElement | null;

    // 已全屏 → 退出并解锁横屏
    if (document.fullscreenElement) {
      try {
        await document.exitFullscreen();
      } catch {
        // 退出失败忽略
      }
      unlockOrientation();
      return;
    }

    try {
      // iOS Safari：webkitEnterFullscreen（原生视频全屏，自动横屏）
      if (video && typeof video.webkitEnterFullscreen === "function") {
        video.webkitEnterFullscreen();
        return;
      }
      // 标准全屏（安卓 Chrome / 桌面），全屏后锁横屏（窄屏横屏观看）
      if (el?.requestFullscreen) {
        await el.requestFullscreen();
        await lockLandscape();
        return;
      }
      if (el?.webkitRequestFullscreen) {
        el.webkitRequestFullscreen();
      }
    } catch {
      // 全屏被浏览器拒绝/不支持：静默降级
    }
  };

  const handleRefresh = () => {
    armHideTimer(); // 点按钮 = 有动作，重置自动隐藏
    if (spinning) return;
    setSpinning(true);
    onRefresh();
    // 旋转动画 0.6s 后复位；用计时器而非 onAnimationEnd，保证 prefers-reduced-motion
    // 下（动画被禁用）也能复位，不卡住后续点击。
    spinTimer.current = window.setTimeout(() => setSpinning(false), 650);
  };

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
    <div
      className="live-player"
      ref={containerRef}
      onMouseEnter={showControls}
      onMouseMove={showControls}
      onMouseLeave={hideControls}
    >
      <video
        ref={videoRef}
        className="live-player-video"
        style={{ display: showVideo ? "block" : "none" }}
        muted
        autoPlay
        playsInline
        onClick={showControls}
      />
      {showVideo && (
        <div className={`live-player-controls${controlsVisible ? " is-visible" : ""}`}>
          <button
            type="button"
            className={`live-player-btn live-player-refresh${spinning ? " is-spinning" : ""}`}
            onClick={handleRefresh}
            aria-label="跳到最新画面"
            title="跳到最新画面"
          >
            <IconRefresh width={16} height={16} />
          </button>
          <div className="live-player-corner">
            {pipSupported && (
              <button
                type="button"
                className="live-player-btn"
                onClick={togglePip}
                aria-label="画中画"
                title="画中画"
              >
                <IconPip width={16} height={16} />
              </button>
            )}
            <button
              type="button"
              className="live-player-btn"
              onClick={toggleFullscreen}
              aria-label="全屏"
              title="全屏"
            >
              <IconFullscreen width={16} height={16} />
            </button>
          </div>
        </div>
      )}
      {!showVideo && renderOverlay()}
    </div>
  );
}
