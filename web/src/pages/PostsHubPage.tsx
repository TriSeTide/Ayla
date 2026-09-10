/**
 * PostsHubPage —— 一级帖子 tab 信息流（路由 /posts，F6）。
 *
 * 单列信息流（R-P1）+ 游标分页（滚到底加载更多）；发帖走右下 FAB（CreateFab，
 * 区别于群内帖子界面的输入框发帖，R-P2）；收藏即时反馈（R-P4）。
 * 窄屏带 NarrowTopBar；宽屏内容占满侧栏右侧（directory-page 布局）。
 *
 * 分类选项卡（全部/热门/公开/好友/我的）：
 * - 每个 tab 独立数据缓存与分页游标（模块级 Map，账号切换清空），切 tab 自动加载该 tab 第一页；
 * - 「我的」tab 拉 scope=mine（后端过滤），其余 tab 拉 scope=feed 后前端过滤/排序；
 * - 热门按 view_count 降序（唯一排序例外）；好友 = 作者是好友（friendIds），非 visibility=friends；
 * - 各 tab 独立滚动位置（useScrollRestore，scope 含 filter），内容区 key=scope 重挂载。
 *
 * 本轮（方案 §4-U2 + §5-A2 + §4-U14 + §3.3 + 分类选项卡）：
 * - U2：>1024px 双列等宽错排瀑布流（useMasonryColumns，ResizeObserver 量高插较矮列），
 *   窄屏单列；
 * - A2：仅新增DOM帖子逐条浮入（useListEntryMotion）；
 * - U14：返回保留滚动位置（useScrollRestore，恢复路径禁 stagger）；
 * - 3.3：下拉刷新（PullToRefresh）。
 */
import { useCallback, useEffect, useId, useMemo, useRef, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import * as postsApi from "../api/posts";
import type { Post, PostScope } from "../api/types";
import { PostCard } from "../components/posts/PostCard";
import { StablePaginationFooter } from "../components/StablePaginationFooter";
import { PullToRefresh } from "../components/motion/PullToRefresh";
import { useMasonryColumns } from "../hooks/useMasonryColumns";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { useListEntryMotion } from "../hooks/useListEntryMotion";
import { saveScrollPosition, useScrollRestore } from "../hooks/useScrollRestore";
import { useShellStore } from "../stores/shell";
import { usePostViewTracking } from "../hooks/usePostViewTracking";
import { useSocialPage } from "../hooks/useSocialPage";
import { DirectoryFilters } from "../components/DirectoryFilters";
import { IconPost } from "../components/icons";
import { useAuthStore } from "../stores/auth";
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

/** 每个 tab 的后端查询：「我的」独立拉 mine；公开/好友由后端过滤（不依赖「全部」分页进度）；
    热门/全部拉 feed 后前端排序/过滤（热门只排序不筛内容，无"加载不到"问题） */
const TAB_QUERY: Record<PostFilter, { scope: PostScope; visibility?: "public" | "friends" | "group"; friends?: boolean }> = {
  all: { scope: "feed" },
  hot: { scope: "feed" },
  public: { scope: "feed", visibility: "public" },
  friends: { scope: "feed", friends: true },
  mine: { scope: "mine" },
};

type PostTabState = {
  posts: Post[];
  cursor: string | null;
  hasMore: boolean;
  loaded: boolean;
  loading: boolean;
  /** 后端返回的当前 tab 过滤后总数（header 统计用，不随分页进度变化） */
  total: number;
  /** 首屏/刷新错误（列表顶部提示） */
  error: string | null;
  /** 追加错误（分页 footer 提示，滚动不自动重试） */
  nextPageError: string | null;
  updatedAt: number;
};
/** 每 tab 独立分页缓存（模块级，跨挂载保留；账号切换清空） */
const postTabPages = new Map<string, PostTabState>();
let postTabSession = 0;
useAuthStore.subscribe((state, previous) => {
  if (state.currentUser?.id !== previous.currentUser?.id || Boolean(state.accessToken) !== Boolean(previous.accessToken)) {
    postTabSession += 1;
    postTabPages.clear();
  }
});
export function clearPostTabMemory() { postTabPages.clear(); }
function postTabAccount() { return `${useAuthStore.getState().currentUser?.id ?? "anonymous"}:${postTabSession}`; }
const emptyPostTab = (): PostTabState => ({ posts: [], cursor: null, hasMore: false, loaded: false, loading: false, total: 0, error: null, nextPageError: null, updatedAt: 0 });

export function PostsHubPage() {
  const navigate = useNavigate();
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const isMasonry = useMediaQuery(MASONRY_QUERY);
  const selectionId = useId();
  const [params, setParams] = useSearchParams();
  const filter = FILTERS.find((item) => item.key === params.get("type"))?.key ?? "all";
  const account = postTabAccount();
  const scope = `posts:${account}:${filter}`;
  const [state, setState] = useState<PostTabState>(() => {
    const cached = postTabPages.get(scope);
    return cached ? { ...cached, loading: false } : emptyPostTab();
  });
  const stateRef = useRef(state);
  const requestOwner = useRef({ active: false, revision: 0, busy: false, nextFailed: false, deletedIds: new Set<number>() });
  const [resumeEntry, setResumeEntry] = useState(false);
  // §3.4 刷新动画：刷新完成后递增，已入场卡片整批重播浮入（第一页也有动画）
  const [replayNonce, setReplayNonce] = useState(0);
  const hubRef = useRef<HTMLDivElement>(null);
  // 好友 tab：作者是好友（friendIds 集合），不是 visibility=friends 才显示
  const friendsPage = useSocialPage("friends", {});
  const friendIds = useMemo(() => new Set(friendsPage.items.map((f) => f.user.id)), [friendsPage.items]);
  // 视口浏览上报（浏览与已读同源）：进入视口即加浏览，无需点击；
  // onViewed 同步当前 tab 的已读/浏览量（posts store 的 markViewedBatch 由 hook 内部维护，供其它页面共享）
  usePostViewTracking(hubRef, (updated) => {
    update((value) => ({ ...value, posts: value.posts.map((p) =>
      updated[String(p.id)] != null ? { ...p, is_viewed: true, view_count: updated[String(p.id)] } : p) }));
  });
  const scrollRestoreKey = `posts-feed:${filter}`;
  // U14：返回保留滚动位置（restoring 时禁 reveal stagger）
  const { restoring } = useScrollRestore(scrollRestoreKey, hubRef, { ready: state.loaded });
  useListEntryMotion(hubRef, ".posts-feed-item", restoring && !resumeEntry, replayNonce);
  const columnCount = isMasonry ? 2 : 1;
  // 过滤/排序全部前端实现（对已加载数据）：公开/好友/我的按字段过滤；
  // 热门按 view_count 降序（唯一排序例外，其余保持 feed 原顺序）
  const visiblePosts = useMemo(() => {
    if (filter === "hot") return [...state.posts].sort((a, b) => b.view_count - a.view_count);
    if (filter === "public") return state.posts.filter((post) => post.visibility === "public");
    if (filter === "friends") return state.posts.filter((post) => friendIds.has(post.author_id));
    return state.posts;
  }, [state.posts, filter, friendIds]);
  const { columns, columnRefs } = useMasonryColumns(visiblePosts, columnCount, (p) => p.id, `posts-feed:${filter}`);

  const update = useCallback((change: (current: PostTabState) => PostTabState) => {
    const next = change(stateRef.current);
    stateRef.current = next;
    setState(next);
    postTabPages.delete(scope);
    postTabPages.set(scope, { ...next, loading: false });
    while (postTabPages.size > 14) postTabPages.delete(postTabPages.keys().next().value!);
  }, [scope]);

  // 切 tab（scope 变化）：render 期间从缓存恢复/空态，并使旧 tab 的在途请求失效
  const [activeScope, setActiveScope] = useState(scope);
  if (activeScope !== scope) {
    setActiveScope(scope);
    requestOwner.current.revision += 1;
    requestOwner.current.busy = false;
    requestOwner.current.nextFailed = false;
    const cached = postTabPages.get(scope);
    const next = cached ? { ...cached, loading: false } : emptyPostTab();
    stateRef.current = next;
    setState(next);
  }

  // 首页替换拥有新revision；迟到的追加响应不得覆写新首页和游标。
  const requestPage = useCallback(async (kind: "first" | "refresh" | "append") => {
    const owner = requestOwner.current;
    const current = stateRef.current;
    // 只有 append 受 busy 限制；refresh/first 必须能接管在途追加（刷新接管语义）
    if (!owner.active || (kind === "append" && (owner.busy || !current.hasMore))) return;
    const cursor = kind === "append" ? current.cursor : null;
    const knownIds = new Set(current.posts.map((post) => post.id));
    const revision = ++owner.revision;
    owner.busy = true;
    owner.nextFailed = false;
    const isCurrent = () => owner.active && requestOwner.current === owner && owner.revision === revision && postTabAccount() === account;
    update((value) => ({ ...value, loading: true, error: null, nextPageError: null }));
    try {
      // 游标缺失/未推进（防御性检查，正常不触发）：静默降级，不显示错误，
      // 但标记 nextFailed 阻止滚动重复请求相同页
      if (kind === "append" && !cursor) { owner.nextFailed = true; return; }
      const page = await postsApi.listPosts({ ...TAB_QUERY[filter], limit: 20, ...(cursor ? { cursor } : {}) });
      if (!isCurrent()) return;
      if (page.has_more && (!page.next_cursor || page.next_cursor === cursor)) { owner.nextFailed = true; return; }
      const currentPosts = stateRef.current.posts;
      const currentById = new Map(currentPosts.map((post) => [post.id, post]));
      const seen = new Set<number>();
      const incoming: Post[] = [];
      for (const post of page.results) {
        if (seen.has(post.id) || owner.deletedIds.has(post.id)) continue;
        seen.add(post.id);
        const currentPost = currentById.get(post.id);
        incoming.push({
          ...post,
          is_viewed: post.is_viewed || currentPost?.is_viewed || false,
          view_count: Math.max(post.view_count, currentPost?.view_count ?? 0),
        });
      }
      if (kind === "append") {
        update((value) => {
          const seen = new Set(value.posts.map((p) => p.id));
          return { ...value, posts: [...value.posts, ...incoming.filter((p) => !seen.has(p.id))],
            cursor: page.next_cursor, hasMore: page.has_more, loaded: true, total: page.total ?? value.total,
            error: null, nextPageError: null, updatedAt: Date.now() };
        });
      } else {
        // 请求期间新收到的WS帖子保留；已读/浏览状态不能被较早的HTTP快照倒退。
        const realtime = currentPosts.filter((post) => !knownIds.has(post.id) && !seen.has(post.id) && !owner.deletedIds.has(post.id));
        update((value) => ({ ...value, posts: [...realtime, ...incoming], cursor: page.next_cursor,
          hasMore: page.has_more, loaded: true, total: page.total ?? value.total,
          error: null, nextPageError: null, updatedAt: Date.now() }));
      }
      if (kind !== "first") setResumeEntry(true);
    } catch (e) {
      if (!isCurrent()) return;
      const message = e instanceof Error ? e.message : "加载失败";
      if (kind === "append") {
        owner.nextFailed = true;
        update((value) => ({ ...value, nextPageError: message }));
      } else {
        update((value) => ({ ...value, error: message }));
      }
    } finally {
      if (isCurrent()) {
        owner.busy = false;
        update((value) => ({ ...value, loading: false }));
      }
    }
  }, [account, filter, update]);

  // 首屏/切 tab：自动加载该 tab 第一页；详情返回保留已加载页和 cursor（60s 内不重拉）
  const loadFirst = useCallback(() => {
    const owner = requestOwner.current;
    if (!owner.active || owner.busy) return;
    if (stateRef.current.loaded && Date.now() - stateRef.current.updatedAt < 60_000) return;
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
        // 从本账号所有 tab 缓存移除（含当前 tab），避免切回时复活已删帖
        for (const [key, cached] of postTabPages) {
          if (!key.startsWith(`posts:${account}:`)) continue;
          postTabPages.set(key, { ...cached, posts: cached.posts.filter((p) => p.id !== postId) });
        }
        update((value) => ({ ...value, posts: value.posts.filter((p) => p.id !== postId) }));
        return;
      }
      if (frame.type === "post.created") {
        postsApi
          .getPost(Number(frame.post.id))
          .then((post) => {
            if (owner.active && !owner.deletedIds.has(post.id)) {
              update((value) => ({
                ...value,
                posts: value.posts.some((p) => p.id === post.id)
                  ? value.posts.map((p) => (p.id === post.id ? post : p))
                  : [post, ...value.posts],
              }));
            }
          })
          .catch(() => {
            // 事件只作提示；REST 失败不伪造或插入不完整帖子。
          });
      }
    });
    return () => {
      owner.active = false;
      owner.revision += 1;
      owner.busy = false;
      unsubscribe();
    };
  }, [account, loadFirst, update]);

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
            <span className="directory-filter-stats">{state.loaded ? `${state.total} 条帖子` : "… 条帖子"}</span>
          </div>} />
        <div key={scrollRestoreKey} className="directory-content posts-content" ref={hubRef}
          id={`${selectionId}-panel`} role="tabpanel" aria-labelledby={`${selectionId}-${filter}`} tabIndex={0}
          onScroll={(e) => handleScroll(e.currentTarget)}>
          {state.error && state.posts.length > 0 && <div className="chat-notice" role="alert">{state.error}</div>}
          {state.loading && state.posts.length === 0 ? (
            <div className="posts-skeleton">
              <div className="skeleton" style={{ height: 120, marginBottom: 12 }} />
              <div className="skeleton" style={{ height: 120, marginBottom: 12 }} />
              <div className="skeleton" style={{ height: 120 }} />
            </div>
          ) : state.error && state.posts.length === 0 ? (
            <div className="home-state" role="alert">
              <p className="placeholder-desc">{state.error}</p>
              <button type="button" className="btn btn-ghost" onClick={loadFirst}>
                重试
              </button>
            </div>
          ) : state.posts.length === 0 ? (
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
                  <StablePaginationFooter className="home-load-more" aria-hidden={!state.hasMore && !state.loading}>
                    {state.hasMore && <>
                      {state.nextPageError && <span role="alert">{state.nextPageError}</span>}
                      {state.loading ? (
                        <span className="pagination-loading-dots" role="status" aria-label="加载更多"><span className="home-load-dot" /><span className="home-load-dot" /><span className="home-load-dot" /></span>
                      ) : (
                        <button type="button" className="btn btn-ghost" onClick={() => void requestPage("append")}>
                          {state.nextPageError ? "重试加载更多" : "加载更多"}
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
