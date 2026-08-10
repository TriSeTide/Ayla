/**
 * auth store 测试：注册/登录/恢复/登出/refresh 旋转覆盖。
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useAuthStore } from "../stores/auth";

const fetchMock = vi.fn<(...args: unknown[]) => Promise<Response>>();

beforeEach(() => {
  fetchMock.mockReset();
  vi.stubGlobal("fetch", fetchMock);
  useAuthStore.setState({ accessToken: null, refreshToken: null, currentUser: null });
  sessionStorage.clear();
});

afterEach(() => {
  vi.unstubAllGlobals();
  sessionStorage.clear();
});

const jsonResponse = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

describe("auth store", () => {
  it("登录成功 → access/refresh 写入 store + sessionStorage", async () => {
    fetchMock
      .mockResolvedValueOnce(jsonResponse({ access: "acc", refresh: "ref" }))
      .mockResolvedValueOnce(
        jsonResponse({ id: "1", username: "a", nickname: "A", online: false }),
      );

    await useAuthStore.getState().login("a", "password123");
    const s = useAuthStore.getState();
    expect(s.accessToken).toBe("acc");
    expect(s.refreshToken).toBe("ref");
    expect(s.currentUser?.username).toBe("a");
    expect(sessionStorage.getItem("elysia.refresh_token")).toBe("ref");
  });

  it("登录失败 → 抛错，store 不写 token", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ detail: "用户名或密码错误" }, 401));
    await expect(useAuthStore.getState().login("a", "wrong")).rejects.toThrow();
    const s = useAuthStore.getState();
    expect(s.accessToken).toBeNull();
    expect(s.refreshToken).toBeNull();
  });

  it("注册成功 → 写入当前用户 + 令牌", async () => {
    fetchMock.mockResolvedValueOnce(
      jsonResponse(
        {
          user: { id: "2", username: "b", nickname: "B", online: true },
          access: "acc-r",
          refresh: "ref-r",
        },
        201,
      ),
    );
    await useAuthStore.getState().register({
      username: "b",
      email: "b@x.com",
      password: "password123",
    });
    expect(useAuthStore.getState().currentUser?.username).toBe("b");
    expect(sessionStorage.getItem("elysia.refresh_token")).toBe("ref-r");
  });

  it("restoreSession：有 refresh → 刷新并拉 me（旋转后新 refresh 已持久化）", async () => {
    sessionStorage.setItem("elysia.refresh_token", "old-ref");
    useAuthStore.setState({ refreshToken: "old-ref" });

    fetchMock
      .mockResolvedValueOnce(jsonResponse({ access: "new-acc", refresh: "new-ref" }))
      .mockResolvedValueOnce(
        jsonResponse({ id: "1", username: "a", nickname: "A", online: false }),
      );

    await useAuthStore.getState().restoreSession();
    const s = useAuthStore.getState();
    expect(s.accessToken).toBe("new-acc");
    expect(s.refreshToken).toBe("new-ref");
    expect(s.initialized).toBe(true);
    // 关键：旋转后新 refresh 必须覆盖旧值
    expect(sessionStorage.getItem("elysia.refresh_token")).toBe("new-ref");
  });

  it("restoreSession：无 refresh → 直接 initialized，不发请求", async () => {
    await useAuthStore.getState().restoreSession();
    expect(useAuthStore.getState().initialized).toBe(true);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("restoreSession：refresh 失效 → 清 store 并标记 initialized", async () => {
    sessionStorage.setItem("elysia.refresh_token", "dead");
    useAuthStore.setState({ refreshToken: "dead" });
    fetchMock.mockResolvedValueOnce(jsonResponse({ detail: "无效 refresh" }, 401));

    await useAuthStore.getState().restoreSession();
    expect(useAuthStore.getState().accessToken).toBeNull();
    expect(useAuthStore.getState().refreshToken).toBeNull();
    expect(useAuthStore.getState().initialized).toBe(true);
    expect(sessionStorage.getItem("elysia.refresh_token")).toBeNull();
  });

  it("logout → 清 store + 清 sessionStorage", async () => {
    sessionStorage.setItem("elysia.refresh_token", "ref");
    useAuthStore.setState({ accessToken: "acc", refreshToken: "ref", currentUser: {} as never });
    useAuthStore.getState().logout();
    expect(useAuthStore.getState().accessToken).toBeNull();
    expect(sessionStorage.getItem("elysia.refresh_token")).toBeNull();
  });
});
