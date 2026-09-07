import { useEffect, useRef, useState } from "react";
import * as favoritesApi from "../api/favorites";
import type { FavoriteTargetType } from "../api/types";
import { useFavoriteStatuses } from "../hooks/useFavoriteStatuses";
import { applyFavoriteStatus, ensureFavoriteScope, favoriteStatusKey, loadFavoriteStatuses, useFavoriteStatusStore } from "../stores/favoriteStatus";
import { IconHeart } from "./icons";
import { useAuthStore } from "../stores/auth";

export const subscribeFavoriteChanges = (listener: () => void) => useFavoriteStatusStore.subscribe(listener);
export function applyFavoriteChanged(type: FavoriteTargetType, id: string, favoriteId: number | null) {
  applyFavoriteStatus(type, id, favoriteId);
}

export function FavoriteButton({ targetType, targetId, compact = false, className = "" }: {
  targetType: FavoriteTargetType;
  targetId: string | number;
  compact?: boolean;
  className?: string;
}) {
  const key = String(targetId);
  const account = useAuthStore((state) => `${state.currentUser?.id ?? "anonymous"}:${!!state.accessToken}`);
  const state = useFavoriteStatuses(targetType, [key])[key];
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const owner = useRef(0);
  useEffect(() => {
    owner.current += 1;
    setBusy(false);
    setActionError(null);
    return () => { owner.current += 1; };
  }, [targetType, key, account]);
  const toggle = async (event: React.MouseEvent<HTMLButtonElement>) => {
    event.stopPropagation();
    if (busy || state.loading) return;
    if (state.error || state.favoriteId === undefined) {
      loadFavoriteStatuses(targetType, [key], true);
      return;
    }
    const requestEpoch = ensureFavoriteScope();
    const requestOwner = owner.current;
    const requestRevision = state.revision;
    setBusy(true);
    setActionError(null);
    try {
      let favoriteId: number | null;
      if (state.favoriteId !== null) {
        await favoritesApi.removeFavorite(state.favoriteId);
        favoriteId = null;
      } else {
        favoriteId = (await favoritesApi.addFavorite(targetType, key)).id;
      }
      if (requestEpoch === ensureFavoriteScope() && useFavoriteStatusStore.getState().entries.get(favoriteStatusKey(targetType, key))?.revision === requestRevision) {
        applyFavoriteStatus(targetType, key, favoriteId);
      }
    } catch (error) {
      if (requestOwner === owner.current && requestEpoch === ensureFavoriteScope()) setActionError(error instanceof Error ? error.message : "收藏操作失败，请重试");
    } finally {
      if (requestOwner === owner.current) setBusy(false);
    }
  };
  const active = state.favoriteId != null;
  const unknown = state.favoriteId === undefined;
  const label = state.error ? "收藏状态加载失败，点击重试" : unknown ? "正在加载收藏状态" : active ? "取消收藏" : "收藏";
  return (
    <button
      type="button"
      className={`favorite-toggle ${active ? "is-active is-favorited" : ""} ${compact ? "is-compact" : ""} ${className}`}
      onClick={(event) => void toggle(event)}
      disabled={busy || state.loading || (unknown && !state.error)}
      aria-label={label}
      aria-pressed={unknown ? undefined : active}
      title={actionError ?? state.error ?? label}
    >
      <IconHeart width={compact ? 16 : 18} height={compact ? 16 : 18} fill={active ? "currentColor" : "none"} />
      {!compact && <span>{state.error ? "重试收藏状态" : unknown ? "加载中…" : active ? "已收藏" : "收藏"}</span>}
      {actionError && <span role="alert">{actionError}</span>}
    </button>
  );
}
