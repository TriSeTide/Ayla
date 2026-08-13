/**
 * useLiveRoom：进房/退房编排（M5-4，文档 §4.2）。
 *
 * 进房序列：详情 → SRS 实时状态 → 历史弹幕 → 连弹幕 WS；
 * 状态轮询：每 15s GET /status/（页面隐藏暂停，visibilitychange 恢复）；
 * 播放器：srsStatus=live 才 attach HLS；live↔idle 切换时重建/销毁；
 * 退房销毁清单（owner 语义）：hls.destroy() → 断 WS → 停轮询 → 清 store current。
 */
import { useEffect, useRef, useState } from "react";
import * as liveApi from "../api/live";
import type { DanmakuFrame } from "../api/types";
import { useLiveStore } from "../stores/live";
import { liveWS } from "../ws/live";
import { HlsPlayer } from "../player/hls";

export const LIVE_STATUS_POLL_INTERVAL_MS = 15_000;

export interface UseLiveRoomResult {
  loading: boolean;
  /** 进房失败（404 频道不存在 / 4401 未认证等）的提示文案 */
  error: string | null;
  /** 播放器 fatal 错误（与"未开播"区分；重试 = 重建播放器） */
  playerError: string | null;
  retryPlayer: () => void;
  videoRef: React.MutableRefObject<HTMLVideoElement | null>;
}

export function useLiveRoom(channelId: number): UseLiveRoomResult {
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [playerError, setPlayerError] = useState<string | null>(null);
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const playerRef = useRef<HlsPlayer | null>(null);
  /** 标记当前 effect 生命周期，异步回调落地前校验 */
  const aliveRef = useRef(true);

  const srsStatus = useLiveStore((s) => s.current.srsStatus);
  const hlsUrl = useLiveStore((s) => s.current.channel?.hls_url ?? null);

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

    (async () => {
      try {
        const channel = await liveApi.getLiveChannel(channelId);
        if (!aliveRef.current) return;
        useLiveStore.getState().setCurrentChannel(channel);

        const status = await liveApi.getLiveChannelStatus(channelId);
        if (!aliveRef.current) return;
        useLiveStore.getState().setSrsStatus(status.status);

        const history = await liveApi.listDanmaku(channelId, 50);
        if (!aliveRef.current) return;
        useLiveStore.getState().mergeDanmakuHistory(history);

        liveWS.connect(channelId);
        setLoading(false);
      } catch (e) {
        if (!aliveRef.current) return;
        setError(e instanceof Error ? e.message : "加载直播间失败");
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
      useLiveStore.getState().clearCurrent();
    };
  }, [channelId]);

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
  useEffect(() => {
    if (srsStatus !== "live" || !hlsUrl) {
      playerRef.current?.destroy();
      playerRef.current = null;
      return;
    }
    const video = videoRef.current;
    if (!video) return;
    if (!playerRef.current) playerRef.current = new HlsPlayer();
    setPlayerError(null);
    playerRef.current.attach(video, hlsUrl, {
      onFatalError: (detail) => {
        if (aliveRef.current) setPlayerError(detail);
      },
    });
    return () => {
      playerRef.current?.destroy();
      playerRef.current = null;
    };
  }, [srsStatus, hlsUrl]);

  const retryPlayer = () => {
    setPlayerError(null);
    const video = videoRef.current;
    if (!video || !hlsUrl) return;
    if (!playerRef.current) playerRef.current = new HlsPlayer();
    playerRef.current.attach(video, hlsUrl, {
      onFatalError: (detail) => {
        if (aliveRef.current) setPlayerError(detail);
      },
    });
  };

  return { loading, error, playerError, retryPlayer, videoRef };
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
