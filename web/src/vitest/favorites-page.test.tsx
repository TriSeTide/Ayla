/**
 * FavoritesPage 测试（F10 R-U3）：帖子收藏列表 + 取消收藏即时移除。
 */
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as favoritesApi from "../api/favorites";
import type { Favorite } from "../api/types";
import { FavoritesPage } from "../pages/FavoritesPage";
import { usePostsStore } from "../stores/posts";

vi.mock("../api/favorites", () => ({
  listFavorites: vi.fn(),
  removeFavorite: vi.fn(),
}));

function fav(id: number, postId: string, title: string): Favorite {
  return {
    id,
    user_id: "u1",
    target_type: "post",
    target_id: postId,
    target: { id: postId, title, body: "正文" },
    created_at: "2026-01-01T00:00:00Z",
  };
}

beforeEach(() => {
  vi.stubGlobal(
    "matchMedia",
    vi.fn(() => ({ matches: true, addEventListener: vi.fn(), removeEventListener: vi.fn() })),
  );
  usePostsStore.getState().reset();
  vi.mocked(favoritesApi.listFavorites).mockResolvedValue([fav(1, "10", "帖子A"), fav(2, "11", "帖子B")]);
  vi.mocked(favoritesApi.removeFavorite).mockResolvedValue({ deleted: true });
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.clearAllMocks();
  usePostsStore.getState().reset();
});

describe("FavoritesPage", () => {
  it("展示帖子收藏列表", async () => {
    render(
      <MemoryRouter>
        <FavoritesPage />
      </MemoryRouter>,
    );
    await waitFor(() => expect(screen.getByText("帖子A")).toBeInTheDocument());
    expect(screen.getByText("帖子B")).toBeInTheDocument();
  });

  it("取消收藏即时移除", async () => {
    render(
      <MemoryRouter>
        <FavoritesPage />
      </MemoryRouter>,
    );
    await waitFor(() => expect(screen.getByText("帖子A")).toBeInTheDocument());
    const buttons = screen.getAllByRole("button", { name: "取消收藏" });
    fireEvent.click(buttons[0]);
    await waitFor(() => expect(screen.queryByText("帖子A")).not.toBeInTheDocument());
    expect(favoritesApi.removeFavorite).toHaveBeenCalledWith(1);
  });

  it("空态提示", async () => {
    vi.mocked(favoritesApi.listFavorites).mockResolvedValue([]);
    render(
      <MemoryRouter>
        <FavoritesPage />
      </MemoryRouter>,
    );
    await waitFor(() => expect(screen.getByText("还没有收藏的帖子")).toBeInTheDocument());
  });
});
