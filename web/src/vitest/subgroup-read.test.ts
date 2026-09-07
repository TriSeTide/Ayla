import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ChatMessage, ConversationSummary, SubGroup, UserPublic } from "../api/types";
import * as chatApi from "../api/chat";
import { markMessageReadExact, markSubgroupRead } from "../hooks/useChat";
import { useAuthStore } from "../stores/auth";
import { useChatStore } from "../stores/chat";
import { useMessageStore } from "../stores/message";
import { useSubGroupStore } from "../stores/subgroup";
import { applySubgroupReadReceipt } from "../stores/subgroupRead";

vi.mock("../api/chat", () => ({ markMessageRead: vi.fn(), markSubgroupRead: vi.fn() }));
vi.mock("../api/accounts", () => ({ getBadges: vi.fn().mockResolvedValue({ private_unread: 0, group_unread: 0 }) }));
vi.mock("../ws/chat", () => ({ chatWS: { subscribe: vi.fn() } }));

const user: UserPublic = {
  id: "me", username: "me", nickname: "我", avatar: "", signature: "", status: "online", online: true, date_joined: "",
};
const group: ConversationSummary = {
  id: "g1", type: "group", title: "群", announcement: "", avatar: "", owner_id: "me", members: [],
  my_role: "member", member_count: 2, unread_count: 5, unread_seqs: [1, 2, 3, 4, 100],
  mention_unread_seqs: [3, 100], reply_unread_seqs: [4], created_at: "", peer: null,
};
const subgroups: SubGroup[] = [
  { id: "a", name: "默认组", conversation_id: "g1", is_default: true, unread_count: 4, unread_seqs: [1, 2, 3, 4], last_message_seq: 4, created_at: "" },
  { id: "b", name: "另组", conversation_id: "g1", is_default: false, unread_count: 1, unread_seqs: [100], last_message_seq: 100, created_at: "" },
];
const message = (seq: number, subgroupId: string | null = "a"): ChatMessage => ({
  id: `m${seq}`, conversation_id: "g1", subgroup_id: subgroupId, sender_id: "peer", type: "text",
  content: "消息", media_id: null, reply_to: null, status: "sent", seq, created_at: "",
});

beforeEach(() => {
  vi.clearAllMocks();
  useAuthStore.setState({ currentUser: user });
  useSubGroupStore.getState().reset();
  useMessageStore.getState().reset();
  useChatStore.setState({ conversations: [group] });
  useSubGroupStore.getState().setSubgroups("g1", subgroups);
  for (const seq of [1, 2, 3, 4]) useMessageStore.getState().upsertMessage("g1", message(seq));
  useMessageStore.getState().upsertMessage("g1", message(100, "b"));
});

describe("群聊可见消息精确已读", () => {
  it("只移除已看到的序号，未看到的普通/@/回复和另一子群未读保留", async () => {
    vi.mocked(chatApi.markMessageRead).mockResolvedValue({ detail: "ok", marked_seqs: [2] });
    await markMessageReadExact("g1", "m2");
    expect(chatApi.markMessageRead).toHaveBeenCalledWith("g1", "m2", true);
    expect(useSubGroupStore.getState().unreadSeqsByKey["g1:a"]).toEqual([1, 3, 4]);
    expect(useSubGroupStore.getState().unreadByKey["g1:a"]).toBe(3);
    expect(useSubGroupStore.getState().unreadSeqsByKey["g1:b"]).toEqual([100]);
    expect(useChatStore.getState().conversations[0]).toMatchObject({
      unread_count: 4, unread_seqs: [1, 3, 4, 100], mention_unread_seqs: [3, 100], reply_unread_seqs: [4],
    });
    expect(useMessageStore.getState().buckets.g1.messages.filter((m) => m.read_by_me).map((m) => m.seq)).toEqual([2]);
  });

  it("精确确认失败保留未读，默认组旧 null 消息确认只消除自身", async () => {
    vi.mocked(chatApi.markMessageRead).mockRejectedValueOnce(new Error("offline"));
    await expect(markMessageReadExact("g1", "m1")).rejects.toThrow("offline");
    expect(useSubGroupStore.getState().unreadByKey["g1:a"]).toBe(4);
    useMessageStore.getState().removeMessage("g1", "m1");
    useMessageStore.getState().upsertMessage("g1", message(1, null));
    vi.mocked(chatApi.markMessageRead).mockResolvedValue({ detail: "ok", marked_seqs: [1] });
    await markMessageReadExact("g1", "m1");
    expect(useSubGroupStore.getState().unreadSeqsByKey["g1:a"]).toEqual([2, 3, 4]);
  });

  it("重复回执不多减；旧回执及迟到 REST 不清新消息，也不恢复已确认消息", () => {
    applySubgroupReadReceipt("g1", "a", [2]);
    useSubGroupStore.getState().bumpSubgroupUnread("g1", "a", 5);
    useChatStore.getState().bumpUnread("g1", { seq: 5 });
    applySubgroupReadReceipt("g1", "a", [2]);
    useSubGroupStore.getState().setSubgroups("g1", subgroups);
    useSubGroupStore.getState().bumpSubgroupUnread("g1", "a", 2);
    expect(useSubGroupStore.getState().unreadSeqsByKey["g1:a"]).toEqual([1, 3, 4, 5]);
    expect(useSubGroupStore.getState().unreadByKey["g1:a"]).toBe(4);
    expect(useChatStore.getState().conversations[0].unread_count).toBe(5);
  });

  it("确认先于列表到达仍按精确范围过滤，未确认消息保留", () => {
    useSubGroupStore.getState().reset();
    applySubgroupReadReceipt("g1", "a", [2]);
    useSubGroupStore.getState().setSubgroups("g1", subgroups);
    expect(useSubGroupStore.getState().unreadSeqsByKey["g1:a"]).toEqual([1, 3, 4]);
  });

  it("确认先到、历史后到时，legacy消息的read_by_me也保持已读而非重复确认", () => {
    useSubGroupStore.getState().reset();
    useMessageStore.getState().reset();
    applySubgroupReadReceipt("g1", "a", [2]);
    useMessageStore.getState().prependHistory("g1", [{ ...message(2, null), read_by_me: false }, message(3)], false);
    expect(useMessageStore.getState().buckets.g1.messages[0].read_by_me).toBe(true);
    expect(useMessageStore.getState().buckets.g1.messages[1].read_by_me).not.toBe(true);
  });

  it("迟到编辑响应同样保留快照之后的新消息，不恢复已读序号", () => {
    applySubgroupReadReceipt("g1", "a", [2]);
    useSubGroupStore.getState().bumpSubgroupUnread("g1", "a", 5);
    useSubGroupStore.getState().upsertSubgroup("g1", { ...subgroups[0], name: "改名" });
    expect(useSubGroupStore.getState().unreadSeqsByKey["g1:a"]).toEqual([1, 3, 4, 5]);
    expect(useSubGroupStore.getState().unreadByKey["g1:a"]).toBe(4);
  });

  it("默认组列表未加载时，用REST归属记录旧null消息确认，迟到列表不恢复", async () => {
    useSubGroupStore.getState().reset();
    useMessageStore.getState().removeMessage("g1", "m1");
    useMessageStore.getState().upsertMessage("g1", message(1, null));
    vi.mocked(chatApi.markMessageRead).mockResolvedValue({ detail: "ok", marked_seqs: [1], subgroup_id: "a" });
    await markMessageReadExact("g1", "m1");
    useSubGroupStore.getState().setSubgroups("g1", subgroups);
    expect(useSubGroupStore.getState().unreadSeqsByKey["g1:a"]).toEqual([2, 3, 4]);
  });

  it("显式整组动作仅应用响应快照，执行期间到达的新消息不被清空", async () => {
    let complete!: (value: { marked: number; marked_seqs: number[] }) => void;
    vi.mocked(chatApi.markSubgroupRead).mockReturnValue(new Promise((resolve) => { complete = resolve; }));
    const pending = markSubgroupRead("g1", "a");
    useSubGroupStore.getState().bumpSubgroupUnread("g1", "a", 5);
    useChatStore.getState().bumpUnread("g1", { seq: 5 });
    complete({ marked: 4, marked_seqs: [1, 2, 3, 4] });
    await pending;
    expect(useSubGroupStore.getState().unreadSeqsByKey["g1:a"]).toEqual([5]);
    expect(useChatStore.getState().conversations[0].unread_seqs).toEqual([5, 100]);
  });

  it("旧整组响应缺失确认范围时不猜测清零", async () => {
    vi.mocked(chatApi.markSubgroupRead).mockResolvedValue({ marked: 4 });
    await markSubgroupRead("g1", "a");
    expect(useSubGroupStore.getState().unreadByKey["g1:a"]).toBe(4);
  });

  it("退出和切换账号清理确认集，旧账号待响应不能消除新账号未读", async () => {
    applySubgroupReadReceipt("g1", "a", [1]);
    let complete!: (value: { detail: string; marked_seqs: number[] }) => void;
    vi.mocked(chatApi.markMessageRead).mockReturnValue(new Promise((resolve) => { complete = resolve; }));
    const pending = markMessageReadExact("g1", "m2");
    useAuthStore.getState().logout();
    expect(useSubGroupStore.getState().confirmedReadSeqsByKey).toEqual({});
    useAuthStore.getState().setUser({ ...user, id: "new-user" });
    useSubGroupStore.getState().setSubgroups("g1", subgroups);
    complete({ detail: "ok", marked_seqs: [2] });
    await pending;
    expect(useSubGroupStore.getState().unreadSeqsByKey["g1:a"]).toEqual([1, 2, 3, 4]);
    applySubgroupReadReceipt("g1", "a", [1]);
    useAuthStore.getState().setUser(user);
    expect(useSubGroupStore.getState().confirmedReadSeqsByKey).toEqual({});
  });
});
