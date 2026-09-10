/**
 * GroupPosts —— 群内帖子子界面（F6，R-G5/R-G8 帖子）。
 *
 * 该群帖子信息流 + **底部输入框发帖**（区别于一级 tab 的 FAB 发帖，R-P2）。
 *
 * 目录由服务端group scope分页：首屏20条，滚到底再取一页，保留cursor与失败重试。
 * 全局posts store只同步已加载卡的已读/浏览状态，不当作本群完整目录或分页边界。
 * 详情返回保留已加载页；新DOM卡片单独进入，刷新不重挂整个帖子流。
 */
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { StablePaginationFooter } from "../../components/StablePaginationFooter";
import { PostDetailPage } from "../PostDetailPage";
import * as postsApi from "../../api/posts";
import type { Post } from "../../api/types";
import { PostCard } from "../../components/posts/PostCard";
import { PostEditor } from "../../components/posts/PostEditor";
import { PullToRefresh } from "../../components/motion/PullToRefresh";
import { useMasonryColumns } from "../../hooks/useMasonryColumns";
import { useMediaQuery } from "../../hooks/useMediaQuery";
import { usePostViewTracking } from "../../hooks/usePostViewTracking";
import { useListEntryMotion } from "../../hooks/useListEntryMotion";
import { saveScrollPosition, useScrollRestore } from "../../hooks/useScrollRestore";
import { usePostsStore } from "../../stores/posts";
import { useChatStore } from "../../stores/chat";
import { useAuthStore } from "../../stores/auth";
import { useShellStore } from "../../stores/shell";
import { chatWS } from "../../ws/chat";

/** 瀑布流断点与一级帖子流保持一致：>1024px 双列。 */
const MASONRY_QUERY = "(min-width: 1025px)";
const PAGE_SIZE = 20;

/** Keep retained cards in place; only previously unseen ids append/prepend. */
function mergePosts(current: Post[], incoming: Post[], prepend = false): Post[] {
  const updates = new Map(incoming.map((post) => [post.id, post]));
  const retained = current.map((post) => {
    const update = updates.get(post.id);
    updates.delete(post.id);
    return update ? {
      ...update,
      is_viewed: post.is_viewed || update.is_viewed,
      view_count: Math.max(post.view_count ?? 0, update.view_count ?? 0),
    } : post;
  });
  const added = [...updates.values()];
  return prepend ? [...added, ...retained] : [...retained, ...added];
}

function createRequestOwner(key: string) {
  return {
    key, active: true, revision: 0, busy: false, loaded: false,
    cursor: null as string | null, hasMore: false, nextFailed: false,
    deletedIds: new Set<number>(),
    mutationRevision: 0,
    mutations: new Map<number, { revision: number; post: Post | null }>(),
    detailRevision: new Map<number, number>(),
  };
}

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
  const userId = useAuthStore((s) => s.currentUser?.id ?? "anonymous");
  const ownerKey = `${userId}:group-posts:${groupId}`;
  const requestOwner = useRef(createRequestOwner(ownerKey));
  if (requestOwner.current.key !== ownerKey) requestOwner.current = createRequestOwner(ownerKey);
  const [dataOwner, setDataOwner] = useState(ownerKey);
  // 全局缓存只用于已加载卡片的状态同步，不能提前显示不在当前分页中的旧缓存。
  const feedPosts = usePostsStore((s) => s.posts);
  const [groupPosts, setGroupPosts] = useState<Post[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [hasMore, setHasMore] = useState(false);
  // 发帖编辑器展开态：驱动上方遮罩（与输入面板平级，z 夹在列表与面板之间）
  const [editorExpanded, setEditorExpanded] = useState(false);
  const listRef = useRef<HTMLDivElement>(null);
  const listActive = useRef(postId == null);
  listActive.current = postId == null;
  const scrollRestoreKey = ownerKey;
  // 同组件详情往返会先渲染列表、再由恢复 hook 的 layout effect 标记 restoring；
  // 单独记住本次详情返回，确保该首帧也不挂 stagger。
  const [skipRevealRestoreKey, setSkipRevealRestoreKey] = useState<string | null>(null);
  // 恢复时现有卡静止；之后实际新增卡片可独立进入。
  const [revealAfterRefresh, setRevealAfterRefresh] = useState(false);
  // §3.4 刷新动画：刷新完成后递增，已入场卡片整批重播浮入（第一页也有动画）
  const [replayNonce, setReplayNonce] = useState(0);

  const requestPage = useCallback(async (append: boolean) => {
    const owner = requestOwner.current;
    if (!owner.active || owner.key !== ownerKey) return;
    if (append && (owner.busy || !owner.loaded || !owner.hasMore || !owner.cursor)) return;
    const wasLoaded = owner.loaded;
    const cursor = append ? owner.cursor : null;
    const mutationRevision = owner.mutationRevision;
    const revision = ++owner.revision;
    owner.busy = true;
    owner.nextFailed = false;
    if (append) setLoadingMore(true);
    else {
      if (!owner.loaded) { setGroupPosts([]); setHasMore(false); }
      setDataOwner(ownerKey);
      setLoading(true);
      setLoadingMore(false);
    }
    const current = () => requestOwner.current === owner && owner.active && owner.revision === revision;
    try {
      const page = await postsApi.listPosts({
        scope: `group:${groupId}`,
        limit: PAGE_SIZE,
        cursor,
      });
      if (!current()) return;
      // 游标未推进（防御性检查，正常不触发）：静默降级，不打扰用户
      if (page.has_more && (!page.next_cursor || page.next_cursor === cursor)) return;
      setGroupPosts((prev) => {
        const existing = new Map(prev.map((post) => [post.id, post]));
        const rows: Post[] = [];
        for (const post of page.results) {
          if (owner.deletedIds.has(post.id)) continue;
          const mutation = owner.mutations.get(post.id);
          // A refresh/append response cannot undo a change delivered after it began.
          const currentPost = mutation && mutation.revision > mutationRevision ? mutation.post : post;
          if (!currentPost) continue;
          const old = existing.get(post.id);
          rows.push({ ...currentPost, is_viewed: old?.is_viewed || currentPost.is_viewed,
            view_count: Math.max(old?.view_count ?? 0, currentPost.view_count ?? 0) });
        }
        const incomingIds = new Set(rows.map((post) => post.id));
        const newDuringRequest = prev.filter((post) => !incomingIds.has(post.id)
          && !owner.deletedIds.has(post.id)
          && (owner.mutations.get(post.id)?.revision ?? 0) > mutationRevision);
        return mergePosts(append ? prev : newDuringRequest, rows);
      });
      setDataOwner(ownerKey);
      owner.cursor = page.next_cursor;
      owner.hasMore = page.has_more;
      owner.loaded = true;
      setHasMore(page.has_more);
      if (listActive.current && wasLoaded) {
        setSkipRevealRestoreKey(null);
        setRevealAfterRefresh(true);
        // 仅刷新（非追加）重播已入场卡片；追加只让新增卡片入场
        if (!append) setReplayNonce((n) => n + 1);
      }
    } catch {
      if (!current()) return;
      if (append) owner.nextFailed = true;
    } finally {
      if (current()) {
        owner.busy = false;
        setLoading(false);
        setLoadingMore(false);
      }
    }
  }, [groupId, ownerKey]);

  const load = useCallback(() => requestPage(false), [requestPage]);
  const refresh = load;
  const loadMore = useCallback(() => requestPage(true), [requestPage]);

  // §3.4 RefreshFAB：注册当前页刷新回调（引用守卫见 HomePage）
  useEffect(() => {
    if (postId != null) return;
    useShellStore.getState().registerRefresh(refresh);
    return () => {
      if (useShellStore.getState().refreshCallback === refresh) {
        useShellStore.getState().registerRefresh(null);
      }
    };
  }, [postId, refresh]);

  // 上拉刷新仅当滚动容器（.group-posts-list）已在顶部时响应
  const isAtTop = useCallback(() => (listRef.current?.scrollTop ?? 0) <= 0, []);

  useEffect(() => {
    const owner = requestOwner.current;
    owner.active = true;
    void load();
    const unsubscribe = chatWS.onFrame((frame) => {
      if (requestOwner.current !== owner || !owner.active) return;
      if (frame.type === "post.deleted") {
        const id = Number(frame.post_id);
        owner.deletedIds.add(id);
        owner.mutations.set(id, { revision: ++owner.mutationRevision, post: null });
        setGroupPosts((prev) => prev.filter((post) => post.id !== id));
        return;
      }
      if (frame.type === "post.created" || frame.type === "post.updated") {
        const id = Number(frame.post.id);
        if (!id) return;
        const detailRevision = (owner.detailRevision.get(id) ?? 0) + 1;
        owner.detailRevision.set(id, detailRevision);
        // 单条权限REST对账；目录提示不重拉首页，不丢失已加载页/游标/滚动位置。
        void postsApi.getPost(id).then((post) => {
          if (requestOwner.current !== owner || !owner.active || owner.deletedIds.has(id) || owner.detailRevision.get(id) !== detailRevision) return;
          if (!(post.allowed_group_ids ?? []).some((gid) => String(gid) === String(groupId))) {
            owner.mutations.set(id, { revision: ++owner.mutationRevision, post: null });
            setGroupPosts((prev) => prev.filter((item) => item.id !== id));
            return;
          }
          owner.mutations.set(id, { revision: ++owner.mutationRevision, post });
          setGroupPosts((prev) => mergePosts(prev, [post], true));
          if (listActive.current) setRevealAfterRefresh(true);
        }).catch(() => {
          // 不可见或已删除的目录提示不成为新卡；现有列表仍可继续分页/刷新。
        });
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
    return () => {
      owner.active = false;
      owner.revision += 1;
      unsubscribe();
    };
  }, [load]);

  const handleCreated = useCallback(
    (post: Post) => {
      const owner = requestOwner.current;
      if (!owner.active || owner.key !== ownerKey) return;
      owner.mutations.set(post.id, { revision: ++owner.mutationRevision, post });
      setGroupPosts((prev) => mergePosts(prev, [post], true));
      setRevealAfterRefresh(true);
    },
    [ownerKey],
  );

  // 只投影本目录已加载卡；共享缓存提供单调已读/浏览量，不扩大分页结果。
  const displayPosts = useMemo(() => {
    if (dataOwner !== ownerKey) return [];
    const byId = new Map(feedPosts.map((post) => [post.id, post]));
    return groupPosts.map((p) => {
      const existing = byId.get(p.id);
      if (existing) {
        return {
          ...p,
          is_viewed: p.is_viewed || existing.is_viewed,
          view_count: Math.max(p.view_count ?? 0, existing.view_count ?? 0),
        };
      }
      return p;
    });
  }, [dataOwner, feedPosts, groupPosts, ownerKey]);

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
  const totalUnread = useChatStore((s) =>
    s.conversations.find((conversation) => conversation.id === groupId)?.post_unread_count ?? 0,
  );
  const unloadedUnread = hasMore ? Math.max(0, totalUnread - unreadPosts.length) : 0;

  // 滚动位置 → 上方/下方未读数（实时更新：每看到一条即已读，标签随之减少）
  const [scrollTick, setScrollTick] = useState(0);
  const handleListScroll = useCallback(() => {
    setScrollTick((t) => t + 1);
    const root = listRef.current;
    if (root && root.scrollHeight > root.clientHeight
      && root.scrollHeight - root.scrollTop - root.clientHeight <= 160
      && !requestOwner.current.nextFailed) {
      void loadMore();
    }
  }, [loadMore]);
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
    return { aboveUnread: above, belowUnread: below + unloadedUnread };
  }, [unreadPosts, scrollTick, displayPosts, unloadedUnread]);

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
      if (!target) {
        if (direction === "below" && unloadedUnread > 0) void loadMore();
        return;
      }
      const targetRect = target.getBoundingClientRect();
      root.scrollTop += targetRect.top - elRect.top - root.clientHeight / 2;
      setScrollTick((t) => t + 1);
    },
    [loadMore, unreadPosts, unloadedUnread],
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
  useListEntryMotion(listRef, ".posts-feed-item", (
    postId != null || ((restoring || skipRevealRestoreKey === scrollRestoreKey) && !revealAfterRefresh)
  ), replayNonce);

  if (postId) {
    return <PostDetailPage groupId={groupId} />;
  }

  const showLoadingSkeleton = displayPosts.length === 0 && (loading || dataOwner !== ownerKey);

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
        <PullToRefresh isAtTop={isAtTop} onRefresh={refresh}>
          {showLoadingSkeleton ? (
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
            <div className={`posts-feed group-posts-feed${isMasonry ? " is-masonry" : ""}`}>
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
                            // 详情入口仍能访问列表 DOM 时同步保存；不依赖路由退出/卸载时序。
                            setSkipRevealRestoreKey(scrollRestoreKey);
                            setRevealAfterRefresh(false);
                            saveScrollPosition(scrollRestoreKey, listRef.current);
                            navigate(`/group/${encodeURIComponent(groupId)}/posts/${post.id}`);
                          }}
                        />
                      </div>
                    );
                  })}
                </div>
              ))}
              <StablePaginationFooter className="group-posts-loading-more" aria-hidden={!hasMore && !loading}>
                {loading && <span className="home-load-text">正在刷新…</span>}
                {hasMore && <button type="button" className="btn btn-ghost"
                  disabled={loadingMore || loading} onClick={() => void loadMore()}>
                  {loadingMore ? "正在加载更多…" : "加载更多帖子"}
                </button>}
              </StablePaginationFooter>
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
