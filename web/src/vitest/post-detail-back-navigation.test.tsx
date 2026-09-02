/**
 * PostDetailPage 返回导航回归测试（Bug：我的帖子进入详情返回后，再返回又回到详情）。
 *
 * 根因：详情返回用 navigate(returnTo) 再 push 一个列表页（/posts/mine），
 * 破坏历史栈 → 列表页的 navigate(-1) 退回刚才的详情，而非真实来源。
 *
 * 修复：详情返回走历史栈回退 navigate(-1)，回到原有列表页；列表页再 navigate(-1)
 * 回真实来源。仅在直接打开详情（无站内历史）时用 navigate(returnTo, { replace: true })
 * 替换详情条目回退到显式 returnTo，避免再 push 一个可回退的列表页。
 *
 * 覆盖：
 * 1. 真实三段栈 /posts -> /posts/mine -> /posts/1?from=mine：详情返回回到我的帖子，
 *    我的帖子返回回到 /posts（不回到详情）。
 * 2. 从其他入口（/group/:id/posts）进入 /posts/mine 时，返回回到原入口（不硬编码 /posts）。
 * 3. 直接打开详情 /posts/1?from=mine（无站内历史）：返回 replace 到 /posts/mine，
 *    且 mine 的返回不再回到详情（replace 后不留 detail 历史条目）。
 */
import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as postsApi from "../api/posts";
import type { Post } from "../api/types";
import { MyPostsPage } from "../pages/MyPostsPage";
import { PostDetailPage } from "../pages/PostDetailPage";
import { useAuthStore } from "../stores/auth";

vi.mock("../api/posts", () => ({
  listPosts: vi.fn(),
  getPost: vi.fn(),
  listComments: vi.fn(),
  createComment: vi.fn(),
  deleteComment: vi.fn(),
  updatePost: vi.fn(),
  deletePost: vi.fn(),
  reportPostViews: vi.fn().mockResolvedValue({ updated: {} }),
}));
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
vi.mock("../components/posts/CommentList", () => ({
  CommentList: () => <div>评论列表 mock</div>,
}));

const post: Post = {
  id: 1,
  author: {
    id: "u1", username: "alice", nickname: "爱丽丝", avatar: "", signature: "",
    status: "online", online: true, date_joined: "2026-01-01",
  },
  author_id: "u1",
  title: "我的第一帖",
  body: "内容",
  visibility: "public",
  group: null,
  group_name: null,
  images: [],
  comment_count: 0,
  is_author: true,
  view_count: 0,
  is_viewed: false,
  created_at: "2026-01-01",
  updated_at: "2026-01-01",
};

function renderMineFlow() {
  vi.mocked(postsApi.listPosts).mockResolvedValue({ results: [post], next_cursor: null, has_more: false });
  vi.mocked(postsApi.getPost).mockResolvedValue(post);
  vi.mocked(postsApi.listComments).mockResolvedValue([]);
  return render(
    <MemoryRouter initialEntries={["/posts", "/posts/mine"]}>
      <Routes>
        <Route path="/posts" element={<div>帖子主页占位</div>} />
        <Route path="/posts/mine" element={<MyPostsPage />} />
        <Route path="/posts/:postId" element={<PostDetailPage />} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  useAuthStore.setState({ currentUser: null });
});

afterEach(() => {
  vi.clearAllMocks();
  useAuthStore.setState({ currentUser: null });
});

describe("PostDetailPage 返回导航（历史栈）", () => {
  it("三段栈 /posts -> /posts/mine -> /posts/1?from=mine：详情返回回到我的帖子，再返回回到 /posts", async () => {
    renderMineFlow();

    // 我的帖子列表加载 → 点击帖子进入详情
    fireEvent.click(await screen.findByRole("button", { name: "我的第一帖" }));
    // 详情加载完成（正文 + 评论区渲染）
    expect(await screen.findByText("评论列表 mock")).toBeInTheDocument();

    // 详情返回 → 我的帖子（回到原有 mine，而非 push 新 mine）
    fireEvent.click(screen.getByRole("button", { name: "返回" }));
    expect(await screen.findByRole("button", { name: "我的第一帖" })).toBeInTheDocument();

    // 我的帖子返回 → /posts（真实来源，而非回到刚才的详情）
    fireEvent.click(screen.getByRole("button", { name: "返回" }));
    expect(await screen.findByText("帖子主页占位")).toBeInTheDocument();
  });

  it("从其他入口（群内帖子）进入 /posts/mine 时，我的帖子返回回到原入口（不硬编码 /posts）", async () => {
    vi.mocked(postsApi.listPosts).mockResolvedValue({ results: [], next_cursor: null, has_more: false });
    render(
      <MemoryRouter initialEntries={["/group/g1/posts", "/posts/mine"]}>
        <Routes>
          <Route path="/group/:id/posts" element={<div>群内帖子占位</div>} />
          <Route path="/posts/mine" element={<MyPostsPage />} />
        </Routes>
      </MemoryRouter>,
    );

    await screen.findByText("还没有帖子");
    fireEvent.click(screen.getByRole("button", { name: "返回" }));
    expect(await screen.findByText("群内帖子占位")).toBeInTheDocument();
  });

  it("直接打开详情 /posts/1?from=mine（无站内历史）：返回 replace 到我的帖子，且我的帖子返回不再回到详情", async () => {
    vi.mocked(postsApi.listPosts).mockResolvedValue({ results: [], next_cursor: null, has_more: false });
    vi.mocked(postsApi.getPost).mockResolvedValue(post);
    vi.mocked(postsApi.listComments).mockResolvedValue([]);
    render(
      <MemoryRouter initialEntries={["/posts/1?from=mine"]}>
        <Routes>
          <Route path="/posts/:postId" element={<PostDetailPage />} />
          <Route path="/posts/mine" element={<MyPostsPage />} />
        </Routes>
      </MemoryRouter>,
    );

    // 详情加载完成
    expect(await screen.findByText("评论列表 mock")).toBeInTheDocument();

    // 详情返回 → replace 到 /posts/mine（栈底不留 detail 条目）
    fireEvent.click(screen.getByRole("button", { name: "返回" }));
    expect(await screen.findByText("还没有帖子")).toBeInTheDocument();
    expect(screen.queryByText("评论列表 mock")).not.toBeInTheDocument();

    // 我的帖子返回 → 栈底 no-op，不会回到详情
    fireEvent.click(screen.getByRole("button", { name: "返回" }));
    expect(screen.queryByText("评论列表 mock")).not.toBeInTheDocument();
    expect(screen.getByText("还没有帖子")).toBeInTheDocument();
  });
});
