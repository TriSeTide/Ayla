import { act, renderHook, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { listCommentsPage } from "../api/posts";
import type { DirectoryPage } from "../api/directory";
import type { PostComment } from "../api/types";
import { usePostComments } from "../hooks/usePostComments";
import { useAuthStore } from "../stores/auth";
import { chatWS } from "../ws/chat";

vi.mock("../api/posts", () => ({ listCommentsPage: vi.fn() }));
vi.mock("../ws/chat", () => ({ chatWS: { onFrame: vi.fn(() => vi.fn()) } }));
vi.mock("../stores/auth", async () => {
  const { create } = await import("zustand");
  return { useAuthStore: create(() => ({ currentUser: { id: "test" }, accessToken: "test" })) };
});
let account = 0;
const comment = (id: number, postId = 1) => ({ id, post_id: postId, author_id: "test", body: `评论${id}`, reply_to: null, is_author: false, images: [], media: null, media_id: null, created_at: "2026-09-08T00:00:00Z" } as unknown as PostComment);
const page = (ids: number[], cursor: string | null = null, postId = 1): DirectoryPage<PostComment> => ({ results: ids.map((id) => comment(id, postId)), next_cursor: cursor, has_more: cursor !== null, total: 40 });
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((yes) => { resolve = yes; });
  return { promise, resolve };
}
const handler = () => vi.mocked(chatWS.onFrame).mock.calls.at(-1)![0];
beforeEach(() => {
  vi.clearAllMocks();
  useAuthStore.setState({ currentUser: { id: `comment-reader-${++account}` } as never });
  vi.mocked(listCommentsPage).mockReset().mockResolvedValue(page([]));
});

describe("post comments cursor ownership", () => {
  it("requests 20 initially and preserves the cursor and rows after a failed append", async () => {
    vi.mocked(listCommentsPage).mockResolvedValueOnce(page([1, 2], "next"))
      .mockRejectedValueOnce(new Error("评论下一页暂时失败")).mockResolvedValueOnce(page([2, 3]));
    const { result } = renderHook(() => usePostComments(1));
    await waitFor(() => expect(result.current.loaded).toBe(true));
    expect(listCommentsPage).toHaveBeenNthCalledWith(1, 1, { limit: 20, cursor: null });
    await act(async () => result.current.loadMore());
    expect(result.current.items.map((item) => item.id)).toEqual([1, 2]);
    expect(result.current.cursor).toBe("next");
    expect(result.current.errorKind).toBe("append");
    await act(async () => result.current.retry());
    expect(listCommentsPage).toHaveBeenLastCalledWith(1, { limit: 20, cursor: "next" });
    expect(result.current.items.map((item) => item.id)).toEqual([1, 2, 3]);
  });
  it("one pending page owns repeated load-more calls", async () => {
    const pending = deferred<DirectoryPage<PostComment>>();
    vi.mocked(listCommentsPage).mockResolvedValueOnce(page([1], "next")).mockReturnValueOnce(pending.promise);
    const { result } = renderHook(() => usePostComments(1));
    await waitFor(() => expect(result.current.loaded).toBe(true));
    act(() => { void result.current.loadMore(); void result.current.loadMore(); });
    expect(listCommentsPage).toHaveBeenCalledTimes(2);
    await act(async () => pending.resolve(page([2])));
  });
  it("WS and local creations survive a delayed head, and deletion cannot reappear", async () => {
    const pending = deferred<DirectoryPage<PostComment>>();
    vi.mocked(listCommentsPage).mockReturnValueOnce(pending.promise);
    const { result } = renderHook(() => usePostComments(1));
    act(() => {
      handler()({ type: "comment.created", data: { post_id: "1", comment: comment(9), comment_count: 9 } } as never);
      result.current.upsert(comment(10));
      handler()({ type: "comment.deleted", data: { post_id: "1", comment_id: 2, comment_count: 9 } } as never);
    });
    await act(async () => pending.resolve(page([1, 2], "next")));
    expect(result.current.items.map((item) => item.id)).toEqual([1, 9, 10]);
    expect(result.current.total).toBe(9);
    act(() => handler()({ type: "comment.created", data: { post_id: "1", comment: comment(9), comment_count: 9 } } as never));
    expect(result.current.items.map((item) => item.id)).toEqual([1, 9, 10]);
  });
  it("post switches reject a stale page and an old post mutation callback", async () => {
    const old = deferred<DirectoryPage<PostComment>>();
    vi.mocked(listCommentsPage).mockReturnValueOnce(old.promise).mockResolvedValueOnce(page([20], null, 2));
    const { result, rerender } = renderHook(({ id }) => usePostComments(id), { initialProps: { id: 1 } });
    const oldUpsert = result.current.upsert;
    rerender({ id: 2 });
    await waitFor(() => expect(result.current.items[0]?.id).toBe(20));
    await act(async () => { old.resolve(page([1])); oldUpsert(comment(5)); });
    expect(result.current.items.map((item) => item.id)).toEqual([20]);
  });
  it("restores loaded pages on return and only later new rows enable entry motion", async () => {
    vi.mocked(listCommentsPage).mockResolvedValueOnce(page([1], "next")).mockResolvedValueOnce(page([2], "third")).mockResolvedValueOnce(page([3]));
    const first = renderHook(() => usePostComments(1));
    await waitFor(() => expect(first.result.current.loaded).toBe(true));
    await act(async () => first.result.current.loadMore());
    first.unmount();
    const second = renderHook(() => usePostComments(1));
    expect(second.result.current.items.map((item) => item.id)).toEqual([1, 2]);
    expect(second.result.current.suppressEntry).toBe(true);
    expect(listCommentsPage).toHaveBeenCalledTimes(2);
    await act(async () => second.result.current.loadMore());
    expect(second.result.current.items.map((item) => item.id)).toEqual([1, 2, 3]);
    expect(second.result.current.suppressEntry).toBe(false);
  });
  it("logout and the same account login do not revive an old cached page", async () => {
    vi.mocked(listCommentsPage).mockResolvedValueOnce(page([1])).mockResolvedValueOnce(page([2]));
    const first = renderHook(() => usePostComments(1));
    await waitFor(() => expect(first.result.current.loaded).toBe(true));
    first.unmount();
    act(() => { useAuthStore.setState({ accessToken: null }); useAuthStore.setState({ accessToken: "again" }); });
    const next = renderHook(() => usePostComments(1));
    await waitFor(() => expect(next.result.current.items[0]?.id).toBe(2));
    expect(listCommentsPage).toHaveBeenCalledTimes(2);
  });
  it("invalid cursor or cross-post rows silently degrade while retaining the page", async () => {
    vi.mocked(listCommentsPage).mockResolvedValueOnce(page([1], "next"))
      .mockResolvedValueOnce(page([2], "next")).mockResolvedValueOnce(page([2], null, 99));
    const { result } = renderHook(() => usePostComments(1));
    await waitFor(() => expect(result.current.loaded).toBe(true));
    await act(async () => result.current.loadMore());
    // 静默降级：不显示错误，已加载页保留
    expect(result.current.error).toBeNull();
    expect(result.current.items.map((item) => item.id)).toEqual([1]);
    await act(async () => result.current.retry());
    expect(result.current.error).toBeNull();
    expect(result.current.items.map((item) => item.id)).toEqual([1]);
  });
});
