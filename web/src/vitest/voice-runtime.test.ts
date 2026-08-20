import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as voiceApi from "../api/voice";
import { voiceSessionRuntime, VOICE_HEARTBEAT_INTERVAL_MS } from "../runtime/voiceSessionRuntime";

describe("voiceSessionRuntime", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => {
    voiceSessionRuntime.stopHeartbeat();
    vi.restoreAllMocks();
    vi.useRealTimers();
  });

  it("同一 runtime 只保留一个 heartbeat owner", async () => {
    const heartbeat = vi.spyOn(voiceApi, "heartbeatVoiceChannel").mockResolvedValue({ ok: true });
    voiceSessionRuntime.startHeartbeat("v1", vi.fn());
    voiceSessionRuntime.startHeartbeat("v2", vi.fn());
    await vi.advanceTimersByTimeAsync(VOICE_HEARTBEAT_INTERVAL_MS);
    expect(heartbeat).toHaveBeenCalledTimes(1);
    expect(heartbeat).toHaveBeenCalledWith("v2");
  });

  it("404 时停止 heartbeat 并明确通知房间已删除", async () => {
    const expired = vi.fn();
    vi.spyOn(voiceApi, "heartbeatVoiceChannel").mockRejectedValue({ status: 404 });
    voiceSessionRuntime.startHeartbeat("v1", expired);
    await vi.advanceTimersByTimeAsync(VOICE_HEARTBEAT_INTERVAL_MS);
    expect(expired).toHaveBeenCalledWith("deleted");
    expect(voiceSessionRuntime.isHeartbeating("v1")).toBe(false);
  });

  it("403 时停止 heartbeat 并通知过期", async () => {
    const expired = vi.fn();
    vi.spyOn(voiceApi, "heartbeatVoiceChannel").mockRejectedValue({ status: 403 });
    voiceSessionRuntime.startHeartbeat("v1", expired);
    await vi.advanceTimersByTimeAsync(VOICE_HEARTBEAT_INTERVAL_MS);
    expect(expired).toHaveBeenCalledOnce();
    expect(expired).toHaveBeenCalledWith("removed");
    expect(voiceSessionRuntime.isHeartbeating("v1")).toBe(false);
  });
});
