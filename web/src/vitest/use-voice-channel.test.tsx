/**
 * useVoiceChannel 编排测试（mock fetch + mock WS + mock LiveKit Room，M5-3 §7.1）：
 * - join 503 → "语音服务未配置"，不进入媒体连接
 * - join 成功但 LiveKit 连接失败 → 调 leave/ 回滚
 * - 心跳：加入后按间隔发 heartbeat/；重复加入不叠加定时器
 * - 心跳 403 → 本地重置未加入态
 * - leave 幂等；toggleMic 乐观 UI + 失败回滚
 */
import { act, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useVoiceChannel, VOICE_HEARTBEAT_INTERVAL_MS } from "../hooks/useVoiceChannel";
import { voiceLiveKit } from "../livekit/client";
import type { LiveKitRoomLike } from "../livekit/client";
import { useAuthStore } from "../stores/auth";
import { useVoiceStore } from "../stores/voice";
import { voiceWS } from "../ws/voice";

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

const JOIN_OK = {
  channel_id: "ch1",
  room_name: "vc-x",
  token: "lk-token",
  ws_url: "ws://lk",
  ttl: 600,
  joined: true,
};

function fakeRoom(overrides: Partial<LiveKitRoomLike> = {}): LiveKitRoomLike {
  return {
    connect: vi.fn().mockResolvedValue(undefined),
    disconnect: vi.fn().mockResolvedValue(undefined),
    setMicrophoneEnabled: vi.fn().mockResolvedValue(undefined),
    isMicrophoneEnabled: vi.fn().mockReturnValue(false),
    startAudio: vi.fn().mockResolvedValue(undefined),
    remoteParticipants: vi.fn().mockReturnValue([]),
    setLocalVolume: vi.fn().mockResolvedValue(undefined),
    getLocalVolume: vi.fn().mockReturnValue(1),
    ...overrides,
  };
}

let fetchMock: ReturnType<typeof vi.fn>;

function stubFetch(routes: Record<string, () => Response>) {
  fetchMock = vi.fn().mockImplementation((url: string, init?: RequestInit) => {
    const path = String(url).replace(/^.*\/api\/v1/, "");
    const method = init?.method ?? "GET";
    const key = `${method} ${path}`;
    const handler = routes[key];
    if (!handler) return Promise.reject(new Error(`unmocked: ${key}`));
    return Promise.resolve(handler());
  });
  vi.stubGlobal("fetch", fetchMock);
}

function calledWith(method: string, pathPart: string): number {
  return fetchMock.mock.calls.filter(
    (c) =>
      String(c[0]).includes(pathPart) && ((c[1]?.method as string | undefined) ?? "GET") === method,
  ).length;
}

beforeEach(() => {
  vi.useFakeTimers();
  useAuthStore.setState({ accessToken: "acc", refreshToken: "ref" });
  useVoiceStore.getState().reset();
  // LiveKit 单例注入 fake；WS 单例断开避免真实连接
  voiceLiveKit.setRoomFactory(() => fakeRoom());
  voiceWS.disconnect();
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  voiceLiveKit.setRoomFactory(null);
  useAuthStore.setState({ accessToken: null, refreshToken: null });
  useVoiceStore.getState().reset();
  voiceWS.disconnect();
});

describe("useVoiceChannel", () => {
  it("join 503（LiveKit 未配置）→ 提示语音服务未配置，不进入媒体连接", async () => {
    stubFetch({
      "POST /voice/channels/ch1/join/": () =>
        jsonResponse({ detail: "LiveKit 未配置，无法加入语音频道" }, 503),
    });
    const { result } = renderHook(() => useVoiceChannel());
    await act(async () => {
      await result.current.join("ch1");
    });
    expect(result.current.error).toBe("语音服务未配置，暂不可用");
    expect(useVoiceStore.getState().currentChannelId).toBeNull();
    expect(useVoiceStore.getState().livekit).toBe("idle");
  });

  it("join 成功但 LiveKit 连接失败 → 调 leave/ 回滚成员状态", async () => {
    voiceLiveKit.setRoomFactory(() =>
      fakeRoom({ connect: vi.fn().mockRejectedValue(new Error("media fail")) }),
    );
    stubFetch({
      "POST /voice/channels/ch1/join/": () => jsonResponse(JOIN_OK),
      "POST /voice/channels/ch1/leave/": () => jsonResponse({ left: true }),
    });
    const { result } = renderHook(() => useVoiceChannel());
    await act(async () => {
      await result.current.join("ch1");
    });
    expect(calledWith("POST", "/leave/")).toBe(1);
    expect(useVoiceStore.getState().currentChannelId).toBeNull();
    expect(useVoiceStore.getState().livekit).toBe("failed");
    expect(result.current.error).toBe("media fail");
  });

  it("join 成功 → 成员铺底 + 心跳按间隔发 heartbeat/；重复加入不叠加定时器", async () => {
    stubFetch({
      "POST /voice/channels/ch1/join/": () => jsonResponse(JOIN_OK),
      "GET /voice/channels/ch1/members/": () =>
        jsonResponse([{ id: 1, user_id: "me", joined_at: "t", last_seen_at: "t" }]),
      "POST /voice/channels/ch1/heartbeat/": () => jsonResponse({ ok: true }),
    });
    const { result } = renderHook(() => useVoiceChannel());
    await act(async () => {
      await result.current.join("ch1");
    });
    expect(useVoiceStore.getState().currentChannelId).toBe("ch1");
    expect(useVoiceStore.getState().members["me"]).toBeDefined();
    expect(useVoiceStore.getState().micEnabled).toBe(false); // 默认关麦加入

    // 重复加入（幂等路径）：心跳定时器不叠加
    await act(async () => {
      await result.current.join("ch1");
    });
    await act(async () => {
      vi.advanceTimersByTime(VOICE_HEARTBEAT_INTERVAL_MS);
    });
    expect(calledWith("POST", "/heartbeat/")).toBe(1); // 只有一个定时器在跳

    await act(async () => {
      await result.current.leave();
    });
  });

  it("心跳 403 → 本地重置未加入态", async () => {
    let heartbeatCalls = 0;
    stubFetch({
      "POST /voice/channels/ch1/join/": () => jsonResponse(JOIN_OK),
      "GET /voice/channels/ch1/members/": () => jsonResponse([]),
      "POST /voice/channels/ch1/heartbeat/": () => {
        heartbeatCalls += 1;
        return jsonResponse({ detail: "非频道成员不可心跳" }, 403);
      },
    });
    const { result } = renderHook(() => useVoiceChannel());
    await act(async () => {
      await result.current.join("ch1");
    });
    expect(useVoiceStore.getState().currentChannelId).toBe("ch1");

    await act(async () => {
      vi.advanceTimersByTime(VOICE_HEARTBEAT_INTERVAL_MS);
      await Promise.resolve(); // flush 心跳 promise
    });
    expect(heartbeatCalls).toBe(1);
    expect(useVoiceStore.getState().currentChannelId).toBeNull();
    expect(result.current.error).toContain("已被移出");

    // 重置后心跳停止（不再发）
    await act(async () => {
      vi.advanceTimersByTime(VOICE_HEARTBEAT_INTERVAL_MS * 2);
      await Promise.resolve();
    });
    expect(heartbeatCalls).toBe(1);
  });

  it("leave → 断媒体 + 停心跳 + 调 leave/（幂等，未加入时空调用安全）", async () => {
    stubFetch({
      "POST /voice/channels/ch1/join/": () => jsonResponse(JOIN_OK),
      "GET /voice/channels/ch1/members/": () => jsonResponse([]),
      "POST /voice/channels/ch1/leave/": () => jsonResponse({ left: true }),
      "POST /voice/channels/ch1/heartbeat/": () => jsonResponse({ ok: true }),
    });
    const { result } = renderHook(() => useVoiceChannel());

    // 未加入时 leave 安全
    await act(async () => {
      await result.current.leave();
    });
    expect(calledWith("POST", "/leave/")).toBe(0);

    await act(async () => {
      await result.current.join("ch1");
    });
    await act(async () => {
      await result.current.leave();
    });
    expect(calledWith("POST", "/leave/")).toBe(1);
    expect(useVoiceStore.getState().currentChannelId).toBeNull();

    // 离开后心跳停止
    await act(async () => {
      vi.advanceTimersByTime(VOICE_HEARTBEAT_INTERVAL_MS * 2);
    });
    expect(calledWith("POST", "/heartbeat/")).toBe(0);
  });

  it("toggleMic 乐观 UI + SDK 失败回滚", async () => {
    stubFetch({
      "POST /voice/channels/ch1/join/": () => jsonResponse(JOIN_OK),
      "GET /voice/channels/ch1/members/": () => jsonResponse([]),
      "POST /voice/channels/ch1/heartbeat/": () => jsonResponse({ ok: true }),
    });
    const room = fakeRoom();
    voiceLiveKit.setRoomFactory(() => room);
    const { result } = renderHook(() => useVoiceChannel());
    await act(async () => {
      await result.current.join("ch1");
    });

    // 成功路径
    await act(async () => {
      await result.current.toggleMic();
    });
    expect(useVoiceStore.getState().micEnabled).toBe(true);
    expect(room.setMicrophoneEnabled).toHaveBeenCalledWith(true);

    // 失败路径 → 回滚
    (room.setMicrophoneEnabled as ReturnType<typeof vi.fn>).mockRejectedValueOnce(
      new Error("device busy"),
    );
    await act(async () => {
      await result.current.toggleMic();
    });
    expect(useVoiceStore.getState().micEnabled).toBe(true); // 回滚到之前状态
    expect(result.current.error).toContain("device busy");

    await act(async () => {
      await result.current.leave();
    });
  });
});
