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
import { ImageViewer } from "../components/chat/ImageViewer";
import { ResourceImage } from "../components/ResourceImage";
import { SignedVideo } from "../components/SignedVideo";
import { mediaContentUrl } from "../api/media";
import { VisibilitySelector, type VisibilitySelection } from "../components/VisibilitySelector";
import { IconBack, IconHeart } from "../components/icons";
import { useEnterRoomAnimation } from "../hooks/useEnterRoomAnimation";
import { useRevealOnEnter } from "../hooks/useRevealOnEnter";
import { usePostsStore } from "../stores/posts";
import { useShellStore } from "../stores/shell";
import { useAuthStore } from "../stores/auth";
import { chatWS } from "../ws/chat";
import { goUserProfile } from "../utils/navigation";
import { getVisibilityLabels } from "../utils/visibility";

export function PostDetailPage({ groupId }: { groupId?: string } = {}) {
  const { postId } = useParams<{ postId: string }>();
  const navigate = useNavigate();
  const currentUserId = useAuthStore((s) => s.currentUser?.id);
  const [searchParams] = useSearchParams();
  const fromGroup = groupId ?? searchParams.get("fromGroup");
  const returnTo = fromGroup ? `/group/${encodeURIComponent(fromGroup)}/posts` : "/posts";
  // 群内详情沿用群场景顶部导航；只有一级帖子详情才让底栏下滑并带动评论输入框滑入。
  const usesRoomEntryAnimation = groupId == null;
  const favoriteByPostId = usePostsStore((s) => s.favoriteByPostId);

  useEffect(() => {
    if (!usesRoomEntryAnimation) return;
    useShellStore.getState().setBottomTabsLeaving(true);
    return () => useShellStore.getState().setBottomTabsLeaving(false);
  }, [usesRoomEntryAnimation]);

  const id = Number(postId);

  // 秒开优化：posts store 里存的是全量可见列表（scope=feed 即 visible_queryset，登录预加载），
  // 若当前帖已在其中，则初始化直接用缓存对象（正文立即渲染），再后台 load() 刷新最新 +
  // 评论 + 收藏。命中时 loading 初始为 false，详情不再有"空白加载"。
  const cachedPost = Number.isInteger(id) && id > 0
    ? (usePostsStore.getState().posts.find((p) => p.id === id) ?? null)
    : null;

  const [post, setPost] = useState<Post | null>(cachedPost);
  const [comments, setComments] = useState<PostComment[]>([]);
  const [loading, setLoading] = useState(cachedPost == null);
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
  // 图片查看器（Portal 全屏弹窗，原图 + 保存）
  const [viewerIndex, setViewerIndex] = useState<number | null>(null);

  // 输入框滑入 + 内容入场动画：内容就绪（loading 结束）后才浮入，
  // 避免异步加载完成前动画就提前跑完、看不到浮入效果（直播间同源节奏）。
  const { inputEntered } = useEnterRoomAnimation(usesRoomEntryAnimation);
  const { step } = useRevealOnEnter(!loading && usesRoomEntryAnimation);

  const load = useCallback(() => {
    if (!Number.isInteger(id) || id <= 0) {
      setError("帖子不存在");
      setLoading(false);
      return;
    }
    // 后台刷新：不置 loading=true（避免缓存命中时又闪骨架）；只更新数据。
    setError(null);
    // 正文是第一优先 —— getPost 一返回就立刻覆盖（缓存命中时也在后台静默刷新）。
    // 评论与收藏并发后台填充（各 .then 独立落地，互不阻塞正文显示）。
    postsApi
      .getPost(id)
      .then((p) => {
        setPost(p);
        setLoading(false);
      })
      .catch((e) => {
        const message = e instanceof Error ? e.message : "加载帖子失败";
        setCommentError(message);
        setError(message);
        setLoading(false);
      });
    postsApi
      .listComments(id)
      .then((list) => {
        setComments(list);
        setCommentError(null);
      })
      .catch((e) => {
        const message = e instanceof Error ? e.message : "加载评论失败";
        setCommentError(message);
      });
    favoritesApi
      .listFavorites("post")
      .then((list) => usePostsStore.getState().loadFavorites(list))
      .catch((e) => setActionError(e instanceof Error ? e.message : "加载收藏状态失败"));
  }, [id]);

  useEffect(() => {
    load();
  }, [load]);

  // 评论实时推送（善用 WebSocket）：评论创建/删除实时插入/移除 + 更新计数
  useEffect(() => {
    if (!Number.isInteger(id) || id <= 0) return;
    const off = chatWS.onFrame((frame) => {
      if (frame.type === "comment.created" && Number(frame.data.post_id) === id) {
        const c = frame.data.comment;
        setComments((prev) => {
          if (prev.some((item) => item.id === c.id)) return prev; // 去重（自己发的也会回传）
          // 评论按 created_at 升序（与列表接口一致），插入正确位置
          const next = [...prev, c].sort(
            (a, b) => new Date(a.created_at).getTime() - new Date(b.created_at).getTime(),
          );
          return next;
        });
        setPost((prev) =>
          prev ? { ...prev, comment_count: frame.data.comment_count } : prev,
        );
        return;
      }
      if (frame.type === "comment.deleted" && Number(frame.data.post_id) === id) {
        const cid = frame.data.comment_id;
        setComments((prev) => prev.filter((item) => item.id !== cid));
        setPost((prev) =>
          prev ? { ...prev, comment_count: frame.data.comment_count } : prev,
        );
      }
    });
    return off;
  }, [id]);

  const sendComment = useCallback(
    async (body: string, replyTo: number | null, imageIds: string[] = []) => {
      const c = await postsApi.createComment(id, {
        body,
        reply_to: replyTo,
        images: imageIds,
        media_id: imageIds[0] ?? null, // 旧契约兼容字段
      });
      // 乐观本地插入（去重靠 WS comment.created 的 id 去重；计数以 WS 权威值为准，
      // 不做本地 +1，避免与实时推送重复累加）。
      setComments((prev) => {
        if (prev.some((item) => item.id === c.id)) return prev;
        return [...prev, c].sort(
          (a, b) => new Date(a.created_at).getTime() - new Date(b.created_at).getTime(),
        );
      });
    },
    [id],
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
    // 顶栏框架先上（返回键 + 标题始终可见），仅正文/评论区显示结构化骨架，
    // 避免整页被骨架替换造成的"空白加载"。
    return (
      <div className="post-detail">
        <header className="post-detail-head">
          <button type="button" className="icon-btn-40" onClick={() => navigate(returnTo)} aria-label="返回">
            <IconBack width={22} height={22} />
          </button>
          <span className="post-detail-title">帖子</span>
        </header>
        <div className="post-detail-skeleton" aria-label="正在加载帖子">
          <div className="post-detail-skeleton-head">
            <span className="skeleton post-detail-skeleton-avatar" style={{ width: 40, height: 40, borderRadius: 999 }} />
            <span className="skeleton" style={{ width: 96, height: 16, borderRadius: 8 }} />
            <span className="skeleton" style={{ width: 64, height: 12, borderRadius: 6 }} />
          </div>
          <span className="skeleton" style={{ height: 14, width: "100%", borderRadius: 8 }} />
          <span className="skeleton" style={{ height: 14, width: "92%", borderRadius: 8 }} />
          <span className="skeleton" style={{ height: 120, width: "100%", borderRadius: 12 }} />
          <div className="post-detail-skeleton-comments">
            <span className="skeleton" style={{ height: 12, width: 80, borderRadius: 6 }} />
            <span className="skeleton" style={{ height: 13, width: "88%", borderRadius: 8 }} />
            <span className="skeleton" style={{ height: 13, width: "76%", borderRadius: 8 }} />
            <span className="skeleton" style={{ height: 13, width: "82%", borderRadius: 8 }} />
          </div>
        </div>
      </div>
    );
  }

  if (!post) {
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
        <article className={`post-card post-detail-card ${usesRoomEntryAnimation ? "reveal" : ""} ${usesRoomEntryAnimation && step === 1 ? "is-in" : ""}`}>
          <div className="post-card-main">
            <header className="post-card-head">
              <Avatar
                label={post.author.nickname || post.author.username}
                size={36}
                online={post.author.online}
                imageUrl={post.author.avatar || null}
                onClick={() => goUserProfile(currentUserId, post.author.id)}
                ariaLabel={`查看 ${post.author.nickname || post.author.username} 的个人主页`}
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
                {post.images.slice(0, 9).map((img) => {
                  const media = img.media;
                  if (!media) return null;
                  const idx = post.images.findIndex((x) => x.id === img.id);
                  // 图片/视频统一点击弹窗：ImageViewer 内图片看原图、视频全屏播放（均带保存）
                  return (
                    <button
                      key={img.id}
                      type="button"
                      className={`post-card-img ${media.kind === "video" ? "post-card-video" : "post-card-img-btn"}`}
                      onClick={() => setViewerIndex(idx)}
                      aria-label={media.kind === "video" ? "播放视频" : "查看图片原图"}
                    >
                      {media.kind === "video" ? (
                        <>
                          <SignedVideo
                            mediaId={media.media_id}
                            className="post-card-video-el"
                            ariaLabel="帖子视频"
                          />
                          <span className="post-card-video-badge" aria-hidden="true">▶</span>
                        </>
                      ) : (
                        <ResourceImage
                          src={media.thumbnail || mediaContentUrl(media.media_id)}
                          variant={media.thumbnail ? "thumb" : undefined}
                          alt="帖子图片"
                          className="post-card-img-inner"
                        />
                      )}
                    </button>
                  );
                })}
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

        <div className={`post-detail-comments ${usesRoomEntryAnimation ? "reveal" : ""} ${usesRoomEntryAnimation && step === 1 ? "is-in" : ""}`}>
          {commentError && <div className="chat-notice" role="alert">{commentError}</div>}
          <CommentList
            comments={comments}
            onSend={sendComment}
            onDelete={deleteComment}
            replyTarget={replyTarget}
            onReply={setReplyTarget}
            onReplyClear={() => setReplyTarget(null)}
            hideComposer
            revealItems={usesRoomEntryAnimation}
          />
        </div>
      </div>
      <CommentComposer
        className="post-detail-composer"
        // 一级详情：复用进直播间输入框滑入动画（inputEntered 由动画驱动）；
        // 群内详情：无底栏下滑动画，输入框直接显示（不进隐藏态）。
        inputEntered={usesRoomEntryAnimation ? inputEntered : true}
        onSend={sendComment}
        replyTarget={replyTarget}
        onReplyClear={() => setReplyTarget(null)}
      />
      {/* 图片原图查看器（Portal 全屏弹窗 + 保存） */}
      {viewerIndex != null && post.images[viewerIndex]?.media && (
        <ImageViewer
          media={post.images[viewerIndex].media}
          alt={post.title || "帖子图片"}
          onClose={() => setViewerIndex(null)}
        />
      )}
    </div>
  );
}
