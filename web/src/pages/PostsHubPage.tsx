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
 * - A2：仅新增DOM帖子逐条浮入（useListEntryMotion）；
 * - U14：返回保留滚动位置（useScrollRestore，恢复路径禁 stagger）；
 * - 3.3：下拉刷新（PullToRefresh）。
 */
import { useCallback, useEffect, useId, useMemo, useRef, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import * as postsApi from "../api/posts";
import type { Post } from "../api/types";
import { PostCard } from "../components/posts/PostCard";
import { StablePaginationFooter } from "../components/StablePaginationFooter";
import { PullToRefresh } from "../components/motion/PullToRefresh";
import { useMasonryColumns } from "../hooks/useMasonryColumns";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { useListEntryMotion } from "../hooks/useListEntryMotion";
import { saveScrollPosition, useScrollRestore } from "../hooks/useScrollRestore";
import { usePostsStore, isPostsStale } from "../stores/posts";
import { useShellStore } from "../stores/shell";
import { usePostViewTracking } from "../hooks/usePostViewTracking";
import { DirectoryFilters } from "../components/DirectoryFilters";
import { IconPost } from "../components/icons";
import { chatWS } from "../ws/chat";

/** 瀑布流断点：>1024px 双列（方案 §4-U2；design.md §9 断点 1024）。 */
const MASONRY_QUERY = "(min-width: 1025px)";

type PostFilter = "all" | "hot" | "public" | "friends" | "mine";
const FILTERS: ReadonlyArray<{ key: PostFilter; label: string }> = [
  { key: "all", label: "全部" },
  { key: "hot", label: "热门" },
  { key: "public", label: "公开" },
  { key: "friends", label: "好友" },
  { key: "mine", label: "我的" },
];

export function PostsHubPage() {
  const navigate = useNavigate();
  const { posts, hasMore, loading, error } = usePostsStore();
  const [loadError, setLoadError] = useState<string | null>(null);
  const [nextPageError, setNextPageError] = useState<string | null>(null);
  const [resumeEntry, setResumeEntry] = useState(false);
  // §3.4 刷新动画：刷新完成后递增，已入场卡片整批重播浮入（第一页也有动画）
  const [replayNonce, setReplayNonce] = useState(0);
  const requestOwner = useRef({ active: false, revision: 0, busy: false, nextFailed: false, deletedIds: new Set<number>() });

  const hubRef = useRef<HTMLDivElement>(null);
  // 视口浏览上报（浏览与已读同源）：进入视口即加浏览，无需点击
  usePostViewTracking(hubRef);
  // 分类选项卡：URL ?type= 驱动（与收藏/搜索一致），各 tab 独立滚动位置
  const selectionId = useId();
  const [params, setParams] = useSearchParams();
  const filter = FILTERS.find((item) => item.key === params.get("type"))?.key ?? "all";
  const scrollRestoreKey = `posts-feed:${filter}`;
  // U14：返回保留滚动位置（restoring 时禁 reveal stagger）
  const { restoring } = useScrollRestore(scrollRestoreKey, hubRef, { ready: posts.length > 0 || !loading });
  useListEntryMotion(hubRef, ".posts-feed-item", restoring && !resumeEntry, replayNonce);
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const isMasonry = useMediaQuery(MASONRY_QUERY);
  const columnCount = isMasonry ? 2 : 1;
  // 过滤/排序全部前端实现（对已加载数据）：公开/好友/我的按字段过滤；
  // 热门按 view_count 降序（唯一排序例外，其余保持 feed 原顺序）
  const visiblePosts = useMemo(() => {
    if (filter === "hot") return [...posts].sort((a, b) => b.view_count - a.view_count);
    if (filter === "public") return posts.filter((post) => post.visibility === "public");
    if (filter === "friends") return posts.filter((post) => post.visibility === "friends");
    if (filter === "mine") return posts.filter((post) => post.is_author);
    return posts;
  }, [posts, filter]);
  const { columns, columnRefs } = useMasonryColumns(visiblePosts, columnCount, (p) => p.id, `posts-feed:${filter}`);

  // 首页替换拥有新revision；迟到的追加响应不得覆写新首页和游标。
  const requestPage = useCallback(async (kind: "first" | "refresh" | "append") => {
    const owner = requestOwner.current;
    const store = usePostsStore.getState();
    if (!owner.active || (kind === "append" && (owner.busy || !store.hasMore))) return;
    const cursor = kind === "append" ? store.nextCursor : null;
    const knownIds = new Set(store.posts.map((post) => post.id));
    const revision = ++owner.revision;
    owner.busy = true;
    owner.nextFailed = false;
    store.setError(null);
    store.setLoading(true);
    setLoadError(null);
    setNextPageError(null);
    const isCurrent = () => owner.active && requestOwner.current === owner && owner.revision === revision;
    try {
      // 游标缺失/未推进（防御性检查，正常不触发）：静默降级，不显示错误，
      // 但标记 nextFailed 阻止滚动重复请求相同页
      if (kind === "append" && !cursor) { owner.nextFailed = true; return; }
      const page = await postsApi.listPosts({ scope: "feed", limit: 20, ...(cursor ? { cursor } : {}) });
      if (!isCurrent()) return;
      if (page.has_more && (!page.next_cursor || page.next_cursor === cursor)) { owner.nextFailed = true; return; }
      const currentPosts = usePostsStore.getState().posts;
      const currentById = new Map(currentPosts.map((post) => [post.id, post]));
      const seen = new Set<number>();
      const incoming: Post[] = [];
      for (const post of page.results) {
        if (seen.has(post.id) || owner.deletedIds.has(post.id)) continue;
        seen.add(post.id);
        const current = currentById.get(post.id);
        incoming.push({
          ...post,
          is_viewed: post.is_viewed || current?.is_viewed || false,
          view_count: Math.max(post.view_count, current?.view_count ?? 0),
        });
      }
      if (kind === "append") {
        store.appendPage(incoming, page.next_cursor, page.has_more);
      } else {
        // 请求期间新收到的WS帖子保留；已读/浏览状态不能被较早的HTTP快照倒退。
        const realtime = currentPosts.filter((post) => !knownIds.has(post.id) && !seen.has(post.id) && !owner.deletedIds.has(post.id));
        store.setPage([...realtime, ...incoming], page.next_cursor, page.has_more);
      }
      if (kind !== "first") setResumeEntry(true);
    } catch (e) {
      if (!isCurrent()) return;
      const message = e instanceof Error ? e.message : "加载失败";
      if (kind === "append") {
        owner.nextFailed = true;
        setNextPageError(message);
      } else {
        setLoadError(message);
        store.setError(message);
      }
    } finally {
      if (isCurrent()) {
        owner.busy = false;
        store.setLoading(false);
      }
    }
  }, []);

  // 首屏信息流；详情返回保留已加载页和 cursor。收藏由可见卡片按 ID 查询。
  const loadFirst = useCallback(() => {
    const owner = requestOwner.current;
    const store = usePostsStore.getState();
    if (!owner.active || owner.busy) return;
    if (store.posts.length > 0 && !isPostsStale()) return;
    void requestPage("first");
  }, [requestPage]);

  useEffect(() => {
    const owner = requestOwner.current;
    owner.active = true;
    loadFirst();
    const unsubscribe = chatWS.onFrame((frame) => {
      if (!owner.active) return;
      if (frame.type === "post.deleted") {
        const postId = Number(frame.post_id);
        owner.deletedIds.add(postId);
        usePostsStore.getState().removePost(postId);
        return;
      }
      if (frame.type === "post.created") {
        postsApi
          .getPost(Number(frame.post.id))
          .then((post) => {
            if (owner.active && !owner.deletedIds.has(post.id)) usePostsStore.getState().upsertPost(post);
          })
          .catch(() => {
            // 事件只作提示；REST 失败不伪造或插入不完整帖子。
          });
      }
    });
    return () => {
      owner.active = false;
      owner.revision += 1;
      if (owner.busy) usePostsStore.getState().setLoading(false);
      owner.busy = false;
      unsubscribe();
    };
  }, [loadFirst]);

  // 滚到底加载更多
  const handleScroll = (el: HTMLElement) => {
    if (requestOwner.current.nextFailed) return;
    if (el.scrollHeight > el.clientHeight && el.scrollHeight - el.scrollTop - el.clientHeight < 240) {
      void requestPage("append");
    }
  };

  // 刷新保留现有卡片；新revision使此前追加失效，失败仍可继续原cursor。
  // 刷新完成后递增 replayNonce，让已入场卡片整批重播浮入（第一页也有动画）。
  const refresh = useCallback(async () => {
    await requestPage("refresh");
    setReplayNonce((n) => n + 1);
  }, [requestPage]);

  // §3.4 RefreshFAB：注册当前页刷新回调（引用守卫见 HomePage）
  useEffect(() => {
    useShellStore.getState().registerRefresh(refresh);
    return () => {
      if (useShellStore.getState().refreshCallback === refresh) {
        useShellStore.getState().registerRefresh(null);
      }
    };
  }, [refresh]);

  // 下拉刷新仅当滚动容器（.directory-content）已在顶部时响应
  const isAtTop = useCallback(() => (hubRef.current?.scrollTop ?? 0) <= 0, []);

  return (
    <div className="posts-hub directory-page">
      <div className="directory-body">
        <DirectoryFilters id={selectionId} label="帖子分类" options={FILTERS} value={filter} narrow={isNarrow}
          className="posts-filters" buttonClassName="posts-filter"
          onChange={(next) => {
            saveScrollPosition(scrollRestoreKey, hubRef.current);
            setParams(next === "all" ? {} : { type: next }, { replace: true });
          }}
          decor={<IconPost width={64} height={64} className="directory-filter-decor posts-filter-decor" role="presentation" aria-hidden="true" />}
          header={<div className="directory-filter-header">
            <span className="directory-filter-kicker">Posts</span>
            <span className="directory-filter-title">帖子</span>
            {posts.length > 0 && <span className="directory-filter-stats">{posts.length} 条帖子</span>}
          </div>} />
        <div key={scrollRestoreKey} className="directory-content posts-content" ref={hubRef}
          id={`${selectionId}-panel`} role="tabpanel" aria-labelledby={`${selectionId}-${filter}`} tabIndex={0}
          onScroll={(e) => handleScroll(e.currentTarget)}>
          {loadError && posts.length > 0 && <div className="chat-notice" role="alert">{loadError}</div>}
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
              {visiblePosts.length === 0 && filter !== "all" ? (
                <div className="home-state">
                  <h2 className="placeholder-title">这个分类还没有帖子</h2>
                  <p className="placeholder-desc">换个分类看看</p>
                </div>
              ) : (
                <div className={`posts-feed${isMasonry ? " is-masonry" : ""}`}>
                  {columns.map((colItems, colIdx) => (
                    <div key={colIdx} className="posts-masonry-col" ref={columnRefs[colIdx]}>
                      {colItems.map((p) => {
                        return (
                          <div
                            key={p.id}
                            data-post-id={p.id}
                            className="posts-feed-item"
                          >
                            <PostCard
                              post={p}
                              onOpen={() => {
                                // 详情入口同步保存，避免 AnimatePresence 退出阶段覆盖记录。
                                saveScrollPosition(scrollRestoreKey, hubRef.current);
                                navigate(`/posts/${p.id}`);
                              }}
                            />
                          </div>
                        );
                      })}
                    </div>
                  ))}
                  <StablePaginationFooter className="home-load-more" aria-hidden={!hasMore && !loading}>
                    {hasMore && <>
                      {nextPageError && <span role="alert">{nextPageError}</span>}
                      {loading ? (
                        <span className="pagination-loading-dots" role="status" aria-label="加载更多"><span className="home-load-dot" /><span className="home-load-dot" /><span className="home-load-dot" /></span>
                      ) : (
                        <button type="button" className="btn btn-ghost" onClick={() => void requestPage("append")}>
                          {nextPageError ? "重试加载更多" : "加载更多"}
                        </button>
                      )}
                    </>}
                  </StablePaginationFooter>
                </div>
              )}
            </PullToRefresh>
          )}
        </div>
      </div>
    </div>
  );
}
