/**
 * PostDetailPage 测试 —— 编辑帖子可见范围（Bug #9 回归）。
 *
 * 断言：
 * - 编辑面板用 VisibilitySelector（checkbox 三选 + 群搜索 + 群多选），不再是无群选择的 select；
 * - 保存时 updatePost 携带 allowed_group_ids；
 * - group 可见但未选任何群时阻止保存并提示"请至少选择一个群"；
 * - 群内帖子（post.group 有值）编辑时默认指定群可见，且自动勾选所属群。
 */
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as postsApi from "../api/posts";
import type { Post } from "../api/types";
import { PostDetailPage } from "../pages/PostDetailPage";
import { useChatStore } from "../stores/chat";

vi.mock("../api/posts", () => ({
  getPost: vi.fn(),
  listComments: vi.fn(),
  updatePost: vi.fn(),
  deletePost: vi.fn(),
}));
vi.mock("../api/favorites", () => ({
  listFavorites: vi.fn().mockResolvedValue([]),
  addFavorite: vi.fn(),
  removeFavorite: vi.fn(),
}));
vi.mock("../components/posts/CommentList", () => ({
  CommentList: () => <div>评论列表 mock</div>,
}));

const author = {
  id: "u1",
  username: "alice",
  nickname: "爱丽丝",
  avatar: "",
  signature: "",
  status: "online" as const,
  online: true,
  date_joined: "2026-01-01",
};

const makePost = (overrides: Partial<Post> = {}): Post => ({
  id: 1,
  author,
  author_id: "u1",
  title: "标题",
  body: "正文",
  visibility: "public",
  group: null,
  group_name: null,
  allowed_group_ids: undefined,
  images: [],
  comment_count: 0,
  is_author: true,
  created_at: "2026-01-01T00:00:00Z",
  updated_at: "2026-01-01T00:00:00Z",
  ...overrides,
});

const groupConversation = {
  id: "g1",
  type: "group" as const,
  title: "测试群",
  announcement: "",
  avatar: "",
  join_policy: "public" as const,
  owner_id: "u1",
  members: [],
  my_role: "owner" as const,
  member_count: 1,
  unread_count: 0,
  created_at: "2026-01-01T00:00:00Z",
  peer: null,
};

function renderDetail(post: Post) {
  vi.mocked(postsApi.getPost).mockResolvedValue(post);
  vi.mocked(postsApi.listComments).mockResolvedValue([]);
  vi.mocked(postsApi.updatePost).mockResolvedValue(post);
  return render(
    <MemoryRouter initialEntries={["/posts/1"]}>
      <Routes>
        <Route path="/posts/:postId" element={<PostDetailPage />} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  useChatStore.getState().reset();
  useChatStore.getState().setConversations([groupConversation]);
  vi.clearAllMocks();
});

afterEach(() => {
  vi.clearAllMocks();
});

describe("PostDetailPage 编辑可见范围", () => {
  it("编辑面板使用 VisibilitySelector，选择指定群后保存携带 allowed_group_ids", async () => {
    renderDetail(makePost());
    fireEvent.click(await screen.findByRole("button", { name: "编辑" }));

    // VisibilitySelector 渲染：checkbox 三选（不再是无群选择的普通 select）
    expect(screen.getByRole("checkbox", { name: "公开" })).toBeChecked();
    expect(screen.getByRole("checkbox", { name: "好友可见" })).not.toBeChecked();
    expect(screen.getByRole("checkbox", { name: "指定群可见" })).not.toBeChecked();
    expect(screen.queryByRole("combobox")).not.toBeInTheDocument();

    // 切到"指定群可见" → 出现群搜索与群多选
    fireEvent.click(screen.getByRole("checkbox", { name: "指定群可见" }));
    expect(screen.getByLabelText("搜索群")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("checkbox", { name: "测试群" }));

    fireEvent.click(screen.getByRole("button", { name: "重新发布" }));
    await waitFor(() => {
      expect(postsApi.updatePost).toHaveBeenCalledWith(
        1,
        expect.objectContaining({ visibility: "group", allowed_group_ids: ["g1"] }),
      );
    });
  });

  it("指定群可见但未选任何群时阻止保存并提示", async () => {
    renderDetail(makePost());
    fireEvent.click(await screen.findByRole("button", { name: "编辑" }));

    fireEvent.click(screen.getByRole("checkbox", { name: "指定群可见" }));
    fireEvent.click(screen.getByRole("button", { name: "重新发布" }));

    expect(await screen.findByText("请至少选择一个群")).toBeInTheDocument();
    expect(postsApi.updatePost).not.toHaveBeenCalled();
  });

  it("群内帖子编辑时默认指定群可见，所属群自动勾选并随保存携带", async () => {
    renderDetail(
      makePost({ group: "g1", group_name: "测试群", visibility: "group", allowed_group_ids: ["g1"] }),
    );
    fireEvent.click(await screen.findByRole("button", { name: "编辑" }));

    // 初始即勾选「指定群可见」并自动勾选所属群
    expect(screen.getByRole("checkbox", { name: "指定群可见" })).toBeChecked();
    expect(screen.getByRole("checkbox", { name: "测试群" })).toBeChecked();

    // 直接重新发布：保持群可见 + 白名单
    fireEvent.click(screen.getByRole("button", { name: "重新发布" }));
    await waitFor(() => {
      expect(postsApi.updatePost).toHaveBeenCalledWith(
        1,
        expect.objectContaining({ visibility: "group", allowed_group_ids: ["g1"] }),
      );
    });
  });

  it("从我的帖子进入详情时，返回保留在我的帖子列表", async () => {
    const detail = makePost();
    vi.mocked(postsApi.getPost).mockResolvedValue(detail);
    vi.mocked(postsApi.listComments).mockResolvedValue([]);
    render(
      <MemoryRouter initialEntries={["/posts/mine", "/posts/1?from=mine"]}>
        <Routes>
          <Route path="/posts/:postId" element={<PostDetailPage />} />
          <Route path="/posts/mine" element={<div>我的帖子页占位</div>} />
        </Routes>
      </MemoryRouter>,
    );

    expect(await screen.findByText("评论列表 mock")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "返回" }));
    expect(await screen.findByText("我的帖子页占位")).toBeInTheDocument();
  });
});
