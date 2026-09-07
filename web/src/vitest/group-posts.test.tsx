import { FavoriteButton } from "../components/FavoriteButton";
import { ensureFavoriteScope, useFavoriteStatusStore } from "../stores/favoriteStatus";
/**
 * GroupPosts 测试（Bug #8 + 任务 07）：
 * - 群内帖子列表顶部必须有「我的帖子」入口，点击跳转 /posts/mine；
 * - 收藏键接入真实收藏：favorited 来自 posts store，点击调 favoritesApi 并更新 store。
 */
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as postsApi from "../api/posts";
import * as favoritesApi from "../api/favorites";
import type { Favorite, Post, PostListPage } from "../api/types";
import { GroupPosts } from "../pages/group/GroupPosts";
import { usePostsStore } from "../stores/posts";
import { useChatStore } from "../stores/chat";
import { useShellStore } from "../stores/shell";
import { clearScrollMemory } from "../hooks/useScrollRestore";
import { chatWS } from "../ws/chat";

vi.mock("../api/posts", () => ({
  listPosts: vi.fn(),
  getPost: vi.fn(),
  reportPostViews: vi.fn().mockResolvedValue({ updated: {} }),
}));
vi.mock("../api/favorites", () => ({
  listFavorites: vi.fn(),
  getFavoriteStatuses: vi.fn(),
  addFavorite: vi.fn(),
  removeFavorite: vi.fn(),
}));
vi.mock("../ws/chat", () => ({
  chatWS: { onFrame: vi.fn(() => vi.fn()) },
}));
vi.mock("../components/posts/PostCard", () => ({
  PostCard: ({ post }: { post: Post }) => (
    <div><span>帖卡</span><span>{post.title}</span><FavoriteButton targetType="post" targetId={post.id} compact /></div>
  ),
}));
vi.mock("../components/posts/PostEditor", () => ({
  PostEditor: ({ onCreated }: { onCreated: (post: Post) => void }) => <div>发帖编辑器<button type="button" onClick={() => onCreated({ ...post(5), title: "本地新帖" })}>测试发帖</button></div>,
}));
vi.mock("../pages/PostDetailPage", () => ({ PostDetailPage: () => <div>帖子详情占位</div> }));

function post(id: number): Post {
  return {
    id,
    author_id: "u1",
    author: {
      id: "u1",
      username: "u1",
      nickname: "用户1",
      avatar: "",
      signature: "",
      status: "auto",
      online: false,
      date_joined: "2026-01-01T00:00:00Z",
    },
    title: "",
    body: `帖子${id}`,
    images: [],
    comment_count: 0,
    visibility: "public",
    allowed_group_ids: ["1"],
    group: null,
    group_name: null,
    is_author: false,
    view_count: 0,
    is_viewed: false,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
  };
}

function renderGroupPosts() {
  return render(
    <MemoryRouter initialEntries={["/group/1/posts"]}>
      <Routes>
        <Route
          path="/group/:id/posts"
          element={<GroupPosts groupId="1" onExit={() => {}} />}
        />
        <Route path="/posts/mine" element={<div>我的帖子页占位</div>} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  ensureFavoriteScope();
  useFavoriteStatusStore.setState({ entries: new Map() });
  vi.mocked(favoritesApi.getFavoriteStatuses).mockImplementation(async (target_type, ids) => ({ target_type, statuses: Object.fromEntries(ids.map((id) => [id, null])) }));
  clearScrollMemory();
  usePostsStore.getState().reset();
  vi.mocked(postsApi.listPosts).mockResolvedValue({ results: [], next_cursor: null, has_more: false });
  vi.mocked(favoritesApi.listFavorites).mockResolvedValue([]);
});

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
  usePostsStore.getState().reset();
  useChatStore.setState({ conversations: [] });
});

function deferredPage() {
  let resolve!: (page: PostListPage) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<PostListPage>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function scrollNearBottom(root: HTMLElement) {
  Object.defineProperties(root, {
    scrollHeight: { configurable: true, value: 1000 },
    clientHeight: { configurable: true, value: 200 },
  });
  root.scrollTop = 790;
  fireEvent.scroll(root);
}

describe("GroupPosts bounded cursor pages", () => {
  it("首屏只拉一次，不因未读总数或全局缓存显示整群", async () => {
    useChatStore.setState({ conversations: [{ id: "1", post_unread_count: 100 }] as never });
    usePostsStore.setState({ posts: Array.from({ length: 30 }, (_, i) => post(i + 1)) });
    vi.mocked(postsApi.listPosts).mockResolvedValue({
      results: [post(2), post(1)], next_cursor: "page-2", has_more: true,
    });
    renderGroupPosts();
    await findFavorite(1);
    expect(postsApi.listPosts).toHaveBeenCalledTimes(1);
    expect(document.querySelectorAll(".posts-feed-item")).toHaveLength(2);
    expect(getFavorite(30)).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "加载更多帖子" })).toBeInTheDocument();
  });

  it("滚底只请求一页，重复scroll共享忙锁，append去重且旧卡DOM保持", async () => {
    const pending = deferredPage();
    vi.mocked(postsApi.listPosts)
      .mockResolvedValueOnce({ results: [post(3), post(2)], next_cursor: "page-2", has_more: true })
      .mockReturnValueOnce(pending.promise);
    renderGroupPosts();
    const retained = await findFavorite(3);
    const root = document.querySelector<HTMLElement>(".group-posts-list")!;
    scrollNearBottom(root);
    fireEvent.scroll(root);
    expect(postsApi.listPosts).toHaveBeenCalledTimes(2);
    expect(postsApi.listPosts).toHaveBeenLastCalledWith({ scope: "group:1", limit: 20, cursor: "page-2" });
    await act(async () => pending.resolve({ results: [post(2), post(1), post(1)], next_cursor: null, has_more: false }));
    expect(await findFavorite(1)).toBeInTheDocument();
    expect(getFavorite(3)!).toBe(retained);
    expect(document.querySelectorAll(".posts-feed-item")).toHaveLength(3);
    expect(screen.queryByRole("button", { name: "加载更多帖子" })).not.toBeInTheDocument();
  });

  it("下一页失败保留旧卡及cursor，停止滚动自动重试直到用户明确重试", async () => {
    vi.mocked(postsApi.listPosts)
      .mockResolvedValueOnce({ results: [post(2)], next_cursor: "page-2", has_more: true })
      .mockRejectedValueOnce(new Error("下一页暂不可用"))
      .mockResolvedValueOnce({ results: [post(1)], next_cursor: null, has_more: false });
    renderGroupPosts();
    const retained = await findFavorite(2);
    const root = document.querySelector<HTMLElement>(".group-posts-list")!;
    scrollNearBottom(root);
    await screen.findByText("下一页暂不可用");
    fireEvent.scroll(root);
    expect(postsApi.listPosts).toHaveBeenCalledTimes(2);
    expect(getFavorite(2)!).toBe(retained);
    fireEvent.click(screen.getByRole("button", { name: "重试加载更多" }));
    await findFavorite(1);
    expect(postsApi.listPosts).toHaveBeenLastCalledWith({ scope: "group:1", limit: 20, cursor: "page-2" });
  });

  it("旧群未完成的请求不能覆盖新群，首屏失败可明确重试", async () => {
    const stale = deferredPage();
    vi.mocked(postsApi.listPosts)
      .mockReturnValueOnce(stale.promise)
      .mockRejectedValueOnce(new Error("群2首屏失败"))
      .mockResolvedValueOnce({ results: [{ ...post(20), allowed_group_ids: ["2"] }], next_cursor: null, has_more: false });
    const view = render(<MemoryRouter><GroupPosts groupId="1" onExit={() => {}} /></MemoryRouter>);
    view.rerender(<MemoryRouter><GroupPosts groupId="2" onExit={() => {}} /></MemoryRouter>);
    await screen.findByText("群2首屏失败");
    fireEvent.click(screen.getByRole("button", { name: "重试" }));
    await findFavorite(20);
    await act(async () => stale.resolve({ results: [post(1)], next_cursor: "stale", has_more: true }));
    expect(getFavorite(1)).not.toBeInTheDocument();
    expect(getFavorite(20)!).toBeInTheDocument();
  });

  it("已加载两页详情往返不重请求，返回后可继续第三页", async () => {
    vi.mocked(postsApi.listPosts)
      .mockResolvedValueOnce({ results: [post(3)], next_cursor: "page-2", has_more: true })
      .mockResolvedValueOnce({ results: [post(2)], next_cursor: "page-3", has_more: true })
      .mockResolvedValueOnce({ results: [post(1)], next_cursor: null, has_more: false });
    const view = render(<MemoryRouter><GroupPosts groupId="1" onExit={() => {}} /></MemoryRouter>);
    await findFavorite(3);
    fireEvent.click(screen.getByRole("button", { name: "加载更多帖子" }));
    await findFavorite(2);
    view.rerender(<MemoryRouter><GroupPosts groupId="1" postId="3" onExit={() => {}} /></MemoryRouter>);
    expect(screen.getByText("帖子详情占位")).toBeInTheDocument();
    view.rerender(<MemoryRouter><GroupPosts groupId="1" onExit={() => {}} /></MemoryRouter>);
    expect(await findFavorite(2)).toBeInTheDocument();
    expect(postsApi.listPosts).toHaveBeenCalledTimes(2);
    fireEvent.click(screen.getByRole("button", { name: "加载更多帖子" }));
    await findFavorite(1);
    expect(postsApi.listPosts).toHaveBeenLastCalledWith({ scope: "group:1", limit: 20, cursor: "page-3" });
  });

  it("append在详情中完成仍保留返回滚动和恢复抑制，之后新增页才入场", async () => {
    const previousAnimate = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "animate");
    const animated: HTMLElement[] = [];
    Object.defineProperty(HTMLElement.prototype, "animate", {
      configurable: true,
      value: function (this: HTMLElement) {
        animated.push(this);
        return { cancel: vi.fn(), onfinish: null };
      },
    });
    try {
      const pending = deferredPage();
      vi.mocked(postsApi.listPosts)
        .mockResolvedValueOnce({ results: [post(3)], next_cursor: "page-2", has_more: true })
        .mockReturnValueOnce(pending.promise)
        .mockResolvedValueOnce({ results: [post(1)], next_cursor: null, has_more: false });
      const view = render(<MemoryRouter><GroupPosts groupId="1" onExit={() => {}} /></MemoryRouter>);
      await findFavorite(3);
      expect(animated.filter((node) => node.matches(".posts-feed-item"))).toHaveLength(1);
      const root = document.querySelector<HTMLElement>(".group-posts-list")!;
      root.scrollTop = 320;
      fireEvent.scroll(root);
      fireEvent.click(screen.getByRole("button", { name: "加载更多帖子" }));
      view.rerender(<MemoryRouter><GroupPosts groupId="1" postId="3" onExit={() => {}} /></MemoryRouter>);
      await act(async () => pending.resolve({ results: [post(2)], next_cursor: "page-3", has_more: true }));
      view.rerender(<MemoryRouter><GroupPosts groupId="1" onExit={() => {}} /></MemoryRouter>);
      await findFavorite(2);
      expect(document.querySelector<HTMLElement>(".group-posts-list")!.scrollTop).toBe(320);
      expect(animated.filter((node) => node.matches(".posts-feed-item"))).toHaveLength(1);
      fireEvent.click(screen.getByRole("button", { name: "加载更多帖子" }));
      await findFavorite(1);
      expect(animated.filter((node) => node.matches(".posts-feed-item"))).toHaveLength(2);
      expect(animated.filter((node) => node.dataset.postId === "1")).toHaveLength(1);
      cleanup();
    } finally {
      if (previousAnimate) Object.defineProperty(HTMLElement.prototype, "animate", previousAnimate);
      else delete (HTMLElement.prototype as unknown as { animate?: unknown }).animate;
    }
  });

  it("删除提示不重拉首屏，新增提示只读取单条详情并保留旧卡", async () => {
    vi.mocked(postsApi.listPosts).mockResolvedValue({ results: [post(2), post(1)], next_cursor: "page-2", has_more: true });
    vi.mocked(postsApi.getPost).mockResolvedValue(post(3));
    renderGroupPosts();
    const retained = await findFavorite(2);
    const calls = vi.mocked(chatWS.onFrame).mock.calls;
    const handler = calls[calls.length - 1][0];
    act(() => handler({ type: "post.deleted", post_id: "1" }));
    expect(getFavorite(1)).not.toBeInTheDocument();
    act(() => handler({ type: "post.created", post: { id: "3" } } as never));
    await findFavorite(3);
    expect(postsApi.listPosts).toHaveBeenCalledTimes(1);
    expect(postsApi.getPost).toHaveBeenCalledWith(3);
    expect(getFavorite(2)!).toBe(retained);
  });

  it("刷新仅一页且保留同id卡DOM，不再key重挂整个流", async () => {
    vi.mocked(postsApi.listPosts)
      .mockResolvedValueOnce({ results: [post(2), post(1)], next_cursor: "page-2", has_more: true })
      .mockResolvedValueOnce({ results: [post(3), post(2)], next_cursor: "fresh-2", has_more: true });
    renderGroupPosts();
    const retained = await findFavorite(2);
    await act(async () => { await useShellStore.getState().refreshCallback?.(); });
    await findFavorite(3);
    expect(postsApi.listPosts).toHaveBeenCalledTimes(2);
    expect(getFavorite(2)!).toBe(retained);
    expect(getFavorite(1)).not.toBeInTheDocument();
  });

  it("刷新旧首页不吞掉期间 WS 新帖/编辑、本地发布、删除或可见范围变化", async () => {
    const pending = deferredPage();
    vi.mocked(postsApi.listPosts)
      .mockResolvedValueOnce({ results: [post(1), post(2), post(4)], next_cursor: "old-next", has_more: true })
      .mockReturnValueOnce(pending.promise);
    vi.mocked(postsApi.getPost).mockImplementation(async (id) => ({ ...post(id),
      title: id === 1 ? "实时编辑" : "实时新帖", allowed_group_ids: id === 4 ? ["2"] : ["1"],
    }));
    renderGroupPosts();
    const retained = await findFavorite(1);
    let refresh!: Promise<void>;
    act(() => { refresh = Promise.resolve(useShellStore.getState().refreshCallback!()); });
    const handler = vi.mocked(chatWS.onFrame).mock.calls.at(-1)![0];
    await act(async () => {
      handler({ type: "post.created", post: { id: "3" } } as never);
      handler({ type: "post.updated", post: { id: "1" } } as never);
      handler({ type: "post.updated", post: { id: "4" } } as never);
      handler({ type: "post.deleted", post_id: "2" });
    });
    fireEvent.click(screen.getByRole("button", { name: "测试发帖" }));
    await findFavorite(5);
    await act(async () => {
      pending.resolve({ results: [post(1), post(2), post(4)], next_cursor: "new-next", has_more: true });
      await refresh;
    });
    expect(screen.getByText("实时编辑")).toBeInTheDocument();
    expect(screen.getByText("实时新帖")).toBeInTheDocument();
    expect(screen.getByText("本地新帖")).toBeInTheDocument();
    expect(getFavorite(1)).toBe(retained);
    expect(getFavorite(2)).toBeNull();
    expect(getFavorite(4)).toBeNull();
    expect(document.querySelectorAll(".posts-feed-item")).toHaveLength(3);
  });

  it("同帖后来的更新先返回时，早期单条对账不能覆盖它", async () => {
    let resolveOld!: (value: Post) => void;
    vi.mocked(postsApi.listPosts).mockResolvedValue({ results: [post(1)], next_cursor: null, has_more: false });
    vi.mocked(postsApi.getPost)
      .mockReturnValueOnce(new Promise((resolve) => { resolveOld = resolve; }))
      .mockResolvedValueOnce({ ...post(1), title: "后来的编辑" });
    renderGroupPosts();
    await findFavorite(1);
    const handler = vi.mocked(chatWS.onFrame).mock.calls.at(-1)![0];
    await act(async () => {
      handler({ type: "post.updated", post: { id: "1" } } as never);
      handler({ type: "post.updated", post: { id: "1" } } as never);
    });
    await screen.findByText("后来的编辑");
    await act(async () => resolveOld({ ...post(1), title: "较早的编辑" }));
    expect(screen.getByText("后来的编辑")).toBeInTheDocument();
    expect(screen.queryByText("较早的编辑")).toBeNull();
  });
});

describe("GroupPosts 我的帖子入口", () => {
  it("列表顶部存在「我的帖子」入口链接，点击跳转 /posts/mine", async () => {
    renderGroupPosts();
    const link = await screen.findByRole("link", { name: "我的帖子" });
    expect(screen.getByRole("heading", { name: "群内帖子" })).toBeInTheDocument();
    expect(link.closest(".group-scene-head")).not.toBeNull();
    link.click();
    expect(await screen.findByText("我的帖子页占位")).toBeInTheDocument();
    expect(postsApi.listPosts).toHaveBeenCalledWith({ scope: "group:1", limit: 20, cursor: null });
  });
});

describe("GroupPosts 收藏键（任务 07）", () => {
  it("挂载时加载我的帖子收藏状态（favorited 来自 posts store）", async () => {
    vi.mocked(postsApi.listPosts).mockResolvedValue({
      results: [post(1)],
      next_cursor: null,
      has_more: false,
    });
    vi.mocked(favoritesApi.getFavoriteStatuses).mockResolvedValue({ target_type: "post", statuses: { "1": 100 } });
    renderGroupPosts();

    const btn = await findFavorite(1);
    await waitFor(() => expect(btn).toHaveAttribute("aria-pressed", "true"));
    expect(favoritesApi.listFavorites).not.toHaveBeenCalled();
  });

  it("点击收藏键 → 调 addFavorite 并更新 posts store（即时反馈）", async () => {
    vi.mocked(postsApi.listPosts).mockResolvedValue({
      results: [post(1)],
      next_cursor: null,
      has_more: false,
    });
    vi.mocked(favoritesApi.addFavorite).mockResolvedValue({
      id: 100,
      target_type: "post",
      target_id: "1",
    } as Favorite);
    renderGroupPosts();

    const btn = await findFavorite(1);
    expect(btn).toHaveAttribute("aria-pressed", "false");
    fireEvent.click(btn);

    await waitFor(() => expect(favoritesApi.addFavorite).toHaveBeenCalledWith("post", "1"));
    expect(useFavoriteStatusStore.getState().entries.get("post:1")?.favoriteId).toBe(100);
    await waitFor(() => expect(btn).toHaveAttribute("aria-pressed", "true"));
  });

  it("已收藏时点击 → 调 removeFavorite 并清空 store 收藏态", async () => {
    vi.mocked(postsApi.listPosts).mockResolvedValue({
      results: [post(1)],
      next_cursor: null,
      has_more: false,
    });
    vi.mocked(favoritesApi.getFavoriteStatuses).mockResolvedValue({ target_type: "post", statuses: { "1": 100 } });
    vi.mocked(favoritesApi.removeFavorite).mockResolvedValue({ deleted: true });
    renderGroupPosts();

    const btn = await findFavorite(1);
    await waitFor(() => expect(btn).toHaveAttribute("aria-pressed", "true"));
    fireEvent.click(btn);

    await waitFor(() => expect(favoritesApi.removeFavorite).toHaveBeenCalledWith(100));
    expect(useFavoriteStatusStore.getState().entries.get("post:1")?.favoriteId).toBeNull();
    await waitFor(() => expect(btn).toHaveAttribute("aria-pressed", "false"));
  });
});

function getFavorite(id: number) {
  return document.querySelector<HTMLElement>(`[data-post-id="${id}"] .favorite-toggle`);
}
async function findFavorite(id: number) {
  return waitFor(() => {
    const button = getFavorite(id);
    expect(button).toHaveAttribute("aria-pressed");
    return button!;
  });
}
