/**
 * posts API 契约测试（F6）：listPosts 游标/scope 拼接、发帖/评论 body。
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as postsApi from "../api/posts";
import { useAuthStore } from "../stores/auth";

const fetchMock = vi.fn();

beforeEach(() => {
  vi.stubGlobal("fetch", fetchMock);
  fetchMock.mockResolvedValue(
    new Response(JSON.stringify({ results: [], next_cursor: null, has_more: false }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    }),
  );
  useAuthStore.setState({ accessToken: null, refreshToken: null });
});

afterEach(() => {
  vi.unstubAllGlobals();
  fetchMock.mockReset();
});

function calledUrl(call = 0): string {
  return fetchMock.mock.calls[call][0] as string;
}

describe("posts API", () => {
  it("listPosts feed 无参数 → 不带 query", async () => {
    await postsApi.listPosts({ scope: "feed" });
    expect(calledUrl()).toContain("/posts/");
    expect(calledUrl()).not.toContain("scope");
  });

  it("listPosts group scope + cursor + limit 拼接", async () => {
    await postsApi.listPosts({ scope: "group:5", cursor: "abc", limit: 20 });
    const url = calledUrl();
    expect(url).toContain("scope=group%3A5");
    expect(url).toContain("cursor=abc");
    expect(url).toContain("limit=20");
  });

  it("createPost 带 body + group", async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ id: 1 }), { status: 201, headers: { "Content-Type": "application/json" } }),
    );
    await postsApi.createPost({ body: "hi", group: "5" });
    const body = JSON.parse(fetchMock.mock.calls[0][1].body);
    expect(body).toMatchObject({ body: "hi", group: "5" });
  });

  it("createComment 带 reply_to", async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ id: 2 }), { status: 201, headers: { "Content-Type": "application/json" } }),
    );
    await postsApi.createComment(1, { body: "回复", reply_to: 3 });
    const body = JSON.parse(fetchMock.mock.calls[0][1].body);
    expect(body).toEqual({ body: "回复", reply_to: 3 });
  });
});
