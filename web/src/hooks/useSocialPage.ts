import { useCallback, useEffect } from "react";
import { useAuthStore } from "../stores/auth";
import { loadSocial, socialKey, updateSocialItems, useSocialStore,
  type SocialItems, type SocialKind, type SocialOptions } from "../stores/social";

const EMPTY: never[] = [];

export function useSocialPage<K extends SocialKind>(kind: K, options: SocialOptions = {}, enabled = true) {
  const userId = useAuthStore((state) => state.currentUser?.id);
  const { groupId, q, type, excludeSelf } = options;
  const key = socialKey(kind, { groupId, q, type, excludeSelf });
  const record = useSocialStore((state) => state.records[key]);
  useEffect(() => { if (enabled) void loadSocial(kind, { groupId, q, type, excludeSelf }); },
    [kind, groupId, q, type, excludeSelf, enabled, userId]);
  const refresh = useCallback(() => loadSocial(kind, { groupId, q, type, excludeSelf }, "refresh"), [kind, groupId, q, type, excludeSelf]);
  const loadMore = useCallback(() => loadSocial(kind, { groupId, q, type, excludeSelf }, "more"), [kind, groupId, q, type, excludeSelf]);
  const setItems = useCallback((update: SocialItems[K][] | ((items: SocialItems[K][]) => SocialItems[K][])) =>
    updateSocialItems(kind, { groupId, q, type, excludeSelf }, update), [kind, groupId, q, type, excludeSelf]);
  const onScroll = useCallback((element: HTMLElement) => {
    if (!useSocialStore.getState().records[key]?.error && element.scrollHeight - element.scrollTop - element.clientHeight < 240) void loadMore();
  }, [key, loadMore]);
  return { items: (record?.items ?? EMPTY) as SocialItems[K][], total: record?.total ?? 0,
    loading: enabled && (!record || record.loading), error: record?.error ?? null,
    hasMore: record?.hasMore ?? false, invalidated: false, refresh, loadMore, setItems, onScroll };
}
