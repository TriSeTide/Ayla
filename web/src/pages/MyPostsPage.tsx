import { useCallback, useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import * as favoritesApi from "../api/favorites";
import * as postsApi from "../api/posts";
import type { Post } from "../api/types";
import { IconBack } from "../components/icons";
import { PostCard } from "../components/posts/PostCard";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { NarrowTopBar } from "../layout/NarrowTopBar";

export function MyPostsPage() {
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const navigate = useNavigate();
  const [posts, setPosts] = useState<Post[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [hasMore, setHasMore] = useState(false);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [favorites, setFavorites] = useState<Record<string, number>>({});

  const load = useCallback(async (nextCursor: string | null = null) => {
    const append = nextCursor !== null;
    if (append) setLoadingMore(true); else setLoading(true);
    setError(null);
    try {
      const page = await postsApi.listPosts({ scope: "mine", cursor: nextCursor, limit: 20 });
      setPosts((current) => append ? [...current, ...page.results] : page.results);
      setCursor(page.next_cursor);
      setHasMore(page.has_more);
    } catch (e) {
      setError(e instanceof Error ? e.message : "我的帖子加载失败");
    } finally {
      setLoading(false);
      setLoadingMore(false);
    }
  }, []);

  useEffect(() => {
    void load();
    favoritesApi.listFavorites("post").then((items) => {
      setFavorites(Object.fromEntries(items.map((item) => [String(item.target_id), item.id])));
    }).catch((e) => setActionError(e instanceof Error ? e.message : "收藏状态加载失败"));
  }, [load]);

  const toggleFavorite = async (postId: number) => {
    const key = String(postId);
    try {
      if (favorites[key] != null) {
        await favoritesApi.removeFavorite(favorites[key]);
        setFavorites((current) => { const next = { ...current }; delete next[key]; return next; });
      } else {
        const favorite = await favoritesApi.addFavorite("post", key);
        setFavorites((current) => ({ ...current, [key]: favorite.id }));
      }
    } catch (e) {
      setActionError(e instanceof Error ? e.message : "收藏操作失败");
    }
  };

  return (
    <div className="posts-hub my-posts-page" onScroll={(event) => {
      const el = event.currentTarget;
      if (hasMore && !loadingMore && el.scrollHeight - el.scrollTop - el.clientHeight < 240) void load(cursor);
    }}>
      {isNarrow && <NarrowTopBar />}
      <header className="my-posts-head">
        <button type="button" className="icon-btn-40" onClick={() => navigate(-1)} aria-label="返回">
          <IconBack width={20} height={20} />
        </button>
        <h1 className="placeholder-title">我的帖子</h1>
      </header>
      {actionError && <div className="chat-notice" role="alert">{actionError}</div>}
      {loading ? <div className="posts-skeleton"><div className="skeleton" style={{ height: 120 }} /><div className="skeleton" style={{ height: 120 }} /></div> : error && posts.length === 0 ? (
        <div className="home-state" role="alert"><p className="placeholder-desc">{error}</p><button type="button" className="btn btn-ghost" onClick={() => void load()}>重试</button></div>
      ) : posts.length === 0 ? <div className="home-state"><h2 className="placeholder-title">还没有帖子</h2><p className="placeholder-desc">发布的帖子会显示在这里</p></div> : (
        <div className="posts-feed">
          {posts.map((post) => <PostCard key={post.id} post={post} favorited={favorites[String(post.id)] != null} onOpen={() => navigate(`/posts/${post.id}`)} onToggleFavorite={() => void toggleFavorite(post.id)} />)}
          {loadingMore && <div className="home-load-more" role="status">加载更多…</div>}
        </div>
      )}
    </div>
  );
}

export default MyPostsPage;
