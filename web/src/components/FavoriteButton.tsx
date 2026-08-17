import { useEffect, useState } from "react";
import * as favoritesApi from "../api/favorites";
import type { FavoriteTargetType } from "../api/types";
import { IconHeart } from "./icons";

type FavoriteCache = Map<string, number>;

const cache = new Map<FavoriteTargetType, FavoriteCache>();
const pending = new Map<FavoriteTargetType, Promise<FavoriteCache>>();

function cacheKey(targetId: string | number): string {
  return String(targetId);
}

function loadType(targetType: FavoriteTargetType): Promise<FavoriteCache> {
  const ready = cache.get(targetType);
  if (ready) return Promise.resolve(ready);
  const running = pending.get(targetType);
  if (running) return running;
  const request = favoritesApi.listFavorites(targetType).then((items) => {
    const next = new Map<string, number>();
    for (const item of items) next.set(item.target_id, item.id);
    cache.set(targetType, next);
    pending.delete(targetType);
    return next;
  }).catch((error) => {
    pending.delete(targetType);
    throw error;
  });
  pending.set(targetType, request);
  return request;
}

export function FavoriteButton({
  targetType,
  targetId,
  compact = false,
}: {
  targetType: FavoriteTargetType;
  targetId: string | number;
  compact?: boolean;
}) {
  const key = cacheKey(targetId);
  const [favoriteId, setFavoriteId] = useState<number | null>(() => cache.get(targetType)?.get(key) ?? null);
  const [loading, setLoading] = useState(!cache.has(targetType));
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    if (cache.has(targetType)) {
      setFavoriteId(cache.get(targetType)?.get(key) ?? null);
      setLoading(false);
      return () => { cancelled = true; };
    }
    void loadType(targetType).then((items) => {
      if (!cancelled) {
        setFavoriteId(items.get(key) ?? null);
        setLoading(false);
      }
    }).catch((err) => {
      if (!cancelled) {
        setError(err instanceof Error ? err.message : "收藏状态加载失败");
        setLoading(false);
      }
    });
    return () => { cancelled = true; };
  }, [key, targetType]);

  const toggle = async (event: React.MouseEvent<HTMLButtonElement>) => {
    event.stopPropagation();
    if (loading) return;
    setLoading(true);
    setError(null);
    try {
      const typeCache = cache.get(targetType) ?? new Map<string, number>();
      if (favoriteId != null) {
        await favoritesApi.removeFavorite(favoriteId);
        typeCache.delete(key);
        setFavoriteId(null);
      } else {
        const favorite = await favoritesApi.addFavorite(targetType, key);
        typeCache.set(key, favorite.id);
        setFavoriteId(favorite.id);
      }
      cache.set(targetType, typeCache);
    } catch (err) {
      setError(err instanceof Error ? err.message : "收藏操作失败，请重试");
    } finally {
      setLoading(false);
    }
  };

  const active = favoriteId != null;
  return (
    <button
      type="button"
      className={`favorite-toggle ${active ? "is-active" : ""} ${compact ? "is-compact" : ""}`}
      onClick={toggle}
      disabled={loading}
      aria-label={active ? "取消收藏" : "收藏"}
      aria-pressed={active}
      title={error ?? (active ? "取消收藏" : "收藏")}
    >
      <IconHeart width={compact ? 16 : 18} height={compact ? 16 : 18} fill={active ? "currentColor" : "none"} />
      {!compact && <span>{active ? "已收藏" : "收藏"}</span>}
    </button>
  );
}
