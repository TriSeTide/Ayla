/**
 * PostDetailPage —— 帖子详情（路由 /posts/:postId，F6，R-P3/R-P4）。
 *
 * 详情正文（图片九宫格 / 超 3 行折叠）+ 评论（列表 + 回复 + 发评论）+ 收藏（切换即时反馈）+
 * 删除（仅作者，二次确认）。窄屏：底栏原位替换为评论输入框（usePostDetailTransition，
 * 交叉淡化无位移，与进群/进房动画不同）。
 */
import { useCallback, useEffect, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import * as favoritesApi from "../api/favorites";
import * as postsApi from "../api/posts";
import type { Post, PostComment } from "../api/types";
import { CommentList } from "../components/posts/CommentList";
import { IconBack, IconHeart } from "../components/icons";
import { usePostDetailTransition } from "../hooks/usePostDetailTransition";
import { usePostsStore } from "../stores/posts";

export function PostDetailPage() {
  const { postId } = useParams<{ postId: string }>();
  const navigate = useNavigate();
  const { entered } = usePostDetailTransition();
  const favoriteByPostId = usePostsStore((s) => s.favoriteByPostId);

  const [post, setPost] = useState<Post | null>(null);
  const [comments, setComments] = useState<PostComment[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [replyTarget, setReplyTarget] = useState<PostComment | null>(null);
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);

  const id = Number(postId);

  const load = useCallback(() => {
    if (!Number.isInteger(id) || id <= 0) {
      setError("帖子不存在");
      setLoading(false);
      return;
    }
    setLoading(true);
    setError(null);
    postsApi
      .getPost(id)
      .then((p) => {
        setPost(p);
        return postsApi.listComments(id);
      })
      .then((list) => setComments(list))
      .catch((e) => setError(e instanceof Error ? e.message : "加载失败"))
      .finally(() => setLoading(false));
    favoritesApi
      .listFavorites("post")
      .then((list) => usePostsStore.getState().loadFavorites(list))
      .catch(() => {});
  }, [id]);

  useEffect(() => {
    load();
  }, [load]);

  const sendComment = useCallback(
    async (body: string, replyTo: number | null) => {
      const c = await postsApi.createComment(id, { body, reply_to: replyTo });
      setComments((prev) => [...prev, c]);
      if (post) setPost({ ...post, comment_count: post.comment_count + 1 });
    },
    [id, post],
  );

  const deleteComment = useCallback(
    (comment: PostComment) => {
      if (!comment.is_author) return;
      postsApi
        .deleteComment(comment.id)
        .then(() => setComments((prev) => prev.filter((c) => c.id !== comment.id)))
        .catch(() => {});
    },
    [],
  );

  const toggleFavorite = useCallback(async () => {
    if (!post) return;
    const key = String(post.id);
    const store = usePostsStore.getState();
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
      // 保持原态并显示失败事实，不伪造收藏成功。
      setActionError(e instanceof Error ? e.message : "收藏操作失败，请重试");
    }
  }, [post]);

  const confirmDelete = useCallback(() => {
    if (!post) return;
    postsApi
      .deletePost(post.id)
      .then(() => navigate("/posts"))
      .catch(() => setConfirmingDelete(false));
  }, [post, navigate]);

  if (loading) {
    return (
      <div className="post-detail">
        <div className="skeleton" style={{ height: 160, width: "100%" }} />
      </div>
    );
  }

  if (error || !post) {
    return (
      <div className="post-detail">
        <p className="placeholder-desc">{error ?? "帖子不存在"}</p>
        <button type="button" className="btn btn-ghost" onClick={() => navigate("/posts")}>
          返回
        </button>
      </div>
    );
  }

  const favorited = favoriteByPostId[String(post.id)] != null;

  return (
    <div className="post-detail">
      {actionError && <div className="chat-notice" role="alert">{actionError}</div>}
      <header className="post-detail-head">
        <button type="button" className="icon-btn-40" onClick={() => navigate("/posts")} aria-label="返回">
          <IconBack width={22} height={22} />
        </button>
        <span className="post-detail-title">帖子</span>
        {post.is_author && (
          <button
            type="button"
            className="msg-action-btn"
            onClick={() => {
              if (confirmingDelete) confirmDelete();
              else setConfirmingDelete(true);
            }}
          >
            {confirmingDelete ? "确认删除？" : "删除"}
          </button>
        )}
      </header>

      <article className="post-detail-body">
        <div className="post-detail-author">
          <span className="post-card-nick">{post.author.nickname || post.author.username}</span>
          <span className="post-card-time">{new Date(post.created_at).toLocaleString("zh-CN")}</span>
        </div>
        {post.title && <h2 className="post-detail-title-text">{post.title}</h2>}
        <p className="post-detail-text">{post.body}</p>
        {post.images.length > 0 && (
          <div className={`post-card-images count-${Math.min(post.images.length, 9)}`}>
            {post.images.slice(0, 9).map((img) =>
              img.media?.thumbnail ? (
                <img key={img.id} src={img.media.thumbnail} alt="" className="post-card-img" />
              ) : null,
            )}
          </div>
        )}
      </article>

      <footer className="post-detail-actions">
        <button
          type="button"
          className={`post-card-fav ${favorited ? "is-favorited" : ""}`}
          onClick={() => void toggleFavorite()}
          aria-label={favorited ? "取消收藏" : "收藏"}
          aria-pressed={favorited}
        >
          <IconHeart width={18} height={18} fill={favorited ? "currentColor" : "none"} />
          收藏
        </button>
      </footer>

      <div
        className="post-detail-comments"
        style={{ opacity: entered ? 1 : 0, transition: "opacity 200ms var(--ease-out)" }}
      >
        <CommentList
          comments={comments}
          onSend={sendComment}
          onDelete={deleteComment}
          replyTarget={replyTarget}
          onReply={setReplyTarget}
          onReplyClear={() => setReplyTarget(null)}
        />
      </div>
    </div>
  );
}
