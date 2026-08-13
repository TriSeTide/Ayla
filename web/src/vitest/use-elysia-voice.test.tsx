/**
 * useElysiaVoice 编排测试（mock fetch，M5-3 §7.1 / §4.5）：
 * - ensureCall：reused=true 正常接入不报错；终态不启动轮询
 * - 状态轮询 5s / 投影轮询 10s；面板关闭停轮询
 * - 文本注入空文本前端拦截（不发请求）；502 → "爱莉侧不可用"
 * - end 幂等（重复点击安全）；ended 后停止轮询
 */
import { act, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useElysiaVoice } from "../hooks/useElysiaVoice";
import { useAuthStore } from "../stores/auth";

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

beforeEach(() => {
  vi.useFakeTimers();
  useAuthStore.setState({ accessToken: "acc", refreshToken: "ref" });
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  useAuthStore.setState({ accessToken: null, refreshToken: null });
});

describe("useElysiaVoice", () => {
  it("ensureCall → reused=true 正常接入（不报错）；启动状态/投影轮询", async () => {
    stubFetch({
      "POST /elysia/voice-calls/": () =>
        jsonResponse({ call: callStatus("active"), connection: null, reused: true }),
      "GET /elysia/voice-calls/call-1/": () => jsonResponse({ call: callStatus("active") }),
      "POST /elysia/voice-calls/call-1/poll/": () =>
        jsonResponse({ projected: [], total: 2 }),
    });
    const { result } = renderHook(() => useElysiaVoice(true));
    await act(async () => {
      await result.current.ensureCall();
    });
    expect(result.current.call?.call_id).toBe("call-1");
    expect(result.current.reused).toBe(true);
    expect(result.current.error).toBeNull();

    await act(async () => {
      vi.advanceTimersByTime(5_000);
      await Promise.resolve();
    });
    expect(callsTo("GET", "/elysia/voice-calls/call-1/")).toBeGreaterThanOrEqual(1);

    await act(async () => {
      vi.advanceTimersByTime(10_000);
      await Promise.resolve();
    });
    expect(callsTo("POST", "/poll/")).toBeGreaterThanOrEqual(1);
    expect(result.current.projectedTotal).toBe(2);
  });

  it("文本注入：空文本前端拦截（不发请求）；成功清空由调用方处理", async () => {
    stubFetch({
      "POST /elysia/voice-calls/": () =>
        jsonResponse({ call: callStatus("active"), connection: null, reused: false }),
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

  it("end 幂等：重复点击安全；结束后停止轮询", async () => {
    stubFetch({
      "POST /elysia/voice-calls/": () =>
        jsonResponse({ call: callStatus("active"), connection: null, reused: false }),
      "GET /elysia/voice-calls/call-1/": () => jsonResponse({ call: callStatus("active") }),
      "POST /elysia/voice-calls/call-1/poll/": () => jsonResponse({ projected: [], total: 0 }),
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

    // 结束后轮询停止
    const statusCallsBefore = callsTo("GET", "/elysia/voice-calls/call-1/");
    await act(async () => {
      vi.advanceTimersByTime(15_000);
      await Promise.resolve();
    });
    expect(callsTo("GET", "/elysia/voice-calls/call-1/")).toBe(statusCallsBefore);
  });

  it("面板关闭（active=false）→ 停止轮询", async () => {
    stubFetch({
      "POST /elysia/voice-calls/": () =>
        jsonResponse({ call: callStatus("active"), connection: null, reused: false }),
      "GET /elysia/voice-calls/call-1/": () => jsonResponse({ call: callStatus("active") }),
      "POST /elysia/voice-calls/call-1/poll/": () => jsonResponse({ projected: [], total: 0 }),
    });
    const { result, rerender } = renderHook(({ active }) => useElysiaVoice(active), {
      initialProps: { active: true },
    });
    await act(async () => {
      await result.current.ensureCall();
    });
    rerender({ active: false });
    const before = callsTo("GET", "/elysia/voice-calls/call-1/");
    await act(async () => {
      vi.advanceTimersByTime(20_000);
      await Promise.resolve();
    });
    expect(callsTo("GET", "/elysia/voice-calls/call-1/")).toBe(before);
  });
});
