/**
 * GroupPosts —— 群内帖子子界面（F6，R-G5/R-G8 帖子）。
 *
 * 该群帖子信息流（scope=group:<id>）+ **底部输入框发帖**（区别于一级 tab 的 FAB 发帖，
 * 两条路径不同，R-P2）。PostEditor compact 变体。无帖子 → 空态。
 */
import { useCallback, useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { PostDetailPage } from "../PostDetailPage";
import * as postsApi from "../../api/posts";
import type { Post } from "../../api/types";
import { PostCard } from "../../components/posts/PostCard";
import { PostEditor } from "../../components/posts/PostEditor";

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
  const [posts, setPosts] = useState<Post[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(() => {
    setLoading(true);
    setError(null);
    postsApi
      .listPosts({ scope: `group:${groupId}`, limit: 20 })
      .then((page) => setPosts(page.results))
      .catch((e) => setError(e instanceof Error ? e.message : "加载群内帖子失败"))
      .finally(() => setLoading(false));
  }, [groupId]);

  useEffect(() => {
    load();
  }, [load]);

  const handleCreated = useCallback(
    (post: Post) => {
      setPosts((prev) => [post, ...prev]);
    },
    [],
  );

  if (postId) {
    return <PostDetailPage groupId={groupId} />;
  }

  if (loading) {
    return (
      <div className="group-scene-placeholder">
        <div className="skeleton" style={{ height: 120, width: "90%" }} />
      </div>
    );
  }

  if (error) {
    return (
      <div className="group-scene-placeholder" role="alert">
        <h3 className="placeholder-title">群内帖子加载失败</h3>
        <p className="placeholder-desc">{error}</p>
        <button type="button" className="btn btn-ghost" onClick={load}>重试</button>
      </div>
    );
  }

  return (
    <div className="group-posts">
      <div className="group-posts-head">
        <Link to="/posts/mine" className="btn btn-ghost">我的帖子</Link>
      </div>
      <div className="group-posts-list">
        {posts.length === 0 ? (
          <div className="group-scene-placeholder">
            <h3 className="placeholder-title">群内还没有帖子</h3>
            <p className="placeholder-desc">在下方输入框发第一条帖子</p>
            <button type="button" className="btn btn-ghost" onClick={onExit}>
              返回聊天
            </button>
          </div>
        ) : (
          posts.map((p) => (
            <div key={p.id} className="group-posts-item">
              <PostCard
                post={p}
                favorited={false}
                onOpen={() => navigate(`/group/${encodeURIComponent(groupId)}/posts/${p.id}`)}
                onToggleFavorite={() => {}}
              />
            </div>
          ))
        )}
      </div>
      <div className="group-posts-input">
        <PostEditor group={groupId} onCreated={handleCreated} compact />
      </div>
    </div>
  );
}
