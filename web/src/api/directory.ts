/** A bounded, permission-filtered server directory; cursor ordering is server-owned. */
export interface DirectoryPage<T> {
  results: T[];
  next_cursor: string | null;
  has_more: boolean;
  total: number;
  /** Voice directories retain the full filtered member total for sidebar badges. */
  total_member_count?: number;
}

export interface DirectoryParams {
  limit?: number;
  cursor?: string | null;
  groupId?: string;
}

export function directoryQuery(params: DirectoryParams): URLSearchParams {
  const query = new URLSearchParams({ limit: String(params.limit ?? 20) });
  if (params.cursor) query.set("cursor", params.cursor);
  if (params.groupId) query.set("group_id", params.groupId);
  return query;
}
