/**
 * HLS 播放器薄封装（M5-4，文档 §4.3；低延迟/跳到最新为直播体验增量）。
 *
 * - 分支：Hls.isSupported()（Chrome/Firefox/Edge）→ hls.js；Safari 原生 HLS → video.src 直挂；
 * - 低延迟直播（B 站式"连上就播最新"）：hls.js 分支用 lowLatencyMode + liveSyncDurationCount
 *   贴住直播边缘，并以 startLoad(-1) 从边缘起播（不从头回放历史）；不做追帧倍速（保留
 *   liveSyncPlaybackRate 默认 1.0），"倍速"观感一律留给用户手动刷新跳边，避免画面自动加速；
 * - 错误恢复：networkError → startLoad() 重试；mediaError → recoverMediaError()；
 *   fatal 且不可恢复 → onFatalError 回调（UI 显示"播放失败 + 重试"，重试 = 销毁重建实例）；
 * - refreshToLiveEdge()：跳到直播最新画面并返回是否贴边成功（hls.js → liveSyncPosition；
 *   原生/兜底 → seekable 末尾回退一个安全分片，再兜底 reload + play）；
 * - 播放错误与"未开播"由编排层区分（以 /status/ 的 SRS 判定为准），本封装只上报播放层事实；
 * - destroy 幂等：重复调用不抛错（退房销毁清单允许重复执行）。
 */
import Hls from "hls.js";

export type HlsPlayerMode = "hls.js" | "native";

export interface HlsPlayerCallbacks {
  /** fatal 且不可恢复的错误（UI 显示重试按钮） */
  onFatalError?: (detail: string) => void;
  /**
   * 非 fatal 的分片级故障（404 / 超时 / 解析失败）。
   *
   * hls.js 把分片失败标记为 fatal=false 并自行重试；此前本封装
   * `if (!data.fatal) return` 把这类事件全部丢弃，导致分片持续失败时
   * 画面卡住但 UI 无任何信号。这里只做"观测上报"，不改变 hls.js 的恢复流程。
   */
  onFragmentError?: (detail: string) => void;
  /**
   * HLS playlist 推进回调：每次成功解析 playlist 时上报 MEDIA-SEQUENCE。
   *
   * 用途：上游停止产片时 playlist 内容不变但 HTTP 仍 200，hls.js 不报错、
   * 播放位置也静默 —— 编排层靠"sequence 多久没前进"来判定上游停摆。
   * 首次加载与每次刷新都会回调（同一 sequence 会重复上报，由调用方判定停滞）。
   */
  onPlaylistLevelUpdated?: (mediaSequence: number) => void;
}

export class HlsPlayer {
  private hls: Hls | null = null;
  private video: HTMLVideoElement | null = null;
  private mode: HlsPlayerMode | null = null;
  private destroyed = false;

  /**
   * 把 HLS 流挂到 video 元素上。
   * 返回使用的播放模式；重复 attach 前先销毁旧实例。
   */
  attach(video: HTMLVideoElement, hlsUrl: string, callbacks: HlsPlayerCallbacks = {}): HlsPlayerMode {
    this.destroy();
    this.destroyed = false;
    this.video = video;

    if (Hls.isSupported()) {
      this.mode = "hls.js";
      // 低延迟直播：贴住直播边缘（liveSyncDurationCount=2 目标贴边 2 个分片），
      // 不设追帧倍速（保持 liveSyncPlaybackRate 默认 1.0，不自动加速画面）。
      const hls = new Hls({
        lowLatencyMode: true,
        liveSyncDurationCount: 2,
      });
      this.hls = hls;

      hls.on(Hls.Events.ERROR, (_event, data) => {
        if (this.destroyed) return;
        if (!data.fatal) {
          // 非 fatal：hls.js 自行重试。分片级故障上报给编排层做观测，
          // 其余（如 bufferStalledError 由 hls.js 内部 nudge 恢复）不打扰调用方。
          if (data.frag) callbacks.onFragmentError?.(data.details || "fragment error");
          return;
        }
        if (data.type === Hls.ErrorTypes.NETWORK_ERROR) {
          // 网络错误（含直播未开始时的 404）：从当前播放位置重试。
          // 不能无参 startLoad()：那等价于 startLoad(-1)，而 hls.js 在
          // lastCurrentTime > 0 时会把 -1 覆盖成 lastCurrentTime，语义不稳定；
          // 显式传当前时间可保证"原地重试"，不额外跳变。
          hls.startLoad(video.currentTime > 0 ? video.currentTime : -1);
          return;
        }
        if (data.type === Hls.ErrorTypes.MEDIA_ERROR) {
          hls.recoverMediaError();
          return;
        }
        // 其他 fatal 错误不可恢复
        callbacks.onFatalError?.(data.details || "playback error");
      });

      hls.on(Hls.Events.LEVEL_UPDATED, (_event, data) => {
        if (this.destroyed) return;
        const seq = data?.details?.startSN;
        if (typeof seq === "number" && Number.isFinite(seq)) {
          callbacks.onPlaylistLevelUpdated?.(seq);
        }
      });

      hls.loadSource(hlsUrl);
      hls.attachMedia(video);
      // 从直播边缘起播（-1 = live edge），连上推流即显示最新画面，不从头回放
      hls.startLoad(-1);
      return this.mode;
    }

    // Safari 等原生 HLS 分支
    this.mode = "native";
    video.src = hlsUrl;
    const onError = () => {
      if (this.destroyed) return;
      callbacks.onFatalError?.("native playback error");
    };
    video.addEventListener("error", onError, { once: true });
    // 记录以便 destroy 时移除（once 已保证单次，但 destroy 主动移除更安全）
    this.nativeErrorHandler = onError;
    return this.mode;
  }

  private nativeErrorHandler: (() => void) | null = null;

  /** 销毁实例（幂等）：hls.destroy() + 清 video.src + 移除监听 */
  destroy() {
    if (this.destroyed) return;
    this.destroyed = true;
    if (this.hls) {
      this.hls.destroy();
      this.hls = null;
    }
    if (this.video) {
      if (this.nativeErrorHandler) {
        this.video.removeEventListener("error", this.nativeErrorHandler);
        this.nativeErrorHandler = null;
      }
      // 原生分支挂过 src；hls.js 分支 detach 后 src 由 hls 管理，统一清掉释放资源
      this.video.removeAttribute("src");
      this.video.load();
      this.video = null;
    }
    this.mode = null;
  }

  getMode(): HlsPlayerMode | null {
    return this.mode;
  }

  /**
   * 跳到直播最新画面（左下角"刷新"键）。返回**是否成功贴边**（R1：供后续 UI 反馈使用，
   * 本帧只做接口，不做任何视觉改动）。
   *
   * - hls.js：优先用 liveSyncPosition（直播边缘精确秒数，已含 liveSyncDurationCount 安全距离）；
   * - 通用兜底：seek 到 seekable 末尾**回退一个安全分片**。原因：seekable 的 end 是
   *   playlist 最后一个分片的边界，直接 seek 到 end 会落在尚未写完/尚未解码的位置
   *   （表现为卡住或黑屏）；回退量取 hls 实例的 liveSyncDurationCount × 分片时长，
   *   拿不到则退化为 2s；
   * - 最终兜底：reload + play（原生分支强制重新拉流刷新到边缘），此路径无法证明贴边，
   *   返回 false。
   * 幂等：未挂载/已销毁/无流时静默返回 false，不抛错。
   */
  refreshToLiveEdge(): boolean {
    if (this.destroyed || !this.video) return false;
    const video = this.video;

    if (this.mode === "hls.js" && this.hls) {
      const edge = this.hls.liveSyncPosition;
      if (edge !== null && Number.isFinite(edge) && edge > 0) {
        video.currentTime = edge;
        void video.play().catch(() => {});
        return true;
      }
    }

    try {
      if (video.seekable.length > 0) {
        const end = video.seekable.end(video.seekable.length - 1);
        if (Number.isFinite(end)) {
          // R1：回退一个安全分片，避免贴到尚未写完的边缘
          const back = this.liveEdgeBackoff();
          const target = end - back;
          video.currentTime = target > 0 ? target : end;
          void video.play().catch(() => {});
          return true;
        }
      }
    } catch {
      // seekable 查询可能抛错，落到重载兜底
    }

    video.load();
    void video.play().catch(() => {});
    return false;
  }

  /**
   * seekable 兜底分支的回退量（秒）：hls 实例的 liveSyncDurationCount × 当前分片时长
   * （targetduration，缺失时用 averagetargetduration）；二者任一取不到则退化为 2s。
   */
  private liveEdgeBackoff(): number {
    const fallback = 2;
    const hls = this.hls;
    if (!hls) return fallback;
    const count = hls.config?.liveSyncDurationCount;
    const level = hls.levels?.[hls.currentLevel >= 0 ? hls.currentLevel : 0];
    const details = level?.details;
    const segment =
      typeof details?.targetduration === "number" && details.targetduration > 0
        ? details.targetduration
        : typeof details?.averagetargetduration === "number" && details.averagetargetduration > 0
          ? details.averagetargetduration
          : null;
    if (typeof count === "number" && count > 0 && segment !== null) {
      return count * segment;
    }
    return fallback;
  }
}

/** 当前环境是否可播放 HLS（hls.js 或原生） */
export function canPlayHls(video?: HTMLVideoElement): boolean {
  if (Hls.isSupported()) return true;
  if (video) return video.canPlayType("application/vnd.apple.mpegurl") !== "";
  return false;
}
