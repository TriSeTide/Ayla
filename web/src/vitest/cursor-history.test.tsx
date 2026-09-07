import { act, renderHook, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { HISTORY_WINDOW_LIMIT, useCursorHistory } from "../hooks/useCursorHistory";
import { usePagedMediaList } from "../hooks/usePagedMediaList";
import type { MediaPage } from "../api/mediaPagination";

type Item = { id: string; created_at: string };
const item = (id: number): Item => ({ id: String(id), created_at: "2026-09-08T00:00:00Z" });
const page = (ids: number[], cursor: string | null = null): MediaPage<Item> => ({
  results: ids.map(item), has_more: cursor !== null, next_cursor: cursor, total: 900,
});
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

describe("cursor history ownership and continuity", () => {
  it("keeps realtime arrivals while the first page is pending and deduplicates overlaps", async () => {
    const pending = deferred<MediaPage<Item>>();
    const fetch = vi.fn(() => pending.promise);
    const { result } = renderHook(() => useCursorHistory("room:1", fetch));
    act(() => { result.current.append(item(9)); result.current.append(item(10)); });
    await act(async () => pending.resolve(page([7, 8, 9], "older")));
    expect(result.current.items.map((row) => row.id)).toEqual(["7", "8", "9", "10"]);
    expect(result.current.cursor).toBe("older");
  });

  it("rejects old-room completion and old append callbacks after an owner switch", async () => {
    const old = deferred<MediaPage<Item>>();
    const fetch = vi.fn().mockReturnValueOnce(old.promise).mockResolvedValue(page([20]));
    const { result, rerender } = renderHook(({ owner }) => useCursorHistory(owner, fetch), { initialProps: { owner: "a" } });
    const oldAppend = result.current.append;
    rerender({ owner: "b" });
    await waitFor(() => expect(result.current.loaded).toBe(true));
    await act(async () => { old.resolve(page([1])); oldAppend(item(2)); });
    expect(result.current.items.map((row) => row.id)).toEqual(["20"]);
  });

  it("retains the previous window and cursor on a failed older read and retries that cursor", async () => {
    const fetch = vi.fn().mockResolvedValueOnce(page([5, 6], "older"))
      .mockRejectedValueOnce(new Error("offline")).mockResolvedValueOnce(page([3, 4], "oldest"));
    const { result } = renderHook(() => useCursorHistory("room", fetch));
    await waitFor(() => expect(result.current.loaded).toBe(true));
    await act(() => result.current.loadOlder());
    expect(result.current.items.map((row) => row.id)).toEqual(["5", "6"]);
    expect(result.current.cursor).toBe("older");
    expect(result.current.error).toBe("offline");
    await act(() => result.current.retry());
    expect(fetch.mock.calls[2]).toEqual(["older", undefined]);
    expect(result.current.items.map((row) => row.id)).toEqual(["3", "4", "5", "6"]);
  });

  it("reconnection during a page request leaves an explicit refresh boundary after completion", async () => {
    const pending = deferred<MediaPage<Item>>();
    const fetch = vi.fn().mockReturnValueOnce(pending.promise).mockResolvedValueOnce(page([10]));
    const { result } = renderHook(() => useCursorHistory("room", fetch));
    act(() => result.current.invalidate());
    await act(async () => pending.resolve(page([7, 8], "older")));
    expect(result.current.hasNewer).toBe(true);
    expect(result.current.items.map((row) => row.id)).toEqual(["7", "8"]);
    await act(() => result.current.returnLatest());
    expect(result.current.hasNewer).toBe(false);
    expect(result.current.items.map((row) => row.id)).toEqual(["10"]);
  });

  it.each([null, "older"])("rejects a non-advancing cursor %s without losing the old window", async (badCursor) => {
    const fetch = vi.fn().mockResolvedValueOnce(page([5, 6], "older"))
      .mockResolvedValueOnce({ ...page([3, 4]), has_more: true, next_cursor: badCursor });
    const { result } = renderHook(() => useCursorHistory("room", fetch));
    await waitFor(() => expect(result.current.loaded).toBe(true));
    await act(() => result.current.loadOlder());
    expect(result.current.items.map((row) => row.id)).toEqual(["5", "6"]);
    expect(result.current.cursor).toBe("older");
    expect(result.current.error).toContain("继续位置");
  });

  it("bounds realtime history then resumes older reads at the retained first id", async () => {
    const fetch = vi.fn().mockResolvedValueOnce(page([1, 2], "original"))
      .mockResolvedValueOnce(page([1, 2, 3, 4], "earlier"));
    const { result } = renderHook(() => useCursorHistory("room", fetch));
    await waitFor(() => expect(result.current.loaded).toBe(true));
    act(() => { for (let id = 3; id <= 504; id++) result.current.append(item(id)); });
    expect(result.current.items).toHaveLength(HISTORY_WINDOW_LIMIT);
    expect(result.current.items[0].id).toBe("5");
    await act(() => result.current.loadOlder());
    expect(fetch.mock.calls[1]).toEqual([null, "5"]);
    expect(result.current.items).toHaveLength(HISTORY_WINDOW_LIMIT);
    expect(result.current.items[0].id).toBe("1");
    expect(result.current.hasNewer).toBe(true);
  });

  it("does not insert live arrivals in an older window and retains it if returning latest fails", async () => {
    const fetch = vi.fn().mockResolvedValueOnce(page([5, 6], "older"))
      .mockResolvedValueOnce(page([3, 4], "oldest"))
      .mockRejectedValueOnce(new Error("latest unavailable"))
      .mockResolvedValueOnce(page([7, 8], "newest-cursor"));
    const { result } = renderHook(() => useCursorHistory("room", fetch));
    await waitFor(() => expect(result.current.loaded).toBe(true));
    await act(() => result.current.loadOlder());
    act(() => { result.current.append(item(7)); });
    expect(result.current.items.map((row) => row.id)).toEqual(["3", "4", "5", "6"]);
    expect(result.current.hasNewer).toBe(true);
    await act(() => result.current.returnLatest());
    expect(result.current.cursor).toBe("oldest");
    expect(result.current.items.map((row) => row.id)).toEqual(["3", "4", "5", "6"]);
    await act(() => result.current.retry());
    expect(fetch.mock.calls[3]).toEqual([null, undefined]);
    expect(result.current.items.map((row) => row.id)).toEqual(["7", "8"]);
    expect(result.current.hasNewer).toBe(false);
  });
});

describe("paged media list", () => {
  it("ignores stale owner requests, deduplicates page boundaries, and retains failed pages", async () => {
    const pending = deferred<MediaPage<Item>>();
    const fetch = vi.fn().mockReturnValueOnce(pending.promise).mockResolvedValueOnce(page([20, 21], "b-next"))
      .mockRejectedValueOnce(new Error("offline")).mockResolvedValueOnce(page([21, 22]));
    const { result, rerender } = renderHook(({ scope }) => usePagedMediaList(scope, fetch), { initialProps: { scope: "a" } });
    rerender({ scope: "b" });
    await waitFor(() => expect(result.current.loaded).toBe(true));
    await act(async () => pending.resolve(page([1])));
    await act(() => result.current.loadMore());
    expect(result.current.items.map((row) => row.id)).toEqual(["20", "21"]);
    expect(result.current.cursor).toBe("b-next");
    await act(() => result.current.loadMore());
    expect(result.current.items.map((row) => row.id)).toEqual(["20", "21", "22"]);
  });

  it("retries a failed refresh as a refresh even when the retained page has more rows", async () => {
    const fetch = vi.fn().mockResolvedValueOnce(page([1], "old"))
      .mockRejectedValueOnce(new Error("offline")).mockResolvedValueOnce(page([2], "new"));
    const { result } = renderHook(() => usePagedMediaList("mine", fetch));
    await waitFor(() => expect(result.current.loaded).toBe(true));
    await act(() => result.current.refresh());
    expect(result.current.items[0].id).toBe("1");
    await act(() => result.current.loadMore());
    expect(fetch.mock.calls[2]).toEqual([null]);
    expect(result.current.items[0].id).toBe("2");
  });
});
