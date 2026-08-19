/**
 * PostsHubPage 测试（Bug #8）：群外帖子信息流顶部必须有「我的帖子」入口，
 * 点击跳转 /posts/mine（scope=mine，全局）。
 */
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, describe, expect, it, vi } from "vitest";
import * as favoritesApi from "../api/favorites";
import * as postsApi from "../api/posts";
import { PostsHubPage } from "../pages/PostsHubPage";
import { usePostsStore } from "../stores/posts";

vi.mock("../api/posts", () => ({
  listPosts: vi.fn(),
}));
vi.mock("../api/favorites", () => ({
  listFavorites: vi.fn().mockResolvedValue([]),
  addFavorite: vi.fn(),
  removeFavorite: vi.fn(),
}));
vi.mock("../components/posts/PostCard", () => ({
  PostCard: () => <div>帖卡</div>,
}));

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

afterEach(() => {
  vi.clearAllMocks();
  usePostsStore.getState().reset();
});

describe("PostsHubPage 我的帖子入口", () => {
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
    screen.getByRole("link", { name: "我的帖子" }).click();
    expect(await screen.findByText("我的帖子页占位")).toBeInTheDocument();
  });
});
