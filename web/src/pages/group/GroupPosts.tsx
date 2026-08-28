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
import type { Post } from "../../api/types";
import { PostCard } from "../../components/posts/PostCard";
import { PostEditor } from "../../components/posts/PostEditor";
import { PullToRefresh } from "../../components/motion/PullToRefresh";
import { useMasonryColumns } from "../../hooks/useMasonryColumns";
import { useMediaQuery } from "../../hooks/useMediaQuery";
import { staggerDelay } from "../../hooks/useRevealOnEnter";
import { saveScrollPosition, useScrollRestore } from "../../hooks/useScrollRestore";
import { usePostsStore } from "../../stores/posts";
import { useShellStore } from "../../stores/shell";
import { chatWS } from "../../ws/chat";

/** 瀑布流断点与一级帖子流保持一致：>1024px 双列。 */
const MASONRY_QUERY = "(min-width: 1025px)";

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
  const groupedFromStore = useMemo(
    () =>
      feedPosts.filter(
        (p) =>
          String(p.group) === String(groupId) ||
          (p.allowed_group_ids ?? []).some((g) => String(g) === String(groupId)),
      ),
    [feedPosts, groupId],
  );
  // 完整 group scope 数据（后台补齐）
  const [groupPosts, setGroupPosts] = useState<Post[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
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

  const load = useCallback(() => {
    setError(null);
    postsApi
      .listPosts({ scope: `group:${groupId}`, limit: 20 })
      .then((page) => {
        setGroupPosts(page.results);
        setLoading(false);
      })
      .catch((e) => {
        setLoading(false);
        setError(e instanceof Error ? e.message : "加载群内帖子失败");
      });
  }, [groupId]);

  // 上拉刷新/刷新键共用：强制重拉群内帖子（group scope）
  const refresh = useCallback(async () => {
    setError(null);
    try {
      const page = await postsApi.listPosts({ scope: `group:${groupId}`, limit: 20 });
      setGroupPosts(page.results);
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
      if (frame.type === "post.created" || frame.type === "post.deleted") load();
    });
  }, [load]);

  const handleCreated = useCallback(
    (post: Post) => {
      setGroupPosts((prev) => [post, ...prev]);
    },
    [],
  );

  // 展示 = store 投影 ∪ 完整 group 数据（按 id 去重、时间倒序）
  const displayPosts = useMemo(() => {
    const byId = new Map<number, Post>();
    for (const p of groupedFromStore) byId.set(p.id, p);
    for (const p of groupPosts) byId.set(p.id, p);
    return Array.from(byId.values()).sort(
      (a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime(),
    );
  }, [groupedFromStore, groupPosts]);

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
      <div className="group-posts-list" ref={listRef}>
        <div className="group-scene-head">
          <div className="group-scene-head-copy">
            <h3 className="group-scene-title">群内帖子</h3>
            <p className="group-scene-desc">浏览本群的最新动态</p>
          </div>
          <Link to="/posts/mine" className="btn btn-ghost">我的帖子</Link>
        </div>
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
                        className={`posts-feed-item${revealItems ? " reveal-item" : ""}`}
                        style={
                          revealItems
                            ? ({ ["--reveal-delay" as string]: `${delay}ms` } as CSSProperties)
                            : undefined
                        }
                      >
                        <PostCard
                          post={post}
                          favorited={false}
                          onOpen={() => {
                            // 详情入口仍能访问列表 DOM 时同步保存；不依赖路由退出/卸载时序。
                            setSkipRevealRestoreKey(scrollRestoreKey);
                            setRevealAfterRefresh(false);
                            saveScrollPosition(scrollRestoreKey, listRef.current);
                            navigate(`/group/${encodeURIComponent(groupId)}/posts/${post.id}`);
                          }}
                          onToggleFavorite={() => {}}
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
