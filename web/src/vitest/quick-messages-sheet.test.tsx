/**
 * QuickMessagesSheet —— 红点快捷消息栏测试（R-QM）。
 *
 * - 两个选项卡（私信/认证消息），默认私信 tab 显示会话列表；
 * - 栏内头像不可点（disableAvatarNav=true 传递给 ConversationList / PrivateChatPane）；
 * - 私信 tab 点会话 → 内联聊天（不跳路由），返回按钮回列表；
 * - 认证消息 tab 显示好友申请（同 /messages 认证消息 tab）；
 * - 点击上方 30% 遮罩关闭。
 */
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as usersApi from "../api/users";
import type { FriendRequest } from "../api/types";
import { QuickMessagesSheet } from "../components/chat/QuickMessagesSheet";
import { useAuthStore } from "../stores/auth";
import { useBadgesStore } from "../stores/badges";
import { useChatStore } from "../stores/chat";

vi.mock("../components/chat/ConversationList", () => ({
  ConversationList: ({
    onSelect,
    disableAvatarNav,
  }: {
    onSelect: (id: string) => void;
    disableAvatarNav?: boolean;
  }) => (
    <button
      type="button"
      data-testid="conversation-item"
      data-disable-avatar={String(disableAvatarNav)}
      onClick={() => onSelect("c1")}
    >
      会话
    </button>
  ),
}));

vi.mock("../components/chat/ElysiaEntry", () => ({
  ElysiaEntry: ({ onEnter }: { onEnter: () => void }) => (
    <button type="button" onClick={onEnter}>
      爱莉入口
    </button>
  ),
}));

vi.mock("../components/chat/PrivateChatPane", () => ({
  PrivateChatPane: ({
    onBack,
    disableAvatarNav,
  }: {
    onBack?: () => void;
    disableAvatarNav?: boolean;
  }) => (
    <div data-testid="private-chat-pane" data-disable-avatar={String(disableAvatarNav)}>
      <button type="button" onClick={onBack}>
        返回列表
      </button>
    </div>
  ),
}));

vi.mock("../api/chat", () => ({
  listConversations: vi.fn().mockResolvedValue([]),
  listMyInvites: vi.fn().mockResolvedValue([]),
  listLeaveNotices: vi.fn().mockResolvedValue([]),
  listJoinRequests: vi.fn().mockResolvedValue([]),
  actionGroupInvite: vi.fn().mockResolvedValue({}),
  actionJoinRequest: vi.fn().mockResolvedValue({}),
  openPrivateConversation: vi.fn().mockResolvedValue({ id: "c1" }),
  readLeaveNotice: vi.fn().mockResolvedValue({}),
}));

vi.mock("../api/users", () => ({
  listFriends: vi.fn().mockResolvedValue([]),
  listFriendRequests: vi.fn().mockResolvedValue([]),
  actionFriendRequest: vi.fn().mockResolvedValue({ detail: "ok", status: "accepted" }),
}));

vi.mock("../api/elysia", () => ({
  getElysiaProfile: vi.fn().mockResolvedValue({ enabled: true, user: { id: "u2" } }),
}));

const req: FriendRequest = {
  id: 1,
  from_user: {
    id: "u2",
    username: "bob",
    nickname: "小樱",
    avatar: "",
    signature: "",
    status: "auto",
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

beforeEach(() => {
  useChatStore.setState({ conversations: [] });
  useAuthStore.setState({ currentUser: req.to_user, accessToken: "acc" });
  useBadgesStore.setState({ badges: null, fetch: vi.fn() } as never);
});

afterEach(() => {
  vi.clearAllMocks();
});

function renderSheet(onClose = vi.fn()) {
  return render(<QuickMessagesSheet onClose={onClose} />);
}

describe("QuickMessagesSheet", () => {
  it("渲染私信/认证消息两个 tab，默认私信 tab 会话列表头像不可点", () => {
    renderSheet();
    expect(screen.getByRole("tab", { name: "私信" })).toBeInTheDocument();
    expect(screen.getByRole("tab", { name: /认证消息/ })).toBeInTheDocument();
    // 会话列表 disableAvatarNav=true（头像无效）
    expect(screen.getByTestId("conversation-item")).toHaveAttribute("data-disable-avatar", "true");
  });

  it("私信 tab 点会话 → 内联聊天（头像无效），返回按钮回列表", () => {
    renderSheet();
    fireEvent.click(screen.getByTestId("conversation-item"));
    const pane = screen.getByTestId("private-chat-pane");
    expect(pane).toHaveAttribute("data-disable-avatar", "true");
    fireEvent.click(screen.getByRole("button", { name: "返回列表" }));
    expect(screen.queryByTestId("private-chat-pane")).not.toBeInTheDocument();
    expect(screen.getByTestId("conversation-item")).toBeInTheDocument();
  });

  it("认证消息 tab 显示好友申请条目（同 /messages 认证消息 tab）", async () => {
    vi.mocked(usersApi.listFriendRequests).mockResolvedValue([req]);
    renderSheet();
    fireEvent.click(screen.getByRole("tab", { name: /认证消息/ }));
    await waitFor(() => expect(screen.getByText("加个好友")).toBeInTheDocument());
    expect(screen.getByRole("button", { name: "同意" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "拒绝" })).toBeInTheDocument();
  });

  it("点击上方 30% 遮罩关闭", () => {
    const onClose = vi.fn();
    const { container } = renderSheet(onClose);
    fireEvent.click(container.querySelector(".quick-messages-scrim")!);
    expect(onClose).toHaveBeenCalledTimes(1);
  });
});
