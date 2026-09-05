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
import { useEffect, useMemo, useRef } from "react";
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

  // 以下 UI 态只影响退房时「进小窗 or 完整销毁」的决策，不参与 effect 依赖：
  // isOwnerConsole（= 开播控制台 showOwnerPanel = Boolean(channel?.is_owner)）随 store
  // 的 current.channel 在进房瞬间被 clearCurrent() 清空而翻转；若放进 deps，每次翻转
  // 都会 cleanup(leave→清 channel) + setup(enter→再清 channel)，造成 enter/leave 死循环
  // （owner 进开播控制台时每轮 3 个 API + WS connect/close，最终 ERR_INSUFFICIENT_RESOURCES
  // 页面 Failed to fetch。回归：c78c27f 将 isOwnerConsole 加入 deps）。
  // 用 ref 取最新值，effect 只在 channelId/activityRoute 变化（真实进房/切房）时重跑。
  const isNarrowRef = useRef(isNarrow);
  isNarrowRef.current = isNarrow;
  const isOwnerConsoleRef = useRef(isOwnerConsole);
  isOwnerConsoleRef.current = isOwnerConsole;
  const keepLiveActivityRef = useRef(options.keepLiveActivity);
  keepLiveActivityRef.current = options.keepLiveActivity;

  const loading = useLiveStore((s) => s.currentLoading);
  const error = useLiveStore((s) => s.currentError);
  const playerError = useLiveStore((s) => s.currentPlayerError);
  const srsStatus = useLiveStore((s) => s.current.srsStatus);
  const hlsUrl = useLiveStore((s) => s.current.channel?.hls_url ?? null);

  // 挂载进房 / 卸载分离视图（小窗或销毁）；channelId 变化 = 切台，先销毁旧会话再进新房
  // epoch：enter 返回的会话代际，cleanup 回传——页面间切换（群内/浮层返回/直播间→控制台）
  // 时 AnimatePresence 新旧页并存，旧页 cleanup 的 detachView 携带旧 epoch 会被 runtime
  // 拒绝，避免清掉新页刚建立的会话（2026-09-06 事故第三层：跨页进入复现）。
  useEffect(() => {
    const epoch = liveSessionRuntime.enter(channelId, {
      activityRoute,
      keepLiveActivity: keepLiveActivityRef.current,
      ownerConsoleRoute,
    });
    return () => {
      liveSessionRuntime.detachView({
        epoch,
        isNarrow: isNarrowRef.current,
        isOwnerConsole: isOwnerConsoleRef.current,
      });
    };
  }, [channelId, activityRoute, ownerConsoleRoute]);

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
