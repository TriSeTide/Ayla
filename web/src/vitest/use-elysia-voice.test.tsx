/**
 * useElysiaVoice 编排测试（mock fetch + chat WS，M5-3 §7.1 / §4.5）：
 * - ensureCall：reused=true 正常接入不报错；创建后注册事件订阅 + 一次性 poll 对账
 * - 事件驱动：elysia.voice.call.status 帧更新通话状态；终态帧停止订阅；
 *   elysia.voice.projected 帧更新「已投影 N 条」
 * - 无周期请求：面板打开期间没有 5s/10s 状态/投影轮询
 * - 文本注入空文本前端拦截（不发请求）；502 → "爱莉侧不可用"
 * - end 幂等（重复点击安全）；面板关闭停订阅
 */
import { act, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useElysiaVoice } from "../hooks/useElysiaVoice";
import { useAuthStore } from "../stores/auth";
import { chatWS } from "../ws/chat";

vi.mock("../ws/chat", () => ({
  chatWS: {
    onFrame: vi.fn(() => () => {}),
  },
}));

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function callStatus(state: string, connected = true) {
  return {
    call_id: "call-1",
    episode_id: "ep-1",
    state,
    mode: "auto",
    provider: "voice_live",
    created_at: "t",
    updated_at: "t",
    resumable: true,
    connected,
    input_audio_bytes: 0,
    output_audio_bytes: 0,
    interruptions: 0,
    failure_reason: null,
  };
}

let fetchMock: ReturnType<typeof vi.fn>;
let offMock: ReturnType<typeof vi.fn>;

function stubFetch(routes: Record<string, () => Response>) {
  fetchMock = vi.fn().mockImplementation((url: string, init?: RequestInit) => {
    const path = String(url).replace(/^.*\/api\/v1/, "");
    const key = `${init?.method ?? "GET"} ${path}`;
    const handler = routes[key];
    if (!handler) return Promise.reject(new Error(`unmocked: ${key}`));
    return Promise.resolve(handler());
  });
  vi.stubGlobal("fetch", fetchMock);
}

function callsTo(method: string, pathPart: string): number {
  return fetchMock.mock.calls.filter(
    (c) =>
      String(c[0]).includes(pathPart) && ((c[1]?.method as string | undefined) ?? "GET") === method,
  ).length;
}

/** 模拟后端推送一帧 chat WS 事件 */
function emitFrame(frame: unknown) {
  const handler = vi.mocked(chatWS.onFrame).mock.calls.at(-1)?.[0] as
    | ((f: unknown) => void)
    | undefined;
  act(() => handler?.(frame));
}

beforeEach(() => {
  vi.mocked(chatWS.onFrame).mockClear();
  offMock = vi.fn();
  vi.mocked(chatWS.onFrame).mockImplementation(() => offMock);
  vi.useFakeTimers();
  useAuthStore.setState({ accessToken: "acc", refreshToken: "ref" });
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  useAuthStore.setState({ accessToken: null, refreshToken: null });
});

describe("useElysiaVoice", () => {
  it("ensureCall → reused=true 正常接入；注册事件订阅 + 一次性 poll 对账", async () => {
    stubFetch({
      "POST /elysia/voice-calls/": () =>
        jsonResponse({ call: callStatus("active"), connection: null, reused: true }),
      "POST /elysia/voice-calls/call-1/poll/": () =>
        jsonResponse({ projected: [], total: 2, projected_total: 1 }),
    });
    const { result } = renderHook(() => useElysiaVoice(true));
    await act(async () => {
      await result.current.ensureCall();
    });
    expect(result.current.call?.call_id).toBe("call-1");
    expect(result.current.reused).toBe(true);
    expect(result.current.error).toBeNull();
    // 事件订阅已注册
    expect(vi.mocked(chatWS.onFrame)).toHaveBeenCalled();
    // 一次性 poll 对账：投影计数初始化
    expect(callsTo("POST", "/poll/")).toBe(1);
    expect(result.current.projectedTotal).toBe(1);
  });

  it("事件驱动：call.status 帧更新状态；projected 帧更新计数", async () => {
    stubFetch({
      "POST /elysia/voice-calls/": () =>
        jsonResponse({ call: callStatus("active"), connection: null, reused: false }),
      "POST /elysia/voice-calls/call-1/poll/": () =>
        jsonResponse({ projected: [], total: 0, projected_total: 0 }),
    });
    const { result } = renderHook(() => useElysiaVoice(true));
    await act(async () => {
      await result.current.ensureCall();
    });

    emitFrame({
      type: "elysia.voice.call.status",
      data: { call: callStatus("active", false) },
    });
    expect(result.current.call?.connected).toBe(false);
    expect(result.current.isTerminal).toBe(false);

    emitFrame({
      type: "elysia.voice.projected",
      data: { call_id: "call-1", projected_total: 3 },
    });
    expect(result.current.projectedTotal).toBe(3);
    // 非本通话的帧忽略
    emitFrame({
      type: "elysia.voice.projected",
      data: { call_id: "call-other", projected_total: 99 },
    });
    expect(result.current.projectedTotal).toBe(3);
  });

  it("事件驱动：终态帧（failed/ended）→ 停止订阅", async () => {
    stubFetch({
      "POST /elysia/voice-calls/": () =>
        jsonResponse({ call: callStatus("active"), connection: null, reused: false }),
      "POST /elysia/voice-calls/call-1/poll/": () =>
        jsonResponse({ projected: [], total: 0, projected_total: 0 }),
    });
    const { result } = renderHook(() => useElysiaVoice(true));
    await act(async () => {
      await result.current.ensureCall();
    });

    emitFrame({
      type: "elysia.voice.call.status",
      data: { call: callStatus("failed", false) },
    });
    expect(result.current.isTerminal).toBe(true);
    expect(offMock).toHaveBeenCalledTimes(1);
  });

  it("无周期请求：面板打开 60s 内仅有创建 + 一次性对账，无 5s/10s 轮询", async () => {
    stubFetch({
      "POST /elysia/voice-calls/": () =>
        jsonResponse({ call: callStatus("active"), connection: null, reused: false }),
      "POST /elysia/voice-calls/call-1/poll/": () =>
        jsonResponse({ projected: [], total: 2, projected_total: 2 }),
    });
    const { result } = renderHook(() => useElysiaVoice(true));
    await act(async () => {
      await result.current.ensureCall();
    });
    const statusCalls = callsTo("GET", "/elysia/voice-calls/call-1/");
    const pollCalls = callsTo("POST", "/poll/");
    await act(async () => {
      await vi.advanceTimersByTimeAsync(60_000);
    });
    expect(callsTo("GET", "/elysia/voice-calls/call-1/")).toBe(statusCalls);
    expect(callsTo("POST", "/poll/")).toBe(pollCalls);
    expect(result.current.call?.state).toBe("active");
  });

  it("文本注入：空文本前端拦截（不发请求）；成功清空由调用方处理", async () => {
    stubFetch({
      "POST /elysia/voice-calls/": () =>
        jsonResponse({ call: callStatus("active"), connection: null, reused: false }),
      "POST /elysia/voice-calls/call-1/poll/": () =>
        jsonResponse({ projected: [], total: 0, projected_total: 0 }),
      "POST /elysia/voice-calls/call-1/text/": () =>
        jsonResponse({ command_id: "cmd-1", status: "accepted", accepted: true }),
    });
    const { result } = renderHook(() => useElysiaVoice(true));
    await act(async () => {
      await result.current.ensureCall();
    });

    let ok = true;
    await act(async () => {
      ok = await result.current.sendText("   ");
    });
    expect(ok).toBe(false);
    expect(callsTo("POST", "/text/")).toBe(0);
    expect(result.current.error).toBe("内容不能为空");

    await act(async () => {
      ok = await result.current.sendText("你好");
    });
    expect(ok).toBe(true);
    expect(callsTo("POST", "/text/")).toBe(1);
  });

  it("ensureCall 502 → 提示爱莉侧不可用", async () => {
    stubFetch({
      "POST /elysia/voice-calls/": () =>
        jsonResponse({ detail: "Elysium 侧错误: boom", code: "elysia_error" }, 502),
    });
    const { result } = renderHook(() => useElysiaVoice(true));
    await act(async () => {
      await result.current.ensureCall();
    });
    expect(result.current.error).toBe("爱莉侧不可用");
    expect(result.current.call).toBeNull();
  });

  it("end 幂等：重复点击安全；结束后停止事件订阅", async () => {
    stubFetch({
      "POST /elysia/voice-calls/": () =>
        jsonResponse({ call: callStatus("active"), connection: null, reused: false }),
      "POST /elysia/voice-calls/call-1/poll/": () =>
        jsonResponse({ projected: [], total: 0, projected_total: 0 }),
      "POST /elysia/voice-calls/call-1/end/": () =>
        jsonResponse({ command_id: "cmd-2", status: "ended", accepted: true }),
    });
    const { result } = renderHook(() => useElysiaVoice(true));
    await act(async () => {
      await result.current.ensureCall();
    });
    await act(async () => {
      await result.current.endCall();
      await result.current.endCall(); // 重复点击
    });
    expect(callsTo("POST", "/end/")).toBe(2);
    expect(result.current.call?.state).toBe("ended");
    expect(result.current.isTerminal).toBe(true);
    expect(offMock).toHaveBeenCalled();
  });

  it("面板关闭（active=false）→ 停止事件订阅（不结束通话）", async () => {
    stubFetch({
      "POST /elysia/voice-calls/": () =>
        jsonResponse({ call: callStatus("active"), connection: null, reused: false }),
      "POST /elysia/voice-calls/call-1/poll/": () =>
        jsonResponse({ projected: [], total: 0, projected_total: 0 }),
    });
    const { result, rerender } = renderHook(({ active }) => useElysiaVoice(active), {
      initialProps: { active: true },
    });
    await act(async () => {
      await result.current.ensureCall();
    });
    rerender({ active: false });
    expect(offMock).toHaveBeenCalledTimes(1);
  });
});
