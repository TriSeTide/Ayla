/**
 * GroupChat 群成员加载（头像/昵称数据源）。
 *
 * 回归背景：6fc9142 之后 metadata/目录 serializer 有意排除群 members（后端
 * ConversationMetadataSerializer），GroupChat 只调 getConversationMetadata →
 * conversation.members 恒空 → MessageList 的 memberAvatars/memberNames 空 →
 * 群聊发送者头像/昵称不显示。修复：GroupChat 挂载后全量拉取成员分页并合并进
 * conversation.members（members_complete=true 后不再重复拉取）。
 */
import { act, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as chatApi from "../api/chat";
import type { ConversationMember, ConversationSummary, SubGroup } from "../api/types";
import { loadHistory } from "../hooks/useChat";
import { useAuthStore } from "../stores/auth";
import { useChatStore } from "../stores/chat";
import { useMessageStore } from "../stores/message";
import { useSubGroupStore } from "../stores/subgroup";
import { disposeSocialTracking } from "../stores/social";
import { GroupChat } from "../pages/group/GroupChat";

vi.mock("../api/chat", () => ({
  listSubgroups: vi.fn(() => Promise.resolve(groups())),
  getConversationMetadata: vi.fn(async () => conversation),
  listSubgroupsPage: vi.fn(async (id: string) => {
    const results = await chatApi.listSubgroups(id);
    return { results, total: results.length, has_more: false, next_cursor: null, default: results.find((row) => row.is_default) ?? null };
  }),
  listConversationMembersPage: vi.fn(),
  sendPoke: vi.fn().mockResolvedValue({}),
}));
vi.mock("../api/elysia", () => ({ getElysiaProfile: vi.fn(() => new Promise(() => {})) }));
vi.mock("../ws/chat", () => ({ chatWS: { subscribe: vi.fn() } }));
vi.mock("../hooks/useChat", async () => ({
  messageInSubgroup: (await vi.importActual<typeof import("../hooks/useChat")>("../hooks/useChat")).messageInSubgroup,
  loadHistory: vi.fn().mockResolvedValue(undefined),
  loadMoreHistory: vi.fn().mockResolvedValue(undefined),
  loadHistoryUntilSeq: vi.fn().mockResolvedValue(false),
  markMessageReadExact: vi.fn(),
  recallMessage: vi.fn(),
  retryOptimistic: vi.fn(),
  removeOptimistic: vi.fn(),
  cancelOptimistic: vi.fn(),
  TARGET_HISTORY_MAX_PAGES: 10,
}));
vi.mock("../components/chat/MessageList", () => ({
  MessageList: () => <div className="message-list" />,
}));
vi.mock("../components/chat/MessageInput", async () => {
  const { forwardRef } = await import("react");
  return { MessageInput: forwardRef<HTMLDivElement>((_props, ref) => <div ref={ref} className="composer" />) };
});

function groups(): SubGroup[] {
  return [{ id: "1", conversation_id: "g", name: "默认组", is_default: true, unread_count: 0, created_at: "2026-09-08T00:00:00Z" }];
}
function member(id: string, nickname: string, avatar: string | null): ConversationMember {
  return {
    id,
    user: { id, username: id, nickname, avatar: avatar ?? "", signature: "", status: "auto", online: false, date_joined: "2026-09-08T00:00:00Z" },
    role: "member",
    muted: false,
    joined_at: "2026-09-08T00:00:00Z",
  };
}
const conversation: ConversationSummary = {
  id: "g", type: "group", title: "群", announcement: "", avatar: "", owner_id: "me",
  members: [], members_complete: false, my_role: "owner", member_count: 3, unread_count: 0,
  created_at: "2026-09-08T00:00:00Z", peer: null,
};

beforeEach(() => {
  disposeSocialTracking();
  useAuthStore.setState({
    currentUser: { id: "me", username: "me", nickname: "", avatar: "", signature: "", status: "auto", online: false, date_joined: "" },
    accessToken: "test",
  });
  vi.stubGlobal("matchMedia", vi.fn((query: string) => ({
    get matches() { return query.includes("prefers-reduced-motion") && false; },
    addEventListener: () => {},
    removeEventListener: () => {},
  })));
  vi.mocked(chatApi.listSubgroups).mockReset().mockResolvedValue(groups());
  vi.mocked(chatApi.listConversationMembersPage).mockReset();
  vi.mocked(loadHistory).mockReset().mockResolvedValue(undefined);
  useChatStore.setState({ conversations: [conversation], activeConversationId: null });
  useSubGroupStore.setState({ byGroup: { g: groups() }, activeByGroup: { g: "1" } });
  useMessageStore.getState().reset();
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("GroupChat 群成员加载（头像/昵称数据源）", () => {
  it("挂载后全量拉取成员分页并合并进 conversation.members", async () => {
    vi.mocked(chatApi.listConversationMembersPage)
      .mockResolvedValueOnce({ results: [member("u1", "甲", "https://x/a.png"), member("u2", "乙", null)], total: 3, has_more: true, next_cursor: "c2" })
      .mockResolvedValueOnce({ results: [member("u3", "丙", "https://x/c.png")], total: 3, has_more: false, next_cursor: null });
    render(<MemoryRouter><GroupChat groupId="g" /></MemoryRouter>);
    await waitFor(() => {
      const conv = useChatStore.getState().conversations.find((c) => c.id === "g");
      expect(conv?.members_complete).toBe(true);
      expect(conv?.members).toHaveLength(3);
    });
    expect(chatApi.listConversationMembersPage).toHaveBeenNthCalledWith(1, "g", { limit: 100, cursor: null });
    expect(chatApi.listConversationMembersPage).toHaveBeenNthCalledWith(2, "g", { limit: 100, cursor: "c2" });
    const conv = useChatStore.getState().conversations.find((c) => c.id === "g")!;
    expect(conv.members.map((m) => m.user.nickname)).toEqual(["甲", "乙", "丙"]);
    // 头像/昵称数据源就绪：MessageList 的 memberAvatars 能查到发送者
    expect(conv.members.find((m) => m.user.id === "u1")?.user.avatar).toBe("https://x/a.png");
  });

  it("members_complete=true 后重新挂载不再重复拉取", async () => {
    vi.mocked(chatApi.listConversationMembersPage).mockResolvedValue({ results: [member("u1", "甲", null)], total: 1, has_more: false, next_cursor: null });
    const { unmount } = render(<MemoryRouter><GroupChat groupId="g" /></MemoryRouter>);
    await waitFor(() => expect(useChatStore.getState().conversations.find((c) => c.id === "g")?.members_complete).toBe(true));
    const calls = vi.mocked(chatApi.listConversationMembersPage).mock.calls.length;
    unmount();
    render(<MemoryRouter><GroupChat groupId="g" /></MemoryRouter>);
    await act(async () => {});
    expect(vi.mocked(chatApi.listConversationMembersPage).mock.calls.length).toBe(calls);
  });

  it("成员拉取失败不阻断聊天且不弹错误", async () => {
    vi.mocked(chatApi.listConversationMembersPage).mockRejectedValue(new Error("断网"));
    render(<MemoryRouter><GroupChat groupId="g" /></MemoryRouter>);
    await waitFor(() => expect(loadHistory).toHaveBeenCalled());
    expect(screen.queryByRole("alert")).toBeNull();
  });
});
