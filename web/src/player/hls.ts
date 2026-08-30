/**
 * HLS 播放器薄封装（M5-4，文档 §4.3；低延迟/跳到最新为直播体验增量）。
 *
 * - 分支：Hls.isSupported()（Chrome/Firefox/Edge）→ hls.js；Safari 原生 HLS → video.src 直挂；
 * - 低延迟直播（B 站式"连上就播最新"）：hls.js 分支用 lowLatencyMode + liveSyncDurationCount
 *   贴住直播边缘，并以 startLoad(-1) 从边缘起播（不从头回放历史）；不做追帧倍速（保留
 *   liveSyncPlaybackRate 默认 1.0），"倍速"观感一律留给用户手动刷新跳边，避免画面自动加速；
 * - 错误恢复：networkError → startLoad() 重试；mediaError → recoverMediaError()；
 *   fatal 且不可恢复 → onFatalError 回调（UI 显示"播放失败 + 重试"，重试 = 销毁重建实例）；
 * - refreshToLiveEdge()：跳到直播最新画面（hls.js → liveSyncPosition；原生/兜底 → seekable 末尾，
 *   再兜底 reload + play）；
 * - 播放错误与"未开播"由编排层区分（以 /status/ 的 SRS 判定为准），本封装只上报播放层事实；
 * - destroy 幂等：重复调用不抛错（退房销毁清单允许重复执行）。
 */
import Hls from "hls.js";

export type HlsPlayerMode = "hls.js" | "native";

export interface HlsPlayerCallbacks {
  /** fatal 且不可恢复的错误（UI 显示重试按钮） */
  onFatalError?: (detail: string) => void;
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
        if (!data.fatal) return;
        if (data.type === Hls.ErrorTypes.NETWORK_ERROR) {
          // 网络错误（含直播未开始时的 404）：尝试重试加载
          hls.startLoad();
          return;
        }
        if (data.type === Hls.ErrorTypes.MEDIA_ERROR) {
          hls.recoverMediaError();
          return;
        }
        // 其他 fatal 错误不可恢复
        callbacks.onFatalError?.(data.details || "playback error");
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
   * 跳到直播最新画面（左下角"刷新"键）。
   *
   * - hls.js：优先用 liveSyncPosition（直播边缘精确秒数）；
   * - 通用兜底：seek 到 seekable 末尾（原生 HLS 直播的边缘）；
   * - 最终兜底：reload + play（原生分支强制重新拉流刷新到边缘）。
   * 幂等：未挂载/已销毁/无流时静默返回，不抛错。
   */
  refreshToLiveEdge() {
    if (this.destroyed || !this.video) return;
    const video = this.video;

    if (this.mode === "hls.js" && this.hls) {
      const edge = this.hls.liveSyncPosition;
      if (edge !== null && Number.isFinite(edge) && edge > 0) {
        video.currentTime = edge;
        void video.play().catch(() => {});
        return;
      }
    }

    try {
      if (video.seekable.length > 0) {
        const end = video.seekable.end(video.seekable.length - 1);
        if (Number.isFinite(end)) {
          video.currentTime = end;
          void video.play().catch(() => {});
          return;
        }
      }
    } catch {
      // seekable 查询可能抛错，落到重载兜底
    }

    video.load();
    void video.play().catch(() => {});
  }
}

/** 当前环境是否可播放 HLS（hls.js 或原生） */
export function canPlayHls(video?: HTMLVideoElement): boolean {
  if (Hls.isSupported()) return true;
  if (video) return video.canPlayType("application/vnd.apple.mpegurl") !== "";
  return false;
}
