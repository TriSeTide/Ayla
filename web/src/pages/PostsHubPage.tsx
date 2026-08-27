/**
 * PostsHubPage —— 一级帖子 tab 信息流（路由 /posts，F6）。
 *
 * 单列信息流（R-P1）+ 游标分页（滚到底加载更多）；发帖走右下 FAB（CreateFab，
 * 区别于群内帖子界面的输入框发帖，R-P2）；收藏即时反馈（R-P4）。
 * 窄屏带 NarrowTopBar；宽屏内容 max-width 680px 居中（布局文档 §3.1）。
 *
 * 本轮（方案 §4-U2 + §5-A2 + §4-U14 + §3.3）：
 * - U2：>1024px 双列等宽错排瀑布流（useMasonryColumns，ResizeObserver 量高插较矮列），
 *   窄屏单列；
 * - A2：帖子逐条浮入（.reveal-item + staggerDelay）；
 * - U14：返回保留滚动位置（useScrollRestore，恢复路径禁 stagger）；
 * - 3.3：下拉刷新（PullToRefresh）。
 */
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { CSSProperties } from "react";
import { Link, useNavigate } from "react-router-dom";
import * as favoritesApi from "../api/favorites";
import * as postsApi from "../api/posts";
import { PostCard } from "../components/posts/PostCard";
import { PullToRefresh } from "../components/motion/PullToRefresh";
import { useMasonryColumns } from "../hooks/useMasonryColumns";
import { useMediaQuery } from "../hooks/useMediaQuery";
import { staggerDelay } from "../hooks/useRevealOnEnter";
import { saveScrollPosition, useScrollRestore } from "../hooks/useScrollRestore";
import { usePostsStore, isPostsStale } from "../stores/posts";
import { useShellStore } from "../stores/shell";
import { chatWS } from "../ws/chat";

/** 瀑布流断点：>1024px 双列（方案 §4-U2；design.md §9 断点 1024）。 */
const MASONRY_QUERY = "(min-width: 1025px)";

export function PostsHubPage() {
  const navigate = useNavigate();
  const { posts, nextCursor, hasMore, loading, error, favoriteByPostId } = usePostsStore();
  const [loadError, setLoadError] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [favoriteLoadError, setFavoriteLoadError] = useState<string | null>(null);
  // §3.4 刷新动画：刷新完成后递增，key 变化强制帖子流重挂载 → reveal 重播
  const [revealNonce, setRevealNonce] = useState(0);

  const hubRef = useRef<HTMLDivElement>(null);
  // U14：返回保留滚动位置（restoring 时禁 reveal stagger）
  const scrollRestoreKey = "posts-feed";
  const { restoring } = useScrollRestore(scrollRestoreKey, hubRef);
  const isMasonry = useMediaQuery(MASONRY_QUERY);
  const columnCount = isMasonry ? 2 : 1;
  const { columns, columnRefs } = useMasonryColumns(posts, columnCount, (p) => p.id, "posts-feed");

  // stagger 用全局顺序（跨列逐条浮现）；映射 postId → 原始 index
  const indexByKey = useMemo(() => {
    const m = new Map<number, number>();
    posts.forEach((p, i) => m.set(p.id, i));
    return m;
  }, [posts]);

  // 首屏：信息流 + 我的收藏集合
  const loadFirst = useCallback(() => {
    const store = usePostsStore.getState();
    if (store.posts.length > 0 && !isPostsStale() && !store.loading) return;
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
    return chatWS.onFrame((frame) => {
      if (frame.type === "post.deleted") {
        usePostsStore.getState().removePost(Number(frame.post_id));
        return;
      }
      if (frame.type === "post.created") {
        postsApi
          .getPost(Number(frame.post.id))
          .then((post) => usePostsStore.getState().upsertPost(post))
          .catch(() => {
            // 事件只作提示；REST 失败不伪造或插入不完整帖子。
          });
      }
    });
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

  // 下拉刷新/刷新键共用：强制重拉信息流（绕过 isPostsStale 缓存，不设 loading 以免骨架闪现）
  const refresh = useCallback(async () => {
    const store = usePostsStore.getState();
    setLoadError(null);
    try {
      const page = await postsApi.listPosts({ scope: "feed", limit: 20 });
      store.setPage(page.results, page.next_cursor, page.has_more);
      setRevealNonce((n) => n + 1);
    } catch (e) {
      setLoadError(e instanceof Error ? e.message : "加载失败");
    }
  }, []);

  // §3.4 RefreshFAB：注册当前页刷新回调（引用守卫见 HomePage）
  useEffect(() => {
    useShellStore.getState().registerRefresh(refresh);
    return () => {
      if (useShellStore.getState().refreshCallback === refresh) {
        useShellStore.getState().registerRefresh(null);
      }
    };
  }, [refresh]);

  // 下拉刷新仅当滚动容器（.posts-hub）已在顶部时响应
  const isAtTop = useCallback(() => (hubRef.current?.scrollTop ?? 0) <= 0, []);

  // A2：逐条浮入；恢复路径（restoring）禁 stagger（§7：滚动恢复与入场动画互斥）
  const revealItems = !loading && !restoring;

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
    <div className="posts-hub" ref={hubRef} onScroll={(e) => handleScroll(e.currentTarget)}>
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
        <PullToRefresh isAtTop={isAtTop} onRefresh={refresh}>
          <div className={`posts-feed${isMasonry ? " is-masonry" : ""}`} key={revealNonce}>
            {columns.map((colItems, colIdx) => (
              <div key={colIdx} className="posts-masonry-col" ref={columnRefs[colIdx]}>
                {colItems.map((p) => {
                  const delay = revealItems ? staggerDelay(indexByKey.get(p.id) ?? 0) : 0;
                  return (
                    <div
                      key={p.id}
                      className={`posts-feed-item${revealItems ? " reveal-item" : ""}`}
                      style={
                        revealItems
                          ? ({ ["--reveal-delay" as string]: `${delay}ms` } as CSSProperties)
                          : undefined
                      }
                    >
                      <PostCard
                        post={p}
                        favorited={favoriteByPostId[String(p.id)] != null}
                        onOpen={() => {
                          // 详情入口同步保存，避免 AnimatePresence 退出阶段覆盖记录。
                          saveScrollPosition(scrollRestoreKey, hubRef.current);
                          navigate(`/posts/${p.id}`);
                        }}
                        onToggleFavorite={() => void toggleFavorite(p.id)}
                      />
                    </div>
                  );
                })}
              </div>
            ))}
            {hasMore && <div className="home-load-more" aria-label="加载更多"><span className="home-load-dot" /><span className="home-load-dot" /><span className="home-load-dot" /></div>}
          </div>
        </PullToRefresh>
      )}
    </div>
  );
}
