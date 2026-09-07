/** Bounded target lookups. Missing state is unknown, never an unfavorite. */
import { create } from "zustand";
import { getFavoriteStatuses } from "../api/favorites";
import type { FavoriteTargetType } from "../api/types";
import { useAuthStore } from "./auth";

export interface FavoriteStatus {
  favoriteId: number | null | undefined;
  loading: boolean;
  error: string | null;
  revision: number;
  updatedAt: number;
}
export const UNKNOWN_FAVORITE: FavoriteStatus = {
  favoriteId: undefined, loading: false, error: null, revision: 0, updatedAt: 0,
};
export const useFavoriteStatusStore = create<{ entries: ReadonlyMap<string, FavoriteStatus> }>(() => ({ entries: new Map() }));
export const favoriteStatusKey = (type: FavoriteTargetType, id: string) => `${type}:${id}`;
const retained = new Map<string, number>();
let scope: string | undefined;
let epoch = 0;
let revision = 0;
let tracking = false;
let scheduled = false;
let active = 0;
const queue = new Map<FavoriteTargetType, Set<string>>();

function authScope() {
  const state = useAuthStore.getState();
  return `${state.currentUser?.id ?? "anonymous"}:${state.accessToken ? "authenticated" : "anonymous"}`;
}

/** Lazy installation avoids the auth -> WS -> button -> status import cycle. */
export function ensureFavoriteScope() {
  const next = authScope();
  if (scope !== next) {
    scope = next;
    epoch += 1;
    queue.clear();
    active = 0;
    useFavoriteStatusStore.setState({ entries: new Map() });
  }
  if (!tracking) {
    tracking = true;
    useAuthStore.subscribe(() => { ensureFavoriteScope(); });
  }
  return epoch;
}

function write(key: string, value: FavoriteStatus) {
  const entries = new Map(useFavoriteStatusStore.getState().entries);
  entries.set(key, value);
  // Keep mounted targets; only idle, off-screen cache entries are evictable.
  if (entries.size > 1024) {
    for (const [candidate, state] of entries) {
      if (entries.size <= 1024) break;
      if (candidate !== key && !state.loading && !retained.has(candidate)) entries.delete(candidate);
    }
  }
  useFavoriteStatusStore.setState({ entries });
}

export function retainFavoriteStatus(type: FavoriteTargetType, ids: readonly string[]) {
  ensureFavoriteScope();
  const keys = ids.map((id) => favoriteStatusKey(type, id));
  for (const key of keys) retained.set(key, (retained.get(key) ?? 0) + 1);
  return () => {
    for (const key of keys) {
      const count = (retained.get(key) ?? 1) - 1;
      if (count > 0) retained.set(key, count); else retained.delete(key);
    }
  };
}

/** WS/local writes supersede any request already in flight for this target. */
export function applyFavoriteStatus(type: FavoriteTargetType, id: string, favoriteId: number | null) {
  ensureFavoriteScope();
  write(favoriteStatusKey(type, id), { favoriteId, loading: false, error: null, revision: ++revision, updatedAt: Date.now() });
}

function drain() {
  scheduled = false;
  while (active < 2 && queue.size > 0) {
    const [type, pending] = queue.entries().next().value!;
    const ids = [...pending].slice(0, 100);
    for (const id of ids) pending.delete(id);
    if (!pending.size) queue.delete(type);
    const requestEpoch = epoch;
    const expected = new Map(ids.map((id) => [id, useFavoriteStatusStore.getState().entries.get(favoriteStatusKey(type, id))!.revision]));
    active += 1;
    void Promise.resolve().then(() => getFavoriteStatuses(type, ids)).then((response) => {
      if (requestEpoch !== ensureFavoriteScope()) return;
      if (response.target_type !== type || ids.some((id) => !Object.prototype.hasOwnProperty.call(response.statuses, id) || (response.statuses[id] !== null && (!Number.isInteger(response.statuses[id]) || response.statuses[id]! <= 0)))) {
        throw new Error("收藏状态响应不完整，请重试");
      }
      for (const id of ids) {
        const key = favoriteStatusKey(type, id);
        const current = useFavoriteStatusStore.getState().entries.get(key);
        if (current && current.revision === expected.get(id)) write(key, { ...current, favoriteId: response.statuses[id], loading: false, error: null, updatedAt: Date.now() });
      }
    }).catch((error: unknown) => {
      if (requestEpoch !== ensureFavoriteScope()) return;
      for (const id of ids) {
        const key = favoriteStatusKey(type, id);
        const current = useFavoriteStatusStore.getState().entries.get(key);
        if (current && current.revision === expected.get(id)) write(key, { ...current, loading: false, error: error instanceof Error ? error.message : "收藏状态加载失败" });
      }
    }).finally(() => {
      if (requestEpoch !== epoch) return;
      active -= 1;
      drain();
    });
  }
}

export function loadFavoriteStatuses(type: FavoriteTargetType, ids: readonly string[], force = false) {
  ensureFavoriteScope();
  for (const id of new Set(ids)) {
    const key = favoriteStatusKey(type, id);
    const current = useFavoriteStatusStore.getState().entries.get(key) ?? UNKNOWN_FAVORITE;
    if (current.loading || (!force && current.favoriteId !== undefined && Date.now() - current.updatedAt < 60_000)) continue;
    write(key, { ...current, loading: true, error: null, revision: ++revision });
    const pending = queue.get(type) ?? new Set<string>();
    pending.add(id);
    queue.set(type, pending);
  }
  if (!scheduled) {
    scheduled = true;
    queueMicrotask(drain);
  }
}
