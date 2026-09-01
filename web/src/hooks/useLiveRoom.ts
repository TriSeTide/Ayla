/**
 * useLiveRoom：进房/退房编排的 React 视图绑定（M5-4 §4.2；任务 05 小窗改造）。
 *
 * 会话资源（HLS/SRS 状态/WS/video 元素）已提升到 liveSessionRuntime 全局单例：
 * - 挂载 → runtime.enter(channelId)（同频道幂等；从小窗点回时自动退出小窗模式）；
 * - 卸载 → runtime.detachView({ isNarrow, isOwnerConsole })：窄屏普通观看且直播中
 *   → 进入手机端小窗（video 元素迁移到 AppShell 小窗容器，HLS 不断流）；否则完整销毁；
 * - 播放器 attach 由 srsStatus/hlsUrl 变化驱动（video 元素唯一、跨容器迁移，不再重建，
 *   因此不再需要 videoVersion 重建信号）；
 * - loading/error/playerError 从 live store 读取（runtime 写入）。
 */
import { useEffect, useMemo } from "react";
import { useLiveStore } from "../stores/live";
import { liveSessionRuntime } from "../runtime/liveSessionRuntime";

export interface UseLiveRoomResult {
  loading: boolean;
  /** 进房失败（404 频道不存在 / 4401 未认证等）的提示文案 */
  error: string | null;
  /** 播放器 fatal 错误（与"未开播"区分；重试 = 重建播放器） */
  playerError: string | null;
  retryPlayer: () => void;
  /** 左下角刷新键：健康播放跳边秒跳、黑屏/实例缺失重建兜底 */
  refreshPlayer: () => void;
  /** 指向 runtime 全局 video 元素（LivePlayer 挂载时迁移进容器） */
  videoRef: React.MutableRefObject<HTMLVideoElement | null>;
}

export function useLiveRoom(
  channelId: number,
  options: {
    activityRoute?: string;
    keepLiveActivity?: boolean;
    /** 窄屏判定（小窗触发条件之一） */
    isNarrow?: boolean;
    /** 主播开播控制台（不触发小窗，保持活动态悬浮球） */
    isOwnerConsole?: boolean;
  } = {},
): UseLiveRoomResult {
  const activityRoute = options.activityRoute ?? `/live/${channelId}`;
  const ownerConsoleRoute = activityRoute.startsWith("/live/start/")
    ? activityRoute
    : `/live/start/${channelId}`;
  const isNarrow = options.isNarrow ?? false;
  const isOwnerConsole = options.isOwnerConsole ?? false;

  const loading = useLiveStore((s) => s.currentLoading);
  const error = useLiveStore((s) => s.currentError);
  const playerError = useLiveStore((s) => s.currentPlayerError);
  const srsStatus = useLiveStore((s) => s.current.srsStatus);
  const hlsUrl = useLiveStore((s) => s.current.channel?.hls_url ?? null);

  // 挂载进房 / 卸载分离视图（小窗或销毁）；channelId 变化 = 切台，先销毁旧会话再进新房
  useEffect(() => {
    liveSessionRuntime.enter(channelId, { activityRoute, keepLiveActivity: options.keepLiveActivity, ownerConsoleRoute });
    return () => {
      liveSessionRuntime.detachView({ isNarrow, isOwnerConsole });
    };
  }, [channelId, activityRoute, ownerConsoleRoute, isNarrow, isOwnerConsole, options.keepLiveActivity]);

  // 播放器：srsStatus=live 才 attach；idle/degraded 销毁。
  // **小窗模式（页面卸载但会话保留）下不销毁播放器**——video/src/HLS 全部保留，
  // 只有 video 元素在容器间原子移动，切换零黑屏；直播结束由轮询 leave 兜底销毁。
  useEffect(() => {
    const inMini = () => useLiveStore.getState().miniPlayer !== null;
    if (srsStatus !== "live" || !hlsUrl) {
      if (!inMini()) liveSessionRuntime.destroyPlayer();
      return;
    }
    liveSessionRuntime.attachPlayer();
    return () => {
      if (!inMini()) liveSessionRuntime.destroyPlayer();
    };
  }, [srsStatus, hlsUrl]);

  // 粘性 ref 代理：指向 runtime 的全局 video 元素；LivePlayer 挂载时把它迁移进容器。
  // 忽略 null 写入（React 卸载时把共享 ref 置 null 的常规行为，元素由 runtime 管理）。
  const videoRef: React.MutableRefObject<HTMLVideoElement | null> = useMemo(
    () => ({
      get current() {
        return liveSessionRuntime.getVideoElement();
      },
      set current(_v: HTMLVideoElement | null) {
        // video 元素生命周期归 runtime，React 侧不接管
      },
    }),
    [],
  );

  return {
    loading,
    error,
    playerError,
    retryPlayer: () => liveSessionRuntime.retryPlayer(),
    refreshPlayer: () => liveSessionRuntime.refreshPlayer(),
    videoRef,
  };
}
