/**
 * search API 契约测试（F9）：q/types/limit URL 拼接。
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { search } from "../api/search";
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
});
