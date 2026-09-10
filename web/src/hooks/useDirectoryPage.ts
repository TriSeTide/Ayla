import { useCallback, useEffect } from "react";
import { useAuthStore } from "../stores/auth";
import { directoryKey, loadDirectory, useDirectoryStore, type DirectoryItems, type DirectoryKind, type DirectoryOptions } from "../stores/directory";

const EMPTY_ITEMS: never[] = [];

export function useDirectoryPage<K extends DirectoryKind>(kind: K, options: DirectoryOptions = {}, enabled = true) {
  const userId = useAuthStore((state) => state.currentUser?.id);
  const { groupId, onlyLive, filter, visibility, friends, occupied, status, owner, mine } = options;
  const key = directoryKey(kind, { groupId, onlyLive, filter, visibility, friends, occupied, status, owner, mine });
  const record = useDirectoryStore((state) => state.records[key]);
  useEffect(() => {
    if (enabled) void loadDirectory(kind, { groupId, onlyLive, filter, visibility, friends, occupied, status, owner, mine });
  }, [kind, groupId, onlyLive, filter, visibility, friends, occupied, status, owner, mine, enabled, userId]);
  const refresh = useCallback(() => loadDirectory(kind, { groupId, onlyLive, filter, visibility, friends, occupied, status, owner, mine }, "refresh"), [kind, groupId, onlyLive, filter, visibility, friends, occupied, status, owner, mine]);
  const loadMore = useCallback(() => loadDirectory(kind, { groupId, onlyLive, filter, visibility, friends, occupied, status, owner, mine }, "more"), [kind, groupId, onlyLive, filter, visibility, friends, occupied, status, owner, mine]);
  const onScroll = useCallback((element: HTMLElement) => {
    if (useDirectoryStore.getState().records[key]?.error) return;
    if (element.scrollHeight - element.scrollTop - element.clientHeight < 240) void loadMore();
  }, [key, loadMore]);
  return {
    items: (record?.items ?? EMPTY_ITEMS) as DirectoryItems[K][],
    loading: enabled && (!record || record.loading),
    error: record?.error ?? null,
    total: record?.total ?? 0,
    totalMemberCount: record?.totalMemberCount ?? null,
    hasMore: record?.hasMore ?? false,
    invalidated: record?.invalidated ?? false,
    refresh, loadMore, onScroll,
  };
}
