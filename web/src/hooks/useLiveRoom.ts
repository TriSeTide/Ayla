/**
 * useLiveRoom：进房/退房编排（M5-4，文档 §4.2；黑屏自动恢复增量）。
 *
 * 进房序列：详情 → SRS 实时状态 → 历史弹幕 → 连弹幕 WS；
 * 状态轮询：每 15s GET /status/（页面隐藏暂停，visibilitychange 恢复）；
 * 播放器：srsStatus=live 才 attach HLS；live↔idle 切换时重建/销毁；
 *   - videoRef 粘性代理 + videoVersion 重建信号：video 元素重建（切台动画/宽窄屏切换）即重新 attach，
 *     不依赖轮询，video 挂载即接上，根治「video 重建但 effect 不重跑 → 永久黑屏」；
 *   - fatal 错误冷却期后自动重建；
 *   - 事件驱动黑屏/卡死检测：监听 video waiting/stalled/error，卡顿超时未恢复即重建（替代轮询）；
 *   - 刷新键主功能 = 跳边跟上直播进度，黑屏时顺便重建兜底；
 * 退房销毁清单（owner 语义）：hls.destroy() → 断 WS → 停轮询 → 清 store current。
 */
import { useEffect, useMemo, useRef, useState } from "react";
import * as liveApi from "../api/live";
import type { DanmakuFrame } from "../api/types";
import { useLiveStore } from "../stores/live";
import { useAuthStore } from "../stores/auth";
import { liveWS } from "../ws/live";
import { HlsPlayer } from "../player/hls";
import { useSessionActivityStore } from "../stores/sessionActivity";

export const LIVE_STATUS_POLL_INTERVAL_MS = 15_000;

/** 事件驱动黑屏/卡死检测：卡顿（waiting/stalled/error）持续多久未恢复则重建 */
const STALL_TIMEOUT_MS = 2_000;
/** 自动重建冷却（防 fatal 错误死循环） */
const REBUILD_COOLDOWN_MS = 4_000;

export interface UseLiveRoomResult {
  loading: boolean;
  /** 进房失败（404 频道不存在 / 4401 未认证等）的提示文案 */
  error: string | null;
  /** 播放器 fatal 错误（与"未开播"区分；重试 = 重建播放器） */
  playerError: string | null;
  retryPlayer: () => void;
  /** 左下角刷新键：健康播放跳边秒跳、黑屏/实例缺失重建兜底 */
  refreshPlayer: () => void;
  videoRef: React.MutableRefObject<HTMLVideoElement | null>;
}

export function useLiveRoom(
  channelId: number,
  options: { activityRoute?: string; keepLiveActivity?: boolean } = {},
): UseLiveRoomResult {
  const activityRoute = options.activityRoute ?? `/live/${channelId}`;
  const ownerConsoleRoute = activityRoute.startsWith("/live/start/")
    ? activityRoute
    : `/live/start/${channelId}`;
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [playerError, setPlayerError] = useState<string | null>(null);
  const realVideoRef = useRef<HTMLVideoElement | null>(null);
  // 粘性 ref 代理 + 重建信号：沉浸式上下滑切台（AnimatePresence mode="sync"）/ 宽窄屏切换时，
  // 旧 video 卸载（React 把共享 ref 置 null，忽略）、新 video 挂载——忽略 null 写入保证
  // videoRef.current 始终指向最新 video；新 video 挂载时 setVideoVersion 触发播放器 effect
  // 重新 attach 到新 video（否则 effect 依赖 srsStatus/hlsUrl 不变，video 重建后不会重 attach → 黑屏）。
  const [videoVersion, setVideoVersion] = useState(0);
  const videoRef: React.MutableRefObject<HTMLVideoElement | null> = useMemo(
    () => ({
      get current() {
        return realVideoRef.current;
      },
      set current(v: HTMLVideoElement | null) {
        if (v !== null && v !== realVideoRef.current) {
          realVideoRef.current = v;
          setVideoVersion((x) => x + 1);
        }
      },
    }),
    [],
  );
  const playerRef = useRef<HlsPlayer | null>(null);
  /** 标记当前 effect 生命周期，异步回调落地前校验 */
  const aliveRef = useRef(true);
  /** 上次重建播放器时间戳（fatal/watchdog 自动重建的冷却防抖） */
  const lastRebuildAtRef = useRef(0);

  const srsStatus = useLiveStore((s) => s.current.srsStatus);
  const hlsUrl = useLiveStore((s) => s.current.channel?.hls_url ?? null);

  /**
   * 挂载播放器：销毁旧实例 → 重新 attach（startLoad(-1) 从直播边缘起播 = 跳到最新）。
   * fatal 且冷却期已过 → 自动重建（黑屏自动恢复）；冷却期内连续 fatal → 上报「播放失败」。
   * 返回是否成功挂载（video 未就绪 / 无流返回 false，供轮询重试判断）。
   */
  const attachPlayer = () => {
    const video = videoRef.current;
    if (!video || !hlsUrl) return false;
    lastRebuildAtRef.current = Date.now();
    playerRef.current?.destroy();
    playerRef.current = new HlsPlayer();
    setPlayerError(null);
    playerRef.current.attach(video, hlsUrl, {
      onFatalError: (detail) => {
        if (!aliveRef.current) return;
        if (Date.now() - lastRebuildAtRef.current >= REBUILD_COOLDOWN_MS) {
          attachPlayer(); // fatal 自动重建（黑屏自动恢复）
        } else {
          setPlayerError(detail); // 冷却期内连续 fatal → 播放失败
        }
      },
    });
    return true;
  };

  // ---------- 进房 / 退房 ----------
  useEffect(() => {
    aliveRef.current = true;
    const live = useLiveStore.getState();
    live.clearCurrent();
    setLoading(true);
    setError(null);
    setPlayerError(null);

    // 弹幕 WS 帧 → store（按 id 去重由 store 保证）
    const offFrame = liveWS.onFrame((frame) => {
      if (frame.type === "danmaku") {
        const f = frame as DanmakuFrame;
        useLiveStore.getState().appendDanmaku({
          id: f.id,
          sender: {
            user_id: f.sender.id,
            nickname: f.sender.nickname,
            avatar: f.sender.avatar ?? "",
          },
          content: f.content,
          media_id: f.media_id ?? null,
          media: f.media ?? null,
          created_at: f.created_at,
        });
      }
    });
    liveWS.onConnectionChange = (conn) =>
      useLiveStore.getState().setWsConnection(conn);
    liveWS.onClosedByServer = (reason) => {
      if (!aliveRef.current) return;
      if (reason === "unauthorized") setError("登录已过期，请重新登录");
      else if (reason === "channel_not_found") setError("直播间不存在");
    };
    // 重连成功 → 拉历史对账（WS 无补发语义，断线窗口弹幕补偿）
    liveWS.onReconnected = () => {
      void reconcileDanmaku(channelId);
    };

    let tracksOwnerActivity = false;
    (async () => {
      try {
        const channel = await liveApi.getLiveChannel(channelId);
        if (!aliveRef.current) return;
        useLiveStore.getState().setCurrentChannel(channel);
        tracksOwnerActivity = channel.owner_id === useAuthStore.getState().currentUser?.id;
        const existingActivity = useSessionActivityStore.getState().liveSession;
        const activityTarget =
          existingActivity?.sessionId === String(channel.id)
            ? existingActivity.sourceRoute
            : ownerConsoleRoute;
        if (tracksOwnerActivity) useSessionActivityStore.getState().upsert({
          kind: "live",
          sessionId: String(channel.id),
          sourceRoute: activityTarget,
          owner: channel.owner_id ?? null,
          title: channel.title,
          status: "connecting",
          lastError: null,
        });

        const status = await liveApi.getLiveChannelStatus(channelId);
        if (!aliveRef.current) return;
        useLiveStore.getState().setSrsStatus(status.status);

        const history = await liveApi.listDanmaku(channelId, 50);
        if (!aliveRef.current) return;
        useLiveStore.getState().mergeDanmakuHistory(history);

        liveWS.connect(channelId);
        if (tracksOwnerActivity) {
          useSessionActivityStore.getState().setStatus(
            "live",
            status.status === "live" || useLiveStore.getState().current.channel?.status === "live"
              ? "connected"
              : "ended",
          );
        }
        setLoading(false);
      } catch (e) {
        if (!aliveRef.current) return;
        setError(e instanceof Error ? e.message : "加载直播间失败");
        if (tracksOwnerActivity) {
          useSessionActivityStore.getState().setStatus("live", "failed", e instanceof Error ? e.message : "加载直播间失败");
        }
        setLoading(false);
      }
    })();

    // 退房销毁清单：hls → WS → 轮询（下方 effect 清理）→ 清 store
    return () => {
      aliveRef.current = false;
      playerRef.current?.destroy();
      playerRef.current = null;
      offFrame();
      liveWS.onConnectionChange = null;
      liveWS.onClosedByServer = null;
      liveWS.onReconnected = null;
      liveWS.disconnect();
      const shouldKeepActivity = tracksOwnerActivity && useLiveStore.getState().current.channel?.status === "live";
      useLiveStore.getState().clearCurrent();
      if (tracksOwnerActivity && !shouldKeepActivity) useSessionActivityStore.getState().clear("live", "idle");
    };
  }, [activityRoute, channelId, ownerConsoleRoute]);

  // ---------- 状态轮询（15s，页面隐藏暂停） ----------
  useEffect(() => {
    let timer: ReturnType<typeof setInterval> | null = null;

    const poll = async () => {
      try {
        const status = await liveApi.getLiveChannelStatus(channelId);
        if (!aliveRef.current) return;
        useLiveStore.getState().setSrsStatus(status.status);
      } catch {
        // 轮询失败不打断（下次再试）；SRS 不可用时后端自身返回 degraded
      }
    };

    const start = () => {
      if (timer) return;
      timer = setInterval(() => void poll(), LIVE_STATUS_POLL_INTERVAL_MS);
    };
    const stop = () => {
      if (timer) {
        clearInterval(timer);
        timer = null;
      }
    };
    const onVisibility = () => {
      if (document.hidden) stop();
      else {
        void poll();
        start();
      }
    };

    start();
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      stop();
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [channelId]);

  // ---------- 播放器：srsStatus=live 才 attach；idle/degraded 销毁 ----------
  // video 元素重建（切台动画 / 宽窄屏切换）会经 videoVersion 信号触发本 effect 重跑，
  // 重新 attach 到新 video——不依赖轮询，video 挂载即 attach。
  useEffect(() => {
    if (srsStatus !== "live" || !hlsUrl) {
      playerRef.current?.destroy();
      playerRef.current = null;
      return;
    }
    if (realVideoRef.current) {
      attachPlayer();
    }
    return () => {
      playerRef.current?.destroy();
      playerRef.current = null;
    };
  }, [srsStatus, hlsUrl, videoVersion]);

  // ---------- 事件驱动黑屏/卡死自动重建（替代轮询） ----------
  // 监听 video 的 waiting/stalled/error（卡顿/黑屏信号），卡顿持续 STALL_TIMEOUT_MS
  // 未恢复（仍无帧/暂停）且冷却期已过 → 自动重建；playing/canplay 恢复即取消。
  // 事件驱动：正常播放零开销，黑屏发生的瞬间（事件）就启动重载计时，不用轮询去猜。
  useEffect(() => {
    if (srsStatus !== "live") return;
    const video = realVideoRef.current;
    if (!video) return;

    let stallTimer: number | null = null;

    const rebuildIfStuck = () => {
      if (Date.now() - lastRebuildAtRef.current < REBUILD_COOLDOWN_MS) return;
      if (video.readyState < HTMLMediaElement.HAVE_CURRENT_DATA || video.paused) {
        attachPlayer();
      }
    };
    const onStall = () => {
      if (stallTimer === null) {
        stallTimer = window.setTimeout(() => {
          stallTimer = null;
          rebuildIfStuck();
        }, STALL_TIMEOUT_MS);
      }
    };
    const onResume = () => {
      if (stallTimer !== null) {
        window.clearTimeout(stallTimer);
        stallTimer = null;
      }
    };

    video.addEventListener("waiting", onStall);
    video.addEventListener("stalled", onStall);
    video.addEventListener("error", onStall);
    video.addEventListener("playing", onResume);
    video.addEventListener("canplay", onResume);

    return () => {
      if (stallTimer !== null) window.clearTimeout(stallTimer);
      video.removeEventListener("waiting", onStall);
      video.removeEventListener("stalled", onStall);
      video.removeEventListener("error", onStall);
      video.removeEventListener("playing", onResume);
      video.removeEventListener("canplay", onResume);
    };
  }, [srsStatus, hlsUrl, videoVersion]);

  const retryPlayer = () => {
    attachPlayer();
  };

  /** 左下角刷新键：主要功能 = 跟上直播当前进度（跳边秒跳）；
   *  黑屏/实例缺失时顺便重建（自动恢复兜底，平时由 watchdog 接管）。 */
  const refreshPlayer = () => {
    const video = videoRef.current;
    const player = playerRef.current;
    if (!video || !hlsUrl) return;
    if (
      player &&
      player.getMode() !== null &&
      video.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA
    ) {
      player.refreshToLiveEdge();
      return;
    }
    attachPlayer();
  };

  return { loading, error, playerError, retryPlayer, refreshPlayer, videoRef };
}

/** 重连对账：拉最近历史按 id 合并去重（断线窗口弹幕补偿） */
async function reconcileDanmaku(channelId: number) {
  try {
    const history = await liveApi.listDanmaku(channelId, 50);
    useLiveStore.getState().mergeDanmakuHistory(history);
  } catch {
    // 对账失败下次重连再试，不阻断实时流
  }
}
