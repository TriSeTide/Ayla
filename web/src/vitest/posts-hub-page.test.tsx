import { FavoriteButton } from "../components/FavoriteButton";
import { ensureFavoriteScope, useFavoriteStatusStore } from "../stores/favoriteStatus";
/**
 * PostsHubPage 测试：分类选项卡（全部/热门/公开/好友/我的）过滤与排序契约 +
 * 每 tab 独立加载（切 tab 自动拉取该 tab 第一页，scope=feed/mine）+
 * 分页/刷新/滚动恢复回归（原「我的帖子」链接已被「我的」tab 取代）。
 */
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as favoritesApi from "../api/favorites";
import * as postsApi from "../api/posts";
import * as usersApi from "../api/users";
import type { Post, PostListPage } from "../api/types";
import { PostsHubPage, clearPostTabMemory } from "../pages/PostsHubPage";
import { usePostsStore } from "../stores/posts";
import { useShellStore } from "../stores/shell";
import { useSocialStore } from "../stores/social";
import { useAuthStore } from "../stores/auth";
import { clearScrollMemory, saveScrollPosition } from "../hooks/useScrollRestore";
import { chatWS } from "../ws/chat";

vi.mock("../api/posts", () => ({
  listPosts: vi.fn(),
  getPost: vi.fn(),
  reportPostViews: vi.fn().mockResolvedValue({ updated: {} }),
}));
vi.mock("../api/favorites", () => ({
  listFavorites: vi.fn().mockResolvedValue([]),
  getFavoriteStatuses: vi.fn().mockImplementation(async (target_type, ids: string[]) => ({ target_type, statuses: Object.fromEntries(ids.map((id) => [id, null])) })),
  addFavorite: vi.fn(),
  removeFavorite: vi.fn(),
}));
vi.mock("../api/users", () => ({
  listFriendsPage: vi.fn(),
}));
vi.mock("../components/posts/PostCard", () => ({
  PostCard: ({ post }: { post: Post }) => (
    <div><span>帖卡</span><span>{post.title}</span><FavoriteButton targetType="post" targetId={post.id} compact /></div>
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
  const hub = container.querySelector(".directory-content") as HTMLElement;
  Object.defineProperties(hub, {
    scrollHeight: { configurable: true, value: 1000 },
    clientHeight: { configurable: true, value: 400 },
  });
  hub.scrollTop = 550;
  fireEvent.scroll(hub);
}

function LocationProbe() {
  const location = useLocation();
  return <div data-testid="location">{location.search}</div>;
}

function renderHub(entry = "/posts") {
  return render(
    <MemoryRouter initialEntries={[entry]}>
      <LocationProbe />
      <Routes>
        <Route path="/posts" element={<PostsHubPage />} />
        <Route path="/posts/mine" element={<div>我的帖子页占位</div>} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  ensureFavoriteScope();
  useFavoriteStatusStore.setState({ entries: new Map() });
  useSocialStore.getState().reset();
  clearPostTabMemory();
  clearScrollMemory();
  useAuthStore.setState({
    accessToken: "acc",
    currentUser: {
      id: "u1", username: "alice", nickname: "爱丽丝", avatar: "", signature: "",
      status: "online", online: true, date_joined: "2026-01-01T00:00:00Z",
    },
  });
  vi.mocked(favoritesApi.getFavoriteStatuses).mockImplementation(async (target_type, ids) => ({ target_type, statuses: Object.fromEntries(ids.map((id) => [id, null])) }));
  vi.mocked(favoritesApi.listFavorites).mockResolvedValue([]);
  // 好友列表：u2 是 u1 的好友（好友 tab = 作者是好友）
  vi.mocked(usersApi.listFriendsPage).mockResolvedValue({
    results: [{ id: 1, user: { id: "u2", username: "bob", nickname: "鲍勃", avatar: "", signature: "", status: "auto", online: false, date_joined: "2026-01-01T00:00:00Z" }, created_at: "2026-01-01T00:00:00Z" }],
    next_cursor: null, has_more: false, total: 1,
  });
});

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
  act(() => usePostsStore.getState().reset());
  useSocialStore.getState().reset();
  clearPostTabMemory();
  useShellStore.getState().registerRefresh(null);
});

describe("PostsHubPage 分类选项卡与分页", () => {
  it("首屏请求 pending 保持骨架，成功后显示帖子", async () => {
    let resolvePage!: (page: PostListPage) => void;
    vi.mocked(postsApi.listPosts).mockReturnValue(new Promise((resolve) => { resolvePage = resolve; }));
    const { container } = renderHub();
    expect(container.querySelector(".posts-skeleton .skeleton")).not.toBeNull();
    expect(screen.queryByText("还没有帖子")).not.toBeInTheDocument();
    await act(async () => resolvePage({ results: [post(1)], next_cursor: null, has_more: false }));
    expect(screen.getByText("帖卡")).toBeInTheDocument();
    expect(container.querySelector(".posts-skeleton")).toBeNull();
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

  it("分类选项卡存在；「我的」tab 拉 scope=mine 且只显示我的帖子", async () => {
    vi.mocked(postsApi.listPosts).mockImplementation(async ({ scope } = {}) => {
      if (scope === "mine") return { results: [{ ...post(2), is_author: true }], next_cursor: null, has_more: false };
      return { results: [post(1), { ...post(2), is_author: true }], next_cursor: null, has_more: false };
    });
    renderHub();
    await screen.findByText("帖子1");
    expect(screen.getByRole("tablist", { name: "帖子分类" })).toBeInTheDocument();
    expect(screen.getByRole("tab", { name: "全部" })).toHaveAttribute("aria-selected", "true");
    expect(screen.getByText("帖子2")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("tab", { name: "我的" }));
    expect(screen.getByRole("tab", { name: "我的" })).toHaveAttribute("aria-selected", "true");
    // 「我的」tab 独立加载：scope=mine
    await waitFor(() => expect(postsApi.listPosts).toHaveBeenLastCalledWith({ scope: "mine", limit: 20 }));
    expect(screen.queryByText("帖子1")).not.toBeInTheDocument();
    expect(screen.getByText("帖子2")).toBeInTheDocument();
  });

  it("tab 切换写入 URL ?type=，返回「全部」清空参数", async () => {
    vi.mocked(postsApi.listPosts).mockResolvedValue({ results: [post(1)], next_cursor: null, has_more: false });
    renderHub();
    await screen.findByText("帖子1");
    fireEvent.click(screen.getByRole("tab", { name: "热门" }));
    expect(screen.getByTestId("location")).toHaveTextContent("type=hot");
    fireEvent.click(screen.getByRole("tab", { name: "全部" }));
    expect(screen.getByTestId("location")).toHaveTextContent("");
  });

  it("侧栏统计显示后端 total（分页后总数），非已加载条数", async () => {
    vi.mocked(postsApi.listPosts).mockResolvedValue({ results: [post(1)], next_cursor: "next", has_more: true, total: 25 });
    renderHub();
    await screen.findByText("帖子1");
    expect(screen.getByText("25 条帖子")).toBeInTheDocument();
  });

  it("热门 tab 按 view_count 降序（唯一排序例外）", async () => {
    vi.mocked(postsApi.listPosts).mockResolvedValue({
      results: [{ ...post(1), view_count: 3 }, { ...post(2), view_count: 9 }, { ...post(3), view_count: 5 }],
      next_cursor: null, has_more: false,
    });
    renderHub();
    await screen.findByText("帖子1");
    fireEvent.click(screen.getByRole("tab", { name: "热门" }));
    await waitFor(() => expect(postsApi.listPosts).toHaveBeenLastCalledWith({ scope: "feed", limit: 20 }));
    const items = document.querySelectorAll(".posts-feed-item");
    expect(Array.from(items).map((item) => item.getAttribute("data-post-id"))).toEqual(["2", "3", "1"]);
  });

  it("公开/好友 tab 按 visibility/好友过滤", async () => {
    vi.mocked(postsApi.listPosts).mockResolvedValue({
      results: [
        { ...post(1), visibility: "public" },
        { ...post(2), visibility: "friends", author_id: "u2" },
        { ...post(3), visibility: "group" },
        { ...post(4), visibility: "public", author_id: "u2" },
      ],
      next_cursor: null, has_more: false,
    });
    renderHub();
    await screen.findByText("帖子1");
    fireEvent.click(screen.getByRole("tab", { name: "公开" }));
    // 公开 tab 由后端过滤（visibility=public），不依赖「全部」分页进度
    await waitFor(() => expect(postsApi.listPosts).toHaveBeenLastCalledWith({ scope: "feed", visibility: "public", limit: 20 }));
    expect(screen.getByText("帖子1")).toBeInTheDocument();
    expect(screen.queryByText("帖子2")).not.toBeInTheDocument();
    expect(screen.queryByText("帖子3")).not.toBeInTheDocument();
    expect(screen.getByText("帖子4")).toBeInTheDocument();
    // 好友 = 作者是好友（u2 的 public/friends 都算），后端 friends=1 过滤
    fireEvent.click(screen.getByRole("tab", { name: "好友" }));
    await waitFor(() => expect(postsApi.listPosts).toHaveBeenLastCalledWith({ scope: "feed", friends: true, limit: 20 }));
    expect(screen.queryByText("帖子1")).not.toBeInTheDocument();
    expect(screen.getByText("帖子2")).toBeInTheDocument();
    expect(screen.queryByText("帖子3")).not.toBeInTheDocument();
    expect(screen.getByText("帖子4")).toBeInTheDocument();
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
    console.log("DEBUG-IDS:", Array.from(container.querySelectorAll('[data-post-id]')).map((el) => el.getAttribute("data-post-id")));
    console.log("DEBUG-CALLS:", vi.mocked(postsApi.listPosts).mock.calls.map((c) => c[0]));
    expect(container.querySelectorAll('[data-post-id]')).toHaveLength(3);
    expect(container.querySelector('[data-post-id="1"]')).toBe(first);
  });

  it("追加失败显示错误并保留旧页和cursor，后续滚动不自动重试", async () => {
    vi.mocked(postsApi.listPosts).mockResolvedValueOnce(page([1], "next-1")).mockRejectedValueOnce(new Error("下一页断网"));
    const { container } = renderHub();
    await screen.findByText("帖子1");
    scrollNearBottom(container);
    expect(await screen.findByRole("alert")).toHaveTextContent("下一页断网");
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
    await act(async () => oldAppend.resolve(page([2], "stale-next")));
    expect(container.querySelectorAll('[data-post-id]')).toHaveLength(1);
    expect(container.querySelector('[data-post-id="10"]')).not.toBeNull();
    await act(async () => newAppend.resolve(page([11], null)));
    expect(container.querySelector('[data-post-id="11"]')).not.toBeNull();
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
    expect(container.querySelectorAll('[data-post-id]')).toHaveLength(1);
    vi.mocked(postsApi.listPosts).mockResolvedValueOnce(page([3], null));
    fireEvent.click(screen.getByRole("button", { name: "加载更多" }));
    await screen.findByText("帖子3");
    expect(screen.queryByRole("alert")).toBeNull();
  });

  it("卸载后迟到的首页不能写回，下一次挂载仍可正常加载", async () => {
    const abandoned = deferred<PostListPage>();
    vi.mocked(postsApi.listPosts).mockReturnValueOnce(abandoned.promise);
    const first = renderHub();
    first.unmount();
    vi.mocked(postsApi.listPosts).mockResolvedValueOnce(page([9], null));
    renderHub();
    await screen.findByText("帖子9");
    await act(async () => abandoned.resolve(page([1], null)));
    expect(screen.queryByText("帖子1")).not.toBeInTheDocument();
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
    expect(screen.getByText("帖子3")).toBeInTheDocument();
    expect(screen.queryByText("帖子2")).not.toBeInTheDocument();
    expect(getFavorite(1)!).toHaveAttribute("aria-pressed", "true");
  });

  it("未推进cursor静默降级，不显示错误且不再重复请求", async () => {
    vi.mocked(postsApi.listPosts).mockResolvedValueOnce(page([1], "next-1")).mockResolvedValueOnce(page([2], "next-1"));
    const { container } = renderHub();
    await screen.findByText("帖子1");
    scrollNearBottom(container);
    // 静默：无错误提示，列表保持已加载页
    expect(screen.queryByRole("alert")).toBeNull();
    expect(container.querySelectorAll('[data-post-id]')).toHaveLength(1);
    // nextFailed 阻止后续滚动重复请求相同页
    scrollNearBottom(container);
    expect(postsApi.listPosts).toHaveBeenCalledTimes(2);
  });

  it("恢复已加载两页后旧卡不重播，下一页只让新增DOM入场，刷新重播已入场卡片", async () => {
    const previousAnimate = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "animate");
    const animated: HTMLElement[] = [];
    Object.defineProperty(HTMLElement.prototype, "animate", { configurable: true, value: function (this: HTMLElement) {
      animated.push(this);
      return { cancel: vi.fn(), onfinish: null };
    } });
    try {
      // 预置「全部」tab 两页缓存（保留 hasMore）：首屏不重拉，直接恢复
      vi.mocked(postsApi.listPosts).mockResolvedValueOnce(page([1, 2], "next-2")).mockResolvedValueOnce(page([3], "next-3"));
      const firstRender = renderHub();
      await screen.findByText("帖子1");
      fireEvent.click(screen.getByRole("button", { name: "加载更多" }));
      await screen.findByText("帖子3");
      firstRender.unmount();
      animated.length = 0;
      const scrollOwner = document.createElement("div");
      scrollOwner.scrollTop = 320;
      saveScrollPosition("posts-feed:all", scrollOwner);
      const callsBefore = vi.mocked(postsApi.listPosts).mock.calls.length;
      const { container } = renderHub();
      // 缓存命中：第二次挂载不重拉（调用次数不变）
      expect(postsApi.listPosts).toHaveBeenCalledTimes(callsBefore);
      expect((container.querySelector(".directory-content") as HTMLElement).scrollTop).toBe(320);
      expect(animated).toHaveLength(0);
      const first = container.querySelector('[data-post-id="1"]');
      vi.mocked(postsApi.listPosts).mockResolvedValueOnce(page([4], null));
      fireEvent.click(screen.getByRole("button", { name: "加载更多" }));
      await screen.findByText("帖子4");
      expect(animated.map((node) => node.dataset.postId)).toEqual(["4"]);
      vi.mocked(postsApi.listPosts).mockResolvedValueOnce(page([1, 2, 3, 4, 5], null));
      await act(async () => { await useShellStore.getState().refreshCallback!(); });
      expect(container.querySelector('[data-post-id="1"]')).toBe(first);
      // 刷新：已入场 1/2/3/4 整批重播，新增 5 单独入场
      expect(animated.map((node) => node.dataset.postId)).toEqual(["4", "1", "2", "3", "4", "5"]);
      cleanup();
    } finally {
      if (previousAnimate) Object.defineProperty(HTMLElement.prototype, "animate", previousAnimate);
      else delete (HTMLElement.prototype as unknown as { animate?: unknown }).animate;
    }
  });

  it("切换 tab 后手动刷新重播已入场卡片（刷新动画不失效）", async () => {
    const previousAnimate = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "animate");
    const animated: HTMLElement[] = [];
    Object.defineProperty(HTMLElement.prototype, "animate", { configurable: true, value: function (this: HTMLElement) {
      animated.push(this);
      return { cancel: vi.fn(), onfinish: null };
    } });
    try {
      vi.mocked(postsApi.listPosts).mockResolvedValue({ results: [post(1)], next_cursor: null, has_more: false });
      renderHub();
      await screen.findByText("帖子1");
      // 切到热门 tab：新 tab 独立加载，卡片入场
      fireEvent.click(screen.getByRole("tab", { name: "热门" }));
      await screen.findByText("帖子1");
      animated.length = 0;
      // 手动刷新（RefreshFAB 通道）：已入场卡片整批重播
      await act(async () => { await useShellStore.getState().refreshCallback!(); });
      expect(animated.map((node) => node.dataset.postId)).toEqual(["1"]);
      cleanup();
    } finally {
      if (previousAnimate) Object.defineProperty(HTMLElement.prototype, "animate", previousAnimate);
      else delete (HTMLElement.prototype as unknown as { animate?: unknown }).animate;
    }
  });
});

function getFavorite(id: number) {
  return document.querySelector<HTMLElement>(`[data-post-id="${id}"] .favorite-toggle`);
}
