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
    owner_id: "o",
    members: [],
    my_role: "member",
    member_count: 2,
    unread_count: unread,
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

  it("openConversation 清当前会话未读并记录 activeId", () => {
    const s = useChatStore.getState();
    s.setConversations([conv("1", 5), conv("2", 3)]);
    s.openConversation("1");
    const st = useChatStore.getState();
    expect(st.activeConversationId).toBe("1");
    expect(st.conversations.find((c) => c.id === "1")?.unread_count).toBe(0);
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
});
