/**
 * search API 契约测试（F9）：q/types/limit URL 拼接。
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { search, searchPages } from "../api/search";
import { useAuthStore } from "../stores/auth";

const fetchMock = vi.fn();

beforeEach(() => {
  vi.stubGlobal("fetch", fetchMock);
  fetchMock.mockResolvedValue(
    new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }),
  );
  useAuthStore.setState({ accessToken: null, refreshToken: null });
});

afterEach(() => {
  vi.unstubAllGlobals();
  fetchMock.mockReset();
});

describe("search API", () => {
  it("q 必填进 query", async () => {
    await search({ q: "冰樱" });
    expect(fetchMock.mock.calls[0][0]).toContain("/search/?q=");
    expect(fetchMock.mock.calls[0][0]).toContain(encodeURIComponent("冰樱"));
  });

  it("types 逗号拼接", async () => {
    await search({ q: "x", types: ["user", "group"] });
    expect(fetchMock.mock.calls[0][0]).toContain("types=user%2Cgroup");
  });

  it("limit 传入", async () => {
    await search({ q: "x", limit: 5 });
    expect(fetchMock.mock.calls[0][0]).toContain("limit=5");
  });

  it("游标模式显式开启并只续指定结果组，旧search不启用分页", async () => {
    await searchPages({ q: "冰樱", types: ["group"], limit: 20, cursor: "signed+/=cursor" });
    const url = new URL(fetchMock.mock.calls[0][0], "https://example.test");
    expect(url.searchParams.get("pagination")).toBe("cursor");
    expect(url.searchParams.get("types")).toBe("group");
    expect(url.searchParams.get("cursor")).toBe("signed+/=cursor");
    expect(url.searchParams.get("limit")).toBe("20");
  });
});
