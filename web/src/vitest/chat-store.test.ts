/**
 * stores/chat.ts 测试：
 * - 会话列表 set/upsert
 * - 未读计数：bumpUnread / clearUnread / openConversation 自动清未读
 * - 当前会话 activeConversationId
 */
import { beforeEach, describe, expect, it } from "vitest";
import type { ConversationSummary } from "../api/types";
import { useChatStore } from "../stores/chat";

function conv(id: string, unread = 0): ConversationSummary {
  return {
    id,
    type: "private",
    title: `会话${id}`,
    announcement: "",
    avatar: "",
    owner_id: "o",
    members: [],
    my_role: "member",
    member_count: 2,
    unread_count: unread,
    is_pinned: false,
    last_message: null,
    created_at: new Date().toISOString(),
    peer: null,
  };
}

beforeEach(() => {
  useChatStore.getState().reset();
});

describe("chat store", () => {
  it("setConversations 填充列表并清 loading/error", () => {
    const s = useChatStore.getState();
    s.setLoading(true);
    s.setError("err");
    s.setConversations([conv("1"), conv("2")]);
    const st = useChatStore.getState();
    expect(st.conversations).toHaveLength(2);
    expect(st.loading).toBe(false);
    expect(st.error).toBeNull();
  });

  it("upsertConversation：新会话置顶，已有会话原地更新", () => {
    const s = useChatStore.getState();
    s.setConversations([conv("1")]);
    s.upsertConversation(conv("2"));
    expect(useChatStore.getState().conversations.map((c) => c.id)).toEqual(["2", "1"]);
    s.upsertConversation({ ...conv("1"), title: "改名" });
    const st = useChatStore.getState();
    expect(st.conversations).toHaveLength(2);
    expect(st.conversations.find((c) => c.id === "1")?.title).toBe("改名");
  });

  it("bumpUnread：未打开会话 +1；打开会话不加", () => {
    const s = useChatStore.getState();
    s.setConversations([conv("1"), conv("2")]);
    s.openConversation("1");
    s.bumpUnread("2"); // 未打开 → +1
    s.bumpUnread("1"); // 打开 → 不加
    const st = useChatStore.getState();
    expect(st.conversations.find((c) => c.id === "2")?.unread_count).toBe(1);
    expect(st.conversations.find((c) => c.id === "1")?.unread_count).toBe(0);
  });

  it("openConversation 只记录 activeId，不提前清除未读", () => {
    const s = useChatStore.getState();
    s.setConversations([conv("1", 5), conv("2", 3)]);
    s.openConversation("1");
    const st = useChatStore.getState();
    expect(st.activeConversationId).toBe("1");
    expect(st.conversations.find((c) => c.id === "1")?.unread_count).toBe(5);
    expect(st.conversations.find((c) => c.id === "2")?.unread_count).toBe(3);
  });

  it("clearUnread 只清指定会话", () => {
    const s = useChatStore.getState();
    s.setConversations([conv("1", 2), conv("2", 4)]);
    s.clearUnread("2");
    const st = useChatStore.getState();
    expect(st.conversations.find((c) => c.id === "1")?.unread_count).toBe(2);
    expect(st.conversations.find((c) => c.id === "2")?.unread_count).toBe(0);
  });

  it("closeConversation 清空 activeId", () => {
    const s = useChatStore.getState();
    s.setConversations([conv("1")]);
    s.openConversation("1");
    s.closeConversation();
    expect(useChatStore.getState().activeConversationId).toBeNull();
  });

  it("setPin：置顶会话排到列表最前，取消后留在非置顶组首位", () => {
    const s = useChatStore.getState();
    s.setConversations([conv("1"), conv("2"), conv("3")]);
    // 置顶中间的会话 2
    s.setPin("2", true);
    let ids = useChatStore.getState().conversations.map((c) => c.id);
    expect(ids).toEqual(["2", "1", "3"]);
    expect(useChatStore.getState().conversations[0].is_pinned).toBe(true);
    // 再置顶 3 → 置顶组保持相对顺序（2 在前，3 在后）
    s.setPin("3", true);
    ids = useChatStore.getState().conversations.map((c) => c.id);
    expect(ids).toEqual(["2", "3", "1"]);
    // 取消 2 置顶 → 3 仍置顶在首位，2 进入非置顶组（保持当前相对顺序）
    s.setPin("2", false);
    ids = useChatStore.getState().conversations.map((c) => c.id);
    expect(ids).toEqual(["3", "2", "1"]);
  });

  it("setConversations 置顶优先排序", () => {
    const s = useChatStore.getState();
    const c1 = conv("1");
    const c2 = { ...conv("2"), is_pinned: true };
    const c3 = conv("3");
    s.setConversations([c1, c2, c3]);
    const ids = useChatStore.getState().conversations.map((c) => c.id);
    expect(ids).toEqual(["2", "1", "3"]);
  });

  it("setLastMessage 更新会话预览", () => {
    const s = useChatStore.getState();
    s.setConversations([conv("1")]);
    s.setLastMessage("1", {
      seq: 5,
      type: "text",
      content: "最新一条",
      sender_id: "u2",
      sender_name: "小樱",
      status: "sent",
      created_at: "2026-08-21T00:00:00Z",
    });
    const st = useChatStore.getState();
    expect(st.conversations[0].last_message?.content).toBe("最新一条");
    expect(st.conversations[0].last_message?.sender_name).toBe("小樱");
  });

  it("removeConversation 移除会话并清空当前选中", () => {
    const s = useChatStore.getState();
    s.setConversations([conv("1"), conv("2")]);
    s.openConversation("1");
    s.removeConversation("1");
    const st = useChatStore.getState();
    expect(st.conversations.map((c) => c.id)).toEqual(["2"]);
    expect(st.activeConversationId).toBeNull();
  });
});
