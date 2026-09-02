/**
 * GroupPosts —— 群内帖子子界面（F6，R-G5/R-G8 帖子）。
 *
 * 该群帖子信息流 + **底部输入框发帖**（区别于一级 tab 的 FAB 发帖，R-P2）。
 *
 * 加载策略（避免"空白加载"，对齐 GroupLive/GroupVoice 的 store 投影模式）：
 * - posts store 里存的是**全量可见**列表（后端 scope=feed 即 visible_queryset，
 *   已含公开 + 我所在群的群帖 + 好友帖），登录时已预加载；
 * - 因此切到群内帖子时，先从 store 按当前 groupId **前端投影**出该群帖子 → 立即渲染（秒开）；
 * - 同时后台 `load()` 拉完整 `scope=group:<id>` 补齐 store 投影可能缺失的条目，
 *   用**并集按 id 去重**的方式合并展示，既秒开又完整。
 */
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { CSSProperties } from "react";
import { Link, useNavigate } from "react-router-dom";
import { PostDetailPage } from "../PostDetailPage";
import * as postsApi from "../../api/posts";
import * as favoritesApi from "../../api/favorites";
import type { Post } from "../../api/types";
import { PostCard } from "../../components/posts/PostCard";
import { PostEditor } from "../../components/posts/PostEditor";
import { PullToRefresh } from "../../components/motion/PullToRefresh";
import { useMasonryColumns } from "../../hooks/useMasonryColumns";
import { useMediaQuery } from "../../hooks/useMediaQuery";
import { usePostViewTracking } from "../../hooks/usePostViewTracking";
import { staggerDelay } from "../../hooks/useRevealOnEnter";
import { saveScrollPosition, useScrollRestore } from "../../hooks/useScrollRestore";
import { usePostsStore } from "../../stores/posts";
import { useChatStore } from "../../stores/chat";
import { useAuthStore } from "../../stores/auth";
import { useShellStore } from "../../stores/shell";
import { chatWS } from "../../ws/chat";

/** 瀑布流断点与一级帖子流保持一致：>1024px 双列。 */
const MASONRY_QUERY = "(min-width: 1025px)";
/** 进入群内帖子时，为覆盖全部未读最多连续拉取的页数（防极端数据拖垮首屏） */
const MAX_UNREAD_LOAD_PAGES = 10;

export function GroupPosts({
  groupId,
  onExit,
  postId,
}: {
  groupId: string;
  onExit: () => void;
  /** 群内详情路由参数；存在时保留 GroupPage 外壳渲染详情 */
  postId?: string;
}) {
  const navigate = useNavigate();
  // store 全量可见列表 → 当前群前端投影（登录预加载后通常已就绪，秒开关键）
  const feedPosts = usePostsStore((s) => s.posts);
  // 帖子收藏态（postId → favoriteId），与一级帖子流/详情页共享同一 store
  const favoriteByPostId = usePostsStore((s) => s.favoriteByPostId);
  const groupedFromStore = useMemo(
    () =>
      feedPosts.filter((p) =>
        (p.allowed_group_ids ?? []).some((g) => String(g) === String(groupId)),
      ),
    [feedPosts, groupId],
  );
  // 完整 group scope 数据（后台补齐）
  const [groupPosts, setGroupPosts] = useState<Post[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  // 收藏操作失败提示（与列表加载 error 分离，列表有数据时也能看到）
  const [actionError, setActionError] = useState<string | null>(null);
  // 发帖编辑器展开态：驱动上方遮罩（与输入面板平级，z 夹在列表与面板之间）
  const [editorExpanded, setEditorExpanded] = useState(false);
  const listRef = useRef<HTMLDivElement>(null);
  const scrollRestoreKey = `group-posts:${groupId}`;
  // 同组件详情往返会先渲染列表、再由恢复 hook 的 layout effect 标记 restoring；
  // 单独记住本次详情返回，确保该首帧也不挂 stagger。
  const [skipRevealRestoreKey, setSkipRevealRestoreKey] = useState<string | null>(null);
  // 历史位置恢复后仍可由用户主动刷新重新触发浮入。
  const [revealAfterRefresh, setRevealAfterRefresh] = useState(false);
  // §3.4 刷新动画：刷新完成后递增，key 变化强制帖子列表重挂载 → reveal 重播
  const [revealNonce, setRevealNonce] = useState(0);

  const load = useCallback(async () => {
    setError(null);
    // 目标未读数：会话列表权威值；进入列表时连续拉页直到覆盖全部未读
    // （未读帖子都是最新帖，按时间倒序集中在列表头部，通常 1 页即覆盖）。
    const targetUnread =
      useChatStore
        .getState()
        .conversations.find((c) => c.id === groupId)?.post_unread_count ?? 0;
    let cursor: string | null = null;
    let acc: Post[] = [];
    let hasMore = true;
    let pages = 0;
    while (hasMore && pages < MAX_UNREAD_LOAD_PAGES) {
      const page = await postsApi.listPosts({
        scope: `group:${groupId}`,
        limit: 20,
        cursor,
      });
      acc = [...acc, ...page.results];
      hasMore = page.has_more;
      cursor = page.next_cursor;
      pages += 1;
      const loadedUnread = acc.filter((p) => !p.is_viewed).length;
      if (loadedUnread >= targetUnread) break;
    }
    setGroupPosts(acc);
    setLoading(false);
  }, [groupId]);

  // 上拉刷新/刷新键共用：强制重拉群内帖子（group scope，同样覆盖未读）
  const refresh = useCallback(async () => {
    setError(null);
    try {
      let cursor: string | null = null;
      let acc: Post[] = [];
      let hasMore = true;
      let pages = 0;
      while (hasMore && pages < MAX_UNREAD_LOAD_PAGES) {
        const page = await postsApi.listPosts({
          scope: `group:${groupId}`,
          limit: 20,
          cursor,
        });
        acc = [...acc, ...page.results];
        hasMore = page.has_more;
        cursor = page.next_cursor;
        pages += 1;
        const loadedUnread = acc.filter((p) => !p.is_viewed).length;
        if (loadedUnread >= (useChatStore.getState().conversations.find((c) => c.id === groupId)?.post_unread_count ?? 0)) break;
      }
      setGroupPosts(acc);
      setSkipRevealRestoreKey(null);
      setRevealAfterRefresh(true);
      setRevealNonce((n) => n + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : "加载群内帖子失败");
    }
  }, [groupId]);

  // §3.4 RefreshFAB：注册当前页刷新回调（引用守卫见 HomePage）
  useEffect(() => {
    useShellStore.getState().registerRefresh(refresh);
    return () => {
      if (useShellStore.getState().refreshCallback === refresh) {
        useShellStore.getState().registerRefresh(null);
      }
    };
  }, [refresh]);

  // 上拉刷新仅当滚动容器（.group-posts-list）已在顶部时响应
  const isAtTop = useCallback(() => (listRef.current?.scrollTop ?? 0) <= 0, []);

  useEffect(() => {
    load();
    return chatWS.onFrame((frame) => {
      if (frame.type === "post.created" || frame.type === "post.deleted") {
        load();
        return;
      }
      if (frame.type === "post.viewed") {
        // 跨端已读热更新：本账号其他端浏览后，同步本地 groupPosts（标签实时减少）
        const d = frame.data;
        const me = useAuthStore.getState().currentUser;
        if (!me || String(d.viewer_id) !== String(me.id)) return;
        setGroupPosts((prev) =>
          prev.map((p) =>
            String(p.id) === d.post_id
              ? { ...p, is_viewed: true, view_count: d.view_count }
              : p,
          ),
        );
      }
    });
  }, [load]);

  // 收藏态铺底：群内帖子流可能不经 PostsHubPage 直接进入，需自行加载我的帖子收藏
  // （幂等：重复加载只是覆盖同一份 favoriteByPostId 映射）。
  useEffect(() => {
    let cancelled = false;
    favoritesApi
      .listFavorites("post")
      .then((list) => {
        if (!cancelled) usePostsStore.getState().loadFavorites(list);
      })
      .catch(() => {
        // 收藏状态加载失败不阻塞列表；收藏键保持未收藏态，点击时再报错。
      });
    return () => {
      cancelled = true;
    };
  }, []);

  // 收藏/取消收藏：与 PostsHubPage/PostDetailPage 同一模式（REST + posts store 即时反馈）
  const toggleFavorite = useCallback(async (postId: number) => {
    const store = usePostsStore.getState();
    const key = String(postId);
    const favId = store.favoriteByPostId[key];
    setActionError(null);
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
  }, []);

  const handleCreated = useCallback(
    (post: Post) => {
      setGroupPosts((prev) => [post, ...prev]);
    },
    [],
  );

  // 展示 = store 投影 ∪ 完整 group 数据（按 id 去重、时间倒序）。
  // is_viewed/view_count 单调（浏览后不回退）：合并时取「或 / max」，
  // 让浏览上报（更新 posts store）能实时反映到本地 groupPosts 的已读态与浏览量。
  const displayPosts = useMemo(() => {
    const byId = new Map<number, Post>();
    for (const p of groupedFromStore) byId.set(p.id, p);
    for (const p of groupPosts) {
      const existing = byId.get(p.id);
      if (existing) {
        byId.set(p.id, {
          ...p,
          is_viewed: p.is_viewed || existing.is_viewed,
          view_count: Math.max(p.view_count ?? 0, existing.view_count ?? 0),
        });
      } else {
        byId.set(p.id, p);
      }
    }
    return Array.from(byId.values()).sort(
      (a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime(),
    );
  }, [groupedFromStore, groupPosts]);

  // 视口浏览上报（浏览与已读同源）：进入视口即加浏览/已读；
  // onViewed 同步本地 groupPosts 的已读态（store 可能不含全部群帖，标签据此实时减少）。
  // 群未读红点递减由后端 post.viewed WS 事件统一负责（避免同一条浏览被多条路径重复减）。
  const handleViewed = useCallback((updated: Record<string, number>) => {
    setGroupPosts((prev) =>
      prev.map((p) =>
        updated[String(p.id)] != null
          ? { ...p, is_viewed: true, view_count: updated[String(p.id)] }
          : p,
      ),
    );
  }, []);
  usePostViewTracking(listRef, handleViewed);

  // 未读帖子 = 我未浏览过的（is_viewed=false；作者自己的帖子后端恒 true）
  const unreadPosts = useMemo(
    () => displayPosts.filter((p) => !p.is_viewed),
    [displayPosts],
  );

  // 滚动位置 → 上方/下方未读数（实时更新：每看到一条即已读，标签随之减少）
  const [scrollTick, setScrollTick] = useState(0);
  const handleListScroll = useCallback(() => {
    setScrollTick((t) => t + 1);
  }, []);
  const { aboveUnread, belowUnread } = useMemo(() => {
    const root = listRef.current;
    if (!root) return { aboveUnread: 0, belowUnread: 0 };
    const elRect = root.getBoundingClientRect();
    let above = 0;
    let below = 0;
    for (const p of unreadPosts) {
      const node = root.querySelector<HTMLElement>(`[data-post-id="${p.id}"]`);
      if (!node) continue;
      const r = node.getBoundingClientRect();
      if (r.bottom < elRect.top) {
        above += 1;
      } else if (r.top > elRect.bottom) {
        below += 1;
      } else {
        // 视口内：按中心相对视口中心归入上/下（上报去抖期间仍可跳转）
        const center = (r.top + r.bottom) / 2;
        const viewportCenter = (elRect.top + elRect.bottom) / 2;
        if (center <= viewportCenter) above += 1;
        else below += 1;
      }
    }
    return { aboveUnread: above, belowUnread: below };
  }, [unreadPosts, scrollTick, displayPosts]);

  // 跳转到最近的未读帖子（上方 → 列表顺序中第一个在视口上方的；下方同理）
  const jumpToUnread = useCallback(
    (direction: "above" | "below") => {
      const root = listRef.current;
      if (!root) return;
      const elRect = root.getBoundingClientRect();
      let target: HTMLElement | null = null;
      for (const p of unreadPosts) {
        const node = root.querySelector<HTMLElement>(`[data-post-id="${p.id}"]`);
        if (!node) continue;
        const r = node.getBoundingClientRect();
        if (direction === "above" && r.bottom < elRect.top) {
          target = node;
          break;
        }
        if (direction === "below" && r.top > elRect.bottom) {
          target = node;
          break;
        }
      }
      if (!target) return;
      const targetRect = target.getBoundingClientRect();
      root.scrollTop += targetRect.top - elRect.top - root.clientHeight / 2;
      setScrollTick((t) => t + 1);
    },
    [unreadPosts],
  );

  // U14：群内详情不会卸载 GroupPosts，只会用 postId 条件切换列表/详情 DOM。
  // active 显式描述列表容器生命周期；ready 等帖子形成可滚高度后再恢复。
  useEffect(() => {
    if (postId != null) {
      setSkipRevealRestoreKey(scrollRestoreKey);
      setRevealAfterRefresh(false);
    }
  }, [postId, scrollRestoreKey]);
  const { restoring } = useScrollRestore(scrollRestoreKey, listRef, {
    active: postId == null,
    ready: displayPosts.length > 0,
  });
  const isMasonry = useMediaQuery(MASONRY_QUERY);
  const columnCount = isMasonry ? 2 : 1;
  const { columns, columnRefs } = useMasonryColumns(
    displayPosts,
    columnCount,
    (post) => post.id,
    scrollRestoreKey,
  );
  const indexByKey = useMemo(() => {
    const index = new Map<number, number>();
    displayPosts.forEach((post, position) => index.set(post.id, position));
    return index;
  }, [displayPosts]);
  // 内容加载完成后才允许首次/刷新浮入；恢复路径不播 stagger，避免卡片高度变化导致位置错位。
  const revealItems = !loading
    && displayPosts.length > 0
    && (!restoring || revealAfterRefresh)
    && skipRevealRestoreKey !== scrollRestoreKey;

  if (postId) {
    return <PostDetailPage groupId={groupId} />;
  }

  // 无任何数据（store 也没该群帖子）才显示加载骨架；有一点就先用投影渲染，秒开
  const showLoadingSkeleton = groupedFromStore.length === 0 && groupPosts.length === 0;

  return (
    <div className="group-posts">
      <div className="group-posts-list" ref={listRef} onScroll={handleListScroll}>
        <div className="group-scene-head">
          <div className="group-scene-head-copy">
            <h3 className="group-scene-title">群内帖子</h3>
            <p className="group-scene-desc">浏览本群的最新动态</p>
          </div>
          <Link to="/posts/mine" className="btn btn-ghost">我的帖子</Link>
        </div>
        {actionError && <div className="chat-notice" role="alert">{actionError}</div>}
        <PullToRefresh isAtTop={isAtTop} onRefresh={refresh}>
          {error && groupPosts.length === 0 && groupedFromStore.length === 0 ? (
            <div className="group-scene-placeholder" role="alert">
              <p className="placeholder-desc">{error}</p>
              <button type="button" className="btn btn-ghost" onClick={load}>重试</button>
            </div>
          ) : showLoadingSkeleton && loading ? (
            <div className="group-posts-loading" aria-busy="true">
              <span className="skeleton group-posts-skel" style={{ height: 120 }} />
              <span className="skeleton group-posts-skel" style={{ height: 120 }} />
              <span className="home-load-text">正在加载帖子…</span>
            </div>
          ) : displayPosts.length === 0 ? (
            <div className="group-scene-placeholder">
              <h3 className="placeholder-title">群内还没有帖子</h3>
              <p className="placeholder-desc">在下方输入框发第一条帖子</p>
              <button type="button" className="btn btn-ghost" onClick={onExit}>
                返回聊天
              </button>
            </div>
          ) : (
            <div className={`posts-feed group-posts-feed${isMasonry ? " is-masonry" : ""}`} key={revealNonce}>
              {columns.map((columnPosts, columnIndex) => (
                <div key={columnIndex} className="posts-masonry-col" ref={columnRefs[columnIndex]}>
                  {columnPosts.map((post) => {
                    const delay = revealItems ? staggerDelay(indexByKey.get(post.id) ?? 0) : 0;
                    return (
                      <div
                        key={post.id}
                        data-post-id={post.id}
                        className={`posts-feed-item${revealItems ? " reveal-item" : ""}`}
                        style={
                          revealItems
                            ? ({ ["--reveal-delay" as string]: `${delay}ms` } as CSSProperties)
                            : undefined
                        }
                      >
                        <PostCard
                          post={post}
                          favorited={favoriteByPostId[String(post.id)] != null}
                          onOpen={() => {
                            // 详情入口仍能访问列表 DOM 时同步保存；不依赖路由退出/卸载时序。
                            setSkipRevealRestoreKey(scrollRestoreKey);
                            setRevealAfterRefresh(false);
                            saveScrollPosition(scrollRestoreKey, listRef.current);
                            navigate(`/group/${encodeURIComponent(groupId)}/posts/${post.id}`);
                          }}
                          onToggleFavorite={() => void toggleFavorite(post.id)}
                        />
                      </div>
                    );
                  })}
                </div>
              ))}
              {loading && <span className="home-load-text group-posts-loading-more">正在刷新…</span>}
            </div>
          )}
        </PullToRefresh>
      </div>
      {/* 未读帖子跳转标签（与聊天界面同语言）：上方/下方有未读时显示数量，点击跳转 */}
      {aboveUnread > 0 && (
        <div className="message-jump-tags message-jump-tags-above" aria-live="polite">
          <button
            type="button"
            className="message-jump-mention"
            onClick={() => jumpToUnread("above")}
            aria-label={`跳转到上方 ${aboveUnread} 条未读帖子`}
            title="上方有未读帖子"
          >
            ↑ {aboveUnread} 条未读帖子
          </button>
        </div>
      )}
      {belowUnread > 0 && (
        <div className="message-jump-tags message-jump-tags-below" aria-live="polite">
          <button
            type="button"
            className="message-jump-mention"
            onClick={() => jumpToUnread("below")}
            aria-label={`跳转到下方 ${belowUnread} 条未读帖子`}
            title="下方有未读帖子"
          >
            ↓ {belowUnread} 条未读帖子
          </button>
        </div>
      )}
      {editorExpanded && (
        <div
          className="group-posts-scrim"
          onClick={() => setEditorExpanded(false)}
          aria-hidden="true"
        />
      )}
      <div className={`group-posts-input ${editorExpanded ? "is-expanded" : ""}`}>
        <PostEditor
          group={groupId}
          onCreated={handleCreated}
          compact
          collapsible
          expanded={editorExpanded}
          onExpandedChange={setEditorExpanded}
        />
      </div>
    </div>
  );
}
