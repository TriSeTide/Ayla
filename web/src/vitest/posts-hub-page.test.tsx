/**
 * PostsHubPage 测试（Bug #8）：群外帖子信息流顶部必须有「我的帖子」入口，
 * 点击跳转 /posts/mine（scope=mine，全局）。
 */
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as favoritesApi from "../api/favorites";
import * as postsApi from "../api/posts";
import type { Post, PostListPage } from "../api/types";
import { PostsHubPage } from "../pages/PostsHubPage";
import { usePostsStore } from "../stores/posts";
import { useShellStore } from "../stores/shell";
import { clearScrollMemory, saveScrollPosition } from "../hooks/useScrollRestore";
import { chatWS } from "../ws/chat";

vi.mock("../api/posts", () => ({
  listPosts: vi.fn(),
  getPost: vi.fn(),
  reportPostViews: vi.fn().mockResolvedValue({ updated: {} }),
}));
vi.mock("../api/favorites", () => ({
  listFavorites: vi.fn().mockResolvedValue([]),
  addFavorite: vi.fn(),
  removeFavorite: vi.fn(),
}));
vi.mock("../components/posts/PostCard", () => ({
  PostCard: ({ post, favorited, onToggleFavorite }: { post: Post; favorited: boolean; onToggleFavorite: () => void }) => (
    <div><span>帖卡</span><span>{post.title}</span><button type="button" aria-pressed={favorited} onClick={onToggleFavorite}>收藏{post.id}</button></div>
  ),
}));
vi.mock("../ws/chat", () => ({ chatWS: { onFrame: vi.fn(() => vi.fn()) } }));

function post(id: number): Post {
  return {
    id, author_id: "u1", title: `帖子${id}`, body: "正文", visibility: "public",
    group: null, group_name: null, images: [], comment_count: 0, is_author: false,
    view_count: 0, is_viewed: false, created_at: "2026-09-08T00:00:00Z", updated_at: "2026-09-08T00:00:00Z",
    author: { id: "u1", username: "alice", nickname: "爱丽丝", avatar: "", signature: "", status: "auto", online: false, date_joined: "2026-01-01T00:00:00Z" },
  };
}

function page(ids: number[], cursor: string | null): PostListPage {
  return { results: ids.map(post), next_cursor: cursor, has_more: cursor != null };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}

function scrollNearBottom(container: HTMLElement) {
  const hub = container.querySelector(".posts-hub") as HTMLElement;
  Object.defineProperties(hub, {
    scrollHeight: { configurable: true, value: 1000 },
    clientHeight: { configurable: true, value: 400 },
  });
  hub.scrollTop = 550;
  fireEvent.scroll(hub);
}

function renderHub() {
  return render(
    <MemoryRouter initialEntries={["/posts"]}>
      <Routes>
        <Route path="/posts" element={<PostsHubPage />} />
        <Route path="/posts/mine" element={<div>我的帖子页占位</div>} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  clearScrollMemory();
  vi.mocked(favoritesApi.listFavorites).mockResolvedValue([]);
});

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
  act(() => usePostsStore.getState().reset());
  useShellStore.getState().registerRefresh(null);
});

describe("PostsHubPage 我的帖子入口", () => {
  it("首屏请求 pending 保持骨架，成功后显示帖子", async () => {
    let resolvePage!: (page: PostListPage) => void;
    vi.mocked(postsApi.listPosts).mockReturnValue(new Promise((resolve) => { resolvePage = resolve; }));
    const { container } = renderHub();
    const post: Post = {
      id: 1, author_id: "u1", title: "测试帖子", body: "正文", visibility: "public",
      group: null, group_name: null, images: [], comment_count: 0, is_author: false,
      view_count: 0, is_viewed: false, created_at: "2026-09-08T00:00:00Z", updated_at: "2026-09-08T00:00:00Z",
      author: {
        id: "u1", username: "alice", nickname: "爱丽丝", avatar: "", signature: "",
        status: "auto", online: false, date_joined: "2026-01-01T00:00:00Z",
      },
    };

    expect(container.querySelector(".posts-skeleton .skeleton")).not.toBeNull();
    expect(usePostsStore.getState().loading).toBe(true);
    expect(screen.queryByText("还没有帖子")).not.toBeInTheDocument();
    await act(async () => resolvePage({ results: [post], next_cursor: null, has_more: false }));
    expect(screen.getByText("帖卡")).toBeInTheDocument();
    expect(container.querySelector(".posts-skeleton")).toBeNull();
    expect(usePostsStore.getState().loading).toBe(false);
  });

  it("失败重试在请求完成前显示骨架，空响应才显示空态", async () => {
    vi.mocked(postsApi.listPosts).mockRejectedValueOnce(new Error("帖子加载失败"));
    const { container } = renderHub();
    expect(await screen.findByRole("alert")).toHaveTextContent("帖子加载失败");

    let resolvePage!: (page: PostListPage) => void;
    vi.mocked(postsApi.listPosts).mockReturnValue(new Promise((resolve) => { resolvePage = resolve; }));
    fireEvent.click(screen.getByRole("button", { name: "重试" }));
    expect(container.querySelector(".posts-skeleton .skeleton")).not.toBeNull();
    expect(screen.queryByText("还没有帖子")).not.toBeInTheDocument();
    await act(async () => resolvePage({ results: [], next_cursor: null, has_more: false }));
    expect(screen.getByText("还没有帖子")).toBeInTheDocument();
    expect(container.querySelector(".posts-skeleton")).toBeNull();
  });

  it("信息流顶部存在「我的帖子」入口链接", async () => {
    vi.mocked(postsApi.listPosts).mockResolvedValue({ results: [], next_cursor: null, has_more: false });
    renderHub();
    await waitFor(() => expect(postsApi.listPosts).toHaveBeenCalled());
    expect(screen.getByRole("link", { name: "我的帖子" })).toBeInTheDocument();
    expect(favoritesApi.listFavorites).toHaveBeenCalledWith("post");
  });

  it("点击「我的帖子」跳转到 /posts/mine", async () => {
    vi.mocked(postsApi.listPosts).mockResolvedValue({ results: [], next_cursor: null, has_more: false });
    renderHub();
    await waitFor(() => expect(postsApi.listPosts).toHaveBeenCalled());
    fireEvent.click(screen.getByRole("link", { name: "我的帖子" }));
    expect(await screen.findByText("我的帖子页占位")).toBeInTheDocument();
  });

  it("重复滚底只追加一次，重复id与本页重复记录不会产生重复卡", async () => {
    const next = deferred<PostListPage>();
    vi.mocked(postsApi.listPosts).mockResolvedValueOnce(page([1, 2], "next-1")).mockReturnValueOnce(next.promise);
    const { container } = renderHub();
    await screen.findByText("帖子1");
    const first = container.querySelector('[data-post-id="1"]');
    scrollNearBottom(container);
    scrollNearBottom(container);
    expect(postsApi.listPosts).toHaveBeenCalledTimes(2);
    expect(postsApi.listPosts).toHaveBeenLastCalledWith({ scope: "feed", limit: 20, cursor: "next-1" });
    await act(async () => next.resolve(page([2, 3, 3], "next-2")));
    expect(usePostsStore.getState().posts.map((p) => p.id)).toEqual([1, 2, 3]);
    expect(container.querySelector('[data-post-id="1"]')).toBe(first);
    expect(usePostsStore.getState().nextCursor).toBe("next-2");
  });

  it("追加失败显示错误并保留旧页和cursor，后续滚动不自动重试", async () => {
    vi.mocked(postsApi.listPosts).mockResolvedValueOnce(page([1], "next-1")).mockRejectedValueOnce(new Error("下一页断网"));
    const { container } = renderHub();
    await screen.findByText("帖子1");
    scrollNearBottom(container);
    expect(await screen.findByRole("alert")).toHaveTextContent("下一页断网");
    expect(usePostsStore.getState().nextCursor).toBe("next-1");
    expect(screen.getByText("帖子1")).toBeInTheDocument();
    scrollNearBottom(container);
    expect(postsApi.listPosts).toHaveBeenCalledTimes(2);
    vi.mocked(postsApi.listPosts).mockResolvedValueOnce(page([2], null));
    fireEvent.click(screen.getByRole("button", { name: "重试加载更多" }));
    await screen.findByText("帖子2");
    expect(postsApi.listPosts).toHaveBeenLastCalledWith({ scope: "feed", limit: 20, cursor: "next-1" });
    expect(screen.queryByRole("alert")).toBeNull();
  });

  it("刷新接管后旧追加即使更晚完成也不覆盖新页、cursor或loading", async () => {
    const oldAppend = deferred<PostListPage>();
    const fresh = deferred<PostListPage>();
    const newAppend = deferred<PostListPage>();
    vi.mocked(postsApi.listPosts).mockResolvedValueOnce(page([1], "old-next")).mockReturnValueOnce(oldAppend.promise).mockReturnValueOnce(fresh.promise).mockReturnValueOnce(newAppend.promise);
    const { container } = renderHub();
    await screen.findByText("帖子1");
    scrollNearBottom(container);
    let refresh!: Promise<void>;
    act(() => { refresh = Promise.resolve(useShellStore.getState().refreshCallback!()); });
    await act(async () => { fresh.resolve(page([10], "fresh-next")); await refresh; });
    scrollNearBottom(container);
    expect(usePostsStore.getState().loading).toBe(true);
    await act(async () => oldAppend.resolve(page([2], "stale-next")));
    expect(usePostsStore.getState().posts.map((p) => p.id)).toEqual([10]);
    expect(usePostsStore.getState().nextCursor).toBe("fresh-next");
    expect(usePostsStore.getState().loading).toBe(true);
    await act(async () => newAppend.resolve(page([11], null)));
    expect(usePostsStore.getState().posts.map((p) => p.id)).toEqual([10, 11]);
  });

  it("刷新失败保留原cursor与卡片并显示错误，旧追加仍失效", async () => {
    const oldAppend = deferred<PostListPage>();
    vi.mocked(postsApi.listPosts).mockResolvedValueOnce(page([1], "next-1")).mockReturnValueOnce(oldAppend.promise).mockRejectedValueOnce(new Error("刷新失败"));
    const { container } = renderHub();
    await screen.findByText("帖子1");
    scrollNearBottom(container);
    await act(async () => { await useShellStore.getState().refreshCallback!(); });
    expect(screen.getByRole("alert")).toHaveTextContent("刷新失败");
    await act(async () => oldAppend.resolve(page([2], "stale-next")));
    expect(usePostsStore.getState().posts.map((p) => p.id)).toEqual([1]);
    expect(usePostsStore.getState().nextCursor).toBe("next-1");
    vi.mocked(postsApi.listPosts).mockResolvedValueOnce(page([3], null));
    fireEvent.click(screen.getByRole("button", { name: "加载更多" }));
    await screen.findByText("帖子3");
    expect(screen.queryByRole("alert")).toBeNull();
  });

  it("卸载后迟到的首页不能写回共享store，下一次挂载仍可正常加载", async () => {
    const abandoned = deferred<PostListPage>();
    vi.mocked(postsApi.listPosts).mockReturnValueOnce(abandoned.promise);
    const first = renderHub();
    first.unmount();
    expect(usePostsStore.getState().loading).toBe(false);
    vi.mocked(postsApi.listPosts).mockResolvedValueOnce(page([9], null));
    renderHub();
    await screen.findByText("帖子9");
    await act(async () => abandoned.resolve(page([1], null)));
    expect(usePostsStore.getState().posts.map((p) => p.id)).toEqual([9]);
  });

  it("WS新帖和删除、浏览及收藏变化在刷新响应后仍保留", async () => {
    const fresh = deferred<PostListPage>();
    vi.mocked(postsApi.listPosts).mockResolvedValueOnce(page([1, 2], "next-1")).mockReturnValueOnce(fresh.promise);
    renderHub();
    await screen.findByText("帖子1");
    let refresh!: Promise<void>;
    act(() => { refresh = Promise.resolve(useShellStore.getState().refreshCallback!()); });
    const onFrame = vi.mocked(chatWS.onFrame).mock.calls[0][0];
    vi.mocked(postsApi.getPost).mockResolvedValueOnce(post(3));
    await act(async () => {
      onFrame({ type: "post.created", post: {
        id: "3", title: "帖子3", body: "正文", owner_id: "u1", group_id: null,
        visibility: "public", created_at: "2026-09-08T00:00:00Z",
      } });
      onFrame({ type: "post.deleted", post_id: "2" });
      usePostsStore.getState().markViewedBatch({ "1": 7 });
      usePostsStore.getState().setFavorite("1", 99);
    });
    await act(async () => { fresh.resolve(page([1, 2], "fresh-next")); await refresh; });
    expect(usePostsStore.getState().posts.map((p) => p.id)).toEqual([3, 1]);
    expect(usePostsStore.getState().posts[1]).toMatchObject({ is_viewed: true, view_count: 7 });
    expect(screen.getByRole("button", { name: "收藏1" })).toHaveAttribute("aria-pressed", "true");
  });

  it("未推进cursor显式失败，不能循环重复取相同页", async () => {
    vi.mocked(postsApi.listPosts).mockResolvedValueOnce(page([1], "next-1")).mockResolvedValueOnce(page([2], "next-1"));
    const { container } = renderHub();
    await screen.findByText("帖子1");
    scrollNearBottom(container);
    expect(await screen.findByRole("alert")).toHaveTextContent("下一页游标未推进");
    expect(usePostsStore.getState().posts.map((p) => p.id)).toEqual([1]);
    scrollNearBottom(container);
    expect(postsApi.listPosts).toHaveBeenCalledTimes(2);
  });

  it("恢复已加载两页后旧卡不重播，下一页和刷新只让新增DOM入场", async () => {
    const previousAnimate = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "animate");
    const animated: HTMLElement[] = [];
    Object.defineProperty(HTMLElement.prototype, "animate", { configurable: true, value: function (this: HTMLElement) {
      animated.push(this);
      return { cancel: vi.fn(), onfinish: null };
    } });
    try {
      act(() => usePostsStore.getState().setPage([post(1), post(2)], "next-2", true));
      const scrollOwner = document.createElement("div");
      scrollOwner.scrollTop = 320;
      saveScrollPosition("posts-feed", scrollOwner);
      const { container } = renderHub();
      expect(postsApi.listPosts).not.toHaveBeenCalled();
      expect((container.querySelector(".posts-hub") as HTMLElement).scrollTop).toBe(320);
      expect(animated).toHaveLength(0);
      const first = container.querySelector('[data-post-id="1"]');
      vi.mocked(postsApi.listPosts).mockResolvedValueOnce(page([3], null));
      fireEvent.click(screen.getByRole("button", { name: "加载更多" }));
      await screen.findByText("帖子3");
      expect(animated.map((node) => node.dataset.postId)).toEqual(["3"]);
      vi.mocked(postsApi.listPosts).mockResolvedValueOnce(page([1, 2, 3, 4], null));
      await act(async () => { await useShellStore.getState().refreshCallback!(); });
      expect(container.querySelector('[data-post-id="1"]')).toBe(first);
      expect(animated.map((node) => node.dataset.postId)).toEqual(["3", "4"]);
      cleanup();
    } finally {
      if (previousAnimate) Object.defineProperty(HTMLElement.prototype, "animate", previousAnimate);
      else delete (HTMLElement.prototype as unknown as { animate?: unknown }).animate;
    }
  });
});
