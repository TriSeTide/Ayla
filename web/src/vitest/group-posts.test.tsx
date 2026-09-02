/**
 * GroupPosts 测试（Bug #8 + 任务 07）：
 * - 群内帖子列表顶部必须有「我的帖子」入口，点击跳转 /posts/mine；
 * - 收藏键接入真实收藏：favorited 来自 posts store，点击调 favoritesApi 并更新 store。
 */
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as postsApi from "../api/posts";
import * as favoritesApi from "../api/favorites";
import type { Favorite, Post } from "../api/types";
import { GroupPosts } from "../pages/group/GroupPosts";
import { usePostsStore } from "../stores/posts";

vi.mock("../api/posts", () => ({
  listPosts: vi.fn(),
  reportPostViews: vi.fn().mockResolvedValue({ updated: {} }),
}));
vi.mock("../api/favorites", () => ({
  listFavorites: vi.fn(),
  addFavorite: vi.fn(),
  removeFavorite: vi.fn(),
}));
vi.mock("../ws/chat", () => ({
  chatWS: { onFrame: vi.fn(() => vi.fn()) },
}));
vi.mock("../components/posts/PostCard", () => ({
  PostCard: ({
    post,
    favorited,
    onToggleFavorite,
  }: {
    post: { id: number };
    favorited: boolean;
    onToggleFavorite: () => void;
  }) => (
    <button type="button" onClick={onToggleFavorite} aria-pressed={favorited}>
      收藏{post.id}
    </button>
  ),
}));
vi.mock("../components/posts/PostEditor", () => ({
  PostEditor: () => <div>发帖编辑器</div>,
}));

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
  usePostsStore.getState().reset();
  vi.mocked(postsApi.listPosts).mockResolvedValue({ results: [], next_cursor: null, has_more: false });
  vi.mocked(favoritesApi.listFavorites).mockResolvedValue([]);
});

afterEach(() => {
  vi.clearAllMocks();
  usePostsStore.getState().reset();
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
    vi.mocked(favoritesApi.listFavorites).mockResolvedValue([
      { id: 100, target_type: "post", target_id: "1" } as Favorite,
    ]);
    renderGroupPosts();

    const btn = await screen.findByRole("button", { name: "收藏1" });
    await waitFor(() => expect(btn).toHaveAttribute("aria-pressed", "true"));
    expect(favoritesApi.listFavorites).toHaveBeenCalledWith("post");
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

    const btn = await screen.findByRole("button", { name: "收藏1" });
    expect(btn).toHaveAttribute("aria-pressed", "false");
    fireEvent.click(btn);

    await waitFor(() => expect(favoritesApi.addFavorite).toHaveBeenCalledWith("post", "1"));
    expect(usePostsStore.getState().favoriteByPostId["1"]).toBe(100);
    await waitFor(() => expect(btn).toHaveAttribute("aria-pressed", "true"));
  });

  it("已收藏时点击 → 调 removeFavorite 并清空 store 收藏态", async () => {
    vi.mocked(postsApi.listPosts).mockResolvedValue({
      results: [post(1)],
      next_cursor: null,
      has_more: false,
    });
    vi.mocked(favoritesApi.listFavorites).mockResolvedValue([
      { id: 100, target_type: "post", target_id: "1" } as Favorite,
    ]);
    vi.mocked(favoritesApi.removeFavorite).mockResolvedValue({ deleted: true });
    renderGroupPosts();

    const btn = await screen.findByRole("button", { name: "收藏1" });
    await waitFor(() => expect(btn).toHaveAttribute("aria-pressed", "true"));
    fireEvent.click(btn);

    await waitFor(() => expect(favoritesApi.removeFavorite).toHaveBeenCalledWith(100));
    expect(usePostsStore.getState().favoriteByPostId["1"]).toBeUndefined();
    await waitFor(() => expect(btn).toHaveAttribute("aria-pressed", "false"));
  });
});
