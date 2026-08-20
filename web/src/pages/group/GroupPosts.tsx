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
import { useCallback, useEffect, useMemo, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { PostDetailPage } from "../PostDetailPage";
import * as postsApi from "../../api/posts";
import type { Post } from "../../api/types";
import { PostCard } from "../../components/posts/PostCard";
import { PostEditor } from "../../components/posts/PostEditor";
import { usePostsStore } from "../../stores/posts";
import { chatWS } from "../../ws/chat";

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

  if (postId) {
    return <PostDetailPage groupId={groupId} />;
  }

  // 无任何数据（store 也没该群帖子）才显示加载骨架；有一点就先用投影渲染，秒开
  const showLoadingSkeleton = groupedFromStore.length === 0 && groupPosts.length === 0;

  return (
    <div className="group-posts">
      <div className="group-posts-head">
        <span className="group-voice-title">群内帖子</span>
        <Link to="/posts/mine" className="btn btn-ghost">我的帖子</Link>
      </div>
      <div className="group-posts-list">
        {error && groupPosts.length === 0 && groupedFromStore.length === 0 ? (
          <div className="group-scene-placeholder" role="alert">
            <p className="placeholder-desc">{error}</p>
            <button type="button" className="btn btn-ghost" onClick={load}>重试</button>
          </div>
        ) : showLoadingSkeleton && loading ? (
          <div aria-busy="true">
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
          <>
            {displayPosts.map((p) => (
              <div key={p.id} className="group-posts-item">
                <PostCard
                  post={p}
                  favorited={false}
                  onOpen={() => navigate(`/group/${encodeURIComponent(groupId)}/posts/${p.id}`)}
                  onToggleFavorite={() => {}}
                />
              </div>
            ))}
            {loading && <span className="home-load-text">正在刷新…</span>}
          </>
        )}
      </div>
      <div className="group-posts-input">
        <PostEditor group={groupId} onCreated={handleCreated} compact collapsible />
      </div>
    </div>
  );
}
