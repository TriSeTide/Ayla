/**
 * liveSessionRuntime —— 直播会话全局 owner（任务 05：直播适配手机端小窗）。
 *
 * 会话生命周期与页面解耦：进房/退房编排、HLS 播放器、video 元素、SRS 状态
 * 事件驱动补拉、弹幕 WS 回调全部归本单例持有；页面（LiveRoomBody）只是视图。
 *
 * 小窗模式：窄屏离开直播间页面且直播中 → 不销毁会话，video 元素从大窗容器
 * 迁移到 AppShell 下的小窗容器（同一元素，HLS 不断流不黑屏）；进入直播间
 * 页面 → 小窗让位，video 迁回大窗。关闭小窗/退出登录/切直播间 → 完整销毁。
 *
 * 唯一 owner：同一时间至多一个直播会话/小窗（AGENTS.md 工程约束）。
 */
import * as liveApi from "../api/live";
import type { DanmakuFrame } from "../api/types";
import { useLiveStore } from "../stores/live";
import { useAuthStore } from "../stores/auth";
import { liveWS } from "../ws/live";
import { chatWS } from "../ws/chat";
import { HlsPlayer } from "../player/hls";
import { useSessionActivityStore } from "../stores/sessionActivity";

/** 事件驱动 SRS 状态补拉：开播事件后推流建立有延迟，有界退避重试确认（非周期轮询） */
const SRS_RETRY_BASE_MS = 2_000;
const SRS_RETRY_MAX = 3;

/** 事件驱动黑屏/卡死检测：卡顿（waiting/stalled/error）持续多久未恢复则重建 */
const STALL_TIMEOUT_MS = 2_000;
/** 自动重建冷却（防 fatal 错误死循环） */
const REBUILD_COOLDOWN_MS = 4_000;

export interface LiveSessionOptions {
  activityRoute?: string;
  keepLiveActivity?: boolean;
  ownerConsoleRoute?: string;
}

class LiveSessionRuntime {
  // ---- 会话资源 ----
  private channelId: number | null = null;
  private options: LiveSessionOptions = {};
  private player: HlsPlayer | null = null;
  private videoEl: HTMLVideoElement | null = null;
  /** 开播事件后 SRS 状态有界退避重试（推流建立延迟；非周期轮询） */
  private srsRetryTimer: ReturnType<typeof setTimeout> | null = null;
  private srsRetryCount = 0;
  /** chat WS 状态帧订阅（live.channel.status.changed → 补拉 SRS 实时判定） */
  private offStatusFrame: (() => void) | null = null;
  private offFrame: (() => void) | null = null;
  private alive = false;
  private lastRebuildAt = 0;
  private tracksOwnerActivity = false;
  private stallTimer: ReturnType<typeof setTimeout> | null = null;
  private watchdogCleanup: (() => void) | null = null;
  /** video 的暂存容器（z-index:-1 视口内，不暂停）：容器切换间隙的临时落脚点 */
  private stagingEl: HTMLElement | null = null;
  /** 当前已挂载的 hls_url（attachPlayer 幂等判定：相同流不重建，切换场景零黑屏） */
  private currentHlsUrl: string | null = null;
  /** 大窗宿主容器（LivePlayer 挂载登记）：小窗卸载（点回直播间）时移交目标 */
  private bigHost: HTMLElement | null = null;

  get currentChannelId(): number | null {
    return this.channelId;
  }

  /** 当前是否处于小窗模式（store 镜像为权威 UI 状态） */
  get miniPlayerActive(): boolean {
    return useLiveStore.getState().miniPlayer !== null;
  }

  /** 获取全局 video 元素（手动创建，跨容器迁移；HLS attach 后元素移动不断流） */
  getVideoElement(): HTMLVideoElement | null {
    return this.videoEl;
  }

  /**
   * 把 video 原子移动到目标容器（大窗/小窗）。源容器与目标容器都在文档中时，
   * appendChild 是同一操作内的 remove+insert——video 不脱离文档，浏览器不暂停，
   * 大窗↔小窗/宽屏↔窄屏切换零黑屏、播放状态完全复用。
   * opts.big：登记为大窗宿主（小窗卸载时移交目标）。
   */
  attachVideoTo(container: HTMLElement, opts: { big?: boolean } = {}): void {
    const video = this.videoEl;
    if (!video || video.parentElement === container) return;
    if (opts.big) this.bigHost = container;
    container.appendChild(video);
    // 防御：万一 video 处于暂停（非容器切换导致），恢复播放
    if (video.paused) void video.play()?.catch(() => {});
  }

  /**
   * 把 video 移到暂存容器（z-index:-1 视口内 1px，不可见但不暂停）。
   * 由 LivePlayer/LiveMiniPlayer 的 useLayoutEffect cleanup 调用——React 在
   * DOM 移除前跑 layout cleanup，此时源容器仍在文档中 → 原子移动不脱离。
   * opts.big：大窗宿主卸载，清登记。
   */
  stashVideo(opts: { big?: boolean } = {}): void {
    const video = this.videoEl;
    if (opts.big) this.bigHost = null;
    if (!video) return;
    if (video.parentElement !== this.ensureStaging()) {
      this.ensureStaging().appendChild(video);
    }
  }

  /**
   * 小窗卸载（点回直播间）：若大窗宿主已挂载（LivePlayer 先于小窗挂载的时序），
   * 直接把 video 移交给大窗容器，避免滞留暂存不显示；否则正常 stash。
   */
  detachMiniPlayer(): void {
    const video = this.videoEl;
    if (!video) return;
    if (this.bigHost && this.bigHost.isConnected) {
      if (video.parentElement !== this.bigHost) this.bigHost.appendChild(video);
      return;
    }
    this.stashVideo();
  }

  private ensureStaging(): HTMLElement {
    if (!this.stagingEl) {
      const el = document.createElement("div");
      el.className = "live-video-staging";
      // 视口内（IntersectionObserver 视为可见 → 不暂停）但 z-index:-1 被内容盖住
      el.style.cssText =
        "position:fixed;left:0;top:0;width:1px;height:1px;z-index:-1;pointer-events:none;overflow:hidden;";
      document.body.appendChild(el);
      this.stagingEl = el;
    }
    return this.stagingEl;
  }

  // ---------- 生命周期 ----------

  /**
   * 进房（幂等：同频道不重复进；StrictMode 模拟重挂载安全）。
   * 同频道重挂载 = 从小窗点回直播间：退出小窗模式，video 由 LivePlayer 挂载时迁回。
   */
  enter(channelId: number, options: LiveSessionOptions = {}): void {
    if (this.channelId === channelId && this.alive) {
      this.options = options;
      if (useLiveStore.getState().miniPlayer) {
        useLiveStore.getState().setMiniPlayer(null);
      }
      return;
    }
    // 切频道：先完整销毁旧会话（含旧小窗）；首次进房无旧会话，跳过（leave 会无条件断 WS）
    if (this.channelId !== null) {
      this.leave();
    }
    this.channelId = channelId;
    this.options = options;
    this.alive = true;
    this.tracksOwnerActivity = false;
    // video 元素立即创建：LivePlayer 挂载时即可迁移进容器（loading 阶段 display:none）
    this.ensureVideo();
    const store = useLiveStore.getState();
    store.clearCurrent();
    store.setCurrentLoading(true);
    store.setCurrentError(null);
    store.setCurrentPlayerError(null);

    // 弹幕 WS 帧 → store（按 id 去重由 store 保证）
    this.offFrame = liveWS.onFrame((frame) => {
      if (frame.type !== "danmaku") return;
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
    });
    liveWS.onConnectionChange = (conn) => useLiveStore.getState().setWsConnection(conn);
    liveWS.onClosedByServer = (reason) => {
      if (!this.alive) return;
      if (reason === "unauthorized") useLiveStore.getState().setCurrentError("登录已过期，请重新登录");
      else if (reason === "channel_not_found") useLiveStore.getState().setCurrentError("直播间不存在");
    };
    // 重连成功 → 拉历史对账（WS 无补发语义，断线窗口弹幕补偿）+ 补拉 SRS 状态
    liveWS.onReconnected = () => {
      void this.reconcileDanmaku(channelId);
      void this.refreshSrsStatus(channelId);
    };

    void this.enterAsync(channelId);
    this.subscribeStatusEvents(channelId);
  }

  private async enterAsync(channelId: number): Promise<void> {
    const store = useLiveStore.getState();
    try {
      const channel = await liveApi.getLiveChannel(channelId);
      if (!this.alive || this.channelId !== channelId) return;
      store.setCurrentChannel(channel);
      this.tracksOwnerActivity = channel.owner_id === useAuthStore.getState().currentUser?.id;
      const existingActivity = useSessionActivityStore.getState().liveSession;
      const activityTarget =
        existingActivity?.sessionId === String(channel.id)
          ? existingActivity.sourceRoute
          : this.options.ownerConsoleRoute ?? `/live/start/${channelId}`;
      if (this.tracksOwnerActivity) {
        useSessionActivityStore.getState().upsert({
          kind: "live",
          sessionId: String(channel.id),
          sourceRoute: activityTarget,
          owner: channel.owner_id ?? null,
          title: channel.title,
          status: "connecting",
          lastError: null,
        });
      }

      const status = await liveApi.getLiveChannelStatus(channelId);
      if (!this.alive || this.channelId !== channelId) return;
      store.setSrsStatus(status.status);

      const history = await liveApi.listDanmaku(channelId, 50);
      if (!this.alive || this.channelId !== channelId) return;
      store.mergeDanmakuHistory(history);

      liveWS.connect(channelId);
      if (this.tracksOwnerActivity) {
        useSessionActivityStore.getState().setStatus(
          "live",
          status.status === "live" || useLiveStore.getState().current.channel?.status === "live"
            ? "connected"
            : "ended",
        );
      }
      store.setCurrentLoading(false);
    } catch (e) {
      if (!this.alive || this.channelId !== channelId) return;
      store.setCurrentError(e instanceof Error ? e.message : "加载直播间失败");
      if (this.tracksOwnerActivity) {
        useSessionActivityStore.getState().setStatus(
          "live",
          "failed",
          e instanceof Error ? e.message : "加载直播间失败",
        );
      }
      store.setCurrentLoading(false);
    }
  }

  /**
   * 视图分离（页面卸载）：窄屏 + 普通观看 + 直播中 → 进入小窗；否则完整销毁。
   * StrictMode 模拟卸载也会走到这里，随后重挂载由 enter 同频道分支接管（退出小窗）。
   */
  detachView(opts: { isNarrow: boolean; isOwnerConsole: boolean }): void {
    if (
      opts.isNarrow &&
      !opts.isOwnerConsole &&
      this.channelId !== null &&
      useLiveStore.getState().current.srsStatus === "live" &&
      useLiveStore.getState().currentPlayerError === null
    ) {
      this.enterMiniPlayer();
    } else {
      this.leave();
    }
  }



  private enterMiniPlayer(): void {
    if (this.channelId === null) return;
    useLiveStore.getState().setMiniPlayer({
      channelId: this.channelId,
      channel: useLiveStore.getState().current.channel,
      sourceRoute: this.options.activityRoute ?? `/live/${this.channelId}`,
    });
  }

  /**
   * 完整销毁（关闭小窗/退出登录/切频道）：hls → WS → 轮询 → 清 store → 活动态。
   * 幂等：无会话时静默返回。
   */
  leave(): void {
    this.alive = false;
    this.player?.destroy();
    this.player = null;
    this.offFrame?.();
    this.offFrame = null;
    liveWS.onConnectionChange = null;
    liveWS.onClosedByServer = null;
    liveWS.onReconnected = null;
    liveWS.disconnect();
    this.offStatusFrame?.();
    this.offStatusFrame = null;
    this.clearSrsRetry();
    this.clearStallTimer();
    const shouldKeepActivity =
      this.tracksOwnerActivity && useLiveStore.getState().current.channel?.status === "live";
    useLiveStore.getState().clearCurrent();
    if (this.tracksOwnerActivity && !shouldKeepActivity) {
      useSessionActivityStore.getState().clear("live", "idle");
    }
    this.tracksOwnerActivity = false;
    this.channelId = null;
    this.options = {};
    this.currentHlsUrl = null;
    this.bigHost = null;
    useLiveStore.getState().setCurrentLoading(false);
    useLiveStore.getState().setCurrentError(null);
    useLiveStore.getState().setCurrentPlayerError(null);
    useLiveStore.getState().setMiniPlayer(null);
    // video 元素销毁（从当前容器移除，下次进房重建）
    this.videoEl?.remove();
    this.videoEl = null;
  }

  // ---------- 播放器 ----------

  private ensureVideo(): HTMLVideoElement {
    if (!this.videoEl) {
      const v = document.createElement("video");
      v.className = "live-player-video";
      v.muted = true;
      v.autoplay = true;
      v.playsInline = true;
      this.videoEl = v;
      // 常驻暂存容器：永不脱离文档（脱离会暂停 → 容器切换黑屏）
      this.ensureStaging().appendChild(v);
    }
    return this.videoEl;
  }

  /** 挂载播放器：销毁旧实例 → 重新 attach（startLoad(-1) 从直播边缘起播 = 跳到最新）。
   *  幂等：相同 hls_url 已挂载 → 直接返回（小窗点回/StrictMode 重复触发时**不重建**，
   *  播放状态完全复用，切换零黑屏）。 */
  attachPlayer(): boolean {
    const video = this.ensureVideo();
    const hlsUrl = useLiveStore.getState().current.channel?.hls_url ?? null;
    if (!hlsUrl) return false;
    if (this.player && this.player.getMode() !== null && this.currentHlsUrl === hlsUrl) {
      // 防御：video 未在播放则恢复（容器迁移不应发生，兜底）
      if (video.paused) void video.play()?.catch(() => {});
      return true;
    }
    this.currentHlsUrl = hlsUrl;
    this.lastRebuildAt = Date.now();
    this.player?.destroy();
    this.player = new HlsPlayer();
    useLiveStore.getState().setCurrentPlayerError(null);
    this.player.attach(video, hlsUrl, {
      onFatalError: (detail) => {
        if (!this.alive) return;
        if (Date.now() - this.lastRebuildAt >= REBUILD_COOLDOWN_MS) {
          this.attachPlayer(); // fatal 自动重建（黑屏自动恢复）
        } else {
          // 冷却期内连续 fatal → 播放失败
          useLiveStore.getState().setCurrentPlayerError(detail);
        }
      },
    });
    this.armWatchdog(video);
    return true;
  }

  destroyPlayer(): void {
    this.player?.destroy();
    this.player = null;
    this.clearStallTimer();
    this.currentHlsUrl = null;
  }

  retryPlayer(): void {
    this.attachPlayer();
  }

  /** 左下角刷新键：健康播放跳边秒跳、黑屏/实例缺失重建兜底 */
  refreshPlayer(): void {
    const video = this.videoEl;
    const hlsUrl = useLiveStore.getState().current.channel?.hls_url ?? null;
    if (!video || !hlsUrl) return;
    if (
      this.player &&
      this.player.getMode() !== null &&
      video.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA
    ) {
      this.player.refreshToLiveEdge();
      return;
    }
    this.attachPlayer();
  }

  // ---------- 事件驱动黑屏/卡死自动重建（替代轮询） ----------
  // 监听 video 的 waiting/stalled/error（卡顿/黑屏信号），卡顿持续 STALL_TIMEOUT_MS
  // 未恢复（仍无帧/暂停）且冷却期已过 → 自动重建；playing/canplay 恢复即取消。
  private armWatchdog(video: HTMLVideoElement): void {
    this.clearStallTimer();
    const rebuildIfStuck = () => {
      if (Date.now() - this.lastRebuildAt < REBUILD_COOLDOWN_MS) return;
      if (video.readyState < HTMLMediaElement.HAVE_CURRENT_DATA || video.paused) {
        this.attachPlayer();
      }
    };
    const onStall = () => {
      if (this.stallTimer === null) {
        this.stallTimer = setTimeout(() => {
          this.stallTimer = null;
          rebuildIfStuck();
        }, STALL_TIMEOUT_MS);
      }
    };
    const onResume = () => {
      this.clearStallTimer();
      // 播放恢复（SRS 恢复/开播）→ 补拉一次 SRS 实时判定
      if (this.channelId !== null) void this.refreshSrsStatus(this.channelId);
    };
    const onError = () => {
      onStall(); // 保留黑屏自动重建语义
      // 播放错误（SRS 异常/未开播）→ 补拉一次 SRS 实时判定（可能 degraded/idle）
      if (this.channelId !== null) void this.refreshSrsStatus(this.channelId);
    };
    video.addEventListener("waiting", onStall);
    video.addEventListener("stalled", onStall);
    video.addEventListener("error", onError);
    video.addEventListener("playing", onResume);
    video.addEventListener("canplay", onResume);
    this.watchdogCleanup = () => {
      video.removeEventListener("waiting", onStall);
      video.removeEventListener("stalled", onStall);
      video.removeEventListener("error", onError);
      video.removeEventListener("playing", onResume);
      video.removeEventListener("canplay", onResume);
    };
  }

  private clearStallTimer(): void {
    if (this.stallTimer !== null) {
      clearTimeout(this.stallTimer);
      this.stallTimer = null;
    }
    this.watchdogCleanup?.();
    this.watchdogCleanup = null;
  }

  // ---------- SRS 状态：事件驱动补拉（替代 15s 轮询） ----------
  // SRS 实时判定（live/idle/degraded）是查询时事实、无事件源；改为在以下事件
  // 触发时补拉一次 GET /status/（无周期请求）：
  // - 进房（enterAsync 已拉一次）；
  // - chat WS live.channel.status.changed（开播/下播）；
  // - HLS 播放器 error（SRS 异常/未开播）与 playing/canplay（SRS 恢复/开播）；
  // - live WS 重连成功（对账）。
  // 开播事件后推流建立有延迟（SRS 检测需数秒），补拉非 live 时有界退避重试
  // （2s→4s→8s，最多 3 次），不是周期轮询。

  /** 订阅状态事件：chat WS 开播/下播帧 → 补拉 SRS 实时判定 */
  private subscribeStatusEvents(channelId: number): void {
    this.offStatusFrame?.();
    this.offStatusFrame = chatWS.onFrame((frame) => {
      if (frame.type !== "live.channel.status.changed") return;
      const d = frame.data;
      if (String(d.channel_id) !== String(channelId)) return;
      if (d.status === "live") {
        // 开播：推流建立有延迟，补拉非 live 时有界重试确认
        void this.refreshSrsStatus(channelId, { retryUntilLive: true });
      } else {
        void this.refreshSrsStatus(channelId);
      }
    });
  }

  /** 补拉一次 SRS 实时判定（事件触发；非周期） */
  private async refreshSrsStatus(
    channelId: number,
    opts: { retryUntilLive?: boolean } = {},
  ): Promise<void> {
    try {
      const status = await liveApi.getLiveChannelStatus(channelId);
      if (!this.alive || this.channelId !== channelId) return;
      useLiveStore.getState().setSrsStatus(status.status);
      // 小窗模式下直播结束 → 自动关闭小窗（完整销毁，避免小窗挂着已结束的流）
      if (useLiveStore.getState().miniPlayer && status.status !== "live") {
        this.leave();
        return;
      }
      if (status.status === "live") {
        this.clearSrsRetry();
      } else if (opts.retryUntilLive) {
        this.scheduleSrsRetry(channelId);
      }
    } catch {
      // 补拉失败不打断（下次事件再试）；SRS 不可用时后端自身返回 degraded
    }
  }

  /** 开播事件后 SRS 未就绪：有界退避重试（2s→4s→8s，最多 3 次） */
  private scheduleSrsRetry(channelId: number): void {
    if (this.srsRetryTimer !== null || this.srsRetryCount >= SRS_RETRY_MAX) return;
    const delay = SRS_RETRY_BASE_MS * 2 ** this.srsRetryCount;
    this.srsRetryCount += 1;
    this.srsRetryTimer = setTimeout(() => {
      this.srsRetryTimer = null;
      void this.refreshSrsStatus(channelId, { retryUntilLive: true });
    }, delay);
  }

  private clearSrsRetry(): void {
    if (this.srsRetryTimer !== null) {
      clearTimeout(this.srsRetryTimer);
      this.srsRetryTimer = null;
    }
    this.srsRetryCount = 0;
  }

  // ---------- 弹幕对账 ----------
  private async reconcileDanmaku(channelId: number): Promise<void> {
    try {
      const history = await liveApi.listDanmaku(channelId, 50);
      useLiveStore.getState().mergeDanmakuHistory(history);
    } catch {
      // 对账失败下次重连再试，不阻断实时流
    }
  }
}

/** 单例：直播间同时只需一个会话/小窗（唯一 owner） */
export const liveSessionRuntime = new LiveSessionRuntime();
