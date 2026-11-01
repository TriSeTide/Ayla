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
import type { DanmakuFrame, LiveViewersFrame } from "../api/types";
import { useLiveStore } from "../stores/live";
import { useAuthStore } from "../stores/auth";
import { liveWS } from "../ws/live";
import { chatWS } from "../ws/chat";
import { HlsPlayer } from "../player/hls";
import { useSessionActivityStore } from "../stores/sessionActivity";

/** 事件驱动 SRS 状态补拉：开播事件后推流建立有延迟，有界退避重试确认（非周期轮询） */
const SRS_RETRY_BASE_MS = 2_000;
const SRS_RETRY_MAX = 3;

/** 进房快照写入 store 的预览上限（与后端 WS 帧上限一致；完整名单走弹层 REST） */
const LIVE_VIEWER_PREVIEW = 12;

/** 事件驱动黑屏/卡死检测：卡顿（waiting/stalled/error）持续多久未恢复则重建 */
const STALL_TIMEOUT_MS = 2_000;
/** 自动重建冷却（防 fatal 错误死循环） */
const REBUILD_COOLDOWN_MS = 4_000;
/**
 * 自愈连续失败计数的时间窗（B2，与 Flutter 端 kRebuildCountResetWindow 同语义）：
 * 距上次自愈失败超过该时长 ⇒ 视为新一轮，连续失败计数归零。**没有它就会永久放弃**：
 * 计数只涨不落，一旦封顶，之后任何一次失败都进不了重建分支，直播停在"播放失败"。
 */
const REBUILD_COUNT_RESET_WINDOW_MS = 60_000;
/**
 * 自动重建连续失败上限（B2）：达到上限 = 本次自愈封顶，此时不再无限重建，
 * 但**不放弃**——安排 REBUILD_COUNT_RESET_WINDOW_MS 后的有界重试。
 */
const MAX_CONSECUTIVE_REBUILDS = 3;

export interface LiveSessionOptions {
  activityRoute?: string;
  keepLiveActivity?: boolean;
  ownerConsoleRoute?: string;
}

class LiveSessionRuntime {
  // ---- 会话资源 ----
  private channelId: number | null = null;
  private options: LiveSessionOptions = {};
  /**
   * 会话代际（epoch）：每次「完整进房」递增，enter 返回给调用方（useLiveRoom effect）。
   * detachView/leave 携带调用方持有的 epoch，仅当与当前 epoch 一致才真正销毁——
   * 页面间路由切换（群内→开播控制台、浮层返回控制台、直播间→控制台）时，
   * AnimatePresence(mode="sync") 新旧页并存，旧页卸载 cleanup 的 leave 若无条件执行，
   * 会清掉新页刚建立的会话（alive/channelId/clearCurrent/断 WS），新页 enterAsync 的
   * alive 检查提前 return，channel 永不设置 → 控制台退化 + 弹幕断开（2026-09-06 事故第三层）。
   */
  private epoch = 0;
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
  /** 连续自动重建失败次数（B2）：播放恢复出帧时归零，进入新时间窗时也归零 */
  private consecutiveRebuilds = 0;
  /** 最近一次自愈失败时刻（B2 时间窗判定基准） */
  private lastFailureAt = 0;
  /**
   * 封顶后的延迟重试定时器（B2，有界、防重入）：同一时间至多一个；
   * 只在当前仍是同一路流、且仍不健康时执行一次重建。
   */
  private healRetryTimer: ReturnType<typeof setTimeout> | null = null;
  private tracksOwnerActivity = false;
  private stallTimer: ReturnType<typeof setTimeout> | null = null;
  private watchdogCleanup: (() => void) | null = null;
  /** video 的暂存容器（z-index:-1 视口内，不暂停）：容器切换间隙的临时落脚点 */
  private stagingEl: HTMLElement | null = null;
  /** 当前已挂载的 hls_url（attachPlayer 幂等判定：相同流不重建，切换场景零黑屏） */
  private currentHlsUrl: string | null = null;
  /** 大窗宿主容器（LivePlayer 挂载登记）：小窗卸载（点回直播间）时移交目标 */
  private bigHost: HTMLElement | null = null;
  /** Views own these subscriptions; the runtime reports gaps without replaying history. */
  private historyListeners = new Set<(channelId: number) => void>();

  onHistoryInvalidated(listener: (channelId: number) => void): () => void {
    this.historyListeners.add(listener);
    return () => { this.historyListeners.delete(listener); };
  }

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
   *
   * @returns 本次进房的会话代际（当前活跃 epoch）；调用方须持有并在 detachView 时回传。
   */
  enter(channelId: number, options: LiveSessionOptions = {}): number {
    if (this.channelId === channelId && this.alive) {
      this.options = options;
      if (useLiveStore.getState().miniPlayer) {
        useLiveStore.getState().setMiniPlayer(null);
      }
      // 同频道重复进入 = 会话被**新视图**接管：代际前移，使更早视图尚未执行的
      // detachView(旧 epoch) 被拒绝。
      // 为什么必须前移：宽窄屏切换会让页面渲染两棵结构不同的树（GroupPage 三列 vs
      // 单列、LiveRoomPage 同理），新旧视图并存且挂载可能先于卸载。此时新视图 enter
      // 走本分支拿到**同一个** epoch，旧视图 cleanup 的 detachView 因而通过校验，
      // 把刚被接管的会话 leave 掉——store 当前频道被清空（头部退化为"直播间"、
      // 在看观众条消失），而新视图 effect 依赖未变、不会重进房，状态不再自愈。
      // StrictMode 的 挂载→卸载→挂载 顺序不受影响：cleanup 在第二次 enter 之前执行。
      this.epoch += 1;
      return this.epoch;
    }
    // 切频道：先完整销毁旧会话（含旧小窗）；首次进房无旧会话，跳过（leave 会无条件断 WS）
    if (this.channelId !== null) {
      this.leave();
    }
    const epoch = ++this.epoch;
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

    // 弹幕 WS 帧 → store（按 id 去重由 store 保证）；在看人数帧 → 人数 + 头像预览
    this.offFrame = liveWS.onFrame((frame) => {
      if (frame.type === "viewers") {
        const v = frame as LiveViewersFrame;
        // 切台竞态：只接受当前会话频道的帧（旧连接可能仍在关闭途中）
        if (this.channelId !== null && String(v.channel_id) !== String(this.channelId)) return;
        useLiveStore.getState().setViewers(v.channel_id, v.count, v.viewers ?? []);
        return;
      }
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
    // WS 无补发语义：提醒可见历史补读，禁止把旧历史注入实时 overlay。
    liveWS.onReconnected = () => {
      if (!this.alive || this.channelId !== channelId) return;
      this.historyListeners.forEach((listener) => listener(channelId));
      void this.refreshSrsStatus(channelId);
      // WS 无补发语义：重连后补读一次在看人数快照（断线期间的增减不补发）。
      void this.refreshViewers(channelId);
    };

    void this.enterAsync(channelId);
    this.subscribeStatusEvents(channelId);
    return epoch;
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

      // Historical pages belong to the visible reading window, never the flying overlay.
      liveWS.connect(channelId);
      // 在看人数权威快照：弹幕 WS 还没连上/掉线时人数依然正确。必须晚于
      // setCurrentChannel——store 的 setViewers 只认当前直播间（切台竞态防御）。
      void this.refreshViewers(channelId);
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
   * @param opts.epoch 调用方持有的会话代际（enter 返回值）；与当前 epoch 不一致
   *   （会话已被更新页面接管）时不销毁也不进小窗，避免旧页 cleanup 清掉新页会话。
   */
  detachView(opts: { isNarrow: boolean; isOwnerConsole: boolean; epoch?: number }): void {
    if (
      opts.epoch !== undefined &&
      opts.epoch !== this.epoch
    ) {
      return;
    }
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
   * @param epoch 调用方持有的会话代际；非 undefined 且与当前 epoch 不一致时不销毁
   *   （该调用方已不是当前会话 owner，会话已被更新的 enter 接管）。
   */
  leave(epoch?: number): void {
    if (epoch !== undefined && epoch !== this.epoch) return;
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
    this.clearHealRetry();
    this.consecutiveRebuilds = 0;
    this.lastFailureAt = 0;
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

  /**
   * 挂载播放器：销毁旧实例 → 重新 attach（startLoad(-1) 从直播边缘起播 = 跳到最新）。
   *
   * 幂等（**URL + 实例健康**双条件，缺陷 B3）：相同 hls_url 已挂载且实例健康 → 直接返回
   * （小窗点回/StrictMode 重复触发时**不重建**，播放状态完全复用，切换零黑屏）；
   * 实例已死（无画面 / video 报错 / 已 ended）但 URL 没变 → 幂等命中否决，销毁后重建。
   * 只看 URL 会让"实例已死但 URL 未变"永久黑屏：任何操作都不再触发重建。
   *
   * 画面槽位守卫（缺陷 B6）：小窗态（miniPlayer 投影非空）画面归小窗，本方法**不动 video
   * 元素、也不做首次挂载**——refreshSrsStatus 读到 live 就 attach 时，若把 video
   * append 回大窗容器就是与小窗抢流（小窗黑 + 主窗口黑屏）。
   */
  attachPlayer(opts: { force?: boolean } = {}): boolean {
    const hlsUrl = useLiveStore.getState().current.channel?.hls_url ?? null;
    if (!hlsUrl) return false;
    if (this.miniPlayerActive) {
      // 小窗态：画面槽位不在大窗（B6）。大窗侧一律不接管——不重建、不碰 video 元素、
      // 也不销毁小窗正在用的实例；video 的落点只由 attachVideoTo/stashVideo 决定。
      return false;
    }
    const video = this.ensureVideo();
    if (
      !opts.force &&
      this.player &&
      this.player.getMode() !== null &&
      this.currentHlsUrl === hlsUrl
    ) {
      // 健康 = 有帧；或"刚建实例、还在出帧宽限内"（新实例本来就没有帧，不能因此反复重建）
      if (this.isVideoHealthy(video) || this.withinRebuildGrace()) {
        // 防御：video 未在播放则恢复（容器迁移不应发生，兜底）
        if (video.paused) void video.play()?.catch(() => {});
        return true;
      }
      // 幂等命中但实例不健康且已过宽限 ⇒ 实例已死（B3）：落到重建，不能只比 URL 就 return
    }
    return this.rebuildPlayer(video, hlsUrl);
  }

  /**
   * 出帧宽限：距上次重建不足 REBUILD_COOLDOWN_MS。
   * 新实例从 attach 到出帧需要一段时间，这期间 video.readyState 必然 < HAVE_CURRENT_DATA；
   * 自动挂载路径（页面 effect / 状态补拉）若把它当成"实例已死"就会反复拆掉刚建好的实例
   * （HLS 重新握手、越修越黑）。显式用户动作（重试/刷新）走 force，不受宽限限制。
   */
  private withinRebuildGrace(): boolean {
    return Date.now() - this.lastRebuildAt < REBUILD_COOLDOWN_MS;
  }

  /**
   * 播放器重建（内部路径，不做幂等判定）：销毁旧实例 → attach → 重新布防 watchdog。
   * 画面槽位守卫（B6）放在这里，使所有重建入口（首次挂载 / 实例死亡 / 自愈 / 重试）
   * 都受同一守卫约束：小窗态下画面归小窗，大窗侧不得重挂（否则与小窗抢流）。
   */
  private rebuildPlayer(video: HTMLVideoElement, hlsUrl: string): boolean {
    if (this.miniPlayerActive) {
      // 小窗态：画面槽位属于小窗。video 元素的落点由 attachVideoTo/stashVideo 的
      // 原子迁移决定，这里既不重新挂载、也不 destroy 小窗正在用的实例。
      return false;
    }
    this.currentHlsUrl = hlsUrl;
    this.lastRebuildAt = Date.now();
    this.player?.destroy();
    this.player = new HlsPlayer();
    useLiveStore.getState().setCurrentPlayerError(null);
    this.player.attach(video, hlsUrl, {
      onFatalError: (detail) => {
        if (!this.alive) return;
        // 冷却期内外的 fatal 都走自愈调度（B2：计数 → 封顶 → 60s 后重试），
        // 不再"冷却期内直接报错、此后永不重建"（那就是封顶后永久放弃）。
        this.scheduleHealRebuild(detail);
      },
    });
    this.armWatchdog(video);
    return true;
  }

  /** 用当前会话的 hls_url 强制重建（自愈/延迟重试路径；不复用 attachPlayer 的幂等判定） */
  private rebuildFromCurrent(): boolean {
    const hlsUrl = useLiveStore.getState().current.channel?.hls_url ?? null;
    if (!hlsUrl) return false;
    return this.rebuildPlayer(this.ensureVideo(), hlsUrl);
  }

  /** 自动重建冷却是否已过（自愈入口的防抖：同一冷却期内不重复重建） */
  private canAutoRebuild(): boolean {
    return Date.now() - this.lastRebuildAt >= REBUILD_COOLDOWN_MS;
  }

  /**
   * 自愈调度（B2，双端同语义）：
   * - 进入新时间窗（距上次失败 ≥ REBUILD_COUNT_RESET_WINDOW_MS）⇒ 连续失败计数归零；
   * - 计数未封顶且冷却已过 ⇒ 立即重建；
   * - 封顶或冷却未过 ⇒ 记录播放失败（UI 显示"重试"），**并安排延迟重试**，
   *   不永久放弃（这是 B2 的核心：封顶后必须有后续重试路径）。
   */
  private scheduleHealRebuild(reason: string): void {
    if (!this.alive) return;
    // 小窗态不消耗自愈预算：画面槽位属于小窗（B6），大窗侧不重建；用户点回直播间时
    // enter 退出小窗、页面重新 attach，B3 的健康判定会接手恢复。
    if (this.miniPlayerActive) return;
    const now = Date.now();
    if (now - this.lastFailureAt >= REBUILD_COUNT_RESET_WINDOW_MS) {
      this.consecutiveRebuilds = 0;
    }
    this.lastFailureAt = now;
    if (this.consecutiveRebuilds < MAX_CONSECUTIVE_REBUILDS && this.canAutoRebuild()) {
      this.consecutiveRebuilds += 1;
      this.rebuildFromCurrent();
      return;
    }
    useLiveStore.getState().setCurrentPlayerError(reason);
    this.scheduleHealRetry();
  }

  /**
   * 封顶/冷却期内的有界延迟重试（B2）：REBUILD_COUNT_RESET_WINDOW_MS 后重置计数重试一次。
   * 防重入：同一时间至多一个定时器；执行时校验会话存活、仍是同一路流、实例仍不健康，
   * 三重条件任一不满足即放弃（不制造多余重建）。
   */
  private scheduleHealRetry(): void {
    if (this.healRetryTimer !== null) return;
    this.healRetryTimer = setTimeout(() => {
      this.healRetryTimer = null;
      if (!this.alive) return;
      const video = this.videoEl;
      const hlsUrl = useLiveStore.getState().current.channel?.hls_url ?? null;
      if (!video || !hlsUrl || hlsUrl !== this.currentHlsUrl) return;
      if (this.miniPlayerActive) return; // 小窗态画面归小窗，本轮不抢
      // 已自行恢复（实例在且有帧）⇒ 不重建；实例缺失/已销毁即便 video 还有残帧也要重建
      const instanceAlive = this.player !== null && this.player.getMode() !== null;
      if (instanceAlive && this.isVideoHealthy(video)) return;
      this.consecutiveRebuilds = 0;
      this.lastRebuildAt = 0; // 时间窗已过，忽略冷却
      this.rebuildFromCurrent();
    }, REBUILD_COUNT_RESET_WINDOW_MS);
  }

  /**
   * video 元素是否已出画（符号判据）：有当前帧数据、未结束、无错误。
   * attachPlayer 的实例健康判定与延迟重试复用同一判据。
   */
  private isVideoHealthy(video: HTMLVideoElement): boolean {
    return video.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA && !video.ended && !video.error;
  }

  private clearHealRetry(): void {
    if (this.healRetryTimer !== null) {
      clearTimeout(this.healRetryTimer);
      this.healRetryTimer = null;
    }
  }

  destroyPlayer(): void {
    this.player?.destroy();
    this.player = null;
    this.clearStallTimer();
    this.clearHealRetry();
    this.consecutiveRebuilds = 0;
    this.lastFailureAt = 0;
    this.currentHlsUrl = null;
  }

  /** 播放失败"重试"：用户显式动作 ⇒ 强制重建，不受出帧宽限限制（B3） */
  retryPlayer(): void {
    this.attachPlayer({ force: true });
  }

  /** 左下角刷新键：健康播放跳边秒跳、黑屏/实例缺失重建兜底。
   *  小窗态（画面槽位属于小窗）不在这里抢流：重新挂载交回页面侧（B6）。 */
  refreshPlayer(): boolean {
    const video = this.videoEl;
    const hlsUrl = useLiveStore.getState().current.channel?.hls_url ?? null;
    if (!video || !hlsUrl || this.miniPlayerActive) return false;
    if (
      this.player &&
      this.player.getMode() !== null &&
      video.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA
    ) {
      return Boolean(this.player.refreshToLiveEdge());
    }
    // 刷新键是显式用户动作：黑屏/实例缺失时强制重建，不受出帧宽限限制
    return this.attachPlayer({ force: true });
  }

  // ---------- 事件驱动黑屏/卡死自动重建（替代轮询） ----------
  // 监听 video 的 waiting/stalled/error（卡顿/黑屏信号），卡顿持续 STALL_TIMEOUT_MS
  // 未恢复（仍无帧/暂停）且冷却期已过 → 自动重建；playing/canplay 恢复即取消。
  private armWatchdog(video: HTMLVideoElement): void {
    this.clearStallTimer();
    const rebuildIfStuck = () => {
      // 冷却期内不重复重建（防抖）；小窗态画面归小窗，不抢流（B6）
      if (!this.canAutoRebuild() || this.miniPlayerActive) return;
      if (video.readyState < HTMLMediaElement.HAVE_CURRENT_DATA || video.paused) {
        this.scheduleHealRebuild("stalled");
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
      // 出帧 = 自愈成功：连续失败计数归零、撤销封顶后的延迟重试（B2，有界语义闭环）
      this.consecutiveRebuilds = 0;
      this.clearHealRetry();
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

  /**
   * 在读人数快照（进房 / WS 重连各读一次，非周期轮询）。
   *
   * 只有 store 里还没有该直播间的读数时才写入：同一次进房内「快照响应」与
   * 「WS viewers 帧」的先后无法保证，用较旧的快照覆盖刚到达的实时帧会让人数倒退。
   * presence 存储不可用（503）→ 保持"未知"（不写 0）——读不到 ≠ 没人在看。
   */
  private async refreshViewers(channelId: number): Promise<void> {
    try {
      const page = await liveApi.getLiveChannelViewers(channelId);
      if (!this.alive || this.channelId !== channelId) return;
      const store = useLiveStore.getState();
      if (store.current.channel?.id === channelId && store.current.viewerCount !== null) return;
      store.setViewers(channelId, page.count, page.viewers.slice(0, LIVE_VIEWER_PREVIEW));
    } catch {
      // 503（presence 不可用）/ 403 / 404：保持未知，不冒充 0 人在看
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

}

/** 单例：直播间同时只需一个会话/小窗（唯一 owner） */
export const liveSessionRuntime = new LiveSessionRuntime();
