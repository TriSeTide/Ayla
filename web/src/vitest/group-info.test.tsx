/**
 * GroupInfo 测试（F3 R-G9 角色化）：
 * - owner/admin 看到「编辑群资料」+ 管理项占位；成员看不到编辑，看到退出占位；
 * - 成员列表角色标签（owner/admin/member）。
 */
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ConversationSummary, ConversationMember, UserPublic } from "../api/types";
import { GroupInfo } from "../pages/group/GroupInfo";
import { useAuthStore } from "../stores/auth";
import { useChatStore } from "../stores/chat";

vi.mock("../api/chat", () => ({
  // 默认返回一个群详情，避免未命中 store 时的 effect 拿 undefined（.then 崩）
  getConversation: vi.fn().mockResolvedValue({
    id: "1",
    type: "group",
    title: "测试群",
    announcement: "",
    owner_id: "o1",
    members: [],
    my_role: null,
    member_count: 0,
    unread_count: 0,
    created_at: "2026-01-01T00:00:00Z",
    peer: null,
  }),
  patchConversation: vi.fn(),
}));

function user(id: string, nickname: string): UserPublic {
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

function member(userId: string, role: ConversationMember["role"]): ConversationMember {
  return { id: userId, user: user(userId, userId === "u1" ? "爱丽丝" : "用户" + userId), role, muted: false, joined_at: "2026-01-01T00:00:00Z" };
}

function conv(myRole: ConversationSummary["my_role"]): ConversationSummary {
  return {
    id: "1",
    type: "group",
    title: "测试群",
    announcement: "群公告",
    owner_id: "o1",
    members: [
      member("o1", "owner"),
      { ...member("u1", "member"), user: user("u1", "爱丽丝") },
      member("a1", "admin"),
      member("m1", "member"),
    ],
    my_role: myRole,
    member_count: 4,
    unread_count: 0,
    created_at: "2026-01-01T00:00:00Z",
    peer: null,
  };
}

function renderInfo(myRole: ConversationSummary["my_role"]) {
  useChatStore.setState({ conversations: [conv(myRole)] });
  return render(
    <MemoryRouter>
      <GroupInfo groupId="1" />
    </MemoryRouter>,
  );
}

beforeEach(() => {
  useAuthStore.setState({
    accessToken: "acc",
    currentUser: user("u1", "爱丽丝"),
  });
});

afterEach(() => {
  vi.clearAllMocks();
  useChatStore.setState({ conversations: [] });
});

describe("GroupInfo 角色化", () => {
  it("owner 看到编辑群资料 + 成员角色标签（群主/管理员）", () => {
    renderInfo("owner");
    expect(screen.getByRole("button", { name: "编辑群资料" })).toBeInTheDocument();
    expect(screen.getByText("群主")).toBeInTheDocument();
    expect(screen.getByText("管理员")).toBeInTheDocument();
    expect(screen.getByText("群公告")).toBeInTheDocument();
  });

  it("owner 看到管理项占位（入群申请审批）", () => {
    renderInfo("owner");
    expect(screen.getByText(/入群申请审批/)).toBeInTheDocument();
  });

  it("普通成员不看到编辑按钮，看到退出占位", () => {
    renderInfo("member");
    expect(screen.queryByRole("button", { name: "编辑群资料" })).not.toBeInTheDocument();
    expect(screen.getByText(/退出群/)).toBeInTheDocument();
  });
});
