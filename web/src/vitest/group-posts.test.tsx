/**
 * GroupPosts 测试（Bug #8）：群内帖子列表顶部必须有「我的帖子」入口，
 * 点击跳转 /posts/mine（我的帖子是全局 scope=mine，不区分群）。
 */
import { render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, describe, expect, it, vi } from "vitest";
import * as postsApi from "../api/posts";
import { GroupPosts } from "../pages/group/GroupPosts";

vi.mock("../api/posts", () => ({
  listPosts: vi.fn(),
}));
vi.mock("../components/posts/PostCard", () => ({
  PostCard: () => <div>帖卡</div>,
}));
vi.mock("../components/posts/PostEditor", () => ({
  PostEditor: () => <div>发帖编辑器</div>,
}));

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

afterEach(() => {
  vi.clearAllMocks();
});

describe("GroupPosts 我的帖子入口", () => {
  it("列表顶部存在「我的帖子」入口链接，点击跳转 /posts/mine", async () => {
    vi.mocked(postsApi.listPosts).mockResolvedValue({ results: [], next_cursor: null, has_more: false });
    renderGroupPosts();
    const link = await screen.findByRole("link", { name: "我的帖子" });
    expect(screen.getByRole("heading", { name: "群内帖子" })).toBeInTheDocument();
    expect(link.closest(".group-scene-head")).not.toBeNull();
    link.click();
    expect(await screen.findByText("我的帖子页占位")).toBeInTheDocument();
    expect(postsApi.listPosts).toHaveBeenCalledWith({ scope: "group:1", limit: 20 });
  });
});
