import { beforeEach, describe, expect, it } from "vitest";
import { useChatDraftsStore } from "../stores/chatDrafts";

describe("ChatDraftsStore", () => {
  beforeEach(() => useChatDraftsStore.getState().reset());

  it("按会话保存草稿并可互相隔离", () => {
    useChatDraftsStore.getState().setDraft("c1", "给一号会话");
    useChatDraftsStore.getState().setDraft("c2", "给二号会话");
    expect(useChatDraftsStore.getState().getDraft("c1")).toBe("给一号会话");
    expect(useChatDraftsStore.getState().getDraft("c2")).toBe("给二号会话");
  });

  it("发送成功后可以清除指定会话草稿", () => {
    useChatDraftsStore.getState().setDraft("c1", "待发送");
    useChatDraftsStore.getState().setDraft("c2", "保留");
    useChatDraftsStore.getState().clearDraft("c1");
    expect(useChatDraftsStore.getState().getDraft("c1")).toBe("");
    expect(useChatDraftsStore.getState().getDraft("c2")).toBe("保留");
  });
});
