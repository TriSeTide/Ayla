/**
 * FavoritesPage 测试（F10 R-U3 + 任务 07）：
 * - 分类收藏列表 + 取消收藏即时移除；
 * - openTarget 全类型跳转（voice 直达语音房 / game 直达桌游房 / live/post/group/message）；
 * - WS favorite.changed 实时同步（removed 本地移除 / added 重新加载）。
 */
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as favoritesApi from "../api/favorites";
import type { Favorite, FavoriteTargetType } from "../api/types";
import { FavoritesPage } from "../pages/FavoritesPage";
import { clearMasonryMemory } from "../hooks/useMasonryColumns";
import { usePostsStore } from "../stores/posts";

/** 捕获 chatWS.onFrame 注册的 handler（测试里 fire favorite.changed 帧用） */
const ws = vi.hoisted(() => ({
  frameHandler: null as ((frame: unknown) => void) | null,
}));

vi.mock("../api/favorites", () => ({
  listFavorites: vi.fn(),
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

function renderPage() {
  return render(
    <MemoryRouter initialEntries={["/favorites"]}>
      <Routes>
        <Route path="/favorites" element={<FavoritesPage />} />
        <Route path="/voice/:channelId" element={<div>语音房占位</div>} />
        <Route path="/games/:roomId" element={<div>桌游房占位</div>} />
        <Route path="/live/:channelId" element={<div>直播间占位</div>} />
        <Route path="/posts/:postId" element={<div>帖子详情占位</div>} />
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
      return query === "(max-width: 768px)" ? width <= 768 : query === "(prefers-reduced-motion: reduce)";
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
  vi.stubGlobal(
    "matchMedia",
    vi.fn(() => ({ matches: true, addEventListener: vi.fn(), removeEventListener: vi.fn() })),
  );
  usePostsStore.getState().reset();
  ws.frameHandler = null;
  vi.mocked(favoritesApi.listFavorites).mockResolvedValue([
    fav(1, "post", "10", { id: "10", title: "帖子A", body: "正文" }),
    fav(2, "post", "11", { id: "11", title: "帖子B", body: "正文" }),
  ]);
  vi.mocked(favoritesApi.removeFavorite).mockResolvedValue({ deleted: true });
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.clearAllMocks();
  usePostsStore.getState().reset();
});

describe("FavoritesPage", () => {
  it.each([769, 1440])("宽屏 %d 使用独立两列，取消其他卡片保留剩余 DOM、列归属与焦点", async (width) => {
    responsiveViewport(width);
    vi.mocked(favoritesApi.listFavorites).mockResolvedValue([
      fav(1, "post", "10", { title: "帖子A", body: "较长正文".repeat(60) }),
      fav(2, "post", "11", { title: "帖子B", body: "短正文" }),
      fav(3, "post", "12", { title: "帖子C", body: "正文C" }),
      fav(4, "post", "13", { title: "帖子D", body: "正文D" }),
    ]);
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

  it("768/769 断点往返保持窄屏 API 顺序，宽屏恢复各自列归属", async () => {
    const setWidth = responsiveViewport(768);
    vi.mocked(favoritesApi.listFavorites).mockResolvedValue([
      fav(1, "post", "10", { title: "帖子A" }),
      fav(2, "post", "11", { title: "帖子B" }),
      fav(3, "post", "12", { title: "帖子C" }),
    ]);
    const { container } = renderPage();
    await screen.findByText("帖子A");
    expect(columnIds(container)).toEqual([["1", "2", "3"]]);
    setWidth(769);
    expect(columnIds(container)).toEqual([["1", "3"], ["2"]]);
    setWidth(768);
    expect(columnIds(container)).toEqual([["1", "2", "3"]]);
    expect(favoritesApi.listFavorites).toHaveBeenCalledTimes(1);
  });

  it("分类使用独立分列记忆，异步筛选保留筛选按钮焦点", async () => {
    responsiveViewport(1440);
    const items = [
      fav(1, "message", "50", { content: "消息A", conversation_id: "c1" }),
      fav(2, "post", "11", { title: "帖子B" }),
      fav(3, "post", "12", { title: "帖子C" }),
    ];
    vi.mocked(favoritesApi.listFavorites).mockResolvedValue(items);
    const { container } = renderPage();
    await screen.findByText("消息A");
    expect(columnIds(container)).toEqual([["1", "3"], ["2"]]);
    let resolveFilter!: (favorites: Favorite[]) => void;
    vi.mocked(favoritesApi.listFavorites).mockReturnValue(new Promise((resolve) => { resolveFilter = resolve; }));
    const postFilter = screen.getByRole("tab", { name: "帖子" });
    postFilter.focus();
    fireEvent.click(postFilter);
    expect(container.querySelector(".favorites-list")).toBeNull();
    expect(container.querySelector(".favorites-skeleton")).not.toBeNull();
    expect(screen.queryByText("消息A")).not.toBeInTheDocument();
    await act(async () => resolveFilter(items.slice(1)));
    expect(columnIds(container)).toEqual([["2"], ["3"]]);
    expect(postFilter).toHaveFocus();
    expect(favoritesApi.listFavorites).toHaveBeenLastCalledWith("post");
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
    vi.mocked(favoritesApi.listFavorites).mockResolvedValue([]);
    renderPage();
    await waitFor(() => expect(screen.getByText("这个分类还没有收藏")).toBeInTheDocument());
  });

  describe("openTarget 全类型跳转（任务 07）", () => {
    it("语音房收藏 → 直达具体语音房 /voice/:channelId（不是大厅）", async () => {
      vi.mocked(favoritesApi.listFavorites).mockResolvedValue([
        fav(1, "voice", "42", { id: "42", name: "语音房A" }),
      ]);
      renderPage();
      await waitFor(() => expect(screen.getByText("语音房A")).toBeInTheDocument());
      fireEvent.click(screen.getByText("语音房A"));
      expect(await screen.findByText("语音房占位")).toBeInTheDocument();
    });

    it("桌游房收藏 → 直达具体桌游房 /games/:roomId（不是大厅）", async () => {
      vi.mocked(favoritesApi.listFavorites).mockResolvedValue([
        fav(1, "game", "7", { id: "7", name: "桌游房A" }),
      ]);
      renderPage();
      await waitFor(() => expect(screen.getByText("桌游房A")).toBeInTheDocument());
      fireEvent.click(screen.getByText("桌游房A"));
      expect(await screen.findByText("桌游房占位")).toBeInTheDocument();
    });

    it("直播间收藏 → /live/:channelId", async () => {
      vi.mocked(favoritesApi.listFavorites).mockResolvedValue([
        fav(1, "live", "3", { id: "3", title: "直播间A" }),
      ]);
      renderPage();
      await waitFor(() => expect(screen.getByText("直播间A")).toBeInTheDocument());
      fireEvent.click(screen.getByText("直播间A"));
      expect(await screen.findByText("直播间占位")).toBeInTheDocument();
    });

    it("帖子收藏 → /posts/:postId", async () => {
      vi.mocked(favoritesApi.listFavorites).mockResolvedValue([
        fav(1, "post", "10", { id: "10", title: "帖子A", body: "正文" }),
      ]);
      renderPage();
      await waitFor(() => expect(screen.getByText("帖子A")).toBeInTheDocument());
      fireEvent.click(screen.getByText("帖子A"));
      expect(await screen.findByText("帖子详情占位")).toBeInTheDocument();
    });

    it("群收藏 → /group/:id", async () => {
      vi.mocked(favoritesApi.listFavorites).mockResolvedValue([
        fav(1, "group", "5", { id: "5", title: "群A" }),
      ]);
      renderPage();
      await waitFor(() => expect(screen.getByText("群A")).toBeInTheDocument());
      fireEvent.click(screen.getByText("群A"));
      expect(await screen.findByText("群占位")).toBeInTheDocument();
    });

    it("消息收藏 → /chat/:conversationId（用 target.conversation_id）", async () => {
      vi.mocked(favoritesApi.listFavorites).mockResolvedValue([
        fav(1, "message", "99", { id: "99", conversation_id: "conv-1", content: "消息内容" }),
      ]);
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

    it("added 帧 → 重新加载权威列表", async () => {
      renderPage();
      await waitFor(() => expect(screen.getByText("帖子A")).toBeInTheDocument());
      vi.mocked(favoritesApi.listFavorites).mockResolvedValue([
        fav(1, "post", "10", { id: "10", title: "帖子A", body: "正文" }),
        fav(3, "post", "12", { id: "12", title: "帖子C", body: "正文" }),
      ]);
      act(() => {
        ws.frameHandler?.({
          type: "favorite.changed",
          data: { target_type: "post", target_id: "12", favorite_id: 3, action: "added" },
        });
      });
      await waitFor(() => expect(screen.getByText("帖子C")).toBeInTheDocument());
    });
  });
});
