/**
 * PostsHubPage —— 一级帖子 tab 信息流（路由 /posts，F6）。
 *
 * 单列信息流（R-P1）+ 游标分页（滚到底加载更多）；发帖走右下 FAB（CreateFab，
 * 区别于群内帖子界面的输入框发帖，R-P2）；收藏即时反馈（R-P4）。
 * 窄屏带 NarrowTopBar；宽屏内容 max-width 680px 居中（布局文档 §3.1）。
 */
import { useCallback, useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import * as favoritesApi from "../api/favorites";
import * as postsApi from "../api/posts";
import { PostCard } from "../components/posts/PostCard";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { NarrowTopBar } from "../layout/NarrowTopBar";
import { usePostsStore } from "../stores/posts";

export function PostsHubPage() {
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const navigate = useNavigate();
  const { posts, nextCursor, hasMore, loading, error, favoriteByPostId } = usePostsStore();
  const [loadError, setLoadError] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [favoriteLoadError, setFavoriteLoadError] = useState<string | null>(null);

  // 首屏：信息流 + 我的收藏集合
  const loadFirst = useCallback(() => {
    const store = usePostsStore.getState();
    store.setLoading(true);
    store.setError(null);
    setLoadError(null);
    postsApi
      .listPosts({ scope: "feed", limit: 20 })
      .then((page) => {
        store.setPage(page.results, page.next_cursor, page.has_more);
      })
      .catch((e) => {
        store.setError(e instanceof Error ? e.message : "加载失败");
        setLoadError(e instanceof Error ? e.message : "加载失败");
      });
    favoritesApi
      .listFavorites("post")
      .then((list) => {
        store.loadFavorites(list);
        setFavoriteLoadError(null);
      })
      .catch((e) => setFavoriteLoadError(e instanceof Error ? e.message : "加载收藏状态失败"));
  }, []);

  useEffect(() => {
    loadFirst();
  }, [loadFirst]);

  // 滚到底加载更多
  const handleScroll = (el: HTMLElement) => {
    if (!hasMore || loading) return;
    if (el.scrollHeight - el.scrollTop - el.clientHeight < 240) {
      const store = usePostsStore.getState();
      store.setLoading(true);
      postsApi
        .listPosts({ scope: "feed", limit: 20, cursor: nextCursor })
        .then((page) => store.appendPage(page.results, page.next_cursor, page.has_more))
        .catch(() => store.setLoading(false));
    }
  };

  const toggleFavorite = useCallback(
    async (postId: number) => {
      const store = usePostsStore.getState();
      const key = String(postId);
      const favId = store.favoriteByPostId[key];
      try {
        if (favId != null) {
          await favoritesApi.removeFavorite(favId);
          store.setFavorite(key, null);
        } else {
          const fav = await favoritesApi.addFavorite("post", key);
          store.setFavorite(key, fav.id);
        }
      } catch (e) {
        // 保持原态并明确告知失败；不伪造收藏成功。
        setActionError(e instanceof Error ? e.message : "收藏操作失败，请重试");
      }
    },
    [],
  );

  return (
    <div className="posts-hub" onScroll={(e) => handleScroll(e.currentTarget)}>
      {isNarrow && <NarrowTopBar />}
      <div className="posts-hub-head">
        <Link to="/posts/mine" className="btn btn-ghost">我的帖子</Link>
      </div>
      {favoriteLoadError && <div className="chat-notice" role="alert">收藏状态加载失败：{favoriteLoadError}</div>}
      {actionError && <div className="chat-notice" role="alert">{actionError}</div>}
      {loading && posts.length === 0 ? (
        <div className="posts-skeleton">
          <div className="skeleton" style={{ height: 120, marginBottom: 12 }} />
          <div className="skeleton" style={{ height: 120, marginBottom: 12 }} />
          <div className="skeleton" style={{ height: 120 }} />
        </div>
      ) : error && posts.length === 0 ? (
        <div className="home-state" role="alert">
          <p className="placeholder-desc">{loadError ?? error}</p>
          <button type="button" className="btn btn-ghost" onClick={loadFirst}>
            重试
          </button>
        </div>
      ) : posts.length === 0 ? (
        <div className="home-state">
          <h2 className="placeholder-title">还没有帖子</h2>
          <p className="placeholder-desc">点右下角 + 发布第一条帖子</p>
        </div>
      ) : (
        <div className="posts-feed">
          {posts.map((p) => (
            <PostCard
              key={p.id}
              post={p}
              favorited={favoriteByPostId[String(p.id)] != null}
              onOpen={() => navigate(`/posts/${p.id}`)}
              onToggleFavorite={() => void toggleFavorite(p.id)}
            />
          ))}
          {hasMore && <div className="home-load-more" aria-label="加载更多"><span className="home-load-dot" /><span className="home-load-dot" /><span className="home-load-dot" /></div>}
        </div>
      )}
    </div>
  );
}
