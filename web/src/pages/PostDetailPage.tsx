/**
 * PostDetailPage —— 帖子详情（路由 /posts/:postId，F6，R-P3/R-P4）。
 *
 * 详情正文（图片九宫格 / 超 3 行折叠）+ 评论（列表 + 回复 + 发评论）+ 收藏（切换即时反馈）+
 * 删除（仅作者，二次确认）。窄屏：评论输入框与进入直播间一致，
 * 底栏下滑离场后输入框延迟从底部滑入。
 */
import { useCallback, useEffect, useState } from "react";
import { useNavigate, useParams, useSearchParams } from "react-router-dom";
import * as favoritesApi from "../api/favorites";
import * as postsApi from "../api/posts";
import type { Post, PostComment } from "../api/types";
import { Avatar } from "../components/Avatar";
import { CommentList } from "../components/posts/CommentList";
import { CommentComposer } from "../components/posts/CommentComposer";
import { ResourceImage } from "../components/ResourceImage";
import { VisibilitySelector, type VisibilitySelection } from "../components/VisibilitySelector";
import { IconBack, IconHeart } from "../components/icons";
import { useEnterRoomAnimation } from "../hooks/useEnterRoomAnimation";
import { usePostsStore } from "../stores/posts";
import { useShellStore } from "../stores/shell";
import { getVisibilityLabels } from "../utils/visibility";

export function PostDetailPage({ groupId }: { groupId?: string } = {}) {
  const { postId } = useParams<{ postId: string }>();
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const fromGroup = groupId ?? searchParams.get("fromGroup");
  const returnTo = fromGroup ? `/group/${encodeURIComponent(fromGroup)}/posts` : "/posts";
  // 群内详情沿用群场景顶部导航；只有一级帖子详情才让底栏下滑并带动评论输入框滑入。
  const usesRoomEntryAnimation = groupId == null;
  const { inputEntered } = useEnterRoomAnimation(usesRoomEntryAnimation);
  const favoriteByPostId = usePostsStore((s) => s.favoriteByPostId);

  useEffect(() => {
    if (!usesRoomEntryAnimation) return;
    useShellStore.getState().setBottomTabsLeaving(true);
    return () => useShellStore.getState().setBottomTabsLeaving(false);
  }, [usesRoomEntryAnimation]);

  const [post, setPost] = useState<Post | null>(null);
  const [comments, setComments] = useState<PostComment[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [replyTarget, setReplyTarget] = useState<PostComment | null>(null);
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const [editing, setEditing] = useState(false);
  const [editTitle, setEditTitle] = useState("");
  const [editBody, setEditBody] = useState("");
  const [editVisibility, setEditVisibility] = useState<VisibilitySelection>({ public: true, friends: false, group: false });
  const [editAllowedGroupIds, setEditAllowedGroupIds] = useState<string[]>([]);
  const [savingEdit, setSavingEdit] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [commentError, setCommentError] = useState<string | null>(null);

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
      .then((list) => {
        setComments(list);
        setCommentError(null);
      })
      .catch((e) => {
        const message = e instanceof Error ? e.message : "加载评论失败";
        setCommentError(message);
        setError(message);
      })
      .finally(() => setLoading(false));
    favoritesApi
      .listFavorites("post")
      .then((list) => usePostsStore.getState().loadFavorites(list))
      .catch((e) => setActionError(e instanceof Error ? e.message : "加载收藏状态失败"));
  }, [id]);

  useEffect(() => {
    load();
  }, [load]);

  const sendComment = useCallback(
    async (body: string, replyTo: number | null, mediaId?: string | null) => {
      const c = await postsApi.createComment(id, { body, reply_to: replyTo, media_id: mediaId ?? null });
      setComments((prev) => [...prev, c]);
      if (post) setPost({ ...post, comment_count: post.comment_count + 1 });
    },
    [id, post],
  );

  const deleteComment = useCallback(
    async (comment: PostComment) => {
      if (!comment.is_author) return;
      try {
        await postsApi.deleteComment(comment.id);
        setComments((prev) => prev.filter((c) => c.id !== comment.id));
      } catch (e) {
        setActionError(e instanceof Error ? e.message : "删除评论失败，请重试");
      }
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
      .catch((e) => {
        setConfirmingDelete(false);
        setActionError(e instanceof Error ? e.message : "删除帖子失败，请重试");
      });
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
        <button type="button" className="icon-btn-40" onClick={() => navigate(returnTo)} aria-label="返回">
          <IconBack width={22} height={22} />
        </button>
        <span className="post-detail-title">帖子</span>
        {post.is_author && (
          <div className="post-detail-owner-actions">
            <button type="button" className="msg-action-btn" onClick={() => {
              setEditTitle(post.title);
              setEditBody(post.body);
              // 将后端字符串 visibility 转换为前端多选对象
              const hasGroups = (post.allowed_group_ids ?? []).length > 0;
              setEditVisibility({
                public: post.visibility === "public",
                friends: post.visibility === "friends",
                group: post.visibility === "group" || hasGroups,
              });
              setEditAllowedGroupIds(post.allowed_group_ids ?? []);
              setEditing(true);
            }}>编辑</button>
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
          </div>
        )}
      </header>

      {editing && (
        <section className="post-editor post-detail-edit" aria-label="编辑帖子">
          <input className="field post-editor-title" value={editTitle} onChange={(e) => setEditTitle(e.target.value)} maxLength={128} aria-label="帖子标题" />
          <textarea className="field post-editor-body" value={editBody} onChange={(e) => setEditBody(e.target.value)} rows={5} aria-label="帖子正文" />
          <VisibilitySelector
            value={editVisibility}
            onChange={setEditVisibility}
            selectedGroupIds={editAllowedGroupIds}
            onSelectedGroupIdsChange={setEditAllowedGroupIds}
            initialGroupId={post.group}
          />
          <div className="post-editor-actions">
            <button type="button" className="btn btn-ghost" onClick={() => setEditing(false)}>取消</button>
            <button type="button" className="btn btn-primary" disabled={savingEdit || !editBody.trim()} onClick={() => {
              // 校验：选择了群可见但没有选择任何群
              if (editVisibility.group && editAllowedGroupIds.length === 0) {
                setActionError("请至少选择一个群");
                return;
              }
              // 多选转后端格式：public 单选；friends + group 可共存，优先 friends
              const backendVisibility = editVisibility.public
                ? "public"
                : editVisibility.friends
                  ? "friends"
                  : "group";
              setSavingEdit(true);
              postsApi.updatePost(post.id, {
                title: editTitle.trim(),
                body: editBody.trim(),
                visibility: backendVisibility,
                allowed_group_ids: editAllowedGroupIds.length > 0 ? editAllowedGroupIds : undefined,
              })
                .then((updated) => { setPost(updated); setEditing(false); })
                .catch((e) => setActionError(e instanceof Error ? e.message : "保存编辑失败"))
                .finally(() => setSavingEdit(false));
            }}>{savingEdit ? "保存中…" : "重新发布"}</button>
          </div>
        </section>
      )}

      <div className="post-detail-scroll">
        <article className="post-card post-detail-card">
          <div className="post-card-main">
            <header className="post-card-head">
              <Avatar
                label={post.author.nickname || post.author.username}
                size={36}
                online={post.author.online}
                imageUrl={post.author.avatar || null}
              />
              <span className="post-card-nick">{post.author.nickname || post.author.username}</span>
              <span className="post-card-time">{new Date(post.created_at).toLocaleString("zh-CN")}</span>
              {getVisibilityLabels(post).length > 0 && (
                <div className="post-card-tags">
                  {getVisibilityLabels(post).map((label, idx) => (
                    <span key={idx} className="post-card-tag">{label}</span>
                  ))}
                </div>
              )}
            </header>
            {post.title && <h3 className="post-card-title">{post.title}</h3>}
            <p className="post-card-body is-expanded">{post.body}</p>
            {post.images.length > 0 && (
              <div className={`post-card-images count-${Math.min(post.images.length, 9)}`}>
                {post.images.slice(0, 9).map((img) =>
                  img.media?.thumbnail ? (
                    <ResourceImage
                      key={img.id}
                      src={img.media.thumbnail}
                      alt="帖子图片"
                      className="post-card-img"
                    />
                  ) : null,
                )}
              </div>
            )}
          </div>
          <footer className="post-card-foot">
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
        </article>

        <div className="post-detail-comments">
          {commentError && <div className="chat-notice" role="alert">{commentError}</div>}
          <CommentList
            comments={comments}
            onSend={sendComment}
            onDelete={deleteComment}
            replyTarget={replyTarget}
            onReply={setReplyTarget}
            onReplyClear={() => setReplyTarget(null)}
            hideComposer
          />
        </div>
      </div>
      <CommentComposer
        className="post-detail-composer"
        inputEntered={inputEntered}
        onSend={sendComment}
        replyTarget={replyTarget}
        onReplyClear={() => setReplyTarget(null)}
      />
    </div>
  );
}
