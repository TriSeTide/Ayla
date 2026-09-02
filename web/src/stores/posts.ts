/**
 * posts 全局状态（F6）：信息流游标分页 + 我的帖子收藏集合。
 *
 * - 信息流：scope（feed/mine/group:<id>）+ 游标分页（results/next_cursor/has_more）；
 * - 收藏集合：favoriteByPostId（postId → favoriteId），列表/详情两视图共享收藏态，
 *   收藏/取消即时反馈（R-P4）并在信息流卡片同步反映。
 */
import { create } from "zustand";
import type { Post, PostScope } from "../api/types";

interface PostsState {
  posts: Post[];
  nextCursor: string | null;
  hasMore: boolean;
  loading: boolean;
  error: string | null;
  scope: PostScope;
  /** postId(字符串) → favoriteId；收藏态判断 + 取消收藏定位 */
  favoriteByPostId: Record<string, number>;
  lastFetched: number | null;

  /** 首屏（重置列表） */
  setPage: (posts: Post[], nextCursor: string | null, hasMore: boolean) => void;
  /** 追加下一页（去重 by id） */
  appendPage: (posts: Post[], nextCursor: string | null, hasMore: boolean) => void;
  setLoading: (loading: boolean) => void;
  setError: (error: string | null) => void;
  setScope: (scope: PostScope) => void;

  /** 记收藏（postId → favoriteId）；null 表示取消 */
  setFavorite: (postId: string, favoriteId: number | null) => void;
  /** 批量载入我的收藏（拉 GET /favorites/?type=post 后铺底） */
  loadFavorites: (favorites: Array<{ id: number; target_id: string }>) => void;
  
  /** WebSocket 实时更新：插入或更新帖子（已存在则更新，不存在则插入到列表头部） */
  upsertPost: (post: Post) => void;
  /** WebSocket 实时更新：从列表中移除帖子 */
  removePost: (postId: number) => void;

  /** 浏览上报成功后批量落地：{post_id → 最新 view_count}，标记已读（is_viewed） */
  markViewedBatch: (updated: Record<string, number>) => void;
  /** WS post.viewed（他人浏览）：只刷新 view_count，不标记本人已读 */
  updatePostViewCount: (postId: number, viewCount: number) => void;

  reset: () => void;
}

export const usePostsStore = create<PostsState>((set) => ({
  posts: [],
  nextCursor: null,
  hasMore: false,
  loading: false,
  error: null,
  scope: "feed",
  favoriteByPostId: {},
  lastFetched: null,

  setPage: (posts, nextCursor, hasMore) =>
    set({ posts, nextCursor, hasMore, loading: false, error: null, lastFetched: Date.now() }),

  appendPage: (posts, nextCursor, hasMore) =>
    set((state) => {
      const seen = new Set(state.posts.map((p) => p.id));
      const merged = [...state.posts, ...posts.filter((p) => !seen.has(p.id))];
      return { posts: merged, nextCursor, hasMore, loading: false, error: null };
    }),

  setLoading: (loading) => set({ loading }),
  setError: (error) => set({ error, loading: false }),
  setScope: (scope) => set({ scope, posts: [], nextCursor: null, hasMore: false }),

  setFavorite: (postId, favoriteId) =>
    set((state) => {
      const next = { ...state.favoriteByPostId };
      if (favoriteId == null) delete next[postId];
      else next[postId] = favoriteId;
      return { favoriteByPostId: next };
    }),

  loadFavorites: (favorites) =>
    set(() => {
      const map: Record<string, number> = {};
      for (const f of favorites) map[f.target_id] = f.id;
      return { favoriteByPostId: map };
    }),

  upsertPost: (post) =>
    set((state) => {
      const seen = new Set(state.posts.map((p) => p.id));
      if (seen.has(post.id)) {
        // 已存在：更新
        return {
          posts: state.posts.map((p) => (p.id === post.id ? post : p)),
        };
      } else {
        // 不存在：插入到列表头部（最新优先）
        return {
          posts: [post, ...state.posts],
        };
      }
    }),

  removePost: (postId) =>
    set((state) => ({
      posts: state.posts.filter((p) => p.id !== postId),
    })),

  markViewedBatch: (updated) =>
    set((state) => {
      const ids = new Set(Object.keys(updated).map(Number));
      if (ids.size === 0) return state;
      return {
        posts: state.posts.map((p) =>
          ids.has(p.id)
            ? { ...p, is_viewed: true, view_count: updated[String(p.id)] ?? p.view_count }
            : p,
        ),
      };
    }),

  updatePostViewCount: (postId, viewCount) =>
    set((state) => ({
      posts: state.posts.map((p) =>
        p.id === postId ? { ...p, view_count: viewCount } : p,
      ),
    })),

  reset: () =>
    set({
      posts: [],
      nextCursor: null,
      hasMore: false,
      loading: false,
      error: null,
      scope: "feed",
      favoriteByPostId: {},
      lastFetched: null,
    }),
}));

/** 判断 posts store 数据是否过期（默认 60 秒） */
export function isPostsStale(maxAgeMs = 60_000): boolean {
  const { lastFetched } = usePostsStore.getState();
  if (!lastFetched) return true;
  return Date.now() - lastFetched > maxAgeMs;
}
