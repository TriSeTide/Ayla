/**
 * client.ts 测试：错误归一 + 401 刷新重放 + 并发互斥。
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { type ApiError, apiRequest, normalizeErrorBody } from "../api/client";
import { useAuthStore } from "../stores/auth";

type FetchCall = [string, RequestInit?];

const jsonResponse = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

const fetchMock = vi.fn<(...args: unknown[]) => Promise<Response>>();

beforeEach(() => {
  fetchMock.mockReset();
  vi.stubGlobal("fetch", fetchMock);
  useAuthStore.setState({
    accessToken: "access-1",
    refreshToken: "refresh-1",
    currentUser: null,
    initialized: true,
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
  useAuthStore.setState({ accessToken: null, refreshToken: null, currentUser: null });
  sessionStorage.clear();
});

describe("normalizeErrorBody", () => {
  it("detail 字符串", () => {
    expect(normalizeErrorBody({ detail: "用户名已存在" }, "fallback")).toBe("用户名已存在");
  });

  it("字段错误数组", () => {
    expect(normalizeErrorBody({ password: ["密码至少 8 位"] }, "fallback")).toBe(
      "密码至少 8 位",
    );
  });

  it("空 body 用 fallback", () => {
    expect(normalizeErrorBody(null, "fallback")).toBe("fallback");
  });
});

describe("apiRequest", () => {
  it("携带 Authorization 且解析 JSON", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ id: "1", username: "a" }));
    const data = await apiRequest<{ id: string; username: string }>("/me/");
    expect(data).toEqual({ id: "1", username: "a" });
    const [url, init] = fetchMock.mock.calls[0] as FetchCall;
    expect(url).toBe("/api/v1/me/");
    expect((init?.headers as Record<string, string>).Authorization).toBe("Bearer access-1");
  });

  it("非 2xx 归一为 ApiError", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ detail: "用户名已存在" }, 400));
    await expect(apiRequest("/auth/register/", { method: "POST" })).rejects.toMatchObject({
      status: 400,
      message: "用户名已存在",
    });
  });

  it("401 → 自动 refresh → 重放成功", async () => {
    // 第一次 /me/ 401，refresh 成功，重放 /me/ 200
    fetchMock
      .mockResolvedValueOnce(jsonResponse({ detail: "认证失效" }, 401))
      .mockResolvedValueOnce(jsonResponse({ access: "access-2", refresh: "refresh-2" }))
      .mockResolvedValueOnce(jsonResponse({ id: "9", username: "me" }));

    const data = await apiRequest<{ id: string; username: string }>("/me/");
    expect(data).toEqual({ id: "9", username: "me" });

    // store 已用新 token 覆盖
    expect(useAuthStore.getState().accessToken).toBe("access-2");
    expect(useAuthStore.getState().refreshToken).toBe("refresh-2");

    // 重放请求带新 token
    const replay = fetchMock.mock.calls[2] as FetchCall;
    expect((replay[1]?.headers as Record<string, string>).Authorization).toBe(
      "Bearer access-2",
    );
  });

  it("refresh 也 401 → 清 store 跳登录", async () => {
    // /me/ 401，refresh 401
    fetchMock
      .mockResolvedValueOnce(jsonResponse({ detail: "认证失效" }, 401))
      .mockResolvedValueOnce(jsonResponse({ detail: "无效 refresh" }, 401));

    // jsdom 无 window.location.assign，stub 它
    const assign = vi.fn();
    Object.defineProperty(window, "location", {
      value: { ...window.location, assign, pathname: "/", search: "" },
      writable: true,
    });

    await expect(apiRequest("/me/")).rejects.toMatchObject({
      status: 401,
    } satisfies Partial<ApiError>);

    // store 被清空
    expect(useAuthStore.getState().accessToken).toBeNull();
    expect(useAuthStore.getState().refreshToken).toBeNull();
    expect(assign).toHaveBeenCalled();
  });

  it("noRetry401：认证端点 401 不触发刷新，原样归一", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ detail: "用户名或密码错误" }, 401));
    await expect(
      apiRequest("/auth/login/", { method: "POST", body: { username: "a", password: "x" }, noRetry401: true }),
    ).rejects.toMatchObject({ status: 401, message: "用户名或密码错误" });
    // 不触发 refresh 调用
    const refreshCalls = fetchMock.mock.calls.filter(([url]) =>
      String(url).includes("/auth/refresh/"),
    );
    expect(refreshCalls).toHaveLength(0);
  });

  it("并发 401 只触发一次 refresh（互斥锁）", async () => {
    // 两个 /me/ 都 401；refresh 只应被调用一次
    fetchMock
      .mockResolvedValueOnce(jsonResponse({ detail: "x" }, 401)) // req1
      .mockResolvedValueOnce(jsonResponse({ detail: "x" }, 401)) // req2
      .mockResolvedValueOnce(jsonResponse({ access: "access-2", refresh: "refresh-2" })) // refresh（唯一一次）
      .mockResolvedValueOnce(jsonResponse({ ok: 1 })) // req1 重放
      .mockResolvedValueOnce(jsonResponse({ ok: 2 })); // req2 重放

    const [r1, r2] = await Promise.all([
      apiRequest("/me/"),
      apiRequest("/me/"),
    ]);
    expect(r1).toEqual({ ok: 1 });
    expect(r2).toEqual({ ok: 2 });

    const refreshCalls = fetchMock.mock.calls.filter(([url, init]) => {
      const body = (init as RequestInit | undefined)?.body as string | undefined;
      return String(url).includes("/auth/refresh/") && Boolean(body?.includes('"refresh"'));
    });
    expect(refreshCalls).toHaveLength(1);
  });
});
