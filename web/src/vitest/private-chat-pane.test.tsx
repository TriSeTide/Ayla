/**
 * PrivateChatPane 非好友禁发测试（Bug #2）：
 * - 私聊对端不在好友列表 → 显示「对方已不是你的好友，无法发送消息」且不渲染输入区；
 * - 对端是好友 → 正常渲染输入区，无提示；
 * - 对端是爱莉（elysia profile 绑定用户）→ 放行，正常渲染输入区；
 * - 好友列表加载中/失败 → 视为未知，不禁用（后端 403 权威拦截）。
 *
 * 「对方正在输入」顶栏字样（群聊已删除该功能，私聊保留）：
 * - 自己的 typing 帧 → 顶栏不显示「对方正在输入…」；
 * - 仅当前会话的他人 typing 帧 → 顶栏好友名字下方显示「对方正在输入…」。
 */
import { act, render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { ChatMessage, ConversationSummary, ElysiaProfile, UserPublic } from "../api/types";
import { PrivateChatPane } from "../components/chat/PrivateChatPane";
import { useChatStore } from "../stores/chat";
import { useAuthStore } from "../stores/auth";

/** 捕获 chatWS.onFrame 注册的 handler（vi.mock hoisted，测试里 fire typing 帧用） */
const ws = vi.hoisted(() => ({
  frameHandler: null as ((frame: unknown) => void) | null,
  onRecall: null as ((message: ChatMessage) => void) | null,
}));

vi.mock("../components/chat/MessageList", () => ({
  MessageList: (props: { onRecall: (message: ChatMessage) => void }) => {
    ws.onRecall = props.onRecall;
    return <div data-testid="message-list" />;
  },
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
  chatWS: {
    subscribe: vi.fn(),
    onFrame: vi.fn((handler: (frame: unknown) => void) => {
      ws.frameHandler = handler;
      return vi.fn();
    }),
  },
}));

vi.mock("../api/chat", () => ({ getConversationMetadata: vi.fn(async () => useChatStore.getState().conversations[0]) }));

vi.mock("../api/users", () => ({
  getUserDetail: vi.fn(),
}));

vi.mock("../api/elysia", () => ({
  getElysiaProfile: vi.fn(),
}));

import * as usersApi from "../api/users";
import * as elysiaApi from "../api/elysia";
import { recallMessage } from "../hooks/useChat";

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
  it("撤回失败静默处理，重试成功后不残留任何提示", async () => {
    // bcb00dc 起撤回失败静默：无错误提示条；核心意图保留——重试仍走同一撤回通道。
    vi.mocked(usersApi.getUserDetail).mockResolvedValue({ ...user("peer1"), relation: "friend" });
    vi.mocked(elysiaApi.getElysiaProfile).mockRejectedValue(new Error("404"));
    const message: ChatMessage = { id: "recall-fixture", conversation_id: "c1", sender_id: "me", type: "text", content: "合成撤回内容", media_id: null, media: null, reply_to: null, status: "sent", seq: 1, created_at: "2026-09-08T00:00:00Z" };
    vi.mocked(recallMessage).mockRejectedValueOnce(new Error("合成撤回失败"));
    renderPane();
    await act(async () => ws.onRecall!(message));
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(screen.queryByText(/合成撤回失败/)).not.toBeInTheDocument();
    let resolveRecall!: (value: ChatMessage) => void;
    vi.mocked(recallMessage).mockReturnValueOnce(new Promise((resolve) => { resolveRecall = resolve; }));
    act(() => ws.onRecall!(message));
    await act(async () => resolveRecall({ ...message, status: "recalled" }));
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(recallMessage).toHaveBeenLastCalledWith("c1", "recall-fixture");
  });

  it("对端不在好友列表 → 显示提示且无输入区", async () => {
    vi.mocked(usersApi.getUserDetail).mockResolvedValue({ ...user("peer1"), relation: "none" });
    vi.mocked(elysiaApi.getElysiaProfile).mockRejectedValue(new Error("404"));
    renderPane();
    await waitFor(() =>
      expect(screen.getByText("对方已不是你的好友，无法发送消息")).toBeInTheDocument(),
    );
    expect(screen.queryByTestId("message-input")).not.toBeInTheDocument();
  });

  it("对端是好友 → 正常渲染输入区，无提示", async () => {
    vi.mocked(usersApi.getUserDetail).mockResolvedValue({ ...user("peer1"), relation: "friend" });
    vi.mocked(elysiaApi.getElysiaProfile).mockRejectedValue(new Error("404"));
    renderPane();
    await waitFor(() => expect(screen.getByTestId("message-input")).toBeInTheDocument());
    expect(screen.queryByText("对方已不是你的好友，无法发送消息")).not.toBeInTheDocument();
  });

  it("对端是爱莉 → 放行（非好友也渲染输入区，防回归）", async () => {
    vi.mocked(usersApi.getUserDetail).mockResolvedValue({ ...user("peer1"), relation: "none" });
    vi.mocked(elysiaApi.getElysiaProfile).mockResolvedValue(elysiaProfileOf("peer1"));
    renderPane();
    await waitFor(() => expect(screen.getByTestId("message-input")).toBeInTheDocument());
    expect(screen.queryByText("对方已不是你的好友，无法发送消息")).not.toBeInTheDocument();
  });

  it("好友列表加载中 → 不禁用输入（未知态，后端 403 兜底）", async () => {
    vi.mocked(usersApi.getUserDetail).mockImplementation(() => new Promise(() => {}));
    vi.mocked(elysiaApi.getElysiaProfile).mockRejectedValue(new Error("404"));
    renderPane();
    // 等待加载 effect 跑完（渲染后立即有输入区）
    expect(screen.getByTestId("message-input")).toBeInTheDocument();
    expect(screen.queryByText("对方已不是你的好友，无法发送消息")).not.toBeInTheDocument();
  });

  it("自己输入不显示「对方正在输入」（忽略自己的 typing 帧）", async () => {
    useAuthStore.setState({ currentUser: user("me") });
    vi.mocked(usersApi.getUserDetail).mockResolvedValue({ ...user("peer1"), relation: "friend" });
    vi.mocked(elysiaApi.getElysiaProfile).mockRejectedValue(new Error("404"));
    renderPane();
    await waitFor(() => expect(screen.getByTestId("message-input")).toBeInTheDocument());
    act(() => {
      ws.frameHandler!({
        type: "typing",
        data: { conversation_id: "c1", user_id: "me", is_typing: true },
      });
    });
    expect(screen.queryByText("对方正在输入…")).not.toBeInTheDocument();
    useAuthStore.setState({ currentUser: null });
  });

  it("仅当前会话的他人 typing 帧在顶栏显示「对方正在输入」", async () => {
    useAuthStore.setState({ currentUser: user("me") });
    vi.mocked(usersApi.getUserDetail).mockResolvedValue({ ...user("peer1"), relation: "friend" });
    vi.mocked(elysiaApi.getElysiaProfile).mockRejectedValue(new Error("404"));
    renderPane();
    await waitFor(() => expect(screen.getByTestId("message-input")).toBeInTheDocument());
    // 其他会话的他人 typing 帧 → 不显示
    act(() => {
      ws.frameHandler!({
        type: "typing",
        data: { conversation_id: "c2", user_id: "peer1", is_typing: true },
      });
    });
    expect(screen.queryByText("对方正在输入…")).not.toBeInTheDocument();
    // 当前会话的他人 typing 帧 → 顶栏显示
    act(() => {
      ws.frameHandler!({
        type: "typing",
        data: { conversation_id: "c1", user_id: "peer1", is_typing: true },
      });
    });
    expect(screen.getByText("对方正在输入…")).toBeInTheDocument();
    useAuthStore.setState({ currentUser: null });
  });
});
