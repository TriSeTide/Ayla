import { useCallback, useEffect, useRef, useState } from "react";
import type { MediaPage } from "../api/mediaPagination";

interface ListState<T> {
  scope: string;
  items: T[];
  cursor: string | null;
  hasMore: boolean;
  total: number;
  loading: boolean;
  loaded: boolean;
  error: string | null;
}

/** Request generation belongs to a scope; errors retain the last successful page. */
export function usePagedMediaList<T extends { id: string | number }>(
  scope: string,
  fetchPage: (cursor: string | null) => Promise<MediaPage<T>>,
  enabled = true,
) {
  const empty = useCallback((): ListState<T> => ({ scope, items: [], cursor: null,
    hasMore: false, total: 0, loading: enabled, loaded: false, error: null }), [scope, enabled]);
  const [value, setValue] = useState<ListState<T>>(empty);
  const currentScope = useRef(scope);
  currentScope.current = scope;
  const fetchRef = useRef(fetchPage);
  fetchRef.current = fetchPage;
  const valueRef = useRef(value);
  valueRef.current = value;
  const generation = useRef(0);
  const busy = useRef(false);
  const retryReset = useRef(true);

  const load = useCallback(async (reset: boolean) => {
    if (!enabled || (!reset && busy.current)) return;
    const previous = valueRef.current;
    if (!reset && (previous.scope !== scope || !previous.hasMore || !previous.cursor)) return;
    const request = ++generation.current;
    retryReset.current = reset;
    const cursor = reset ? null : previous.cursor;
    busy.current = true;
    setValue((state) => ({ ...(state.scope === scope ? state : empty()), loading: true, error: null }));
    try {
      const page = await fetchRef.current(cursor);
      if (currentScope.current !== scope || generation.current !== request) return;
      if (page.has_more && (!page.next_cursor || page.next_cursor === cursor || !page.results.length)) {
        // 游标异常（防御性检查，正常不触发）：静默降级，不打扰用户
        setValue((state) => ({ ...state, loading: false }));
        return;
      }
      setValue((state) => {
        const rows = new Map<string, T>((reset ? [] : state.items).map((item) => [String(item.id), item]));
        page.results.forEach((item) => rows.set(String(item.id), item));
        return { scope, items: [...rows.values()], cursor: page.next_cursor, hasMore: page.has_more,
          total: page.total, loading: false, loaded: true, error: null };
      });
      return page;
    } catch (error) {
      if (currentScope.current === scope && generation.current === request) {
        setValue((state) => ({ ...state, loading: false, error: error instanceof Error ? error.message : "加载失败，请重试" }));
      }
    } finally {
      if (currentScope.current === scope && generation.current === request) busy.current = false;
    }
  }, [scope, enabled, empty]);

  useEffect(() => {
    busy.current = false;
    setValue(empty());
    if (enabled) void load(true);
    return () => { generation.current += 1; busy.current = false; };
  }, [empty, enabled, load]);

  const updateItems = useCallback((update: (items: T[]) => T[]) => {
    setValue((state) => state.scope === scope ? { ...state, items: update(state.items) } : state);
  }, [scope]);
  const refreshPage = useCallback(() => load(true), [load]);
  const refresh = useCallback(async () => { await load(true); }, [load]);
  const loadMore = useCallback(async () => { await load(valueRef.current.error ? retryReset.current : false); }, [load]);
  return { ...(value.scope === scope ? value : empty()), refresh, refreshPage, loadMore, updateItems };
}
