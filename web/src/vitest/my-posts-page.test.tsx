import { render, screen, fireEvent } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, describe, expect, it, vi } from "vitest";
import { MyPostsPage } from "../pages/MyPostsPage";
import * as postsApi from "../api/posts";

vi.mock("../api/posts", () => ({
  listPosts: vi.fn(),
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

const post = {
  id: 1, author: { id: "u1", username: "alice", nickname: "爱丽丝", avatar: "", signature: "", status: "online", online: true, date_joined: "2026-01-01" },
  author_id: "u1", title: "我的第一帖", body: "内容", visibility: "public" as const, group: null, group_name: null,
  images: [], comment_count: 0, is_author: true, created_at: "2026-01-01", updated_at: "2026-01-01",
};

afterEach(() => vi.clearAllMocks());

describe("MyPostsPage", () => {
  it("加载我的帖子并支持点击进入详情", async () => {
    vi.mocked(postsApi.listPosts).mockResolvedValue({ results: [post], next_cursor: null, has_more: false });
    render(<MemoryRouter><MyPostsPage /></MemoryRouter>);
    expect(await screen.findByText("我的第一帖")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "我的第一帖" }));
    expect(screen.getByRole("button", { name: "我的第一帖" })).toBeInTheDocument();
    expect(postsApi.listPosts).toHaveBeenCalledWith({ scope: "mine", cursor: null, limit: 20 });
  });

  it("空列表显示明确空态", async () => {
    vi.mocked(postsApi.listPosts).mockResolvedValue({ results: [], next_cursor: null, has_more: false });
    render(<MemoryRouter><MyPostsPage /></MemoryRouter>);
    expect(await screen.findByText("还没有帖子")).toBeInTheDocument();
  });
});
