import { create } from "zustand";
import * as chatApi from "../api/chat";
import * as usersApi from "../api/users";
import type { SocialPage } from "../api/social";
import type { ConversationMember, ConversationSummary, FriendRequest, Friendship,
  GroupInvite, GroupJoinRequest, GroupMemberLeaveNotice, SubGroup, UserPublic } from "../api/types";
import { useAuthStore } from "./auth";
import { useChatStore } from "./chat";
import { useSubGroupStore } from "./subgroup";

export interface SocialItems {
  conversations: ConversationSummary;
  members: ConversationMember;
  subgroups: SubGroup;
  users: UserPublic;
  friends: Friendship;
  friendRequests: FriendRequest;
  invites: GroupInvite;
  joinRequests: GroupJoinRequest;
  leaveNotices: GroupMemberLeaveNotice;
}
export type SocialKind = keyof SocialItems;
type Item = SocialItems[SocialKind];
export interface SocialOptions { groupId?: string; q?: string; type?: "all" | "group" | "private"; excludeSelf?: boolean }
export interface SocialRecord {
  kind: SocialKind;
  options: SocialOptions;
  items: Item[];
  total: number;
  nextCursor: string | null;
  hasMore: boolean;
  loading: boolean;
  error: string | null;
  fetchedAt: number | null;
  revision: number;
  mutationRevision: number;
}
const pending = new Map<string, { promise: Promise<void>; revision: number; deleted: Set<string> }>();
let attempt = 0;
let merging = false;
let tracking = false;
const unsubscribers: Array<() => void> = [];

export const useSocialStore = create<{ records: Record<string, SocialRecord>; reset: () => void }>((set) => ({
  records: {}, reset: () => { attempt += 1; pending.clear(); set({ records: {} }); },
}));

export function socialKey(kind: SocialKind, options: SocialOptions = {}) {
  return JSON.stringify([useAuthStore.getState().currentUser?.id ?? null, kind, options.groupId ?? null,
    options.q?.trim() ?? "", options.type ?? "all", !!options.excludeSelf]);
}
function itemId(item: Item): string {
  return "id" in item ? String(item.id) : String((item as Friendship).user.id);
}
function patch(key: string, record: SocialRecord) {
  useSocialStore.setState((state) => ({ records: { ...state.records, [key]: record } }));
}
function empty(kind: SocialKind, options: SocialOptions): SocialRecord {
  return { kind, options, items: [], total: 0, nextCursor: null, hasMore: false,
    loading: false, error: null, fetchedAt: null, revision: 0, mutationRevision: 0 };
}
function matches(record: SocialRecord, item: Item) {
  if (record.kind === "conversations") {
    const conversation = item as ConversationSummary;
    const query = record.options.q?.trim().toLocaleLowerCase();
    return (!record.options.type || record.options.type === "all" || conversation.type === record.options.type)
      && (!query || [conversation.title, conversation.peer?.nickname, conversation.peer?.username]
        .some((value) => value?.toLocaleLowerCase().includes(query)));
  }
  return record.kind !== "subgroups" || (item as SubGroup).conversation_id === record.options.groupId;
}

/** Explicit local actions retain tombstones until any overlapping page settles. */
export function updateSocialItems<K extends SocialKind>(kind: K, options: SocialOptions,
  update: SocialItems[K][] | ((items: SocialItems[K][]) => SocialItems[K][])) {
  const key = socialKey(kind, options);
  const previous = useSocialStore.getState().records[key] ?? empty(kind, options);
  const items = typeof update === "function" ? update(previous.items as SocialItems[K][]) : update;
  const retained = new Set(items.map(itemId));
  const deleted = previous.items.filter((item) => !retained.has(itemId(item))).map(itemId);
  for (const id of deleted) pending.get(key)?.deleted.add(id);
  patch(key, { ...previous, items, total: Math.max(0, previous.total + items.length - previous.items.length),
    mutationRevision: previous.mutationRevision + 1 });
}

/** Descriptor updates reconcile loaded projections without declaring a cache complete. */
function reconcileCached(kind: "conversations" | "subgroups", next: Item[], old: Item[]) {
  if (merging) return;
  const before = new Map(old.map((item) => [itemId(item), item]));
  const after = new Map(next.map((item) => [itemId(item), item]));
  for (const [key, record] of Object.entries(useSocialStore.getState().records)) {
    if (record.kind !== kind) continue;
    const removed = old.filter((item) => !after.has(itemId(item)) && matches(record, item));
    for (const item of removed) pending.get(key)?.deleted.add(itemId(item));
    const removedIds = new Set(removed.map(itemId));
    const items = record.items.filter((item) => !removedIds.has(itemId(item)))
      .map((item) => after.get(itemId(item)) ?? item).filter((item) => matches(record, item));
    const ids = new Set(items.map(itemId));
    const added = next.filter((item) => !before.has(itemId(item)) && !ids.has(itemId(item)) && matches(record, item));
    const changed = added.length > 0 || items.length !== record.items.length
      || items.some((item, index) => item !== record.items[index]);
    if (!changed) continue;
    patch(key, { ...record, items: [...added, ...items],
      total: Math.max(0, record.total + added.length - removed.length), mutationRevision: record.mutationRevision + 1 });
  }
}

export function ensureSocialTracking() {
  if (tracking) return;
  tracking = true;
  unsubscribers.push(useAuthStore.subscribe((next, old) => {
    if (next.currentUser?.id !== old.currentUser?.id || (!next.accessToken && old.accessToken)) useSocialStore.getState().reset();
  }));
  unsubscribers.push(useChatStore.subscribe((next, old) => {
    if (next.conversations !== old.conversations) reconcileCached("conversations", next.conversations, old.conversations);
  }));
  unsubscribers.push(useSubGroupStore.subscribe((next, old) => {
    if (next.byGroup !== old.byGroup) reconcileCached("subgroups", Object.values(next.byGroup).flat(), Object.values(old.byGroup).flat());
  }));
}
export function disposeSocialTracking() {
  for (const unsubscribe of unsubscribers.splice(0)) unsubscribe();
  tracking = false;
  useSocialStore.getState().reset();
}
if (import.meta.hot) import.meta.hot.dispose(disposeSocialTracking);

function requestPage(kind: SocialKind, options: SocialOptions, cursor: string | null): Promise<SocialPage<Item>> {
  const params = { limit: 30, cursor, q: options.q?.trim() };
  switch (kind) {
    case "conversations": return chatApi.listConversationsPage({ ...params, type: options.type });
    case "members": return chatApi.listConversationMembersPage(options.groupId!, { ...params, exclude_self: options.excludeSelf ? "1" : "0" });
    case "subgroups": return chatApi.listSubgroupsPage(options.groupId!, params);
    case "users": return usersApi.searchUsersPage(options.q ?? "", params);
    case "friends": return usersApi.listFriendsPage(params);
    case "friendRequests": return usersApi.listFriendRequestsPage({ ...params, direction: "received", status: "pending" });
    case "invites": return chatApi.listMyInvitesPage(params);
    case "joinRequests": return options.groupId ? chatApi.listJoinRequestsPage(options.groupId, params) : chatApi.listManagedJoinRequestsPage(params);
    case "leaveNotices": return chatApi.listLeaveNoticesPage(params);
  }
}

/** One visible page per request; only an explicit next-page action continues. */
export function loadSocial(kind: SocialKind, options: SocialOptions = {}, mode: "initial" | "refresh" | "more" = "initial"): Promise<void> {
  ensureSocialTracking();
  const key = socialKey(kind, options);
  const previous = useSocialStore.getState().records[key] ?? empty(kind, options);
  if (!useAuthStore.getState().currentUser?.id) return Promise.resolve();
  if (mode !== "refresh" && pending.has(key)) return pending.get(key)!.promise;
  if (mode === "initial" && previous.fetchedAt != null && Date.now() - previous.fetchedAt < 60_000) return Promise.resolve();
  if (mode === "more" && (!previous.hasMore || !previous.nextCursor)) return Promise.resolve();
  const revision = ++attempt;
  const deleted = new Set<string>();
  const atStart = new Map(previous.items.map((item) => [itemId(item), item]));
  const cursor = mode === "more" ? previous.nextCursor : null;
  patch(key, { ...previous, loading: true, error: null, revision });
  const promise = Promise.resolve().then(() => requestPage(kind, options, cursor)).then((page) => {
    const current = useSocialStore.getState().records[key];
    if (!current || current.revision !== revision || socialKey(kind, options) !== key) return;
    if (!Array.isArray(page.results) || !Number.isFinite(page.total)
        || (page.has_more && (!page.next_cursor || page.next_cursor === cursor))) throw new Error("列表分页响应无效，请重试");
    const latest = new Map(current.items.map((item) => [itemId(item), item]));
    const results = page.results.filter((item) => !deleted.has(itemId(item))).map((item) => {
      const fresh = latest.get(itemId(item));
      return fresh && fresh !== atStart.get(itemId(item)) ? fresh : item;
    });
    const items = new Map((mode === "more" ? current.items : current.items.filter((item) => !atStart.has(itemId(item))))
      .map((item) => [itemId(item), item]));
    for (const item of results) items.set(itemId(item), item);
    merging = true;
    try {
      if (kind === "conversations") for (const item of results) useChatStore.getState().upsertConversation(item as ConversationSummary);
      if (kind === "subgroups") {
        const defaultGroup = (page as SocialPage<SubGroup> & { default?: SubGroup | null }).default;
        if (defaultGroup && !deleted.has(defaultGroup.id)) {
          useSubGroupStore.getState().upsertSubgroup(options.groupId!, defaultGroup);
          items.set(defaultGroup.id, defaultGroup);
        }
        for (const item of results) useSubGroupStore.getState().upsertSubgroup(options.groupId!, item as SubGroup);
      }
    } finally { merging = false; }
    const effectiveItems = kind === "subgroups" ? [...items.values()].sort((a, b) =>
      Number((b as SubGroup).is_default) - Number((a as SubGroup).is_default)
      || ((b as SubGroup).last_message_seq ?? 0) - ((a as SubGroup).last_message_seq ?? 0)) : [...items.values()];
    patch(key, { ...current, items: effectiveItems, total: current.mutationRevision !== previous.mutationRevision && previous.fetchedAt != null
      ? current.total : Math.max(0, page.total - deleted.size), nextCursor: page.next_cursor, hasMore: page.has_more,
      loading: false, error: null, fetchedAt: Date.now() });
  }).catch((error: unknown) => {
    const current = useSocialStore.getState().records[key];
    if (current?.revision === revision && socialKey(kind, options) === key) patch(key, { ...current, loading: false,
      error: error instanceof Error ? error.message : "加载列表失败" });
  }).finally(() => { if (pending.get(key)?.revision === revision) pending.delete(key); });
  pending.set(key, { promise, revision, deleted });
  return promise;
}
