/** Explicit social directory pages. Legacy array endpoints remain separate. */
export interface SocialPage<T> {
  results: T[];
  total: number;
  has_more: boolean;
  next_cursor: string | null;
}

export interface SocialPageParams {
  limit?: number;
  cursor?: string | null;
  q?: string;
}

export function socialQuery<T extends SocialPageParams>(params: T = {} as T) {
  const query = new URLSearchParams({ pagination: "cursor", limit: String(params.limit ?? 30) });
  for (const [key, value] of Object.entries(params)) {
    if (value != null && value !== "" && key !== "limit") query.set(key, String(value));
  }
  return query.toString();
}
