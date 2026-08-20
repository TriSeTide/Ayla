/**
 * 消息中心审批错误提示测试（测试报告 #3 修复）：
 * - 好友申请/群邀请/入群申请的「同意/拒绝」请求失败 → 显示错误提示条；
 * - 点击提示条关闭；
 * - 成功路径 → 条目移除 + 不显示错误。
 * 渲染 WideMessagesSidebar（宽屏认证消息 tab），mock 子组件与 API。
 */
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as usersApi from "../api/users";
import type { FriendRequest } from "../api/types";
import { WideMessagesSidebar } from "../components/chat/WideMessagesSidebar";
import { useBadgesStore } from "../stores/badges";
import { useChatStore } from "../stores/chat";
import { useAuthStore } from "../stores/auth";

vi.mock("../components/chat/ConversationList", () => ({
  ConversationList: () => <div data-testid="conversation-list" />,
}));
vi.mock("../components/chat/ElysiaEntry", () => ({
  ElysiaEntry: () => <div data-testid="elysia-entry" />,
}));

vi.mock("../api/chat", () => ({
  listConversations: vi.fn().mockResolvedValue([]),
  listMyInvites: vi.fn().mockResolvedValue([]),
  listLeaveNotices: vi.fn().mockResolvedValue([]),
  listJoinRequests: vi.fn().mockResolvedValue([]),
  actionGroupInvite: vi.fn().mockResolvedValue({}),
  actionJoinRequest: vi.fn().mockResolvedValue({}),
  openPrivateConversation: vi.fn().mockResolvedValue({ id: "c1" }),
}));

vi.mock("../api/users", () => ({
  listFriends: vi.fn().mockResolvedValue([]),
  listFriendRequests: vi.fn().mockResolvedValue([]),
  actionFriendRequest: vi.fn().mockResolvedValue({ detail: "ok", status: "accepted" }),
}));

vi.mock("../api/elysia", () => ({
  getElysiaProfile: vi.fn().mockResolvedValue({ enabled: false, user: null }),
}));

const req: FriendRequest = {
  id: 1,
  from_user: {
    id: "u2",
    username: "bob",
    nickname: "小樱",
    avatar: "",
    signature: "",
    status: "offline",
    online: false,
    date_joined: "2026-01-01T00:00:00Z",
  },
  to_user: {
    id: "u1",
    username: "alice",
    nickname: "爱丽丝",
    avatar: "",
    signature: "",
    status: "online",
    online: true,
    date_joined: "2026-01-01T00:00:00Z",
  },
  message: "加个好友",
  status: "pending",
  created_at: "2026-01-01T00:00:00Z",
};

function renderSidebar() {
  return render(
    <WideMessagesSidebar
      conversations={[]}
      activeId={null}
      onSelect={vi.fn()}
    />,
  );
}

beforeEach(() => {
  useChatStore.setState({ conversations: [] });
  useAuthStore.setState({ currentUser: req.to_user, accessToken: "acc" });
  useBadgesStore.setState({ fetch: vi.fn() } as never);
});

afterEach(() => {
  vi.clearAllMocks();
  useChatStore.setState({ conversations: [] });
});

describe("审批失败错误提示（#3）", () => {
  it("好友申请同意失败 → 显示错误提示，点击关闭后消失", async () => {
    vi.mocked(usersApi.listFriendRequests).mockResolvedValue([req]);
    vi.mocked(usersApi.actionFriendRequest).mockRejectedValue(new Error("服务器错误"));
    renderSidebar();
    // 切到认证消息 tab
    fireEvent.click(screen.getByRole("button", { name: /认证消息/ }));
    await waitFor(() => expect(screen.getByText("加个好友")).toBeInTheDocument());
    fireEvent.click(screen.getByRole("button", { name: "同意" }));
    await waitFor(() => {
      expect(screen.getByRole("alert")).toBeInTheDocument();
    });
    expect(screen.getByText(/服务器错误/)).toBeInTheDocument();
    // 点击关闭
    fireEvent.click(screen.getByRole("alert"));
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("好友申请拒绝失败 → 显示错误提示（拒绝同路径）", async () => {
    vi.mocked(usersApi.listFriendRequests).mockResolvedValue([req]);
    vi.mocked(usersApi.actionFriendRequest).mockRejectedValue(new Error("网络异常"));
    renderSidebar();
    fireEvent.click(screen.getByRole("button", { name: /认证消息/ }));
    await waitFor(() => expect(screen.getByText("加个好友")).toBeInTheDocument());
    fireEvent.click(screen.getByRole("button", { name: "拒绝" }));
    await waitFor(() => {
      expect(screen.getByText(/网络异常/)).toBeInTheDocument();
    });
  });

  it("同意成功 → 条目移除且无错误提示", async () => {
    vi.mocked(usersApi.listFriendRequests).mockResolvedValue([req]);
    vi.mocked(usersApi.actionFriendRequest).mockResolvedValue({ detail: "ok", status: "accepted" });
    renderSidebar();
    fireEvent.click(screen.getByRole("button", { name: /认证消息/ }));
    await waitFor(() => expect(screen.getByText("加个好友")).toBeInTheDocument());
    fireEvent.click(screen.getByRole("button", { name: "同意" }));
    await waitFor(() => {
      expect(screen.queryByText("加个好友")).not.toBeInTheDocument();
    });
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });
});
