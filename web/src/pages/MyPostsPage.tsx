import { useCallback, useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useIsPresent } from "framer-motion";
import * as postsApi from "../api/posts";
import { getUserDetail } from "../api/users";
import type { Post } from "../api/types";
import { IconBack } from "../components/icons";
import { PostCard } from "../components/posts/PostCard";
import { FullScreenSwipeBack } from "../components/motion/FullScreenSwipeBack";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { useMasonryColumns } from "../hooks/useMasonryColumns";
import { usePostViewTracking } from "../hooks/usePostViewTracking";
import { useListEntryMotion } from "../hooks/useListEntryMotion";
import { saveScrollPosition, useScrollRestore } from "../hooks/useScrollRestore";
import { useAuthStore } from "../stores/auth";

/** 瀑布流断点与一级帖子流保持一致：>1024px 双列。 */
const MASONRY_QUERY = "(min-width: 1025px)";

interface MyPostsSnapshot {
  posts: Post[];
  cursor: string | null;
  hasMore: boolean;
}

/**
 * 仅保存当前浏览目标的 UI 分页投影；权威数据仍来自 posts API。
 * 返回详情时用它保留已加载页，避免滚动位置在短首屏列表上被浏览器裁剪。
 * 按 ownerId 隔离：自己的帖子（/posts/mine）与别人的帖子（/user/:id/posts）互不复用。
 */
const myPostsMemory = new Map<string, MyPostsSnapshot>();

/** 测试用：清空分页投影缓存（与 users.ts _clearUserCache 同模式） */
export function _clearMyPostsMemory(): void {
  myPostsMemory.clear();
}

/**
 * 帖子界面（支持本人与别人两种模式）。
 *
 * - mine（ownerId === 当前用户）：scope=mine，标题「我的帖子」；
 * - other（ownerId 为他人）：owner=<id> 过滤（后端要求对方开启 show_content，
 *   路由层 UserPostsRoute 已做守卫），标题「xx的帖子」。
 */
export function MyPostsPage({ ownerId }: { ownerId: string }) {
  const navigate = useNavigate();
  const present = useIsPresent();
  const currentUserId = useAuthStore((state) => state.currentUser?.id ?? null);
  const mine = currentUserId != null && String(currentUserId) === String(ownerId);
  // 他人模式：拉公开资料拿昵称做标题（守卫已在路由层确认 show_content）
  const [ownerName, setOwnerName] = useState<string | null>(null);
  const initialSnapshot = myPostsMemory.get(ownerId);
  const [posts, setPosts] = useState<Post[]>(() => initialSnapshot?.posts ?? []);
  const [cursor, setCursor] = useState<string | null>(() => initialSnapshot?.cursor ?? null);
  const [hasMore, setHasMore] = useState(() => initialSnapshot?.hasMore ?? false);
  const [loading, setLoading] = useState(() => initialSnapshot == null);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [resumeEntry, setResumeEntry] = useState(false);
  const initializedForOwnerRef = useRef(ownerId);
  const hadInitialSnapshotRef = useRef(initialSnapshot != null);
  const activeRef = useRef(false);
  const busyRef = useRef(false);
  const requestRevisionRef = useRef(0);
  const hubRef = useRef<HTMLDivElement>(null);
  // 视口浏览上报（浏览与已读同源）：自己的帖子后端不计浏览，上报幂等无害；
  // 别人的帖子界面正常计入浏览。
  usePostViewTracking(hubRef);
  // 浏览目标刚切换而本地分页状态尚未换好时，不渲染/恢复上一目标的投影；
  // 但瀑布流可读取目标用户既有快照，避免过渡帧清空其列分配记忆。
  const userStateReady = initializedForOwnerRef.current === ownerId;
  const visiblePosts = userStateReady ? posts : initialSnapshot?.posts ?? [];
  // 与页面快照同样按 owner 隔离，切换账号/目标不会复用别人的滚动位置或瀑布流列分配。
  const scrollRestoreKey = `user-posts:${ownerId}`;
  const { restoring } = useScrollRestore(scrollRestoreKey, hubRef, {
    active: present && userStateReady,
    ready: userStateReady && visiblePosts.length > 0,
  });
  const isMasonry = useMediaQuery(MASONRY_QUERY);
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const columnCount = isMasonry ? 2 : 1;
  const { columns, columnRefs } = useMasonryColumns(visiblePosts, columnCount, (post) => post.id, scrollRestoreKey);
  // 已恢复的 DOM 不重播；再次翻页时只动画新追加的卡片。
  useListEntryMotion(hubRef, ".posts-feed-item", restoring && !resumeEntry);

  const load = useCallback(async (nextCursor: string | null = null) => {
    if (!activeRef.current || busyRef.current) return;
    busyRef.current = true;
    const revision = ++requestRevisionRef.current;
    const requestedForOwner = ownerId;
    const ownsRequest = () => activeRef.current && revision === requestRevisionRef.current
      && (useAuthStore.getState().currentUser?.id ?? null) != null;
    const append = nextCursor !== null;
    if (append) setLoadingMore(true); else setLoading(true);
    setError(null);
    try {
      const page = await postsApi.listPosts(
        mine
          ? { scope: "mine", cursor: nextCursor, limit: 20 }
          : { owner: ownerId, cursor: nextCursor, limit: 20 },
      );
      // 浏览目标切换后丢弃旧请求的结果，不能把 A 的页面投影落到 B 的视图。
      if (!ownsRequest() || requestedForOwner !== ownerId) return;
      if (append) setResumeEntry(true);
      setPosts((current) => {
        const seen = new Set(current.map((post) => post.id));
        const nextPosts = append
          ? [...current, ...page.results.filter((post) => !seen.has(post.id))]
          : page.results;
        myPostsMemory.set(ownerId, {
          posts: nextPosts,
          cursor: page.next_cursor,
          hasMore: page.has_more,
        });
        return nextPosts;
      });
      setCursor(page.next_cursor);
      setHasMore(page.has_more);
    } catch (e) {
      if (ownsRequest() && requestedForOwner === ownerId) {
        setError(e instanceof Error ? e.message : "帖子加载失败");
      }
    } finally {
      if (ownsRequest() && requestedForOwner === ownerId) {
        busyRef.current = false;
        setLoading(false);
        setLoadingMore(false);
      }
    }
  }, [mine, ownerId]);

  useEffect(() => {
    activeRef.current = true;
    busyRef.current = false;
    if (initializedForOwnerRef.current !== ownerId) {
      initializedForOwnerRef.current = ownerId;
      const snapshot = myPostsMemory.get(ownerId);
      hadInitialSnapshotRef.current = snapshot != null;
      setPosts(snapshot?.posts ?? []);
      setCursor(snapshot?.cursor ?? null);
      setHasMore(snapshot?.hasMore ?? false);
      setError(null);
      setResumeEntry(false);
      setLoadingMore(false);
      setLoading(snapshot == null);
    }
    if (!hadInitialSnapshotRef.current) void load();
    return () => {
      activeRef.current = false;
      busyRef.current = false;
      requestRevisionRef.current += 1;
    };
  }, [ownerId, load]);

  // 他人模式：拉昵称做标题（守卫已在路由层确认 show_content）
  useEffect(() => {
    if (mine) { setOwnerName(null); return; }
    let cancelled = false;
    setOwnerName(null);
    getUserDetail(ownerId)
      .then((u) => { if (!cancelled) setOwnerName(u.nickname || u.username); })
      .catch(() => { if (!cancelled) setOwnerName(null); });
    return () => { cancelled = true; };
  }, [mine, ownerId]);

  const title = mine ? "我的帖子" : ownerName ? `${ownerName}的帖子` : "帖子";

  return (
    <FullScreenSwipeBack onBack={() => navigate(-1)} enabled={isNarrow}>
      <div
        className="posts-hub my-posts-page"
        ref={hubRef}
        onScroll={(event) => {
          const el = event.currentTarget;
          if (present && userStateReady && hasMore && cursor !== null && !loading && !loadingMore && !error && el.scrollHeight - el.scrollTop - el.clientHeight < 240) {
            void load(cursor);
          }
        }}
      >
      <header className="my-posts-head">
        <button type="button" className="icon-btn-40" onClick={() => navigate(-1)} aria-label="返回">
          <IconBack width={20} height={20} />
        </button>
        <h1 className="placeholder-title">{title}</h1>
      </header>
      {!userStateReady || loading ? <div className="posts-skeleton"><div className="skeleton" style={{ height: 120 }} /><div className="skeleton" style={{ height: 120 }} /></div> : error && visiblePosts.length === 0 ? (
        <div className="home-state" role="alert"><p className="placeholder-desc">{error}</p><button type="button" className="btn btn-ghost" onClick={() => void load()}>重试</button></div>
      ) : visiblePosts.length === 0 ? <div className="home-state"><h2 className="placeholder-title">{mine ? "还没有帖子" : "暂无帖子"}</h2><p className="placeholder-desc">{mine ? "发布的帖子会显示在这里" : "对方还没有发布帖子"}</p></div> : (
        <div className={`posts-feed${isMasonry ? " is-masonry" : ""}`}>
          {columns.map((columnPosts, columnIndex) => (
            <div key={columnIndex} className="posts-masonry-col" ref={columnRefs[columnIndex]}>
              {columnPosts.map((post) => {
                return (
                  <div
                    key={post.id}
                    data-post-id={post.id}
                    className="posts-feed-item"
                  >
                    <PostCard
                      post={post}
                      onOpen={() => {
                        saveScrollPosition(scrollRestoreKey, hubRef.current);
                        navigate(`/posts/${post.id}?from=${mine ? "mine" : "user"}`);
                      }}
                    />
                  </div>
                );
              })}
            </div>
          ))}
        </div>
      )}
      {userStateReady && !loading && visiblePosts.length > 0 && (
        <div className="home-load-more" aria-live="polite">
          {loadingMore ? <span role="status">正在加载更多帖子…</span> : error ? (
            <div role="alert"><p>{error}</p><button type="button" className="btn btn-ghost" onClick={() => void load(cursor)}>重试加载更多帖子</button></div>
          ) : hasMore ? (
            <button type="button" className="btn btn-ghost" onClick={() => void load(cursor)}>加载更多帖子</button>
          ) : <span>已加载全部帖子</span>}
        </div>
      )}
      </div>
    </FullScreenSwipeBack>
  );
}

export default MyPostsPage;
