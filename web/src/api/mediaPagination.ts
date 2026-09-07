/** A bounded display projection. Original room history remains on the server. */
export interface MediaPage<T> {
  results: T[];
  next_cursor: string | null;
  has_more: boolean;
  total: number;
}

export interface MediaPageParams {
  limit?: number;
  cursor?: string | null;
  /** Re-anchor an older read after the live display window evicted its old edge. */
  beforeId?: string;
}

export function mediaPageQuery(params: MediaPageParams = {}): URLSearchParams {
  const query = new URLSearchParams({ pagination: "cursor", limit: String(params.limit ?? 50) });
  if (params.cursor) query.set("cursor", params.cursor);
  if (params.beforeId) query.set("before_id", params.beforeId);
  return query;
}
