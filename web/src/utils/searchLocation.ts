/** Keep a valid active search filter while changing the query; other entry points pass no current search. */
export function searchLocation(query: string, currentSearch = "") {
  const params = new URLSearchParams();
  const q = query.trim();
  const type = new URLSearchParams(currentSearch).get("type");
  if (q) params.set("q", q);
  if (type && ["user", "group", "post", "live", "game"].includes(type)) params.set("type", type);
  const search = params.toString();
  return { pathname: "/search", search: search ? `?${search}` : "" };
}
