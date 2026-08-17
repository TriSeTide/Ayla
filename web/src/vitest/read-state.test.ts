import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ConversationSummary } from "../api/types";
import { useAuthStore } from "../stores/auth";
import { useChatStore } from "../stores/chat";
import { useMessageStore } from "../stores/message";
import * as chatApi from "../api/chat";
import { markReadLatest } from "../hooks/useChat";

const conversation: ConversationSummary = {
  id: "c1", type: "private", title: "会话", announcement: "", avatar: "", owner_id: "u1", members: [],
  my_role: "member", member_count: 2, unread_count: 2, created_at: new Date().toISOString(), peer: null,
};

describe("已读确认状态", () => {
  beforeEach(() => {
    useAuthStore.setState({ currentUser: { id: "u1", username: "u", nickname: "u", avatar: "", signature: "", status: "online", online: true, date_joined: "" } });
    useChatStore.setState({ conversations: [conversation], activeConversationId: null, loading: false, error: null });
    useMessageStore.getState().reset();
    useMessageStore.getState().upsertMessage("c1", { id: "m1", conversation_id: "c1", sender_id: "u2", type: "text", content: "hi", media_id: null, reply_to: null, status: "sent", seq: 1, created_at: new Date().toISOString() });
  });

  it("确认成功才清红点", async () => {
    vi.spyOn(chatApi, "markMessageRead").mockResolvedValue({ detail: "ok" });
    await markReadLatest("c1");
    expect(useChatStore.getState().conversations[0].unread_count).toBe(0);
  });

  it("确认失败保留红点", async () => {
    vi.spyOn(chatApi, "markMessageRead").mockRejectedValue(new Error("offline"));
    await markReadLatest("c1");
    expect(useChatStore.getState().conversations[0].unread_count).toBe(2);
  });
});
