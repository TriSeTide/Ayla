import { useEffect, useMemo } from "react";
import type { FavoriteTargetType } from "../api/types";
import { useAuthStore } from "../stores/auth";
import { favoriteStatusKey, loadFavoriteStatuses, retainFavoriteStatus, UNKNOWN_FAVORITE, useFavoriteStatusStore } from "../stores/favoriteStatus";

/** Mounting targets coalesce into bounded requests; no complete index is loaded. */
export function useFavoriteStatuses(type: FavoriteTargetType, targetIds: readonly (string | number)[]) {
  const signature = JSON.stringify([...new Set(targetIds.map(String))]);
  const ids = useMemo<string[]>(() => JSON.parse(signature) as string[], [signature]);
  const account = useAuthStore((state) => `${state.currentUser?.id ?? "anonymous"}:${!!state.accessToken}`);
  const entries = useFavoriteStatusStore((state) => state.entries);
  useEffect(() => {
    const release = retainFavoriteStatus(type, ids);
    loadFavoriteStatuses(type, ids);
    return release;
  }, [type, ids, account]);
  return Object.fromEntries(ids.map((id) => [id, entries.get(favoriteStatusKey(type, id)) ?? UNKNOWN_FAVORITE]));
}
