/**
 * 语音 session 运行时 owner（规划 P0-1）。
 * 持有 heartbeat 与跨页面共享的房间选择/切换队列；媒体资源由 LiveKit client 持有。
 */
import { ApiError } from "../api/client";
import * as voiceApi from "../api/voice";

export const VOICE_HEARTBEAT_INTERVAL_MS = 40_000;

type ExpiredReason = "removed" | "deleted";
type ExpiredHandler = (reason: ExpiredReason) => void;

class VoiceSessionRuntime {
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private channelId: string | null = null;
  private expiredHandler: ExpiredHandler | null = null;
  private heartbeatRevision = 0;
  private selectionRevision = 0;
  private selection: { owner: object; channelId: string | null } | null = null;
  private transitionTail: Promise<void> = Promise.resolve();
  private pendingJoin: { revision: number; promise: Promise<void> } | null = null;
  private mediaChannelId: string | null = null;

  /** A route selection revokes old async work before its detail request completes. */
  selectChannel(owner: object, channelId: string | null) {
    if (this.selection?.owner === owner && this.selection.channelId === channelId) return;
    this.selection = { owner, channelId };
    this.selectionRevision += 1;
  }

  cancelSelection() {
    this.selection = null;
    this.selectionRevision += 1;
  }

  selectedChannelId() { return this.selection?.channelId ?? null; }
  currentRevision() { return this.selectionRevision; }
  isRevisionCurrent(revision: number) { return this.selectionRevision === revision; }
  setMediaChannel(channelId: string | null) { this.mediaChannelId = channelId; }
  mediaChannel() { return this.mediaChannelId; }
  ownsMedia(channelId: string) { return this.mediaChannelId === channelId; }

  /** Only one transition can acquire/release the shared REST/media/WS session at a time. */
  runExclusive<T>(operation: () => Promise<T>): Promise<T> {
    const task = this.transitionTail.then(operation, operation);
    this.transitionTail = task.then(() => undefined, () => undefined);
    return task;
  }

  /** Coalesce one selected room; superseded queued rooms never send a join request. */
  runJoin(owner: object, channelId: string, operation: (isCurrent: () => boolean) => Promise<void>): Promise<void> {
    this.selectChannel(owner, channelId);
    const revision = this.selectionRevision;
    if (this.pendingJoin?.revision === revision) return this.pendingJoin.promise;
    const isCurrent = () => this.selectionRevision === revision;
    const promise = this.runExclusive(async () => {
      if (isCurrent()) await operation(isCurrent);
    }).finally(() => {
      if (this.pendingJoin?.revision === revision) this.pendingJoin = null;
    });
    this.pendingJoin = { revision, promise };
    return promise;
  }

  startHeartbeat(channelId: string, onExpired: ExpiredHandler) {
    this.stopHeartbeat();
    const revision = this.heartbeatRevision;
    this.channelId = channelId;
    this.expiredHandler = onExpired;
    this.heartbeatTimer = setInterval(() => {
      if (this.channelId !== channelId || this.heartbeatRevision !== revision) return;
      void voiceApi.heartbeatVoiceChannel(channelId).catch((error: unknown) => {
        const status = error instanceof ApiError
          ? error.status
          : typeof error === "object" && error !== null && "status" in error
            ? error.status
            : undefined;
        if ((status === 403 || status === 404) && this.channelId === channelId && this.heartbeatRevision === revision) {
          const onExpired = this.expiredHandler;
          this.stopHeartbeat();
          onExpired?.(status === 404 ? "deleted" : "removed");
        }
      });
    }, VOICE_HEARTBEAT_INTERVAL_MS);
  }

  stopHeartbeat() {
    this.heartbeatRevision += 1;
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
    this.heartbeatTimer = null;
    this.channelId = null;
    this.expiredHandler = null;
  }

  isHeartbeating(channelId: string) {
    return this.channelId === channelId && this.heartbeatTimer !== null;
  }
}

export const voiceSessionRuntime = new VoiceSessionRuntime();
