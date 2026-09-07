import { beforeEach, describe, expect, it, vi } from "vitest";
import { getFavoriteStatuses } from "../api/favorites";
import type { FavoriteStatuses } from "../api/favorites";
import { useAuthStore } from "../stores/auth";
import { applyFavoriteStatus, ensureFavoriteScope, favoriteStatusKey, loadFavoriteStatuses, useFavoriteStatusStore } from "../stores/favoriteStatus";

vi.mock("../api/favorites", () => ({ getFavoriteStatuses: vi.fn() }));
vi.mock("../stores/auth", async () => {
  const { create } = await import("zustand");
  return { useAuthStore: create(() => ({ currentUser: { id: "one" }, accessToken: "test" })) };
});
const tick = async () => { for (let i = 0; i < 8; i += 1) await Promise.resolve(); };
const state = (id: string) => useFavoriteStatusStore.getState().entries.get(favoriteStatusKey("post", id));
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
const response = (ids: readonly string[], value: number | null = null): FavoriteStatuses => ({ target_type: "post", statuses: Object.fromEntries(ids.map((id) => [id, value])) });
let account = 0;
beforeEach(() => {
  vi.clearAllMocks();
  useAuthStore.setState({ currentUser: { id: String(++account) } as never, accessToken: "test" });
  ensureFavoriteScope();
  vi.mocked(getFavoriteStatuses).mockImplementation(async (type, ids) => ({ ...response(ids), target_type: type }));
});

describe("bounded favorite status", () => {
  it("batches 205 targets in at most two concurrent 100-ID requests", async () => {
    const first = deferred<FavoriteStatuses>();
    const second = deferred<FavoriteStatuses>();
    vi.mocked(getFavoriteStatuses).mockImplementationOnce(() => first.promise).mockImplementationOnce(() => second.promise);
    const ids = Array.from({ length: 205 }, (_, i) => String(i));
    loadFavoriteStatuses("post", ids);
    await tick();
    expect(getFavoriteStatuses).toHaveBeenCalledTimes(2);
    expect(vi.mocked(getFavoriteStatuses).mock.calls.map((call) => call[1].length)).toEqual([100, 100]);
    first.resolve(response(ids.slice(0, 100)));
    second.resolve(response(ids.slice(100, 200)));
    await tick();
    expect(vi.mocked(getFavoriteStatuses).mock.calls.map((call) => call[1].length)).toEqual([100, 100, 5]);
    await tick();
    expect(state("204")?.favoriteId).toBeNull();
  });
  it("deduplicates targets and preserves unrelated known state", async () => {
    applyFavoriteStatus("post", "outside", 12);
    loadFavoriteStatuses("post", ["1", "1"]);
    loadFavoriteStatuses("post", ["1", "2"]);
    await tick();
    expect(getFavoriteStatuses).toHaveBeenCalledTimes(1);
    expect(getFavoriteStatuses).toHaveBeenCalledWith("post", ["1", "2"]);
    expect(state("outside")?.favoriteId).toBe(12);
  });
  it("keeps newer WS added and removed states over a delayed response", async () => {
    const pending = deferred<FavoriteStatuses>();
    vi.mocked(getFavoriteStatuses).mockReturnValueOnce(pending.promise);
    loadFavoriteStatuses("post", ["1", "2"]);
    await tick();
    applyFavoriteStatus("post", "1", 91);
    applyFavoriteStatus("post", "2", null);
    pending.resolve({ target_type: "post", statuses: { "1": null, "2": 92 } });
    await tick();
    expect(state("1")?.favoriteId).toBe(91);
    expect(state("2")?.favoriteId).toBeNull();
  });
  it("incomplete responses remain unknown and explicit retry can succeed", async () => {
    vi.mocked(getFavoriteStatuses).mockResolvedValueOnce(response([]));
    loadFavoriteStatuses("post", ["1"]);
    await tick();
    expect(state("1")).toMatchObject({ favoriteId: undefined, loading: false, error: "收藏状态响应不完整，请重试" });
    loadFavoriteStatuses("post", ["1"], true);
    await tick();
    expect(state("1")).toMatchObject({ favoriteId: null, error: null });
  });
  it("failed refresh retains a known favorite and does not clear other targets", async () => {
    applyFavoriteStatus("post", "1", 71);
    vi.mocked(getFavoriteStatuses).mockRejectedValueOnce(new Error("offline"));
    loadFavoriteStatuses("post", ["1"], true);
    await tick();
    expect(state("1")).toMatchObject({ favoriteId: 71, error: "offline", loading: false });
  });
  it("account changes clear state and old completions cannot overwrite the new owner", async () => {
    const old = deferred<FavoriteStatuses>();
    vi.mocked(getFavoriteStatuses).mockReturnValueOnce(old.promise);
    loadFavoriteStatuses("post", ["1"]);
    await tick();
    useAuthStore.setState({ currentUser: { id: "new-account" } as never });
    expect(state("1")).toBeUndefined();
    loadFavoriteStatuses("post", ["1"]);
    await tick();
    old.resolve(response(["1"], 88));
    await tick();
    expect(state("1")?.favoriteId).toBeNull();
  });
});
