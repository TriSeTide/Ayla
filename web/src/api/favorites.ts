/**
 * 收藏 REST 封装（F6/F10，对齐 backend/apps/favorites/views.py）。
 *
 * - GET /favorites/?type= → 我的收藏列表（按 target_type 过滤）；
 * - POST /favorites/ {target_type, target_id} → 幂等收藏（201 新建 / 200 已存在）；
 * - DELETE /favorites/<id>/ → 取消收藏。
 */
import { apiRequest } from "./client";
import type { Favorite, FavoriteTargetType } from "./types";

/** GET /favorites/?type= —— 我的收藏列表 */
export function listFavorites(targetType?: FavoriteTargetType) {
  const qs = targetType ? `?type=${targetType}` : "";
  return apiRequest<Favorite[]>(`/favorites/${qs}`);
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
