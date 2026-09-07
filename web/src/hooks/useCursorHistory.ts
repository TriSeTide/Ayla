import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import type { MediaPage } from "../api/mediaPagination";

export const HISTORY_WINDOW_LIMIT = 500;
export interface HistoryItem { id: string; created_at: string }
type LoadKind = "older" | "latest";
interface HistoryState<T> {
  owner: string;
  items: T[];
  cursor: string | null;
  cursorDetached: boolean;
  hasMore: boolean;
  hasNewer: boolean;
  loading: boolean;
  loaded: boolean;
  error: string | null;
  retryKind: LoadKind;
}
interface ScrollAnchor { id: string | null; top: number; height: number; scrollTop: number }

export function mergeHistory<T extends HistoryItem>(a: T[], b: T[]): T[] {
  const rows = new Map(a.map((item) => [item.id, item]));
  b.forEach((item) => rows.set(item.id, item));
  return [...rows.values()].sort((x, y) => x.created_at.localeCompare(y.created_at)
    || x.id.localeCompare(y.id, undefined, { numeric: true }));
}

/**
 * A bounded display window over durable cursor history. Older reads preserve
 * the visible anchor; returning to latest only replaces it after success.
 * Live arrivals stay outside an older reading window until the reader returns.
 */
export function useCursorHistory<T extends HistoryItem>(
  owner: string,
  fetchPage: (cursor: string | null, beforeId?: string) => Promise<MediaPage<T>>,
  enabled = true,
) {
  const initial = useCallback((): HistoryState<T> => ({ owner, items: [], cursor: null, cursorDetached: false,
    hasMore: false, hasNewer: false, loading: enabled, loaded: false,
    error: null, retryKind: "latest" }), [owner, enabled]);
  const [state, setState] = useState<HistoryState<T>>(initial);
  const stateRef = useRef(state);
  stateRef.current = state;
  const ownerRef = useRef(owner);
  ownerRef.current = owner;
  const fetchRef = useRef(fetchPage);
  fetchRef.current = fetchPage;
  const generation = useRef(0);
  const invalidationRevision = useRef(0);
  const busy = useRef(false);
  const following = useRef(true);
  const pendingLive = useRef(new Map<string, T>());
  const seenLive = useRef(new Set<string>());
  const listRef = useRef<HTMLDivElement | null>(null);
  const pendingScroll = useRef<{ owner: string; anchor: ScrollAnchor | "bottom" } | null>(null);

  const snapshot = useCallback((): ScrollAnchor => {
    const list = listRef.current;
    if (!list) return { id: null, top: 0, height: 0, scrollTop: 0 };
    const bounds = list.getBoundingClientRect();
    const visible = [...list.querySelectorAll<HTMLElement>("[data-history-id]")]
      .find((element) => { const r = element.getBoundingClientRect(); return r.bottom > bounds.top && r.top < bounds.bottom; });
    return { id: visible?.dataset.historyId ?? null, top: visible?.getBoundingClientRect().top ?? 0,
      height: list.scrollHeight, scrollTop: list.scrollTop };
  }, []);

  useLayoutEffect(() => {
    const restore = pendingScroll.current;
    const list = listRef.current;
    if (!restore || !list || restore.owner !== owner) return;
    pendingScroll.current = null;
    if (restore.anchor === "bottom") { list.scrollTop = list.scrollHeight; return; }
    const anchor = restore.anchor;
    const element = [...list.querySelectorAll<HTMLElement>("[data-history-id]")]
      .find((node) => node.dataset.historyId === anchor.id);
    list.scrollTop = element ? list.scrollTop + element.getBoundingClientRect().top - anchor.top
      : anchor.scrollTop + list.scrollHeight - anchor.height;
  }, [state.items, owner]);

  const load = useCallback(async (kind: LoadKind) => {
    if (!enabled || (kind === "older" && busy.current)) return false;
    const current = stateRef.current;
    if (kind === "older" && (current.owner !== owner || !current.hasMore || (!current.cursor && !current.cursorDetached))) return false;
    const request = ++generation.current;
    const revision = invalidationRevision.current;
    const cursor = kind === "older" && !current.cursorDetached ? current.cursor : null;
    const beforeId = kind === "older" && current.cursorDetached ? current.items[0]?.id : undefined;
    busy.current = true;
    pendingLive.current.clear();
    if (kind === "older") following.current = false;
    setState((prev) => ({ ...(prev.owner === owner ? prev : initial()), loading: true, error: null, retryKind: kind }));
    try {
      const page = await fetchRef.current(cursor, beforeId);
      if (ownerRef.current !== owner || generation.current !== request) return false;
      if (page.has_more && (!page.next_cursor || page.next_cursor === cursor || !page.results.length)) {
        throw new Error("历史分页响应缺少有效的继续位置，请重试");
      }
      const previous = stateRef.current;
      const anchor = snapshot();
      const merged = mergeHistory(kind === "older" ? previous.items : [], page.results);
      const first = page.results[0];
      const liveTail = [...pendingLive.current.values()].filter((item) => !first
        || item.created_at > first.created_at || (item.created_at === first.created_at
          && item.id.localeCompare(first.id, undefined, { numeric: true }) >= 0));
      const latestRows = kind === "latest" ? mergeHistory(merged, liveTail) : [];
      const next = kind === "latest" ? latestRows.slice(-HISTORY_WINDOW_LIMIT)
        : merged.slice(0, HISTORY_WINDOW_LIMIT);
      if (kind === "older" && anchor.id && !next.some((item) => item.id === anchor.id)) {
        setState((prev) => ({ ...prev, loading: false, error: "请先滚动到列表顶部，再加载更早记录" }));
        return false;
      }
      following.current = kind === "latest";
      pendingScroll.current = { owner, anchor: kind === "latest" ? "bottom" : anchor };
      const detached = kind === "latest" && latestRows.length > HISTORY_WINDOW_LIMIT;
      setState({ owner, items: next, cursor: page.next_cursor, cursorDetached: detached, hasMore: page.has_more || detached,
        hasNewer: invalidationRevision.current !== revision || (kind === "older" && (previous.hasNewer || merged.length > HISTORY_WINDOW_LIMIT || pendingLive.current.size > 0)),
        loading: false, loaded: true, error: null, retryKind: kind });
      return true;
    } catch (error) {
      if (ownerRef.current === owner && generation.current === request) {
        setState((prev) => ({ ...prev, loading: false, error: error instanceof Error ? error.message : "读取历史失败，请重试" }));
      }
      return false;
    } finally {
      if (ownerRef.current === owner && generation.current === request) busy.current = false;
    }
  }, [owner, enabled, initial, snapshot]);

  useEffect(() => {
    busy.current = false;
    following.current = true;
    pendingLive.current.clear();
    seenLive.current.clear();
    pendingScroll.current = null;
    setState(initial());
    if (enabled) void load("latest");
    return () => { generation.current += 1; busy.current = false; };
  }, [enabled, initial, load]);

  const append = useCallback((item: T): boolean => {
    if (ownerRef.current !== owner || seenLive.current.has(item.id)) return false;
    seenLive.current.add(item.id);
    if (seenLive.current.size > HISTORY_WINDOW_LIMIT * 2) seenLive.current.delete(seenLive.current.values().next().value!);
    if (busy.current) {
      pendingLive.current.set(item.id, item);
      if (pendingLive.current.size > HISTORY_WINDOW_LIMIT) pendingLive.current.delete(pendingLive.current.keys().next().value!);
    }
    setState((prev) => {
      if (prev.owner !== owner || prev.items.some((row) => row.id === item.id)) return prev;
      if (!following.current || prev.hasNewer) return { ...prev, hasNewer: true };
      pendingScroll.current = { owner, anchor: "bottom" };
      const merged = mergeHistory(prev.items, [item]);
      const evicted = merged.length > HISTORY_WINDOW_LIMIT;
      return { ...prev, items: merged.slice(-HISTORY_WINDOW_LIMIT),
        cursorDetached: prev.cursorDetached || evicted, hasMore: prev.hasMore || evicted };
    });
    return true;
  }, [owner]);

  const handleScroll = useCallback(() => {
    const list = listRef.current;
    if (!list) return;
    following.current = list.scrollHeight - list.scrollTop - list.clientHeight < 40 && !stateRef.current.hasNewer;
  }, []);
  const loadOlder = useCallback(async () => { await load("older"); }, [load]);
  const returnLatest = useCallback(async () => { await load("latest"); }, [load]);
  const retry = useCallback(async () => { await load(stateRef.current.retryKind); }, [load]);
  const invalidate = useCallback(() => {
    if (ownerRef.current !== owner) return;
    invalidationRevision.current += 1;
    setState((previous) => previous.owner === owner ? { ...previous, hasNewer: true } : previous);
  }, [owner]);
  return { ...(state.owner === owner ? state : initial()), listRef, append,
    handleScroll, loadOlder, returnLatest, retry, invalidate };
}
