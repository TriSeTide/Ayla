import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { listPosts } from "../api/posts";
import { getLiveChannel } from "../api/live";
import { getVoiceChannel } from "../api/voice";
import { createFriendRequest, getUserDetail } from "../api/users";
import type { LiveChannelDescriptor, Post, UserPublic, VoiceChannelDescriptor } from "../api/types";
import { ProfileContentSections } from "../components/ProfileContentSections";
import { UserProfilePage } from "../pages/UserProfilePage";
import { useAuthStore } from "../stores/auth";

vi.mock("../api/posts", () => ({ listPosts: vi.fn() }));
vi.mock("../api/live", () => ({ getLiveChannel: vi.fn() }));
vi.mock("../api/voice", () => ({ getVoiceChannel: vi.fn() }));
vi.mock("../api/users", () => ({ getUserDetail: vi.fn(), createFriendRequest: vi.fn() }));
vi.mock("../api/chat", () => ({ openPrivateConversation: vi.fn() }));
const empty = { results: [], total: 0, has_more: false, next_cursor: null };
const actor: UserPublic = { id: "viewer", username: "viewer", nickname: "", avatar: "", signature: "", status: "auto", online: true, date_joined: "" };
const posts = (from: number, to: number) => Array.from({ length: to - from }, (_, index) => ({ id: from + index, title: `帖子 ${from + index}`, body: "" } as Post));

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(listPosts).mockReset().mockResolvedValue(empty);
  vi.mocked(getLiveChannel).mockReset();
  vi.mocked(getVoiceChannel).mockReset();
  vi.mocked(getUserDetail).mockReset();
  useAuthStore.setState({ accessToken: "test", currentUser: actor });
});

describe("profile content cards", () => {
  it("本人模式：正在直播/正在语音按 owner 媒体活动拉详情，帖子取 3 条，桌游占位", async () => {
    const me: UserPublic = { ...actor, is_live: true, live_room_id: 7, is_in_voice: true, voice_room_id: 3 };
    useAuthStore.setState({ accessToken: "test", currentUser: me });
    vi.mocked(listPosts).mockResolvedValueOnce({ ...empty, results: posts(1, 4) });
    vi.mocked(getLiveChannel).mockResolvedValueOnce({ id: 7, title: "我的直播间", owner_nickname: "viewer" } as LiveChannelDescriptor);
    vi.mocked(getVoiceChannel).mockResolvedValueOnce({ id: "3", name: "我的语音房", owner_nickname: "viewer", member_count: 2 } as VoiceChannelDescriptor);

    render(<MemoryRouter><ProfileContentSections owner={me} mine /></MemoryRouter>);

    await waitFor(() => expect(listPosts).toHaveBeenCalledTimes(1));
    expect(listPosts).toHaveBeenCalledWith({ scope: "mine", limit: 3 });
    expect(getLiveChannel).toHaveBeenCalledWith(7);
    expect(getVoiceChannel).toHaveBeenCalledWith("3");

    await screen.findByText("我的直播间");
    await screen.findByText("我的语音房");
    await screen.findByText("帖子 1");
    // 桌游占位卡
    expect(screen.getByText("正在玩的桌游")).toBeInTheDocument();
    expect(screen.getByText("桌游玩法即将上线")).toBeInTheDocument();
    // 更多帖子 → 我的帖子界面
    expect(screen.getByRole("link", { name: "更多帖子" })).toHaveAttribute("href", "/posts/mine");
  });

  it("他人模式：无媒体活动不请求直播/语音详情，帖子走 owner 过滤", async () => {
    const other: UserPublic = { ...actor, id: "other", is_live: false, is_in_voice: false };
    vi.mocked(listPosts).mockResolvedValueOnce({ ...empty, results: posts(1, 3) });

    render(<MemoryRouter><ProfileContentSections owner={other} /></MemoryRouter>);

    await waitFor(() => expect(listPosts).toHaveBeenCalledTimes(1));
    expect(listPosts).toHaveBeenCalledWith({ owner: "other", limit: 3 });
    expect(getLiveChannel).not.toHaveBeenCalled();
    expect(getVoiceChannel).not.toHaveBeenCalled();
    // 更多帖子 → 该用户帖子界面
    expect(screen.getByRole("link", { name: "更多帖子" })).toHaveAttribute("href", "/user/other/posts");
  });

  it("正在直播/正在语音详情不可见（403）时静默不展示对应卡片", async () => {
    const me: UserPublic = { ...actor, is_live: true, live_room_id: 7, is_in_voice: true, voice_room_id: 3 };
    useAuthStore.setState({ accessToken: "test", currentUser: me });
    vi.mocked(listPosts).mockResolvedValueOnce(empty);
    vi.mocked(getLiveChannel).mockRejectedValueOnce(new Error("无权查看"));
    vi.mocked(getVoiceChannel).mockRejectedValueOnce(new Error("无权查看"));

    render(<MemoryRouter><ProfileContentSections owner={me} mine /></MemoryRouter>);

    await waitFor(() => expect(getLiveChannel).toHaveBeenCalledTimes(1));
    await waitFor(() => expect(getVoiceChannel).toHaveBeenCalledTimes(1));
    expect(screen.queryByText("正在直播")).not.toBeInTheDocument();
    expect(screen.queryByText("正在语音")).not.toBeInTheDocument();
    // 帖子空态仍展示
    expect(screen.getByText("还没有发帖")).toBeInTheDocument();
  });

  it("帖子加载失败展示错误，不伪造空态", async () => {
    vi.mocked(listPosts).mockRejectedValueOnce(new Error("帖子断线"));
    render(<MemoryRouter><ProfileContentSections owner={{ ...actor, id: "other" }} /></MemoryRouter>);
    await screen.findByRole("alert");
    expect(screen.getByText("帖子断线")).toBeInTheDocument();
    expect(screen.queryByText("暂无帖子")).not.toBeInTheDocument();
  });

  it("对方关闭内容展示时不渲染内容卡；好友操作错误保留资料", async () => {
    vi.mocked(getUserDetail).mockResolvedValue({ ...actor, id: "hidden", nickname: "隐藏内容用户", show_content: false, relation: "none" });
    vi.mocked(createFriendRequest).mockRejectedValueOnce(new Error("发送失败"));
    render(<MemoryRouter initialEntries={["/user/hidden"]}><Routes><Route path="/user/:userId" element={<UserProfilePage />} /></Routes></MemoryRouter>);
    await screen.findByText("隐藏内容用户");
    expect(listPosts).not.toHaveBeenCalled();
    // 内容卡（帖子卡标题）不渲染
    expect(screen.queryByText("帖子")).not.toBeInTheDocument();
  });
});
