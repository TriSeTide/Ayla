/**
 * FavoritesPage 测试（F10 R-U3 + 任务 07）：
 * - 分类收藏列表 + 取消收藏即时移除；
 * - openTarget 全类型跳转（voice 直达语音房 / game 直达桌游房 / live/post/group/message）；
 * - WS favorite.changed 实时同步（removed 本地移除 / added 重新加载）。
 */
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes, useNavigate } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as favoritesApi from "../api/favorites";
import type { Favorite, FavoriteTargetType } from "../api/types";
import { FavoritesPage, clearFavoritePageMemory } from "../pages/FavoritesPage";
import { clearMasonryMemory } from "../hooks/useMasonryColumns";
import { usePostsStore } from "../stores/posts";
import { useAuthStore } from "../stores/auth";
import { clearScrollMemory } from "../hooks/useScrollRestore";
const originalAnimate = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "animate");

/** 捕获 chatWS.onFrame 注册的 handler（测试里 fire favorite.changed 帧用） */
const ws = vi.hoisted(() => ({
  frameHandler: null as ((frame: unknown) => void) | null,
}));

vi.mock("../api/favorites", () => ({
  listFavoritesPage: vi.fn(),
  removeFavorite: vi.fn(),
}));

vi.mock("../ws/chat", () => ({
  chatWS: {
    onFrame: vi.fn((handler: (frame: unknown) => void) => {
      ws.frameHandler = handler;
      return vi.fn();
    }),
  },
}));

function fav(
  id: number,
  targetType: FavoriteTargetType,
  targetId: string,
  target: Record<string, unknown> | null,
): Favorite {
  return {
    id,
    user_id: "u1",
    target_type: targetType,
    target_id: targetId,
    target,
    created_at: "2026-01-01T00:00:00Z",
  };
}

function favoritePage(rows: Favorite[], cursor: string | null = null) { return { results: rows, next_cursor: cursor, has_more: cursor !== null, total: rows.length }; }

function DetailWithBack() {
  const navigate = useNavigate();
  return <div>帖子详情占位<button onClick={() => navigate(-1)}>返回收藏列表</button></div>;
}

function renderPage(entry = "/favorites") {
  return render(
    <MemoryRouter initialEntries={[entry]}>
      <Routes>
        <Route path="/favorites" element={<FavoritesPage />} />
        <Route path="/voice/:channelId" element={<div>语音房占位</div>} />
        <Route path="/games/:roomId" element={<div>桌游房占位</div>} />
        <Route path="/live/:channelId" element={<div>直播间占位</div>} />
        <Route path="/posts/:postId" element={<DetailWithBack />} />
        <Route path="/group/:id" element={<div>群占位</div>} />
        <Route path="/chat/:conversationId" element={<div>会话占位</div>} />
      </Routes>
    </MemoryRouter>,
  );
}

function responsiveViewport(initialWidth: number) {
  let width = initialWidth;
  const listeners = new Set<() => void>();
  vi.stubGlobal("matchMedia", vi.fn((query: string) => ({
    get matches() {
      return query === "(max-width: 768px)" ? width <= 768 : query === "(max-width: 1024px)" ? width <= 1024 : query === "(prefers-reduced-motion: reduce)";
    },
    addEventListener: (_type: string, listener: () => void) => listeners.add(listener),
    removeEventListener: (_type: string, listener: () => void) => listeners.delete(listener),
  })));
  return (nextWidth: number) => {
    width = nextWidth;
    act(() => Array.from(listeners).forEach((listener) => listener()));
  };
}

function columnIds(container: HTMLElement): string[][] {
  return Array.from(container.querySelectorAll(".favorites-masonry-col"), (column) =>
    Array.from(column.querySelectorAll("[data-favorite-id]"), (item) => item.getAttribute("data-favorite-id")!),
  );
}

beforeEach(() => {
  clearMasonryMemory();
  clearFavoritePageMemory();
  clearScrollMemory();
  useAuthStore.setState({ currentUser: { id: "u1", username: "reader", nickname: "reader", avatar: "", signature: "", status: "auto", online: false, date_joined: "2026-01-01T00:00:00Z" } });
  vi.stubGlobal(
    "matchMedia",
    vi.fn(() => ({ matches: true, addEventListener: vi.fn(), removeEventListener: vi.fn() })),
  );
  usePostsStore.getState().reset();
  ws.frameHandler = null;
  vi.mocked(favoritesApi.listFavoritesPage).mockReset().mockResolvedValue(favoritePage([
    fav(1, "post", "10", { id: "10", title: "帖子A", body: "正文" }),
    fav(2, "post", "11", { id: "11", title: "帖子B", body: "正文" }),
  ]));
  vi.mocked(favoritesApi.removeFavorite).mockResolvedValue({ deleted: true });
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: Error) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

describe("收藏真实分页", () => {
  it("筛选位于结果滚动区外，首次分类归零、返回分类恢复分页和位置", async () => {
    vi.mocked(favoritesApi.listFavoritesPage)
      .mockResolvedValueOnce(favoritePage([fav(1, "message", "50", { content: "全部消息", conversation_id: "c1" })], "all-next"))
      .mockResolvedValueOnce(favoritePage([fav(2, "post", "11", { title: "帖子分类" })], "post-next"));
    const { container } = renderPage();
    await screen.findByText("全部消息");
    const filters = screen.getByRole("tablist", { name: "收藏分类" });
    const allScroll = container.querySelector<HTMLElement>(".favorites-content")!;
    expect(allScroll.contains(filters)).toBe(false);
    allScroll.scrollTop = 280;
    fireEvent.click(screen.getByRole("tab", { name: "帖子" }));
    await screen.findByText("帖子分类");
    const postScroll = container.querySelector<HTMLElement>(".favorites-content")!;
    expect(postScroll).not.toBe(allScroll);
    expect(postScroll.scrollTop).toBe(0);
    postScroll.scrollTop = 90;
    fireEvent.click(screen.getByRole("tab", { name: "全部" }));
    await screen.findByText("全部消息");
    expect(container.querySelector<HTMLElement>(".favorites-content")!.scrollTop).toBe(280);
    fireEvent.click(screen.getByRole("tab", { name: "帖子" }));
    await screen.findByText("帖子分类");
    expect(container.querySelector<HTMLElement>(".favorites-content")!.scrollTop).toBe(90);
    expect(screen.getByRole("tablist", { name: "收藏分类" })).toBe(filters);
    expect(favoritesApi.listFavoritesPage).toHaveBeenCalledTimes(2);
    vi.mocked(favoritesApi.listFavoritesPage).mockResolvedValueOnce(favoritePage([]));
    fireEvent.click(screen.getByRole("button", { name: "加载更多" }));
    await waitFor(() => expect(favoritesApi.listFavoritesPage).toHaveBeenLastCalledWith({ type: "post", limit: 20, cursor: "post-next" }));
  });

  it("目标已删除或权限撤销时显示不可用并保留取消收藏操作", async () => {
    vi.mocked(favoritesApi.listFavoritesPage).mockResolvedValueOnce(favoritePage([fav(1, "post", "10", null)]));
    renderPage();
    expect(await screen.findByRole("button", { name: /内容不可用/ })).toBeDisabled();
    expect(screen.getByRole("button", { name: "取消收藏" })).not.toBeDisabled();
  });
  it("按服务器cursor追加并去重，已有DOM/焦点/滚动和页外帖子收藏索引保留", async () => {
    const a = fav(1, "post", "10", { title: "第一页A" });
    const b = fav(2, "post", "11", { title: "第一页B" });
    const c = fav(3, "post", "12", { title: "第二页C" });
    vi.mocked(favoritesApi.listFavoritesPage).mockResolvedValueOnce(favoritePage([a, b], "cursor-one"))
      .mockResolvedValueOnce(favoritePage([b, c]));
    usePostsStore.getState().setFavorite("outside-page", 888);
    const { container } = renderPage();
    const retained = await screen.findByRole("button", { name: /第一页B/ });
    retained.focus();
    const scroll = container.querySelector<HTMLElement>(".favorites-content")!;
    scroll.scrollTop = 440;
    fireEvent.click(screen.getByRole("button", { name: "加载更多" }));
    await screen.findByText("第二页C");
    expect(favoritesApi.listFavoritesPage).toHaveBeenLastCalledWith({ type: undefined, limit: 20, cursor: "cursor-one" });
    expect(container.querySelectorAll(".favorite-item")).toHaveLength(3);
    expect(screen.getByRole("button", { name: /第一页B/ })).toBe(retained);
    expect(retained).toHaveFocus();
    expect(scroll.scrollTop).toBe(440);
    expect(usePostsStore.getState().favoriteByPostId["outside-page"]).toBe(888);
    expect(screen.queryByRole("button", { name: "加载更多" })).not.toBeInTheDocument();
  });

  it("续页失败保留已有卡片和cursor，显式重试同一页", async () => {
    vi.mocked(favoritesApi.listFavoritesPage)
      .mockResolvedValueOnce(favoritePage([fav(1, "post", "10", { title: "保留内容" })], "retry-cursor"))
      .mockRejectedValueOnce(new Error("续页网络失败"))
      .mockResolvedValueOnce(favoritePage([fav(2, "post", "11", { title: "重试成功" })]));
    renderPage();
    const retained = await screen.findByText("保留内容");
    fireEvent.click(screen.getByRole("button", { name: "加载更多" }));
    await screen.findByText("续页网络失败");
    expect(screen.getByText("保留内容")).toBe(retained);
    fireEvent.click(screen.getByRole("button", { name: "重试" }));
    await screen.findByText("重试成功");
    expect(vi.mocked(favoritesApi.listFavoritesPage).mock.calls.slice(1)).toEqual([
      [{ type: undefined, limit: 20, cursor: "retry-cursor" }],
      [{ type: undefined, limit: 20, cursor: "retry-cursor" }],
    ]);
  });

  it("删除在续页响应之前发生时，重复项不能复活已取消收藏", async () => {
    const a = fav(1, "post", "10", { title: "将被移除" });
    const pending = deferred<ReturnType<typeof favoritePage>>();
    vi.mocked(favoritesApi.listFavoritesPage).mockResolvedValueOnce(favoritePage([a], "next"))
      .mockReturnValueOnce(pending.promise)
      .mockResolvedValueOnce(favoritePage([fav(2, "post", "11", { title: "保留的新页" })]));
    renderPage();
    await screen.findByText("将被移除");
    fireEvent.click(screen.getByRole("button", { name: "加载更多" }));
    act(() => ws.frameHandler?.({ type: "favorite.changed", data: { target_type: "post", target_id: "10", favorite_id: 1, action: "removed" } }));
    await act(async () => pending.resolve(favoritePage([a, fav(2, "post", "11", { title: "保留的新页" })])));
    // stale → 自动刷新（重新拉取，a 已移除）
    await waitFor(() => expect(screen.getByText("保留的新页")).toBeInTheDocument());
    expect(screen.queryByText("将被移除")).not.toBeInTheDocument();
  });

  it("切换分类后旧首屏响应不得污染新分类", async () => {
    const previous = deferred<ReturnType<typeof favoritePage>>();
    vi.mocked(favoritesApi.listFavoritesPage).mockReturnValueOnce(previous.promise)
      .mockResolvedValueOnce(favoritePage([fav(2, "post", "11", { title: "新分类帖子" })]));
    renderPage();
    fireEvent.click(screen.getByRole("tab", { name: "帖子" }));
    await screen.findByText("新分类帖子");
    await act(async () => previous.resolve(favoritePage([fav(1, "message", "50", { content: "旧分类迟到" })])));
    expect(screen.queryByText("旧分类迟到")).not.toBeInTheDocument();
    expect(screen.getByText("新分类帖子")).toBeInTheDocument();
  });

  it("账号变更后旧请求和旧缓存均不能显示", async () => {
    const previous = deferred<ReturnType<typeof favoritePage>>();
    vi.mocked(favoritesApi.listFavoritesPage).mockReturnValueOnce(previous.promise)
      .mockResolvedValueOnce(favoritePage([{ ...fav(2, "post", "11", { title: "新账号收藏" }), user_id: "next-user" }]));
    renderPage();
    act(() => useAuthStore.setState({ currentUser: { id: "next-user", username: "next", nickname: "next", avatar: "", signature: "", status: "auto", online: false, date_joined: "2026-01-01T00:00:00Z" } }));
    await screen.findByText("新账号收藏");
    await act(async () => previous.resolve(favoritePage([fav(1, "post", "10", { title: "旧账号迟到" })])));
    expect(screen.queryByText("旧账号迟到")).not.toBeInTheDocument();
  });

  it("详情返回恢复分类、已加载的多页和滚动，继续使用保存的cursor", async () => {
    const animated: HTMLElement[] = [];
    vi.stubGlobal("matchMedia", vi.fn((query: string) => ({ matches: query === "(max-width: 768px)", addEventListener: vi.fn(), removeEventListener: vi.fn() })));
    Object.defineProperty(HTMLElement.prototype, "animate", { configurable: true, value: function(this: HTMLElement) {
      if (this.matches(".favorite-item")) animated.push(this);
      return { cancel: vi.fn(), onfinish: null };
    } });
    const a = fav(1, "post", "10", { title: "第一页卡片" });
    const b = fav(2, "post", "11", { title: "第二页卡片" });
    const c = fav(3, "post", "12", { title: "第三页卡片" });
    vi.mocked(favoritesApi.listFavoritesPage).mockResolvedValueOnce(favoritePage([a], "c1"))
      .mockResolvedValueOnce(favoritePage([b], "c2")).mockResolvedValueOnce(favoritePage([c]));
    const { container } = renderPage("/favorites?type=post");
    await screen.findByText("第一页卡片");
    fireEvent.click(screen.getByRole("button", { name: "加载更多" }));
    await screen.findByText("第二页卡片");
    expect(animated).toHaveLength(2);
    const scroll = container.querySelector<HTMLElement>(".favorites-content")!;
    scroll.scrollTop = 370;
    fireEvent.scroll(scroll);
    fireEvent.click(screen.getByText("第二页卡片"));
    fireEvent.click(await screen.findByRole("button", { name: "返回收藏列表" }));
    await screen.findByText("第二页卡片");
    expect(favoritesApi.listFavoritesPage).toHaveBeenCalledTimes(2);
    expect(screen.getByRole("tab", { name: "帖子" })).toHaveAttribute("aria-selected", "true");
    expect(container.querySelector<HTMLElement>(".favorites-content")!.scrollTop).toBe(370);
    expect(animated).toHaveLength(2);
    fireEvent.click(screen.getByRole("button", { name: "加载更多" }));
    await screen.findByText("第三页卡片");
    expect(favoritesApi.listFavoritesPage).toHaveBeenLastCalledWith({ type: "post", limit: 20, cursor: "c2" });
    expect(animated).toHaveLength(3);
  });

  it("刷新首页失败后的重试仍是首页请求，不能误续旧页", async () => {
    vi.mocked(favoritesApi.listFavoritesPage)
      .mockResolvedValueOnce(favoritePage([fav(1, "post", "10", { title: "原有收藏" })], "older-page"))
      .mockRejectedValueOnce(new Error("首页刷新失败"))
      .mockResolvedValueOnce(favoritePage([fav(2, "post", "11", { title: "新首页" })]));
    renderPage();
    await screen.findByText("原有收藏");
    act(() => ws.frameHandler?.({ type: "favorite.changed", data: { target_type: "post", target_id: "11", favorite_id: 2, action: "added" } }));
    // stale → 自动刷新首页（无需点击"收藏有更新"按钮）；失败后显示错误+重试
    await screen.findByText("首页刷新失败");
    fireEvent.click(screen.getByRole("button", { name: "重试" }));
    await screen.findByText("新首页");
    expect(favoritesApi.listFavoritesPage).toHaveBeenLastCalledWith({ type: undefined, limit: 20, cursor: null });
  });
});

afterEach(() => {
  if (originalAnimate) Object.defineProperty(HTMLElement.prototype, "animate", originalAnimate);
  else Reflect.deleteProperty(HTMLElement.prototype, "animate");
  vi.unstubAllGlobals();
  vi.clearAllMocks();
  usePostsStore.getState().reset();
});

describe("FavoritesPage", () => {
  it.each([1025, 1440])("宽屏 %d 使用独立两列，取消其他卡片保留剩余 DOM、列归属与焦点", async (width) => {
    responsiveViewport(width);
    vi.mocked(favoritesApi.listFavoritesPage).mockResolvedValue(favoritePage([
      fav(1, "post", "10", { title: "帖子A", body: "较长正文".repeat(60) }),
      fav(2, "post", "11", { title: "帖子B", body: "短正文" }),
      fav(3, "post", "12", { title: "帖子C", body: "正文C" }),
      fav(4, "post", "13", { title: "帖子D", body: "正文D" }),
    ]));
    const { container } = renderPage();
    await screen.findByText("帖子A");
    expect(columnIds(container)).toEqual([["1", "3"], ["2", "4"]]);
    const retained = screen.getByText("帖子B").closest("button")!;
    retained.focus();
    const removal = container.querySelector('[data-favorite-id="1"] .msg-action-btn')!;
    fireEvent.click(removal);
    await waitFor(() => expect(screen.queryByText("帖子A")).not.toBeInTheDocument());
    expect(columnIds(container)).toEqual([["3"], ["2", "4"]]);
    expect(screen.getByText("帖子B").closest("button")).toBe(retained);
    expect(retained).toHaveFocus();
  });

  it("1024/1025 断点往返保留单列 API 顺序，宽屏恢复各自列归属", async () => {
    const setWidth = responsiveViewport(1024);
    vi.mocked(favoritesApi.listFavoritesPage).mockResolvedValue(favoritePage([
      fav(1, "post", "10", { title: "帖子A" }),
      fav(2, "post", "11", { title: "帖子B" }),
      fav(3, "post", "12", { title: "帖子C" }),
    ]));
    const { container } = renderPage();
    await screen.findByText("帖子A");
    expect(columnIds(container)).toEqual([["1", "2", "3"]]);
    setWidth(1025);
    expect(columnIds(container)).toEqual([["1", "3"], ["2"]]);
    setWidth(1024);
    expect(columnIds(container)).toEqual([["1", "2", "3"]]);
    expect(favoritesApi.listFavoritesPage).toHaveBeenCalledTimes(1);
  });

  it("分类使用独立分列记忆，异步筛选保留筛选按钮焦点", async () => {
    responsiveViewport(1440);
    const items = [
      fav(1, "message", "50", { content: "消息A", conversation_id: "c1" }),
      fav(2, "post", "11", { title: "帖子B" }),
      fav(3, "post", "12", { title: "帖子C" }),
    ];
    vi.mocked(favoritesApi.listFavoritesPage).mockResolvedValue(favoritePage(items));
    const { container } = renderPage();
    await screen.findByText("消息A");
    expect(columnIds(container)).toEqual([["1", "3"], ["2"]]);
    let resolveFilter!: (page: ReturnType<typeof favoritePage>) => void;
    vi.mocked(favoritesApi.listFavoritesPage).mockReturnValue(new Promise((resolve) => { resolveFilter = resolve; }));
    const postFilter = screen.getByRole("tab", { name: "帖子" });
    postFilter.focus();
    fireEvent.click(postFilter);
    expect(container.querySelector(".favorites-list")).toBeNull();
    expect(container.querySelector(".favorites-skeleton")).not.toBeNull();
    expect(screen.queryByText("消息A")).not.toBeInTheDocument();
    await act(async () => resolveFilter(favoritePage(items.slice(1))));
    expect(columnIds(container)).toEqual([["2"], ["3"]]);
    expect(postFilter).toHaveFocus();
    expect(favoritesApi.listFavoritesPage).toHaveBeenLastCalledWith({ type: "post", limit: 20, cursor: null });
  });

  it("展示帖子收藏列表", async () => {
    renderPage();
    await waitFor(() => expect(screen.getByText("帖子A")).toBeInTheDocument());
    expect(screen.getByText("帖子B")).toBeInTheDocument();
  });

  it("取消收藏即时移除", async () => {
    renderPage();
    await waitFor(() => expect(screen.getByText("帖子A")).toBeInTheDocument());
    const buttons = screen.getAllByRole("button", { name: "取消收藏" });
    fireEvent.click(buttons[0]);
    await waitFor(() => expect(screen.queryByText("帖子A")).not.toBeInTheDocument());
    expect(favoritesApi.removeFavorite).toHaveBeenCalledWith(1);
  });

  it("空态提示", async () => {
    vi.mocked(favoritesApi.listFavoritesPage).mockResolvedValue(favoritePage([]));
    renderPage();
    await waitFor(() => expect(screen.getByText("这个分类还没有收藏")).toBeInTheDocument());
  });

  describe("openTarget 全类型跳转（任务 07）", () => {
    it("语音房收藏 → 直达具体语音房 /voice/:channelId（不是大厅）", async () => {
      vi.mocked(favoritesApi.listFavoritesPage).mockResolvedValue(favoritePage([
        fav(1, "voice", "42", { id: "42", name: "语音房A" }),
      ]));
      renderPage();
      await waitFor(() => expect(screen.getByText("语音房A")).toBeInTheDocument());
      fireEvent.click(screen.getByText("语音房A"));
      expect(await screen.findByText("语音房占位")).toBeInTheDocument();
    });

    it("桌游房收藏 → 直达具体桌游房 /games/:roomId（不是大厅）", async () => {
      vi.mocked(favoritesApi.listFavoritesPage).mockResolvedValue(favoritePage([
        fav(1, "game", "7", { id: "7", name: "桌游房A" }),
      ]));
      renderPage();
      await waitFor(() => expect(screen.getByText("桌游房A")).toBeInTheDocument());
      fireEvent.click(screen.getByText("桌游房A"));
      expect(await screen.findByText("桌游房占位")).toBeInTheDocument();
    });

    it("直播间收藏 → /live/:channelId", async () => {
      vi.mocked(favoritesApi.listFavoritesPage).mockResolvedValue(favoritePage([
        fav(1, "live", "3", { id: "3", title: "直播间A" }),
      ]));
      renderPage();
      await waitFor(() => expect(screen.getByText("直播间A")).toBeInTheDocument());
      fireEvent.click(screen.getByText("直播间A"));
      expect(await screen.findByText("直播间占位")).toBeInTheDocument();
    });

    it("帖子收藏 → /posts/:postId", async () => {
      vi.mocked(favoritesApi.listFavoritesPage).mockResolvedValue(favoritePage([
        fav(1, "post", "10", { id: "10", title: "帖子A", body: "正文" }),
      ]));
      renderPage();
      await waitFor(() => expect(screen.getByText("帖子A")).toBeInTheDocument());
      fireEvent.click(screen.getByText("帖子A"));
      expect(await screen.findByText("帖子详情占位")).toBeInTheDocument();
    });

    it("群收藏 → /group/:id", async () => {
      vi.mocked(favoritesApi.listFavoritesPage).mockResolvedValue(favoritePage([
        fav(1, "group", "5", { id: "5", title: "群A" }),
      ]));
      renderPage();
      await waitFor(() => expect(screen.getByText("群A")).toBeInTheDocument());
      fireEvent.click(screen.getByText("群A"));
      expect(await screen.findByText("群占位")).toBeInTheDocument();
    });

    it("消息收藏 → /chat/:conversationId（用 target.conversation_id）", async () => {
      vi.mocked(favoritesApi.listFavoritesPage).mockResolvedValue(favoritePage([
        fav(1, "message", "99", { id: "99", conversation_id: "conv-1", content: "消息内容" }),
      ]));
      renderPage();
      await waitFor(() => expect(screen.getByText("消息内容")).toBeInTheDocument());
      fireEvent.click(screen.getByText("消息内容"));
      expect(await screen.findByText("会话占位")).toBeInTheDocument();
    });
  });

  describe("WS favorite.changed 实时同步（任务 07）", () => {
    it("removed 帧 → 本地列表即时移除", async () => {
      renderPage();
      await waitFor(() => expect(screen.getByText("帖子A")).toBeInTheDocument());
      act(() => {
        ws.frameHandler?.({
          type: "favorite.changed",
          data: { target_type: "post", target_id: "10", favorite_id: 1, action: "removed" },
        });
      });
      await waitFor(() => expect(screen.queryByText("帖子A")).not.toBeInTheDocument());
      expect(screen.getByText("帖子B")).toBeInTheDocument();
    });

    it("added 帧保留已加载页并自动刷新", async () => {
      renderPage();
      await waitFor(() => expect(screen.getByText("帖子A")).toBeInTheDocument());
      vi.mocked(favoritesApi.listFavoritesPage).mockResolvedValue(favoritePage([
        fav(1, "post", "10", { id: "10", title: "帖子A", body: "正文" }),
        fav(3, "post", "12", { id: "12", title: "帖子C", body: "正文" }),
      ]));
      act(() => {
        ws.frameHandler?.({
          type: "favorite.changed",
          data: { target_type: "post", target_id: "12", favorite_id: 3, action: "added" },
        });
      });
      // stale → 自动刷新（无需点击按钮）
      await waitFor(() => expect(screen.getByText("帖子C")).toBeInTheDocument());
      expect(favoritesApi.listFavoritesPage).toHaveBeenCalledTimes(2);
    });
  });
});
