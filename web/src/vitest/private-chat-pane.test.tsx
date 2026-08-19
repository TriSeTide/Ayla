/**
 * PrivateChatPane 非好友禁发测试（Bug #2）：
 * - 私聊对端不在好友列表 → 显示「对方已不是你的好友，无法发送消息」且不渲染输入区；
 * - 对端是好友 → 正常渲染输入区，无提示；
 * - 对端是爱莉（elysia profile 绑定用户）→ 放行，正常渲染输入区；
 * - 好友列表加载中/失败 → 视为未知，不禁用（后端 403 权威拦截）。
 */
import { render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { ConversationSummary, ElysiaProfile, Friendship, UserPublic } from "../api/types";
import { PrivateChatPane } from "../components/chat/PrivateChatPane";
import { useChatStore } from "../stores/chat";

vi.mock("../components/chat/MessageList", () => ({
  MessageList: () => <div data-testid="message-list" />,
}));
vi.mock("../components/chat/TypingIndicator", () => ({
  TypingIndicator: () => <div data-testid="typing" />,
}));
vi.mock("../components/chat/MessageInput", () => ({
  MessageInput: () => <div data-testid="message-input" />,
}));

vi.mock("../hooks/useChat", () => ({
  loadHistory: vi.fn().mockResolvedValue(undefined),
  loadMoreHistory: vi.fn().mockResolvedValue(undefined),
  markReadLatest: vi.fn().mockResolvedValue(undefined),
  recallMessage: vi.fn().mockResolvedValue({}),
}));

vi.mock("../ws/chat", () => ({
  chatWS: { subscribe: vi.fn(), onFrame: vi.fn(() => vi.fn()) },
}));

vi.mock("../api/users", () => ({
  listFriends: vi.fn(),
}));

vi.mock("../api/elysia", () => ({
  getElysiaProfile: vi.fn(),
}));

import * as usersApi from "../api/users";
import * as elysiaApi from "../api/elysia";

function user(id: string, nickname = "友友"): UserPublic {
  return {
    id,
    username: id,
    nickname,
    avatar: "",
    signature: "",
    status: "online",
    online: true,
    date_joined: "2026-01-01T00:00:00Z",
  };
}

function privateConv(peerId: string): ConversationSummary {
  return {
    id: "c1",
    type: "private",
    title: "私聊",
    announcement: "",
    avatar: "",
    owner_id: "me",
    members: [],
    my_role: "member",
    member_count: 2,
    unread_count: 0,
    created_at: "2026-01-01T00:00:00Z",
    peer: user(peerId),
  };
}

function friendshipOf(friendId: string): Friendship {
  return { id: 1, user: user(friendId), created_at: "2026-01-01T00:00:00Z" };
}

function elysiaProfileOf(userId: string, enabled = true): ElysiaProfile {
  return {
    id: 1,
    user: user(userId, "爱莉"),
    stream_id: "stream-1",
    platform: "ayla",
    enabled,
    display_name: "爱莉",
    chat_type: "private",
    created_at: "2026-01-01T00:00:00Z",
  };
}

function renderPane() {
  useChatStore.setState({ conversations: [privateConv("peer1")] });
  return render(<PrivateChatPane conversationId="c1" />);
}

describe("PrivateChatPane 非好友禁发（Bug #2）", () => {
  it("对端不在好友列表 → 显示提示且无输入区", async () => {
    vi.mocked(usersApi.listFriends).mockResolvedValue([]);
    vi.mocked(elysiaApi.getElysiaProfile).mockRejectedValue(new Error("404"));
    renderPane();
    await waitFor(() =>
      expect(screen.getByText("对方已不是你的好友，无法发送消息")).toBeInTheDocument(),
    );
    expect(screen.queryByTestId("message-input")).not.toBeInTheDocument();
  });

  it("对端是好友 → 正常渲染输入区，无提示", async () => {
    vi.mocked(usersApi.listFriends).mockResolvedValue([friendshipOf("peer1")]);
    vi.mocked(elysiaApi.getElysiaProfile).mockRejectedValue(new Error("404"));
    renderPane();
    await waitFor(() => expect(screen.getByTestId("message-input")).toBeInTheDocument());
    expect(screen.queryByText("对方已不是你的好友，无法发送消息")).not.toBeInTheDocument();
  });

  it("对端是爱莉 → 放行（非好友也渲染输入区，防回归）", async () => {
    vi.mocked(usersApi.listFriends).mockResolvedValue([]);
    vi.mocked(elysiaApi.getElysiaProfile).mockResolvedValue(elysiaProfileOf("peer1"));
    renderPane();
    await waitFor(() => expect(screen.getByTestId("message-input")).toBeInTheDocument());
    expect(screen.queryByText("对方已不是你的好友，无法发送消息")).not.toBeInTheDocument();
  });

  it("好友列表加载中 → 不禁用输入（未知态，后端 403 兜底）", async () => {
    vi.mocked(usersApi.listFriends).mockImplementation(() => new Promise(() => {}));
    vi.mocked(elysiaApi.getElysiaProfile).mockRejectedValue(new Error("404"));
    renderPane();
    // 等待加载 effect 跑完（渲染后立即有输入区）
    expect(screen.getByTestId("message-input")).toBeInTheDocument();
    expect(screen.queryByText("对方已不是你的好友，无法发送消息")).not.toBeInTheDocument();
  });
});
