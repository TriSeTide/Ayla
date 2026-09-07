/**
 * 收藏 REST 封装（F6/F10，对齐 backend/apps/favorites/views.py）。
 *
 * - GET /favorites/?type= → 我的收藏列表（按 target_type 过滤）；
 * - POST /favorites/ {target_type, target_id} → 幂等收藏（201 新建 / 200 已存在）；
 * - DELETE /favorites/<id>/ → 取消收藏。
 */
import { apiRequest } from "./client";
import type { Favorite, FavoriteTargetType } from "./types";
import type { DirectoryPage } from "./directory";

/** GET /favorites/?type= —— 我的收藏列表 */
export function listFavorites(targetType?: FavoriteTargetType) {
  const qs = targetType ? `?type=${targetType}` : "";
  return apiRequest<Favorite[]>(`/favorites/${qs}`);
}

export interface FavoriteStatuses {
  target_type: FavoriteTargetType;
  statuses: Record<string, number | null>;
}

/** Query only displayed targets; each request has a hard 100-ID ceiling. */
export function getFavoriteStatuses(targetType: FavoriteTargetType, targetIds: readonly string[]) {
  if (targetIds.length > 100) throw new Error("一次最多查询 100 个收藏状态");
  return apiRequest<FavoriteStatuses>("/favorites/status/", {
    method: "POST",
    body: { target_type: targetType, target_ids: targetIds },
  });
}

/** SQL cursor page; callers must not replace a complete favorite index with one page. */
export function listFavoritesPage(params: { type?: FavoriteTargetType; limit?: number; cursor?: string | null } = {}) {
  const query = new URLSearchParams({ limit: String(params.limit ?? 20) });
  if (params.type) query.set("type", params.type);
  if (params.cursor != null) query.set("cursor", params.cursor);
  return apiRequest<DirectoryPage<Favorite>>(`/favorites/?${query}`);
}

/** POST /favorites/ —— 收藏（幂等） */
export function addFavorite(targetType: FavoriteTargetType, targetId: string) {
  return apiRequest<Favorite>("/favorites/", {
    method: "POST",
    body: { target_type: targetType, target_id: targetId },
  });
}

/** DELETE /favorites/<id>/ —— 取消收藏 */
export function removeFavorite(favoriteId: number) {
  return apiRequest<{ deleted: boolean }>(`/favorites/${favoriteId}/`, {
    method: "DELETE",
  });
}
