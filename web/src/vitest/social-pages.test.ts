import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as chatApi from "../api/chat";
import * as usersApi from "../api/users";
import type { ConversationSummary, SubGroup, UserPublic } from "../api/types";
import { useAuthStore } from "../stores/auth";
import { useChatStore } from "../stores/chat";
import { useSubGroupStore } from "../stores/subgroup";
import { disposeSocialTracking, loadSocial, socialKey, updateSocialItems, useSocialStore } from "../stores/social";

vi.mock("../api/chat", () => ({
  listConversationsPage: vi.fn(), listConversationMembersPage: vi.fn(),
  listSubgroupsPage: vi.fn(), listMyInvitesPage: vi.fn(),
  listManagedJoinRequestsPage: vi.fn(), listJoinRequestsPage: vi.fn(), listLeaveNoticesPage: vi.fn(),
}));
vi.mock("../api/users", () => ({
  searchUsersPage: vi.fn(), listFriendsPage: vi.fn(), listFriendRequestsPage: vi.fn(),
}));
const user = (id: string): UserPublic => ({ id, username: id, nickname: id, avatar: "", signature: "", status: "auto", online: false, date_joined: "" });
const row = (id: string): ConversationSummary => ({ id, type: "group", title: id, owner_id: "me", announcement: "", avatar: "",
  members: [], my_role: "member", member_count: 1000, unread_count: 0, created_at: "", peer: null, members_complete: false, unread_seqs_complete: false });
const page = <T>(results: T[], total = results.length, next: string | null = null) => ({ results, total, has_more: next !== null, next_cursor: next });
const record = (options = { type: "group" as const }) => useSocialStore.getState().records[socialKey("conversations", options)];
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>((done) => { resolve = done; }); return { promise, resolve }; }

beforeEach(() => {
  disposeSocialTracking(); useChatStore.getState().reset(); useSubGroupStore.getState().reset(); vi.clearAllMocks();
  useAuthStore.setState({ currentUser: user("me"), accessToken: "test" });
});
afterEach(() => { disposeSocialTracking(); useAuthStore.setState({ currentUser: null, accessToken: null }); });

describe("bounded social pages", () => {
  it("loads only one requested page, coalesces concurrent requests and deduplicates overlapping continuation rows", async () => {
    vi.mocked(chatApi.listConversationsPage).mockResolvedValueOnce(page([row("1"), row("2")], 5, "next"))
      .mockResolvedValueOnce(page([row("2"), row("3")], 5, "last"));
    const first = loadSocial("conversations", { type: "group" });
    expect(loadSocial("conversations", { type: "group" })).toBe(first);
    await first;
    expect(chatApi.listConversationsPage).toHaveBeenCalledTimes(1);
    expect(record().total).toBe(5); expect(record().items).toHaveLength(2);
    await loadSocial("conversations", { type: "group" }, "more");
    expect(chatApi.listConversationsPage).toHaveBeenLastCalledWith({ limit: 30, cursor: "next", q: undefined, type: "group" });
    expect(record().items.map((item) => (item as ConversationSummary).id)).toEqual(["1", "2", "3"]);
    expect(record().hasMore).toBe(true);
  });

  it("failed continuation preserves data and retries the same cursor", async () => {
    vi.mocked(chatApi.listConversationsPage).mockResolvedValueOnce(page([row("1")], 2, "retry"))
      .mockRejectedValueOnce(new Error("翻页断网")).mockResolvedValueOnce(page([row("2")], 2));
    await loadSocial("conversations", { type: "group" });
    await loadSocial("conversations", { type: "group" }, "more");
    expect(record().items).toHaveLength(1); expect(record().error).toBe("翻页断网"); expect(record().nextCursor).toBe("retry");
    await loadSocial("conversations", { type: "group" }, "more");
    expect(chatApi.listConversationsPage).toHaveBeenLastCalledWith(expect.objectContaining({ cursor: "retry" }));
    expect(record().items).toHaveLength(2); expect(record().error).toBeNull(); expect(record().hasMore).toBe(false);
  });

  it("a first-page failure remains an error, never a successful empty collection", async () => {
    vi.mocked(usersApi.listFriendsPage).mockRejectedValueOnce(new Error("好友不可用"));
    await loadSocial("friends");
    const value = useSocialStore.getState().records[socialKey("friends")];
    expect(value.error).toBe("好友不可用"); expect(value.fetchedAt).toBeNull(); expect(value.loading).toBe(false);
  });

  it("isolates query results and never inserts a late result into another query", async () => {
    const old = deferred<ReturnType<typeof page<UserPublic>>>();
    vi.mocked(usersApi.searchUsersPage).mockReturnValueOnce(old.promise).mockResolvedValueOnce(page([user("new")]));
    const a = loadSocial("users", { q: "old" });
    await loadSocial("users", { q: "new" }); old.resolve(page([user("old")])); await a;
    expect(useSocialStore.getState().records[socialKey("users", { q: "new" })].items).toEqual([user("new")]);
    expect(usersApi.searchUsersPage).toHaveBeenNthCalledWith(2, "new", expect.objectContaining({ cursor: null, q: "new" }));
  });

  it("logout/account change rejects pending rows and does not populate the descriptor cache", async () => {
    const pending = deferred<ReturnType<typeof page<ConversationSummary>>>();
    vi.mocked(chatApi.listConversationsPage).mockReturnValueOnce(pending.promise);
    const work = loadSocial("conversations", { type: "group" }); await Promise.resolve();
    useAuthStore.setState({ currentUser: user("other"), accessToken: "next" });
    pending.resolve(page([row("private-to-me")])); await work;
    expect(useSocialStore.getState().records).toEqual({}); expect(useChatStore.getState().conversations).toEqual([]);
  });

  it("a removed row stays removed when an overlapping older page settles", async () => {
    vi.mocked(chatApi.listConversationsPage).mockResolvedValueOnce(page([row("1")], 2, "next"));
    await loadSocial("conversations", { type: "group" });
    const pending = deferred<ReturnType<typeof page<ConversationSummary>>>();
    vi.mocked(chatApi.listConversationsPage).mockReturnValueOnce(pending.promise);
    const work = loadSocial("conversations", { type: "group" }, "more");
    useChatStore.getState().removeConversation("1");
    pending.resolve(page([row("1"), row("2")], 2)); await work;
    expect(record().items.map((item) => (item as ConversationSummary).id)).toEqual(["2"]);
    expect(useChatStore.getState().conversations.map((item) => item.id)).toEqual(["2"]);
  });

  it("in-flight approval removal remains removed and totals reflect the remaining requests", async () => {
    const request = { id: 7 } as import("../api/types").GroupJoinRequest;
    vi.mocked(chatApi.listManagedJoinRequestsPage).mockResolvedValueOnce(page([request], 2, "pending"));
    await loadSocial("joinRequests");
    const pending = deferred<ReturnType<typeof page<typeof request>>>();
    vi.mocked(chatApi.listManagedJoinRequestsPage).mockReturnValueOnce(pending.promise);
    const work = loadSocial("joinRequests", {}, "more");
    updateSocialItems("joinRequests", {}, []);
    pending.resolve(page([request, { ...request, id: 8 }], 2)); await work;
    const value = useSocialStore.getState().records[socialKey("joinRequests")];
    expect(value.items.map((item) => (item as typeof request).id)).toEqual([8]); expect(value.total).toBe(1);
  });

  it("a later refresh wins over a prior page without losing mutation data", async () => {
    const old = deferred<ReturnType<typeof page<ConversationSummary>>>();
    vi.mocked(chatApi.listConversationsPage).mockReturnValueOnce(old.promise).mockResolvedValueOnce(page([row("fresh")]));
    const work = loadSocial("conversations", { type: "group" }); await Promise.resolve();
    await loadSocial("conversations", { type: "group" }, "refresh"); old.resolve(page([row("stale")])); await work;
    expect(record().items.map((item) => (item as ConversationSummary).id)).toEqual(["fresh"]);
  });

  it("keeps live descriptor edits when an older page returns", async () => {
    vi.mocked(chatApi.listConversationsPage).mockResolvedValueOnce(page([row("1")], 2, "next"));
    await loadSocial("conversations", { type: "group" });
    const pending = deferred<ReturnType<typeof page<ConversationSummary>>>();
    vi.mocked(chatApi.listConversationsPage).mockReturnValueOnce(pending.promise);
    const work = loadSocial("conversations", { type: "group" }, "more");
    useChatStore.getState().upsertConversation({ ...row("1"), title: "最新群名" });
    pending.resolve(page([row("1"), row("2")], 2)); await work;
    expect((record().items[0] as ConversationSummary).title).toBe("最新群名");
  });

  it("default subgroup is supplied independently when it is outside the current page", async () => {
    const subgroup = (id: string, is_default = false): SubGroup => ({ id, conversation_id: "g", name: id, is_default, unread_count: 0, created_at: "" });
    vi.mocked(chatApi.listSubgroupsPage).mockResolvedValueOnce({ ...page([subgroup("20")], 100, "next"), default: subgroup("1", true) });
    await loadSocial("subgroups", { groupId: "g" });
    const value = useSocialStore.getState().records[socialKey("subgroups", { groupId: "g" })];
    expect(value.items.map((item) => (item as SubGroup).id)).toEqual(["1", "20"]); expect(value.total).toBe(100);
  });

  it("rejects a repeated continuation cursor instead of looping forever", async () => {
    vi.mocked(chatApi.listConversationsPage).mockResolvedValueOnce(page([row("1")], 3, "same"))
      .mockResolvedValueOnce(page([row("2")], 3, "same"));
    await loadSocial("conversations", { type: "group" }); await loadSocial("conversations", { type: "group" }, "more");
    expect(record().error).toMatch(/分页响应无效/); expect(record().items).toHaveLength(1);
  });
});
