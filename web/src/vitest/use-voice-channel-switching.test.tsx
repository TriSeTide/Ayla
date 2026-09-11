import { StrictMode } from "react";
import { act, cleanup, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ChatServerFrame, UserPublic, VoiceServerFrame } from "../api/types";
import * as voiceApi from "../api/voice";
import { useVoiceChannel } from "../hooks/useVoiceChannel";
import { voiceLiveKit, type LiveKitRoomLike } from "../livekit/client";
import { voiceSessionRuntime, VOICE_HEARTBEAT_INTERVAL_MS } from "../runtime/voiceSessionRuntime";
import { useAuthStore } from "../stores/auth";
import { useSessionActivityStore } from "../stores/sessionActivity";
import { useVoiceStore } from "../stores/voice";
import { voiceWS } from "../ws/voice";

const events = vi.hoisted(() => ({
  voice: new Set<(frame: VoiceServerFrame) => void>(),
  chat: new Set<(frame: ChatServerFrame) => void>(),
  reconnected: new Set<() => void>(),
}));
vi.mock("../api/voice", () => ({
  joinVoiceChannel: vi.fn(), leaveVoiceChannel: vi.fn(),
  listVoiceChannelMembers: vi.fn(), heartbeatVoiceChannel: vi.fn(),
}));
vi.mock("../api/users", () => ({ ensureUsers: vi.fn().mockResolvedValue(undefined) }));
vi.mock("../runtime/liveSessionRuntime", () => ({ liveSessionRuntime: { leave: vi.fn() } }));
vi.mock("../ws/voice", () => ({ voiceWS: {
  connect: vi.fn(), disconnect: vi.fn(), subscribe: vi.fn(), unsubscribe: vi.fn(),
  onFrame: (handler: (frame: VoiceServerFrame) => void) => {
    events.voice.add(handler); return () => events.voice.delete(handler);
  },
  onReconnected: (handler: () => void) => {
    events.reconnected.add(handler); return () => events.reconnected.delete(handler);
  },
} }));
vi.mock("../ws/chat", () => ({ chatWS: {
  onFrame: (handler: (frame: ChatServerFrame) => void) => {
    events.chat.add(handler); return () => events.chat.delete(handler);
  },
} }));

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
const member = (channelId: string) => ({ id: 1, user_id: `member-${channelId}`, joined_at: "t", last_seen_at: "t" });
const joinResult = (channelId: string) => ({ channel_id: channelId, room_name: channelId, token: `media-${channelId}`, ws_url: "ws://fixture", ttl: 60, joined: true });
function room(overrides: Partial<LiveKitRoomLike> = {}): LiveKitRoomLike {
  return {
    connect: vi.fn().mockResolvedValue(undefined), disconnect: vi.fn().mockResolvedValue(undefined),
    setMicrophoneEnabled: vi.fn().mockResolvedValue(undefined), isMicrophoneEnabled: () => false,
    remoteParticipants: () => [], startAudio: vi.fn().mockResolvedValue(undefined),
    setLocalVolume: vi.fn().mockResolvedValue(undefined), getLocalVolume: () => 1,
    ...overrides,
  };
}

beforeEach(() => {
  vi.useFakeTimers();
  vi.clearAllMocks();
  voiceSessionRuntime.cancelSelection();
  voiceSessionRuntime.stopHeartbeat();
  voiceSessionRuntime.setMediaChannel(null);
  useVoiceStore.getState().reset();
  useSessionActivityStore.getState().reset();
  useAuthStore.setState({ accessToken: "original-session", refreshToken: "original-refresh", currentUser: { id: "me" } as UserPublic });
  vi.mocked(voiceApi.joinVoiceChannel).mockReset().mockImplementation(async (id) => joinResult(id));
  vi.mocked(voiceApi.leaveVoiceChannel).mockReset().mockResolvedValue({ left: true });
  vi.mocked(voiceApi.listVoiceChannelMembers).mockReset().mockImplementation(async (id) => [member(id)]);
  vi.mocked(voiceApi.heartbeatVoiceChannel).mockReset().mockResolvedValue({ ok: true });
  voiceLiveKit.setRoomFactory(() => room());
});
afterEach(async () => {
  cleanup();
  voiceSessionRuntime.cancelSelection();
  voiceSessionRuntime.stopHeartbeat();
  voiceSessionRuntime.setMediaChannel(null);
  await voiceLiveKit.disconnect();
  voiceLiveKit.setRoomFactory(null);
  useVoiceStore.getState().reset();
  useSessionActivityStore.getState().reset();
  useAuthStore.setState({ accessToken: null, refreshToken: null, currentUser: null });
  vi.useRealTimers();
});

describe("latest selected voice session", () => {
  it.each(["join", "members", "connect", "previous-leave"] as const)("A → B → C while A's %s waits only commits C", async (stage) => {
    const reached = deferred<void>();
    const gate = deferred<void>();
    // WS 中继传输下 connect 入参 = (relayWsUrl(channelId), 访问令牌)；
    // 房间身份以 url 里的 channel 区分（token 恒为访问令牌，不再随房间变化）
    const media: Array<{ url: string; room: LiveKitRoomLike }> = [];
    voiceLiveKit.setRoomFactory(() => {
      const owned = room({ connect: vi.fn(async (url) => {
        media.push({ url, room: owned });
        if (stage === "connect" && url.includes("channel=A")) { reached.resolve(); await gate.promise; }
      }) });
      return owned;
    });
    vi.mocked(voiceApi.joinVoiceChannel).mockImplementation(async (id) => {
      if (stage === "join" && id === "A") { reached.resolve(); await gate.promise; }
      return joinResult(id);
    });
    vi.mocked(voiceApi.listVoiceChannelMembers).mockImplementation(async (id) => {
      if (stage === "members" && id === "A") { reached.resolve(); await gate.promise; }
      return [member(id)];
    });
    vi.mocked(voiceApi.leaveVoiceChannel).mockImplementation(async (id) => {
      if (stage === "previous-leave" && id === "old") { reached.resolve(); await gate.promise; }
      return { left: true };
    });
    const { result } = renderHook(() => useVoiceChannel());
    if (stage === "previous-leave") await act(async () => { await result.current.join("old"); });
    let a!: Promise<void>, b!: Promise<void>, c!: Promise<void>;
    await act(async () => { a = result.current.join("A"); await reached.promise; });
    act(() => { b = result.current.join("B"); c = result.current.join("C"); });
    await act(async () => { gate.resolve(); await Promise.all([a, b, c]); });
    expect(useVoiceStore.getState().currentChannelId).toBe("C");
    expect(Object.keys(useVoiceStore.getState().members)).toEqual(["member-C"]);
    expect(useSessionActivityStore.getState().voiceSession).toMatchObject({ sessionId: "C", status: "connected" });
    expect(voiceSessionRuntime.ownsMedia("C")).toBe(true);
    expect(voiceSessionRuntime.isHeartbeating("C")).toBe(true);
    expect(voiceSessionRuntime.isHeartbeating("A")).toBe(false);
    expect(voiceApi.joinVoiceChannel).not.toHaveBeenCalledWith("B");
    expect(voiceApi.leaveVoiceChannel).toHaveBeenCalledWith("A", "original-session");
    expect(vi.mocked(voiceWS.subscribe).mock.calls.at(-1)).toEqual([["C"]]);
    const currentRoom = media.find((item) => item.url.includes("channel=C"))!.room;
    expect(currentRoom.disconnect).not.toHaveBeenCalled();
    for (const previous of media.filter((item) => !item.url.includes("channel=C"))) expect(previous.room.disconnect).toHaveBeenCalled();
    const calls = vi.mocked(voiceApi.joinVoiceChannel).mock.calls.map(([id]) => id);
    expect(calls).toEqual(stage === "previous-leave" ? ["old", "A", "C"] : ["A", "C"]);
    expect(result.current.joining).toBe(false);
    expect(result.current.error).toBeNull();
  });

  it("a route selection cancels A before the new room's detail is ready", async () => {
    const aResult = deferred<ReturnType<typeof joinResult>>();
    const started = deferred<void>();
    vi.mocked(voiceApi.joinVoiceChannel).mockImplementation(async (id) => {
      if (id === "A") { started.resolve(); return aResult.promise; }
      return joinResult(id);
    });
    const { result, rerender } = renderHook(({ selected }) => useVoiceChannel(selected), { initialProps: { selected: "A" } });
    let a!: Promise<void>;
    await act(async () => { a = result.current.join("A"); await started.promise; });
    rerender({ selected: "C" });
    await act(async () => { aResult.resolve(joinResult("A")); await a; });
    expect(useVoiceStore.getState().currentChannelId).toBeNull();
    expect(voiceApi.leaveVoiceChannel).toHaveBeenCalledWith("A", "original-session");
    await act(async () => { await result.current.join("C"); });
    expect(useVoiceStore.getState().currentChannelId).toBe("C");
  });

  it("different mounted hook owners still serialize one global media session", async () => {
    const reply = deferred<ReturnType<typeof joinResult>>();
    const started = deferred<void>();
    vi.mocked(voiceApi.joinVoiceChannel).mockImplementation(async (id) => {
      if (id === "A") { started.resolve(); return reply.promise; }
      return joinResult(id);
    });
    const first = renderHook(() => useVoiceChannel("A"));
    let a!: Promise<void>, c!: Promise<void>;
    await act(async () => { a = first.result.current.join("A"); await started.promise; });
    first.unmount();
    const second = renderHook(() => useVoiceChannel("C"));
    act(() => { c = second.result.current.join("C"); });
    expect(voiceApi.joinVoiceChannel).toHaveBeenCalledTimes(1);
    await act(async () => { reply.resolve(joinResult("A")); await Promise.all([a, c]); });
    expect(useVoiceStore.getState().currentChannelId).toBe("C");
    expect(voiceApi.leaveVoiceChannel).toHaveBeenCalledWith("A", "original-session");
    expect(voiceSessionRuntime.ownsMedia("C")).toBe(true);
  });

  it.each(["left", "heartbeat"] as const)("old room %s cannot cancel the newer selected target", async (event) => {
    const { result } = renderHook(() => useVoiceChannel());
    await act(async () => { await result.current.join("old"); });
    const oldHeartbeat = deferred<{ ok: boolean }>();
    if (event === "heartbeat") {
      vi.mocked(voiceApi.heartbeatVoiceChannel).mockReturnValueOnce(oldHeartbeat.promise);
      await act(async () => { await vi.advanceTimersByTimeAsync(VOICE_HEARTBEAT_INTERVAL_MS); });
      expect(voiceApi.heartbeatVoiceChannel).toHaveBeenCalledWith("old");
    }
    const aResult = deferred<ReturnType<typeof joinResult>>();
    const started = deferred<void>();
    vi.mocked(voiceApi.joinVoiceChannel).mockImplementation(async (id) => {
      if (id === "A") { started.resolve(); return aResult.promise; }
      return joinResult(id);
    });
    let a!: Promise<void>, c!: Promise<void>;
    await act(async () => { a = result.current.join("A"); await started.promise; });
    act(() => { c = result.current.join("C"); });
    await act(async () => {
      if (event === "heartbeat") oldHeartbeat.reject({ status: 403 });
      else events.voice.forEach((handler) => handler({ type: "voice.state", data: {
        channel_id: "old", user_id: "me", state: "left", ts: "2026-09-08T00:00:00Z",
      } } as VoiceServerFrame));
      await Promise.resolve();
    });
    expect(voiceSessionRuntime.selectedChannelId()).toBe("C");
    await act(async () => { aResult.resolve(joinResult("A")); await Promise.all([a, c]); });
    expect(useVoiceStore.getState().currentChannelId).toBe("C");
    expect(result.current.error).toBeNull();
  });

  it("pending logout compensates with the captured account and never activates a new account's store", async () => {
    const reply = deferred<ReturnType<typeof joinResult>>();
    const started = deferred<void>();
    vi.mocked(voiceApi.joinVoiceChannel).mockImplementation(async () => { started.resolve(); return reply.promise; });
    const { result } = renderHook(() => useVoiceChannel());
    let pending!: Promise<void>;
    await act(async () => { pending = result.current.join("A"); await started.promise; });
    act(() => {
      useAuthStore.getState().logout();
      useAuthStore.setState({ accessToken: "new-session", currentUser: { id: "other" } as UserPublic });
    });
    await act(async () => { reply.resolve(joinResult("A")); await pending; });
    expect(voiceApi.leaveVoiceChannel).toHaveBeenCalledWith("A", "original-session");
    expect(useVoiceStore.getState().currentChannelId).toBeNull();
    expect(useSessionActivityStore.getState().voiceSession).toBeNull();
    expect(voiceSessionRuntime.mediaChannel()).toBeNull();
    expect(useAuthStore.getState().currentUser?.id).toBe("other");
  });

  it("same-room concurrent calls under StrictMode share one REST and media acquisition", async () => {
    const reply = deferred<ReturnType<typeof joinResult>>();
    vi.mocked(voiceApi.joinVoiceChannel).mockReturnValue(reply.promise);
    const factory = vi.fn(() => room());
    voiceLiveKit.setRoomFactory(factory);
    const { result } = renderHook(() => useVoiceChannel("A"), { wrapper: StrictMode });
    let a!: Promise<void>, duplicate!: Promise<void>;
    act(() => { a = result.current.join("A"); duplicate = result.current.join("A"); });
    await act(async () => { reply.resolve(joinResult("A")); await Promise.all([a, duplicate]); });
    expect(voiceApi.joinVoiceChannel).toHaveBeenCalledTimes(1);
    expect(factory).toHaveBeenCalledTimes(1);
    expect(useVoiceStore.getState().currentChannelId).toBe("A");
  });

  it("a same-account login cannot join the same room before logout's old leave finishes", async () => {
    const { result } = renderHook(() => useVoiceChannel());
    await act(async () => { await result.current.join("A"); });
    const leaving = deferred<{ left: boolean }>();
    const started = deferred<void>();
    vi.mocked(voiceApi.leaveVoiceChannel).mockImplementationOnce(async () => { started.resolve(); return leaving.promise; });
    await act(async () => { useAuthStore.getState().logout(); await started.promise; });
    let next!: Promise<void>;
    act(() => {
      useAuthStore.setState({ accessToken: "new-session", currentUser: { id: "me" } as UserPublic });
      next = result.current.join("A");
    });
    expect(voiceApi.joinVoiceChannel).toHaveBeenCalledTimes(1);
    await act(async () => { leaving.resolve({ left: true }); await next; });
    expect(voiceApi.joinVoiceChannel).toHaveBeenCalledTimes(2);
    expect(voiceApi.leaveVoiceChannel).toHaveBeenCalledWith("A", "original-session");
    expect(useVoiceStore.getState().currentChannelId).toBe("A");
    expect(voiceSessionRuntime.isHeartbeating("A")).toBe(true);
  });

  it("a late reconnect member response cannot replace the next room's members", async () => {
    const { result } = renderHook(() => useVoiceChannel());
    await act(async () => { await result.current.join("A"); });
    const old = deferred<Awaited<ReturnType<typeof voiceApi.listVoiceChannelMembers>>>();
    vi.mocked(voiceApi.listVoiceChannelMembers).mockReturnValueOnce(old.promise);
    let reconcile!: Promise<void>;
    act(() => { reconcile = result.current.reconcile("A"); });
    await act(async () => { await result.current.join("C"); });
    await act(async () => { old.resolve([member("A")]); await reconcile; });
    expect(Object.keys(useVoiceStore.getState().members)).toEqual(["member-C"]);
  });

  it("explicit leave during a pending join cancels it and waits for compensation", async () => {
    const reply = deferred<ReturnType<typeof joinResult>>();
    const started = deferred<void>();
    vi.mocked(voiceApi.joinVoiceChannel).mockImplementation(async () => { started.resolve(); return reply.promise; });
    const { result } = renderHook(() => useVoiceChannel());
    let pending!: Promise<void>, leave!: Promise<void>;
    await act(async () => { pending = result.current.join("A"); await started.promise; });
    act(() => { leave = result.current.leave(); });
    await act(async () => { reply.resolve(joinResult("A")); await Promise.all([pending, leave]); });
    expect(useVoiceStore.getState().currentChannelId).toBeNull();
    expect(voiceApi.leaveVoiceChannel).toHaveBeenCalledTimes(1);
    expect(voiceSessionRuntime.mediaChannel()).toBeNull();
  });
});
