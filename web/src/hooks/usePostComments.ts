import { useCallback, useEffect, useRef, useState } from "react";
import { listCommentsPage } from "../api/posts";
import type { PostComment } from "../api/types";
import { useAuthStore } from "../stores/auth";
import { chatWS } from "../ws/chat";

interface CommentsPage {
  items: PostComment[];
  cursor: string | null;
  hasMore: boolean;
  total: number;
  loaded: boolean;
  loading: boolean;
  error: string | null;
  errorKind: "first" | "append" | null;
  updatedAt: number;
  revision: number;
}
const empty = (): CommentsPage => ({ items: [], cursor: null, hasMore: false, total: 0, loaded: false, loading: false, error: null, errorKind: null, updatedAt: 0, revision: 0 });
const snapshots = new Map<string, CommentsPage>();
let cacheAccount = "";
let tracking = false;
let accountEpoch = 0;
function accountScope() {
  const auth = useAuthStore.getState();
  return `${auth.currentUser?.id ?? "anonymous"}:${!!auth.accessToken}`;
}
function ensureAccount() {
  const account = accountScope();
  if (cacheAccount !== account) { cacheAccount = account; snapshots.clear(); accountEpoch += 1; }
  if (!tracking) {
    tracking = true;
    useAuthStore.subscribe(ensureAccount);
  }
  return accountEpoch;
}
function merge(current: PostComment[], incoming: PostComment[]) {
  const rows = new Map(current.map((item) => [item.id, item]));
  for (const item of incoming) rows.set(item.id, item);
  return [...rows.values()].sort((a, b) => Date.parse(a.created_at) - Date.parse(b.created_at) || a.id - b.id);
}

/** Visible comments have an account/post owner and an independent bounded cursor. */
export function usePostComments(postId: number) {
  const account = useAuthStore((state) => `${state.currentUser?.id ?? "anonymous"}:${!!state.accessToken}`);
  const key = `${account}:post-comments:${postId}`;
  const [state, setState] = useState<CommentsPage>(() => { ensureAccount(); return snapshots.get(key) ?? empty(); });
  const stateRef = useRef(state);
  const owner = useRef({ key, active: true, epoch: ensureAccount(), request: 0, mutation: 0, deleted: new Set<number>(), changed: new Map<number, number>() });
  const restored = useRef(snapshots.has(key));
  if (owner.current.key !== key) {
    owner.current = { key, active: true, epoch: ensureAccount(), request: 0, mutation: 0, deleted: new Set(), changed: new Map() };
    stateRef.current = snapshots.get(key) ?? empty();
    restored.current = snapshots.has(key);
  }
  const [resumeEntry, setResumeEntry] = useState(false);
  const valid = useCallback((candidate: typeof owner.current) => candidate.active && candidate === owner.current && candidate.epoch === ensureAccount(), []);
  const update = useCallback((next: CommentsPage | ((current: CommentsPage) => CommentsPage)) => {
    const value = typeof next === "function" ? next(stateRef.current) : next;
    stateRef.current = value;
    setState(value);
    if (value.loaded) {
      snapshots.delete(owner.current.key);
      snapshots.set(owner.current.key, { ...value, loading: false });
      while (snapshots.size > 12) snapshots.delete(snapshots.keys().next().value!);
    }
  }, []);

  const request = useCallback(async (append = false) => {
    const current = owner.current;
    if (!valid(current) || current.key !== key || !Number.isInteger(postId) || postId <= 0) return;
    const page = stateRef.current;
    if (page.loading || (append && (!page.loaded || !page.hasMore || !page.cursor))) return;
    const requestId = ++current.request;
    const mutationAtStart = current.mutation;
    const cursor = append ? page.cursor : null;
    update({ ...page, loading: true, error: null, errorKind: null });
    try {
      const result = await listCommentsPage(postId, { limit: 20, cursor });
      if (!valid(current) || current.request !== requestId) return;
      if (result.results.some((item) => Number(item.post_id) !== postId)) throw new Error("评论响应不属于当前帖子，请重试");
      if (result.has_more && (!result.next_cursor || result.next_cursor === cursor)) throw new Error("评论分页游标未推进，请重试");
      const rows = result.results.filter((item) => !current.deleted.has(item.id));
      const latest = stateRef.current;
      const preserved = append ? latest.items : latest.items.filter((item) => (current.changed.get(item.id) ?? 0) > mutationAtStart);
      update({ items: merge(preserved, rows), cursor: result.next_cursor, hasMore: result.has_more,
        total: current.mutation > mutationAtStart ? latest.total : result.total,
        loaded: true, loading: false, error: null, errorKind: null, updatedAt: Date.now(), revision: latest.revision + 1 });
      if (page.loaded) setResumeEntry(true);
    } catch (error) {
      if (!valid(current) || current.request !== requestId) return;
      update((latest) => ({ ...latest, loading: false, error: error instanceof Error ? error.message : "加载评论失败", errorKind: append ? "append" : "first" }));
    }
  }, [postId, key, valid, update]);

  const upsert = useCallback((comment: PostComment, total?: number) => {
    const current = owner.current;
    if (!valid(current) || current.key !== key || Number(comment.post_id) !== postId || current.deleted.has(comment.id)) return;
    current.changed.set(comment.id, ++current.mutation);
    update((latest) => ({ ...latest, items: merge(latest.items, [comment]), total: total ?? latest.total + (latest.items.some((item) => item.id === comment.id) ? 0 : 1), revision: latest.revision + 1 }));
    setResumeEntry(true);
  }, [key, postId, valid, update]);
  const remove = useCallback((id: number, total?: number) => {
    const current = owner.current;
    if (!valid(current) || current.key !== key) return;
    current.deleted.add(id);
    current.changed.set(id, ++current.mutation);
    update((latest) => ({ ...latest, items: latest.items.filter((item) => item.id !== id), total: total ?? Math.max(0, latest.total - (latest.items.some((item) => item.id === id) ? 1 : 0)), revision: latest.revision + 1 }));
  }, [key, valid, update]);

  useEffect(() => {
    const current = owner.current;
    current.active = true;
    setState(stateRef.current);
    if (!stateRef.current.loaded) void request();
    const off = chatWS.onFrame((frame) => {
      if (!valid(current)) return;
      if (frame.type === "comment.created" && Number(frame.data.post_id) === postId) upsert(frame.data.comment, frame.data.comment_count);
      if (frame.type === "comment.deleted" && Number(frame.data.post_id) === postId) remove(frame.data.comment_id, frame.data.comment_count);
    });
    return () => {
      current.active = false;
      current.request += 1;
      stateRef.current = { ...stateRef.current, loading: false };
      // This view no longer receives WS frames. Keep its loaded pages, but
      // make the uncertainty visible on return instead of claiming freshness.
      const snapshot = snapshots.get(current.key);
      if (snapshot) snapshots.set(current.key, { ...snapshot, updatedAt: 0 });
      off();
    };
  }, [request, postId, valid, upsert, remove]);

  const visibleState = stateRef.current;
  return { ...visibleState, key, suppressEntry: restored.current && !resumeEntry,
    stale: visibleState.loaded && Date.now() - visibleState.updatedAt > 60_000,
    loadMore: () => request(true), refresh: () => request(false),
    retry: () => request(stateRef.current.errorKind === "append"), upsert, remove };
}
