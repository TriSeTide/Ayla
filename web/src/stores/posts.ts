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

  setPage: (posts, nextCursor, hasMore) =>
    set({ posts, nextCursor, hasMore, loading: false, error: null }),

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

  reset: () =>
    set({
      posts: [],
      nextCursor: null,
      hasMore: false,
      loading: false,
      error: null,
      scope: "feed",
      favoriteByPostId: {},
    }),
}));
