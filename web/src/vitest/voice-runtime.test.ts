import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as voiceApi from "../api/voice";
import { voiceSessionRuntime, VOICE_HEARTBEAT_INTERVAL_MS } from "../runtime/voiceSessionRuntime";

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}

describe("voiceSessionRuntime", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    voiceSessionRuntime.cancelSelection();
    voiceSessionRuntime.setMediaChannel(null);
  });
  afterEach(() => {
    voiceSessionRuntime.cancelSelection();
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

  it("同一选择的并发join共享进行中的工作", async () => {
    const held = deferred<void>();
    const owner = {};
    const operation = vi.fn(async () => { await held.promise; });
    const first = voiceSessionRuntime.runJoin(owner, "A", operation);
    const duplicate = voiceSessionRuntime.runJoin(owner, "A", operation);
    try {
      await vi.advanceTimersByTimeAsync(0);
      expect(duplicate).toBe(first);
      expect(operation).toHaveBeenCalledTimes(1);
      expect(voiceSessionRuntime.selectedChannelId()).toBe("A");
    } finally {
      held.resolve();
      await Promise.all([first, duplicate]);
    }
  });

  it("跨owner的A尚未结束时B/C排队，只让最后C在A收尾之后执行", async () => {
    const held = deferred<void>();
    const events: string[] = [];
    let ownsA: (() => boolean) | undefined;
    const first = voiceSessionRuntime.runJoin({}, "A", async (isCurrent) => {
      ownsA = isCurrent;
      events.push("A-start");
      await held.promise;
      events.push(isCurrent() ? "A-current" : "A-stale-finished");
    });
    await vi.advanceTimersByTimeAsync(0);
    const intermediate = vi.fn(async () => { events.push("B-start"); });
    const latest = vi.fn(async (isCurrent: () => boolean) => {
      expect(isCurrent()).toBe(true);
      events.push("C-start");
    });
    const second = voiceSessionRuntime.runJoin({}, "B", intermediate);
    const third = voiceSessionRuntime.runJoin({}, "C", latest);
    try {
      await vi.advanceTimersByTimeAsync(0);
      expect(ownsA?.()).toBe(false);
      expect(events).toEqual(["A-start"]);
      expect(voiceSessionRuntime.selectedChannelId()).toBe("C");
    } finally {
      held.resolve();
      await Promise.all([first, second, third]);
    }
    expect(intermediate).not.toHaveBeenCalled();
    expect(latest).toHaveBeenCalledTimes(1);
    expect(events).toEqual(["A-start", "A-stale-finished", "C-start"]);
  });

  it("cancelSelection立即撤销revision，尚未开始的queued join不执行", async () => {
    const held = deferred<void>();
    const closing = voiceSessionRuntime.runExclusive(async () => { await held.promise; });
    const operation = vi.fn(async () => {});
    const queued = voiceSessionRuntime.runJoin({}, "A", operation);
    const revision = voiceSessionRuntime.currentRevision();
    voiceSessionRuntime.cancelSelection();
    try {
      expect(voiceSessionRuntime.selectedChannelId()).toBeNull();
      expect(voiceSessionRuntime.isRevisionCurrent(revision)).toBe(false);
    } finally {
      held.resolve();
      await Promise.all([closing, queued]);
    }
    expect(operation).not.toHaveBeenCalled();
  });

  it.each(["v1", "v2"])("旧heartbeat迟到403不能停止重新启动在%s的新owner", async (nextChannel) => {
    const oldResponse = deferred<{ ok: boolean }>();
    const oldExpired = vi.fn();
    const currentExpired = vi.fn();
    const heartbeat = vi.spyOn(voiceApi, "heartbeatVoiceChannel")
      .mockReturnValueOnce(oldResponse.promise)
      .mockRejectedValueOnce({ status: 403 });
    voiceSessionRuntime.startHeartbeat("v1", oldExpired);
    await vi.advanceTimersByTimeAsync(VOICE_HEARTBEAT_INTERVAL_MS);
    expect(heartbeat).toHaveBeenCalledTimes(1);
    voiceSessionRuntime.startHeartbeat(nextChannel, currentExpired);
    oldResponse.reject({ status: 403 });
    await vi.advanceTimersByTimeAsync(0);
    expect(oldExpired).not.toHaveBeenCalled();
    expect(currentExpired).not.toHaveBeenCalled();
    expect(voiceSessionRuntime.isHeartbeating(nextChannel)).toBe(true);

    await vi.advanceTimersByTimeAsync(VOICE_HEARTBEAT_INTERVAL_MS);
    expect(heartbeat).toHaveBeenCalledTimes(2);
    expect(currentExpired).toHaveBeenCalledTimes(1);
    expect(currentExpired).toHaveBeenCalledWith("removed");
    expect(oldExpired).not.toHaveBeenCalled();
    expect(voiceSessionRuntime.isHeartbeating(nextChannel)).toBe(false);
  });
});
