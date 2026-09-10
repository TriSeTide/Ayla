import { create } from "zustand";
import { listLiveChannelsPage } from "../api/live";
import { listVoiceChannelsPage } from "../api/voice";
import { listGameRoomsPage } from "../api/boardgame";
import type { DirectoryPage } from "../api/directory";
import type { GameRoom, LiveChannelDescriptor, VoiceChannelDescriptor } from "../api/types";
import { useAuthStore } from "./auth";
import { useLiveStore } from "./live";
import { useVoiceStore } from "./voice";
import { useBoardgameStore } from "./boardgame";
import { chatWS } from "../ws/chat";
import { sortLiveChannels, sortVoiceChannels } from "../utils/sortChannels";

export interface DirectoryItems {
  live: LiveChannelDescriptor;
  voice: VoiceChannelDescriptor;
  game: GameRoom;
}
export type DirectoryKind = keyof DirectoryItems;
type Item = DirectoryItems[DirectoryKind];
export interface DirectoryOptions {
  groupId?: string;
  onlyLive?: boolean;
  /** 分类选项卡（voice-hub/live-hub/games-hub 大厅）：每个 tab 独立 key/游标/加载 */
  filter?: string;
  /** 分类选项卡：public/friends/group（后端过滤，不依赖「全部」分页进度） */
  visibility?: "public" | "friends" | "group";
  /** 分类选项卡：只看我的好友发布的内容（作者是好友，后端过滤） */
  friends?: boolean;
  /** 分类选项卡：语音「有人」（member_count>0，后端过滤） */
  occupied?: boolean;
  /** 分类选项卡：直播/桌游状态（live/idle/ended/offline、waiting/playing/ended，后端过滤） */
  status?: string;
  /** 直播/桌游/语音「我的」tab：后端 owner 过滤（owner_id=当前用户） */
  owner?: string;
  /** 桌游「我在局」过滤（保留给后端契约） */
  mine?: boolean;
}
export interface DirectoryRecord {
  kind: DirectoryKind;
  groupId?: string;
  onlyLive?: boolean;
  items: Item[];
  nextCursor: string | null;
  hasMore: boolean;
  total: number;
  totalMemberCount: number | null;
  loading: boolean;
  error: string | null;
  fetchedAt: number | null;
  invalidated: boolean;
  revision: number;
  mutationRevision: number;
}

const emptyRecord = (kind: DirectoryKind): DirectoryRecord => ({
  kind, items: [], nextCursor: null, hasMore: false, total: 0, totalMemberCount: null,
  loading: false, error: null, fetchedAt: null, invalidated: false, revision: 0, mutationRevision: 0,
});
const pending = new Map<string, Promise<void>>();
const requestDeletions = new Map<number, { kind: DirectoryKind; ids: Set<string> }>();
let attempt = 0;
let mergingPage = false;
// Short-lived hints wait for the existing permission-checked REST reconciliation.
// Failed/inaccessible creations cannot retain unbounded or cross-account state.
const createdIds: Record<DirectoryKind, Map<string, number>> = { live: new Map(), voice: new Map(), game: new Map() };
const recentlyRemoved: Record<DirectoryKind, Map<string, Item>> = { live: new Map(), voice: new Map(), game: new Map() };
function clearMutationHints() {
  for (const kind of ["live", "voice", "game"] as const) {
    createdIds[kind].clear();
    recentlyRemoved[kind].clear();
  }
}

function pruneCreationHints(kind: DirectoryKind) {
  const now = Date.now();
  for (const [id, expiresAt] of createdIds[kind]) if (expiresAt <= now) createdIds[kind].delete(id);
}

/** Query-specific page projections. A page never claims the descriptor cache is complete. */
export const useDirectoryStore = create<{
  records: Record<string, DirectoryRecord>;
  reset: () => void;
}>((set) => ({ records: {}, reset: () => { pending.clear(); requestDeletions.clear(); clearMutationHints(); attempt += 1; set({ records: {} }); } }));

export function directoryKey(kind: DirectoryKind, options: DirectoryOptions = {}) {
  return JSON.stringify([useAuthStore.getState().currentUser?.id ?? null, kind, options.groupId ?? null,
    !!options.onlyLive, options.filter ?? null, options.visibility ?? null, !!options.friends,
    !!options.occupied, options.status ?? null, options.owner ?? null, !!options.mine]);
}

function patch(key: string, record: DirectoryRecord) {
  useDirectoryStore.setState((state) => ({ records: { ...state.records, [key]: record } }));
}

function sortIdentity(kind: DirectoryKind, item: Item): string {
  if (kind === "live") {
    const channel = item as LiveChannelDescriptor;
    return JSON.stringify([channel.status, channel.started_at, channel.ended_at]);
  }
  if (kind === "voice") {
    const channel = item as VoiceChannelDescriptor;
    return JSON.stringify([channel.member_count > 0, channel.last_occupied_at, channel.last_vacant_at]);
  }
  return item.created_at;
}

function matchesQuery(record: DirectoryRecord, item: Item): boolean {
  return (!record.groupId || (item.allowed_group_ids ?? []).some((id) => String(id) === record.groupId))
    && (!record.onlyLive || (item as LiveChannelDescriptor).status === "live");
}

function sortItems(kind: DirectoryKind, items: Item[]): Item[] {
  if (kind === "live") return sortLiveChannels(items as LiveChannelDescriptor[]);
  if (kind === "voice") return sortVoiceChannels(items as VoiceChannelDescriptor[]);
  return [...items].sort((a, b) => b.created_at.localeCompare(a.created_at) || Number(b.id) - Number(a.id));
}

function cachedItems(kind: DirectoryKind): Item[] {
  return kind === "live" ? useLiveStore.getState().channels
    : kind === "voice" ? useVoiceStore.getState().channels : useBoardgameStore.getState().rooms;
}

function updateCachedItems(kind: DirectoryKind, next: Item[], previous: Item[]) {
  pruneCreationHints(kind);
  const before = new Map(previous.map((item) => [String(item.id), item]));
  const after = new Map(next.map((item) => [String(item.id), item]));
  recentlyRemoved[kind] = new Map([...before].filter(([id]) => !after.has(id)));
  useDirectoryStore.setState((state) => ({ records: Object.fromEntries(
    Object.entries(state.records).map(([key, record]) => {
      if (record.kind !== kind) return [key, record];
      const changed = record.items.some((item) => {
        const old = before.get(String(item.id));
        const current = after.get(String(item.id));
        return old != null && current != null && sortIdentity(kind, old) !== sortIdentity(kind, current);
      });
      const updated = record.items.map((item) => after.get(String(item.id)) ?? item);
      let items = updated.filter((item) => matchesQuery(record, item));
      const removed = record.items.filter((item) => !items.some((current) => String(current.id) === String(item.id)));
      // Created hints carry incomplete ACL data. Only the existing REST reconciliation's
      // authorized descriptor can establish which group/filter queries gained a member.
      const added = mergingPage ? [] : next.filter((item) => {
        const id = String(item.id);
        const old = before.get(id);
        return !record.items.some((current) => String(current.id) === id) && matchesQuery(record, item)
          && (createdIds[kind].has(id) || (old != null && !matchesQuery(record, old)));
      });
      const membershipChanged = !mergingPage && (removed.length > 0 || added.length > 0);
      const complete = record.fetchedAt != null && !record.hasMore;
      if (complete) items = [...items, ...added];
      // A known retained room's activity changes rank, not the cursor's identity.
      // Keep immediate activity ordering and deduplicate later pages by stable ID.
      const invalidated = membershipChanged && !complete;
      if (!mergingPage && (changed || membershipChanged)) items = sortItems(kind, items);
      const memberDelta = kind === "voice" && !mergingPage
        ? record.items.reduce((sum, item) => {
          const replacement = after.get(String(item.id)) as VoiceChannelDescriptor | undefined;
          return sum + (replacement ? (matchesQuery(record, replacement) ? replacement.member_count : 0)
            - (item as VoiceChannelDescriptor).member_count : 0);
        }, 0) + added.reduce((sum, item) => sum + (item as VoiceChannelDescriptor).member_count, 0) : 0;
      return [key, { ...record, items,
        total: Math.max(0, record.total + (membershipChanged ? added.length - removed.length : 0)),
        totalMemberCount: record.totalMemberCount == null ? null : Math.max(0, record.totalMemberCount + memberDelta),
        invalidated: record.invalidated || invalidated,
        mutationRevision: record.mutationRevision + (membershipChanged ? 1 : 0),
      }];
    }),
  ) }));
  for (const id of after.keys()) createdIds[kind].delete(id);
}

let tracking = false;
const trackingUnsubscribers: Array<() => void> = [];
export function disposeDirectoryTracking() {
  for (const unsubscribe of trackingUnsubscribers.splice(0)) unsubscribe();
  tracking = false;
  useDirectoryStore.getState().reset();
}
export function ensureDirectoryTracking() {
  if (tracking) return;
  tracking = true;
  trackingUnsubscribers.push(useLiveStore.subscribe((next, old) => {
    if (next.channels !== old.channels) updateCachedItems("live", next.channels, old.channels);
  }));
  trackingUnsubscribers.push(useVoiceStore.subscribe((next, old) => {
    if (next.channels !== old.channels) updateCachedItems("voice", next.channels, old.channels);
  }));
  trackingUnsubscribers.push(useBoardgameStore.subscribe((next, old) => {
    if (next.rooms !== old.rooms) updateCachedItems("game", next.rooms, old.rooms);
  }));
  trackingUnsubscribers.push(useAuthStore.subscribe((next, old) => {
    if (next.currentUser?.id !== old.currentUser?.id) useDirectoryStore.getState().reset();
  }));
  trackingUnsubscribers.push(chatWS.onFrame((frame) => {
    const kind = frame.type === "live.channel.created" || frame.type === "live.channel.deleted" ? "live"
      : frame.type === "voice.channel.created" || frame.type === "voice.channel.deleted" ? "voice"
        : frame.type === "boardgame.room.created" || frame.type === "boardgame.room.deleted" ? "game" : null;
    if (!kind) return;
    const deletedId = frame.type === "live.channel.deleted" || frame.type === "voice.channel.deleted" ? String(frame.data.channel_id)
      : frame.type === "boardgame.room.deleted" ? String(frame.room_id) : null;
    if (deletedId == null) {
      const createdId = frame.type === "live.channel.created" || frame.type === "voice.channel.created"
        ? String(frame.data.channel_id) : frame.type === "boardgame.room.created" ? String(frame.room.id) : null;
      if (createdId != null) {
        pruneCreationHints(kind);
        createdIds[kind].set(createdId, Date.now() + 60_000);
        if (createdIds[kind].size > 256) createdIds[kind].delete(createdIds[kind].keys().next().value!);
      }
      return;
    }
    createdIds[kind].delete(deletedId);
    for (const request of requestDeletions.values()) if (request.kind === kind) request.ids.add(deletedId);
    const descriptor = recentlyRemoved[kind].get(deletedId)
      ?? Object.values(useDirectoryStore.getState().records).filter((record) => record.kind === kind)
        .flatMap((record) => record.items).find((item) => String(item.id) === deletedId);
    useDirectoryStore.setState((state) => ({ records: Object.fromEntries(
      Object.entries(state.records).map(([key, record]) => {
        const included = record.items.find((item) => String(item.id) === deletedId);
        const affected = record.kind === kind && (included != null || (record.hasMore && descriptor != null && matchesQuery(record, descriptor)));
        if (!affected) return [key, record];
        const invalidated = record.hasMore;
        const removed = included ?? descriptor;
        return [key, { ...record, invalidated: record.invalidated || invalidated,
          mutationRevision: record.mutationRevision + 1,
          total: Math.max(0, record.total - 1),
          totalMemberCount: kind === "voice" && record.totalMemberCount != null
            ? Math.max(0, record.totalMemberCount - (removed as VoiceChannelDescriptor).member_count) : record.totalMemberCount,
          items: record.items.filter((item) => String(item.id) !== deletedId),
        }];
      }),
    ) }));
    recentlyRemoved[kind].delete(deletedId);
  }));
}

if (import.meta.hot) import.meta.hot.dispose(disposeDirectoryTracking);

/** First-page and append requests are bounded to 20; refresh supersedes stale attempts. */
export function loadDirectory(
  kind: DirectoryKind,
  options: DirectoryOptions = {},
  mode: "initial" | "refresh" | "more" = "initial",
): Promise<void> {
  ensureDirectoryTracking();
  const key = directoryKey(kind, options);
  const previous = useDirectoryStore.getState().records[key] ?? emptyRecord(kind);
  if (mode !== "refresh" && pending.has(key)) return pending.get(key)!;
  if (mode === "initial" && previous.fetchedAt != null && Date.now() - previous.fetchedAt < 60_000) return Promise.resolve();
  if (mode === "more" && (!previous.hasMore || previous.invalidated || !previous.nextCursor)) return Promise.resolve();
  const revision = ++attempt;
  const deletedDuringRequest = new Set<string>();
  requestDeletions.set(revision, { kind, ids: deletedDuringRequest });
  const descriptorsAtStart = new Map(cachedItems(kind).map((item) => [String(item.id), item]));
  const cursor = mode === "more" ? previous.nextCursor : null;
  patch(key, { ...previous, ...options, loading: true, error: null, revision });
  // 按 kind 精确传参：分类选项卡过滤参数（visibility/friends/status/occupied/owner）由后端执行，
  // 每个 tab 独立 key/游标，切 tab 自动拉取该 tab 过滤后的第一页
  const base = { limit: 20, cursor, groupId: options.groupId };
  const request: Promise<DirectoryPage<Item>> = kind === "live"
    ? listLiveChannelsPage({ ...base, onlyLive: options.onlyLive, owner: options.owner,
      visibility: options.visibility, friends: options.friends, status: options.status as "live" | "idle" | "ended" | "offline" | undefined })
    : kind === "voice" ? listVoiceChannelsPage({ ...base, visibility: options.visibility,
      friends: options.friends, occupied: options.occupied, owner: options.owner })
      : listGameRoomsPage({ ...base, mine: options.mine, owner: options.owner,
        visibility: options.visibility, friends: options.friends, status: options.status as "waiting" | "playing" | "ended" | undefined });
  const task = request.then((page) => {
    const current = useDirectoryStore.getState().records[key];
    if (!current || current.revision !== revision || directoryKey(kind, options) !== key) return;
    if (page.has_more && (!page.next_cursor || page.next_cursor === cursor)) {
      // 游标无效（防御性检查，正常不触发）：静默降级，不打扰用户
      patch(key, { ...current, loading: false });
      return;
    }
    // Store descriptors are immutable. A different object received after this request
    // began is newer than its page snapshot, including duplicate IDs on an append.
    const latestDescriptors = new Map(cachedItems(kind).map((item) => [String(item.id), item]));
    const effectiveResults = page.results.map((item) => {
      const latest = latestDescriptors.get(String(item.id));
      return latest && latest !== descriptorsAtStart.get(String(item.id)) ? latest : item;
    });
    const results = effectiveResults.filter((item) => !deletedDuringRequest.has(String(item.id)) && matchesQuery(current, item));
    const discardedMembers = kind === "voice" ? effectiveResults.filter((item) => !results.includes(item))
      .reduce((sum, item) => sum + (item as VoiceChannelDescriptor).member_count, 0) : 0;
    // Only merge descriptors: sidebar/room detail records and other query pages survive.
    mergingPage = true;
    try {
      for (const item of results) {
        if (kind === "live") useLiveStore.getState().upsertChannel(item as LiveChannelDescriptor);
        else if (kind === "voice") useVoiceStore.getState().upsertChannel(item as VoiceChannelDescriptor);
        else useBoardgameStore.getState().upsertRoom(item as GameRoom);
      }
    } finally {
      mergingPage = false;
    }
    const items = new Map((mode === "more" ? current.items : []).map((item) => [String(item.id), item]));
    for (const item of results) items.set(String(item.id), item);
    patch(key, { ...current, items: [...items.values()], nextCursor: page.next_cursor,
      hasMore: page.has_more,
      total: previous.fetchedAt != null && current.mutationRevision !== previous.mutationRevision
        ? current.total : Math.max(0, page.total - (effectiveResults.length - results.length)),
      totalMemberCount: current.totalMemberCount !== previous.totalMemberCount
        ? current.totalMemberCount : page.total_member_count == null ? null : Math.max(0, page.total_member_count - discardedMembers),
      loading: false, error: null, fetchedAt: Date.now(),
      invalidated: mode === "more" ? current.invalidated : current.mutationRevision !== previous.mutationRevision });
  }).catch((error: unknown) => {
    const current = useDirectoryStore.getState().records[key];
    if (current?.revision === revision) patch(key, { ...current, loading: false,
      error: error instanceof Error ? error.message : "加载列表失败" });
  }).finally(() => {
    requestDeletions.delete(revision);
    if (pending.get(key) === task) pending.delete(key);
  });
  pending.set(key, task);
  return task;
}
