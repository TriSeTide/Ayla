import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { listPosts } from "../api/posts";
import { listLiveChannelsPage } from "../api/live";
import { listGameRoomsPage } from "../api/boardgame";
import { createFriendRequest, getUserDetail } from "../api/users";
import type { GameRoom, LiveChannelDescriptor, Post, PostListPage, UserPublic } from "../api/types";
import { ProfileContentSections } from "../components/ProfileContentSections";
import { UserProfilePage } from "../pages/UserProfilePage";
import { useAuthStore } from "../stores/auth";

vi.mock("../api/posts", () => ({ listPosts: vi.fn() }));
vi.mock("../api/live", () => ({ listLiveChannelsPage: vi.fn() }));
vi.mock("../api/boardgame", () => ({ listGameRoomsPage: vi.fn() }));
vi.mock("../api/users", () => ({ getUserDetail: vi.fn(), createFriendRequest: vi.fn() }));
vi.mock("../api/chat", () => ({ openPrivateConversation: vi.fn() }));
const empty = { results: [], total: 0, has_more: false, next_cursor: null };
const actor: UserPublic = { id: "viewer", username: "viewer", nickname: "", avatar: "", signature: "", status: "auto", online: true, date_joined: "" };
const posts = (from: number, to: number) => Array.from({ length: to - from }, (_, index) => ({ id: from + index, title: `帖子 ${from + index}`, body: "" } as Post));
const page = <T,>(results: T[], next: string | null = null) => ({ results, total: 21, has_more: Boolean(next), next_cursor: next });

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(listPosts).mockReset().mockResolvedValue(empty);
  vi.mocked(listLiveChannelsPage).mockReset().mockResolvedValue(empty);
  vi.mocked(listGameRoomsPage).mockReset().mockResolvedValue(empty);
  vi.mocked(getUserDetail).mockReset();
  useAuthStore.setState({ accessToken: "test", currentUser: actor });
});

describe("profile content cursor pages", () => {
  it("本人三分区首屏各取20条，使用服务端总数并分别按游标续读", async () => {
    vi.mocked(listPosts).mockResolvedValueOnce(page(posts(1, 21), "posts-tail")).mockResolvedValueOnce(page(posts(21, 22)));
    vi.mocked(listLiveChannelsPage).mockResolvedValueOnce(page([{ id: 1, title: "直播首屏" } as LiveChannelDescriptor], "live-tail"))
      .mockResolvedValueOnce(page([{ id: 21, title: "直播尾页" } as LiveChannelDescriptor]));
    vi.mocked(listGameRoomsPage).mockResolvedValueOnce(page([{ id: 1, name: "桌游首屏" } as GameRoom], "games-tail"))
      .mockResolvedValueOnce(page([{ id: 21, name: "桌游尾页" } as GameRoom]));
    render(<MemoryRouter><ProfileContentSections ownerId="viewer" mine /></MemoryRouter>);
    await waitFor(() => expect(listPosts).toHaveBeenCalledTimes(1));
    expect(listPosts).toHaveBeenCalledWith({ scope: "mine", limit: 20, cursor: null });
    expect(listLiveChannelsPage).toHaveBeenCalledWith({ owner: "viewer", limit: 20, cursor: null });
    expect(listGameRoomsPage).toHaveBeenCalledWith({ mine: true, limit: 20, cursor: null });
    for (const title of ["我的发帖", "我的直播间", "正在玩的桌游"]) {
      const section = screen.getByRole("region", { name: title });
      expect(within(section).getByRole("button")).toHaveTextContent("21");
      fireEvent.click(within(section).getByRole("button"));
      fireEvent.click(within(section).getByRole("button", { name: "加载更多" }));
    }
    await screen.findByText("帖子 21"); await screen.findByText("直播尾页"); await screen.findByText("桌游尾页");
    expect(listPosts).toHaveBeenLastCalledWith({ scope: "mine", limit: 20, cursor: "posts-tail" });
    expect(listLiveChannelsPage).toHaveBeenLastCalledWith({ owner: "viewer", limit: 20, cursor: "live-tail" });
    expect(listGameRoomsPage).toHaveBeenLastCalledWith({ mine: true, limit: 20, cursor: "games-tail" });
  });

  it("首屏失败可重试，续读失败保留已读条目，且各分区互不阻塞", async () => {
    vi.mocked(listPosts).mockRejectedValueOnce(new Error("帖子断线"))
      .mockResolvedValueOnce(page(posts(1, 3), "tail"))
      .mockRejectedValueOnce(new Error("尾页断线"))
      .mockResolvedValueOnce(page(posts(3, 4)));
    render(<MemoryRouter><ProfileContentSections ownerId="other" /></MemoryRouter>);
    const section = screen.getByRole("region", { name: "他的发帖" });
    fireEvent.click(within(section).getByRole("button"));
    await screen.findByText("帖子断线");
    expect(screen.queryByText("暂无发帖")).not.toBeInTheDocument();
    fireEvent.click(within(section).getByRole("button", { name: "重试" }));
    await screen.findByText("帖子 1");
    fireEvent.click(within(section).getByRole("button", { name: "加载更多" }));
    await screen.findByText("尾页断线");
    expect(screen.getByText("帖子 1")).toBeInTheDocument();
    fireEvent.click(within(section).getByRole("button", { name: "重试" }));
    await screen.findByText("帖子 3");
    expect(listPosts).toHaveBeenLastCalledWith({ owner: "other", limit: 20, cursor: "tail" });
    expect(listLiveChannelsPage).toHaveBeenCalledTimes(1); expect(listGameRoomsPage).toHaveBeenCalledTimes(1);
  });

  it("切换资料主人后拒绝上一人的迟到分页回包", async () => {
    let finish!: (result: PostListPage) => void;
    vi.mocked(listPosts).mockReturnValueOnce(new Promise((resolve) => { finish = resolve; }))
      .mockResolvedValueOnce(page([{ id: 9, title: "新主人的帖子", body: "" } as Post]));
    const { rerender } = render(<MemoryRouter><ProfileContentSections ownerId="old" /></MemoryRouter>);
    await waitFor(() => expect(listPosts).toHaveBeenCalledTimes(1));
    rerender(<MemoryRouter><ProfileContentSections ownerId="new" /></MemoryRouter>);
    fireEvent.click(within(screen.getByRole("region", { name: "他的发帖" })).getByRole("button"));
    await screen.findByText("新主人的帖子");
    await act(async () => { finish(page([{ id: 1, title: "旧主人的帖子", body: "" } as Post])); });
    expect(screen.queryByText("旧主人的帖子")).not.toBeInTheDocument();
    expect(listLiveChannelsPage).toHaveBeenLastCalledWith({ owner: "new", limit: 20, cursor: null });
    expect(listGameRoomsPage).toHaveBeenLastCalledWith({ owner: "new", limit: 20, cursor: null });
  });

  it("对方关闭内容展示时不发三分区请求；好友操作错误保留资料", async () => {
    vi.mocked(getUserDetail).mockResolvedValue({ ...actor, id: "hidden", nickname: "隐藏内容用户", show_content: false, relation: "none" });
    vi.mocked(createFriendRequest).mockRejectedValueOnce(new Error("发送失败"));
    render(<MemoryRouter initialEntries={["/user/hidden"]}><Routes><Route path="/user/:userId" element={<UserProfilePage />} /></Routes></MemoryRouter>);
    await screen.findByText("隐藏内容用户");
    expect(listPosts).not.toHaveBeenCalled(); expect(listLiveChannelsPage).not.toHaveBeenCalled(); expect(listGameRoomsPage).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "添加好友" }));
    await screen.findByRole("alert");
    expect(screen.getByText("隐藏内容用户")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "添加好友" })).toBeEnabled();
  });
});
