import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { getFavoriteStatuses, listFavorites, listFavoritesPage } from "../api/favorites";
import { useAuthStore } from "../stores/auth";

const fetchMock = vi.fn();
beforeEach(() => {
  useAuthStore.setState({ accessToken: null, refreshToken: null });
  vi.stubGlobal("fetch", fetchMock);
  fetchMock.mockImplementation(() => Promise.resolve(new Response(JSON.stringify([]), {
    status: 200, headers: { "Content-Type": "application/json" },
  })));
});
afterEach(() => { vi.unstubAllGlobals(); fetchMock.mockReset(); });

describe("favorite API compatibility", () => {
  it("legacy API remains compatible with an unpaginated array request", async () => {
    await listFavorites("post");
    expect(fetchMock.mock.calls[0][0]).toContain("/favorites/?type=post");
    expect(fetchMock.mock.calls[0][0]).not.toContain("limit=");
  });
  it("status uses only supplied IDs and rejects an oversized batch before sending", async () => {
    await getFavoriteStatuses("post", ["1", "2"]);
    expect(fetchMock.mock.calls[0][0]).toContain("/favorites/status/");
    expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toEqual({ target_type: "post", target_ids: ["1", "2"] });
    expect(() => getFavoriteStatuses("post", Array.from({ length: 101 }, (_, i) => String(i)))).toThrow("100");
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });
  it("new pages send a bounded limit and encode the server cursor", async () => {
    await listFavoritesPage({ type: "message", limit: 20, cursor: "signed:cursor+/=" });
    const url = new URL(fetchMock.mock.calls[0][0], "https://example.test");
    expect(url.searchParams.get("type")).toBe("message");
    expect(url.searchParams.get("limit")).toBe("20");
    expect(url.searchParams.get("cursor")).toBe("signed:cursor+/=");
  });
});
