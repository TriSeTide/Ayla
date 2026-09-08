/**
 * 聚合搜索 REST 封装（F9，对齐 backend/apps/search/views.py）。
 *
 * - GET /search/?q=&types=&limit= —— 六类分组（user/group/post/live/game/voice），
 *   每组 {items, total}（截断 + 总数分离）；q 空 → 400。
 */
import { apiRequest } from "./client";
import type { SearchResults } from "./types";

export type SearchType = "user" | "group" | "post" | "live" | "game" | "voice";

export type SearchPageResults = {
  [Key in keyof SearchResults]?: NonNullable<SearchResults[Key]> & {
    next_cursor: string | null;
    has_more: boolean;
  };
};

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

/** Opt-in grouped keyset pages; a continuation requests one type only. */
export function searchPages(params: { q: string; types?: SearchType[]; limit?: number; cursor?: string | null }) {
  const query = new URLSearchParams({ q: params.q, pagination: "cursor" });
  if (params.types?.length) query.set("types", params.types.join(","));
  if (params.limit != null) query.set("limit", String(params.limit));
  if (params.cursor != null) query.set("cursor", params.cursor);
  return apiRequest<SearchPageResults>(`/search/?${query}`);
}
