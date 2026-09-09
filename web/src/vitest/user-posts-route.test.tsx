/**
 * UserPostsRoute 路由守卫测试：/user/:userId/posts。
 *
 * 覆盖：
 * 1. 对方开启「向他人展示内容」→ 渲染 MyPostsPage（owner 模式，owner 过滤拉帖子）；
 * 2. 对方未开启 → 显示提示页，不渲染帖子内容；
 * 3. 用户不存在/加载失败 → 显示提示页。
 */
import { render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { listPosts } from "../api/posts";
import { getUserDetail } from "../api/users";
import type { Post, UserPublic } from "../api/types";
import { UserPostsRoute } from "../pages/UserPostsRoute";
import { useAuthStore } from "../stores/auth";

vi.mock("../api/posts", () => ({
  listPosts: vi.fn(),
  reportPostViews: vi.fn().mockResolvedValue({ updated: {} }),
}));
vi.mock("../api/users", () => ({ getUserDetail: vi.fn() }));
vi.mock("../api/favorites", () => ({
  listFavorites: vi.fn().mockResolvedValue([]),
  addFavorite: vi.fn(),
  removeFavorite: vi.fn(),
}));
vi.mock("../components/posts/PostCard", () => ({
  PostCard: ({ post, onOpen }: { post: { title: string }; onOpen: () => void }) => (
    <button type="button" onClick={onOpen}>{post.title}</button>
  ),
}));

const me: UserPublic = { id: "viewer", username: "viewer", nickname: "", avatar: "", signature: "", status: "auto", online: true, date_joined: "" };
const other: UserPublic = { id: "other", username: "other", nickname: "别人", avatar: "", signature: "", status: "auto", online: true, date_joined: "", show_content: true };
const post: Post = {
  id: 1, author: other, author_id: "other", title: "别人的帖子", body: "内容", visibility: "public",
  group: null, group_name: null, images: [], comment_count: 0, is_author: false, view_count: 0,
  is_viewed: false, created_at: "2026-01-01", updated_at: "2026-01-01",
};

function renderRoute(userId = "other") {
  return render(
    <MemoryRouter initialEntries={[`/user/${userId}/posts`]}>
      <Routes>
        <Route path="/user/:userId/posts" element={<UserPostsRoute />} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(listPosts).mockReset().mockResolvedValue({ results: [], next_cursor: null, has_more: false });
  vi.mocked(getUserDetail).mockReset();
  useAuthStore.setState({ accessToken: "test", currentUser: me });
});

describe("UserPostsRoute 路由守卫", () => {
  it("对方开启内容展示 → 渲染帖子界面（owner 过滤）", async () => {
    vi.mocked(getUserDetail).mockResolvedValue(other);
    vi.mocked(listPosts).mockResolvedValue({ results: [post], next_cursor: null, has_more: false });
    renderRoute();
    // 标题为「xx的帖子」，帖子卡渲染
    expect(await screen.findByRole("heading", { name: "别人的帖子" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "别人的帖子" })).toBeInTheDocument();
    expect(listPosts).toHaveBeenCalledWith({ owner: "other", cursor: null, limit: 20 });
  });

  it("对方未开启内容展示 → 显示提示页，不渲染帖子内容", async () => {
    vi.mocked(getUserDetail).mockResolvedValue({ ...other, show_content: false });
    renderRoute();
    expect(await screen.findByText("对方未开启内容展示")).toBeInTheDocument();
    expect(listPosts).not.toHaveBeenCalled();
  });

  it("用户不存在/加载失败 → 显示提示页", async () => {
    vi.mocked(getUserDetail).mockRejectedValue(new Error("用户不存在"));
    renderRoute();
    expect(await screen.findByText("对方未开启内容展示")).toBeInTheDocument();
    expect(listPosts).not.toHaveBeenCalled();
  });
});
