/**
 * 语音 session 运行时 owner（规划 P0-1）。
 * 目前只承载 heartbeat；LiveKit/WS 迁移仍由后续批次完成。
 */
import { ApiError } from "../api/client";
import * as voiceApi from "../api/voice";

export const VOICE_HEARTBEAT_INTERVAL_MS = 40_000;

type ExpiredHandler = () => void;

class VoiceSessionRuntime {
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private channelId: string | null = null;
  private expiredHandler: ExpiredHandler | null = null;

  startHeartbeat(channelId: string, onExpired: ExpiredHandler) {
    this.stopHeartbeat();
    this.channelId = channelId;
    this.expiredHandler = onExpired;
    this.heartbeatTimer = setInterval(() => {
      if (this.channelId !== channelId) return;
      void voiceApi.heartbeatVoiceChannel(channelId).catch((error: unknown) => {
        if (((error instanceof ApiError && error.status === 403) || (typeof error === "object" && error !== null && "status" in error && error.status === 403)) && this.channelId === channelId) {
          const onExpired = this.expiredHandler;
          this.stopHeartbeat();
          onExpired?.();
        }
      });
    }, VOICE_HEARTBEAT_INTERVAL_MS);
  }

  stopHeartbeat() {
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
