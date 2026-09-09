import { act, render, screen, fireEvent, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MyPostsPage, _clearMyPostsMemory } from "../pages/MyPostsPage";
import * as postsApi from "../api/posts";
import { useAuthStore } from "../stores/auth";

vi.mock("../api/posts", () => ({
  listPosts: vi.fn(),
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

const post = {
  id: 1, author: { id: "u1", username: "alice", nickname: "爱丽丝", avatar: "", signature: "", status: "online", online: true, date_joined: "2026-01-01" },
  author_id: "u1", title: "我的第一帖", body: "内容", visibility: "public" as const, group: null, group_name: null,
  images: [], comment_count: 0, is_author: true, view_count: 0, is_viewed: false, created_at: "2026-01-01", updated_at: "2026-01-01",
};

/** 当前登录用户（与 post.author 一致，MyPostsPage 的 mine 模式依赖它） */
const me = { id: "u1", username: "alice", nickname: "爱丽丝", avatar: "", signature: "", status: "online", online: true, date_joined: "2026-01-01" };

function DetailLocation() {
  const location = useLocation();
  return <div>详情地址：{location.pathname}{location.search}</div>;
}

beforeEach(() => {
  _clearMyPostsMemory();
  // 清除 listPosts 的默认实现与 Once 队列（clearAllMocks 不清实现，跨测试会残留）
  vi.mocked(postsApi.listPosts).mockReset();
  useAuthStore.setState({ currentUser: me });
});

afterEach(() => {
  vi.clearAllMocks();
  _clearMyPostsMemory();
  useAuthStore.setState({ currentUser: null });
});

describe("MyPostsPage", () => {
  it("加载我的帖子并支持携带来源进入详情", async () => {
    vi.mocked(postsApi.listPosts).mockResolvedValue({ results: [post], next_cursor: null, has_more: false });
    render(
      <MemoryRouter initialEntries={["/posts/mine"]}>
        <Routes>
          <Route path="/posts/mine" element={<MyPostsPage ownerId="u1" />} />
          <Route path="/posts/:postId" element={<DetailLocation />} />
        </Routes>
      </MemoryRouter>,
    );
    expect(await screen.findByText("我的第一帖")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "我的第一帖" }));
    expect(await screen.findByText("详情地址：/posts/1?from=mine")).toBeInTheDocument();
    expect(postsApi.listPosts).toHaveBeenCalledWith({ scope: "mine", cursor: null, limit: 20 });
  });

  it("空列表显示明确空态", async () => {
    vi.mocked(postsApi.listPosts).mockResolvedValue({ results: [], next_cursor: null, has_more: false });
    render(<MemoryRouter><MyPostsPage ownerId="u1" /></MemoryRouter>);
    expect(await screen.findByText("还没有帖子")).toBeInTheDocument();
  });

  it("尾页失败保留已有帖子和游标，滚动不自动重试，显式重试后追加且不重复", async () => {
    vi.mocked(postsApi.listPosts)
      .mockResolvedValueOnce({ results: [post], next_cursor: "page-2", has_more: true })
      .mockRejectedValueOnce(new Error("尾页读取失败"))
      .mockResolvedValueOnce({ results: [post, { ...post, id: 2, title: "第二页帖子" }], next_cursor: null, has_more: false });
    const { container } = render(<MemoryRouter><MyPostsPage ownerId="u1" /></MemoryRouter>);
    await screen.findByText("我的第一帖");
    fireEvent.click(screen.getByRole("button", { name: "加载更多帖子" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("尾页读取失败");
    expect(screen.getByText("我的第一帖")).toBeInTheDocument();
    fireEvent.scroll(container.querySelector(".my-posts-page")!);
    fireEvent.scroll(container.querySelector(".my-posts-page")!);
    expect(postsApi.listPosts).toHaveBeenCalledTimes(2);
    fireEvent.click(screen.getByRole("button", { name: "重试加载更多帖子" }));
    await screen.findByText("第二页帖子");
    expect(screen.getAllByText("我的第一帖")).toHaveLength(1);
    expect(postsApi.listPosts).toHaveBeenLastCalledWith({ scope: "mine", cursor: "page-2", limit: 20 });
    expect(screen.getByText("已加载全部帖子")).toBeInTheDocument();
  });

  it("同一游标的连续滚动只发一次请求，卸载后的完成不会写回返回页缓存", async () => {
    let finish!: (value: Awaited<ReturnType<typeof postsApi.listPosts>>) => void;
    const pending = new Promise<Awaited<ReturnType<typeof postsApi.listPosts>>>((resolve) => { finish = resolve; });
    vi.mocked(postsApi.listPosts)
      .mockResolvedValueOnce({ results: [post], next_cursor: "page-2", has_more: true })
      .mockReturnValueOnce(pending);
    const view = render(<MemoryRouter><MyPostsPage ownerId="u1" /></MemoryRouter>);
    await screen.findByText("我的第一帖");
    const scroller = view.container.querySelector(".my-posts-page")!;
    fireEvent.scroll(scroller);
    fireEvent.scroll(scroller);
    fireEvent.scroll(scroller);
    expect(postsApi.listPosts).toHaveBeenCalledTimes(2);
    view.unmount();
    await act(async () => finish({ results: [{ ...post, id: 99, title: "过期返回" }], next_cursor: null, has_more: false }));
    vi.mocked(postsApi.listPosts).mockResolvedValue({ results: [], next_cursor: null, has_more: false });
    render(<MemoryRouter><MyPostsPage ownerId="u1" /></MemoryRouter>);
    // 卸载前已加载的快照保留（首次加载的帖子），卸载后 resolve 的「过期返回」不写回缓存
    await screen.findByText("我的第一帖");
    expect(screen.queryByText("过期返回")).not.toBeInTheDocument();
  });

  it("首屏错误允许明确重试，恢复时退出错误状态", async () => {
    vi.mocked(postsApi.listPosts).mockRejectedValueOnce(new Error("首屏读取失败"))
      .mockResolvedValueOnce({ results: [post], next_cursor: null, has_more: false });
    render(<MemoryRouter><MyPostsPage ownerId="u1" /></MemoryRouter>);
    expect(await screen.findByRole("alert")).toHaveTextContent("首屏读取失败");
    fireEvent.click(screen.getByRole("button", { name: "重试" }));
    await screen.findByText("我的第一帖");
    await waitFor(() => expect(screen.queryByRole("alert")).not.toBeInTheDocument());
  });

  it("顶部返回键点击回到上一页（navigate(-1)）", async () => {
    vi.mocked(postsApi.listPosts).mockResolvedValue({ results: [], next_cursor: null, has_more: false });
    render(
      <MemoryRouter initialEntries={["/posts", "/posts/mine"]}>
        <Routes>
          <Route path="/posts" element={<div>帖子主页占位</div>} />
          <Route path="/posts/mine" element={<MyPostsPage ownerId="u1" />} />
        </Routes>
      </MemoryRouter>,
    );
    await screen.findByText("还没有帖子");
    fireEvent.click(screen.getByRole("button", { name: "返回" }));
    expect(await screen.findByText("帖子主页占位")).toBeInTheDocument();
  });
});
