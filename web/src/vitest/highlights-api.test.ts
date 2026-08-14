/**
 * fetchHighlights 契约测试：URL 拼接与空 ids 短路。
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fetchHighlights } from "../api/chat";
import { useAuthStore } from "../stores/auth";

// apiRequest 走 client.ts 的 fetch；这里 stub 全局 fetch 验证 URL
const fetchMock = vi.fn();

beforeEach(() => {
  vi.stubGlobal("fetch", fetchMock);
  fetchMock.mockResolvedValue(
    new Response(JSON.stringify({ "1": [], "2": [] }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    }),
  );
  // client.ts 依赖 auth store 的 accessToken；置为无 token 避免注入 Authorization 干扰
  useAuthStore.setState({ accessToken: null, refreshToken: null });
});

afterEach(() => {
  vi.unstubAllGlobals();
  fetchMock.mockReset();
});

describe("fetchHighlights", () => {
  it("空 ids 短路返回空 dict，不发请求", async () => {
    const map = await fetchHighlights([]);
    expect(map).toEqual({});
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("多个 ids 用逗号拼接进 query", async () => {
    await fetchHighlights(["1", "2", "3"]);
    const url = fetchMock.mock.calls[0][0] as string;
    expect(url).toContain("/chat/conversations/highlights/?ids=1%2C2%2C3");
  });

  it("返回 dict 原样透传", async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ "7": [{ type: "post", title: "t", cover_url: null, target_url: "/posts/1", created_at: "2026-01-01T00:00:00Z" }] }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );
    const map = await fetchHighlights(["7"]);
    expect(map["7"]).toHaveLength(1);
    expect(map["7"][0].type).toBe("post");
  });
});
