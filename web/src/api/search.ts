/**
 * 聚合搜索 REST 封装（F9，对齐 backend/apps/search/views.py）。
 *
 * - GET /search/?q=&types=&limit= —— 五类分组（user/group/post/live/game），
 *   每组 {items, total}（截断 + 总数分离）；q 空 → 400。
 */
import { apiRequest } from "./client";
import type { SearchResults } from "./types";

export type SearchType = "user" | "group" | "post" | "live" | "game";

export function search(params: {
  q: string;
  types?: SearchType[];
  limit?: number;
}) {
  const qs = new URLSearchParams({ q: params.q });
  if (params.types && params.types.length > 0) qs.set("types", params.types.join(","));
  if (params.limit != null) qs.set("limit", String(params.limit));
  return apiRequest<SearchResults>(`/search/?${qs.toString()}`);
}
