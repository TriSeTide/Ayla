/**
 * PostDetailPage —— 帖子详情（路由 /posts/:postId，F6，R-P3/R-P4）。
 *
 * 详情正文（图片九宫格 / 超 3 行折叠）+ 评论（列表 + 回复 + 发评论）+ 收藏（切换即时反馈）+
 * 删除（仅作者，二次确认）。顶栏从上、评论输入框从下独立进入；
 * 群外正文继续保留原 500ms 浮入缩放与内容 reveal。
 */
import { useCallback, useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { motion, useIsPresent } from "framer-motion";
import { useNavigate, useNavigationType, useParams, useSearchParams } from "react-router-dom";
import { FavoriteButton } from "../components/FavoriteButton";
import * as postsApi from "../api/posts";
import type { MediaDescriptor, Post, PostComment } from "../api/types";
import { Avatar } from "../components/Avatar";
import { CommentList } from "../components/posts/CommentList";
import { CommentComposer } from "../components/posts/CommentComposer";
import { ImageViewer } from "../components/chat/ImageViewer";
import { ResourceImage } from "../components/ResourceImage";
import { PostVideoCover } from "../components/posts/PostVideoCover";
import { deleteMedia, mediaContentUrl, uploadMediaFile, validateMediaFile } from "../api/media";
import { VisibilitySelector, type VisibilitySelection } from "../components/VisibilitySelector";
import { IconBack, IconEye, IconImage } from "../components/icons";
import { FullScreenSwipeBack } from "../components/motion/FullScreenSwipeBack";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { useRevealOnEnter } from "../hooks/useRevealOnEnter";
import { usePrefersReducedMotion } from "../hooks/usePrefersReducedMotion";
import { panelVariants, surfaceEntryVariants } from "../components/motion/auroraquaMotion";
import { usePostsStore } from "../stores/posts";
import { useShellStore } from "../stores/shell";
import { useAuthStore } from "../stores/auth";
import { chatWS } from "../ws/chat";
import { usePresenceStore } from "../stores/presence";
import { presenceOnline } from "../utils/displayStatus";
import { goUserProfile } from "../utils/navigation";
import { getVisibilityLabels } from "../utils/visibility";
import { usePostComments } from "../hooks/usePostComments";
import { saveScrollPosition, useScrollRestore } from "../hooks/useScrollRestore";
import { StablePaginationFooter } from "../components/StablePaginationFooter";

/** 编辑面板中的媒体项：已有图片（isNew=false，用 descriptor 渲染）或新上传（isNew=true，用 localUrl 预览）。 */
type EditImageItem = {
  key: string;
  mediaId: string;
  kind: "image" | "video";
  descriptor?: MediaDescriptor;
  localUrl?: string;
  isNew: boolean;
};

export function PostDetailPage({ groupId }: { groupId?: string } = {}) {
  const { postId } = useParams<{ postId: string }>();
  const account = useAuthStore((state) => `${state.currentUser?.id ?? "anonymous"}:${!!state.accessToken}`);
  return <PostDetailContent key={`${account}:${groupId ?? ""}:${postId}`} groupId={groupId} />;
}

function PostDetailContent({ groupId }: { groupId?: string }) {
  const { postId } = useParams<{ postId: string }>();
  const navigate = useNavigate();
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const reduced = usePrefersReducedMotion();
  const navigationType = useNavigationType();
  const present = useIsPresent();
  const saveBeforeBack = useRef<() => void>(() => {});
  const currentUserId = useAuthStore((s) => s.currentUser?.id);
  const onlineUsers = usePresenceStore((s) => s.users);
  const [searchParams] = useSearchParams();
  const fromGroup = groupId ?? searchParams.get("fromGroup");
  const fromMine = searchParams.get("from") === "mine";
  const returnTo = fromGroup
    ? `/group/${encodeURIComponent(fromGroup)}/posts`
    : fromMine
      ? "/posts/mine"
      : "/posts";
  // 详情返回走历史栈回退（navigate(-1)），回到进入详情前的列表页，避免 navigate(returnTo)
  // 再 push 一个列表页 → 列表页的 navigate(-1) 退回详情（Bug：我的帖子返回到刚才的详情）。
  // 站内点击进入详情是 PUSH，返回时回退原有历史栈，避免再 push 列表页；
  // 直接打开或通过 POP/REPLACE 到达详情时没有可靠的站内来源，替换到显式 returnTo。
  const goBack = useCallback(() => {
    saveBeforeBack.current();
    if (navigationType === "PUSH") {
      navigate(-1);
    } else {
      navigate(returnTo, { replace: true });
    }
  }, [navigationType, navigate, returnTo]);
  // 群外详情启用全屏右滑返回（用户拍板 2026-09-04 全站统一）；群内沿用群场景顶部导航，不启用。
  const wrapSwipe = (node: ReactNode) =>
    groupId == null ? (
      <FullScreenSwipeBack onBack={goBack} enabled={isNarrow}>
        {node}
      </FullScreenSwipeBack>
    ) : (
      node
    );
  // 群内详情沿用群场景顶部导航；只有一级帖子详情才让底栏下滑并带动评论输入框滑入。
  const usesRoomEntryAnimation = groupId == null;

  useEffect(() => {
    if (!usesRoomEntryAnimation) return;
    useShellStore.getState().setBottomTabsLeaving(true);
    return () => useShellStore.getState().setBottomTabsLeaving(false);
  }, [usesRoomEntryAnimation]);

  const id = Number(postId);

  // 已加载的帖子可供即时展示，随后独立刷新正文和有界评论页。
  const cachedPost = Number.isInteger(id) && id > 0
    ? (usePostsStore.getState().posts.find((p) => p.id === id) ?? null)
    : null;

  const [post, setPost] = useState<Post | null>(cachedPost);
  const commentPage = usePostComments(id);
  const [loading, setLoading] = useState(cachedPost == null);
  const [error, setError] = useState<string | null>(null);
  const [replyTarget, setReplyTarget] = useState<PostComment | null>(null);
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const [deletingPost, setDeletingPost] = useState(false);
  const deleteBusy = useRef(false);
  const [editing, setEditing] = useState(false);
  const [editTitle, setEditTitle] = useState("");
  const [editBody, setEditBody] = useState("");
  const [editVisibility, setEditVisibility] = useState<VisibilitySelection>({ public: true, friends: false, group: false });
  const [editAllowedGroupIds, setEditAllowedGroupIds] = useState<string[]>([]);
  const [savingEdit, setSavingEdit] = useState(false);
  const editBusy = useRef(false);
  const [editImages, setEditImages] = useState<EditImageItem[]>([]);
  const [editUploading, setEditUploading] = useState(false);
  const [editMediaError, setEditMediaError] = useState<string | null>(null);
  // 打开编辑时的已有图片 media_id 快照：提交时判断图片是否有增删，并在成功后回收被移除的媒体
  const initialExistingMediaIdsRef = useRef<string[]>([]);
  const [actionError, setActionError] = useState<string | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  useScrollRestore(commentPage.key, scrollRef, { active: present && !loading, ready: !loading && commentPage.loaded });
  saveBeforeBack.current = () => saveScrollPosition(commentPage.key, scrollRef.current);
  const activeRef = useRef(true);
  const detailRequest = useRef(0);
  // 图片查看器（Portal 全屏弹窗，原图 + 保存）
  const [viewerIndex, setViewerIndex] = useState<number | null>(null);
  const editTitleRef = useRef<HTMLInputElement>(null);
  const editButtonRef = useRef<HTMLButtonElement>(null);
  const wasEditingRef = useRef(false);
  const backgroundInert = editing ? { inert: "", "aria-hidden": true as const } : {};
  useLayoutEffect(() => {
    const restoreFocus = !editing && wasEditingRef.current;
    wasEditingRef.current = editing;
    if (editing) editTitleRef.current?.focus();
    else if (restoreFocus) {
      // 等待按钮实际结束 visibility 过渡，避免焦点被仍隐藏的控件拒绝。
      let cancelled = false;
      const button = editButtonRef.current;
      const visibilityTransitions = button?.getAnimations?.().filter(
        (animation) => "transitionProperty" in animation && animation.transitionProperty === "visibility",
      ) ?? [];
      void Promise.allSettled(visibilityTransitions.map((animation) => animation.finished)).then(() => {
        if (!cancelled) button?.focus({ preventScroll: true });
      });
      return () => { cancelled = true; };
    }
  }, [editing]);

  // 输入框滑入 + 内容入场动画：内容就绪（loading 结束）后才浮入，
  // 避免异步加载完成前动画就提前跑完、看不到浮入效果（直播间同源节奏）。
  const { step } = useRevealOnEnter(!loading && usesRoomEntryAnimation);

  const load = useCallback(() => {
    if (!Number.isInteger(id) || id <= 0) {
      setError("帖子不存在");
      setLoading(false);
      return;
    }
    const request = ++detailRequest.current;
    setError(null);
    void postsApi.getPost(id).then((next) => {
      if (!activeRef.current || request !== detailRequest.current) return;
      setPost((previous) => ({ ...next, is_viewed: previous?.is_viewed || next.is_viewed,
        view_count: Math.max(previous?.view_count ?? 0, next.view_count ?? 0) }));
      setLoading(false);
    }).catch((error) => {
      if (!activeRef.current || request !== detailRequest.current) return;
      setError(error instanceof Error ? error.message : "加载帖子失败");
      setLoading(false);
    });
  }, [id]);

  useEffect(() => {
    activeRef.current = true;
    load();
    return () => { activeRef.current = false; detailRequest.current += 1; };
  }, [load]);

  // 打开详情即浏览（浏览与已读同源）：上报成功后标记已读 + 更新浏览量 + 群未读递减
  useEffect(() => {
    if (!Number.isInteger(id) || id <= 0) return;
    let cancelled = false;
    postsApi
      .reportPostViews([id])
      .then(({ updated }) => {
        if (cancelled || Object.keys(updated).length === 0) return;
        usePostsStore.getState().markViewedBatch(updated);
        // 详情本地 state 同步最新浏览量/已读态（load 与上报并发，避免显示旧值）
        setPost((prev) =>
          prev && updated[String(prev.id)] != null
            ? { ...prev, is_viewed: true, view_count: updated[String(prev.id)] }
            : prev,
        );
        // 群未读红点递减由后端 post.viewed WS 事件统一负责（避免重复减）
      })
      .catch(() => {
        // 上报失败不阻塞详情；下次打开再试
      });
    return () => {
      cancelled = true;
    };
  }, [id]);

  // 评论实时推送（善用 WebSocket）：评论创建/删除实时插入/移除 + 更新计数
  useEffect(() => {
    if (!Number.isInteger(id) || id <= 0) return;
    const off = chatWS.onFrame((frame) => {
      if ((frame.type === "comment.created" || frame.type === "comment.deleted") && Number(frame.data.post_id) === id) {
        setPost((previous) => previous ? { ...previous, comment_count: frame.data.comment_count } : previous);
        if (frame.type === "comment.deleted") setReplyTarget((previous) => previous?.id === frame.data.comment_id ? null : previous);
        return;
      }
      if (frame.type === "post.viewed" && Number(frame.data.post_id) === id) {
        // 浏览/已读热更新：他人浏览刷新 view_count；本人（多端）浏览再同步已读态
        const d = frame.data;
        const me = useAuthStore.getState().currentUser;
        const isMe = me && String(d.viewer_id) === String(me.id);
        setPost((prev) =>
          prev
            ? {
                ...prev,
                view_count: d.view_count,
                ...(isMe ? { is_viewed: true } : {}),
              }
            : prev,
        );
        return;
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
      commentPage.upsert(c);
    },
    [id, commentPage.upsert],
  );

  const deleteComment = useCallback(
    async (comment: PostComment) => {
      if (!comment.is_author) return;
      try {
        await postsApi.deleteComment(comment.id);
        commentPage.remove(comment.id);
        setReplyTarget((current) => current?.id === comment.id ? null : current);
      } catch (e) {
        if (activeRef.current) setActionError(e instanceof Error ? e.message : "删除评论失败，请重试");
      }
    },
    [commentPage.remove],
  );

  const confirmDelete = useCallback(() => {
    if (!post || deleteBusy.current) return;
    deleteBusy.current = true;
    setDeletingPost(true);
    setActionError(null);
    postsApi
      .deletePost(post.id)
      .then(() => { if (activeRef.current) goBack(); })
      .catch((e) => {
        if (!activeRef.current) return;
        setConfirmingDelete(false);
        setActionError(e instanceof Error ? e.message : "删除帖子失败，请重试");
      }).finally(() => {
        deleteBusy.current = false;
        if (activeRef.current) setDeletingPost(false);
      });
  }, [post, goBack]);

  // ---- 编辑帖子媒体（图片/视频）----

  /** 上传新媒体到编辑面板（复用三步上传；失败保留原输入，不伪造成功） */
  const uploadEditImages = async (files: File[]) => {
    if (editUploading || savingEdit || files.length === 0) return;
    const remaining = Math.max(0, 9 - editImages.length);
    if (files.length > remaining) {
      setEditMediaError(`最多添加 9 个媒体，还可添加 ${remaining} 个`);
      files = files.slice(0, remaining);
    }
    if (files.length === 0) return;
    setEditUploading(true);
    setEditMediaError(null);
    const uploaded: EditImageItem[] = [];
    for (const file of files) {
      const check = validateMediaFile(file);
      if (check.error) {
        setEditMediaError(check.error);
        continue;
      }
      try {
        const result = await uploadMediaFile(file, check.kind);
        uploaded.push({
          key: result.media_id,
          mediaId: result.media_id,
          kind: result.descriptor.kind === "video" ? "video" : "image",
          descriptor: result.descriptor,
          localUrl: URL.createObjectURL(file),
          isNew: true,
        });
      } catch {
        setEditMediaError("媒体上传失败，请重试");
      }
    }
    setEditImages((prev) => [...prev, ...uploaded]);
    setEditUploading(false);
  };

  /** 从编辑面板移除媒体：新上传的立即回收；已有图片仅从列表移除，提交成功后统一回收 */
  const removeEditImage = (item: EditImageItem) => {
    setEditImages((prev) => prev.filter((i) => i.key !== item.key));
    if (item.isNew) {
      void deleteMedia(item.mediaId).catch(() => {});
    }
  };

  /** 回收尚未提交的新上传媒体（取消编辑时调用，避免孤儿对象） */
  const cleanupNewEditImages = (images: EditImageItem[]) => {
    for (const item of images) {
      if (item.isNew) void deleteMedia(item.mediaId).catch(() => {});
    }
  };

  /** 关闭编辑：回收未提交的新媒体，已有图片保持不动 */
  const cancelEdit = () => {
    cleanupNewEditImages(editImages);
    setActionError(null);
    setEditMediaError(null);
    setEditing(false);
  };

  /** 保存编辑：标题/正文/可见性/媒体（媒体有变化才全量替换） */
  const saveEdit = () => {
    if (!post || editBusy.current || editUploading) return;
    if (editVisibility.group && editAllowedGroupIds.length === 0) {
      setActionError("请至少选择一个群");
      return;
    }
    const backendVisibility = editVisibility.public
      ? "public"
      : editVisibility.friends
        ? "friends"
        : "group";
    const currentIds = editImages.map((i) => i.mediaId);
    const initialIds = initialExistingMediaIdsRef.current;
    const imagesChanged =
      currentIds.length !== initialIds.length ||
      currentIds.some((id, idx) => id !== initialIds[idx]);
    const payload: Parameters<typeof postsApi.updatePost>[1] = {
      title: editTitle.trim(),
      body: editBody.trim(),
      visibility: backendVisibility,
      allowed_group_ids: editAllowedGroupIds.length > 0 ? editAllowedGroupIds : undefined,
    };
    if (imagesChanged) payload.images = currentIds;
    editBusy.current = true;
    setSavingEdit(true);
    setActionError(null);
    postsApi
      .updatePost(post.id, payload)
      .then((updated) => {
        if (!activeRef.current) return;
        setPost(updated);
        setEditing(false);
        // 提交成功：回收被移除的已有图片（后端已清除其 PostImage 关联）
        if (imagesChanged) {
          for (const removedId of initialIds) {
            if (!currentIds.includes(removedId)) {
              void deleteMedia(removedId).catch(() => {});
            }
          }
        }
      })
      .catch((e) => { if (activeRef.current) setActionError(e instanceof Error ? e.message : "保存编辑失败"); })
      .finally(() => { editBusy.current = false; if (activeRef.current) setSavingEdit(false); });
  };

  if (loading) {
    // 顶栏框架先上（返回键 + 标题始终可见），仅正文/评论区显示结构化骨架，
    // 避免整页被骨架替换造成的"空白加载"。
    return wrapSwipe(
      <div className="post-detail">
        <header className="post-detail-head">
          <button type="button" className="icon-btn-40" onClick={goBack} aria-label="返回">
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
      </div>,
    );
  }

  if (!post) {
    return wrapSwipe(
      <div className="post-detail">
        <p className="placeholder-desc">{error ?? "帖子不存在"}</p>
        <button type="button" className="btn btn-ghost" onClick={goBack}>
          返回
        </button>
      </div>,
    );
  }


  return wrapSwipe(
    <div className={`post-detail${editing ? " is-editing" : ""}`}>
      {actionError && !editing && <div className="chat-notice" role="alert">{actionError}</div>}
      <header className="post-detail-head post-detail-background" {...backgroundInert}>
        <button type="button" className="icon-btn-40" onClick={goBack} aria-label="返回">
          <IconBack width={22} height={22} />
        </button>
        <span className="post-detail-title">帖子</span>
        {post.is_author && (
          <div className="post-detail-owner-actions">
            <button ref={editButtonRef} type="button" className="msg-action-btn" onClick={() => {
              setEditTitle(post.title);
              setEditBody(post.body);
              // 将后端字符串 visibility 转换为前端多选对象
              const hasGroups = (post.allowed_group_ids ?? []).length > 0;
              setEditVisibility({
                public: post.visibility === "public",
                friends: post.visibility === "friends",
                group: hasGroups,
              });
              setEditAllowedGroupIds(post.allowed_group_ids ?? []);
              // 初始化编辑媒体：已有图片（media 非空）进列表，新上传从空开始
              const existing = (post.images ?? []).filter((img) => img.media != null);
              setEditImages(existing.map((img) => ({
                key: img.media!.media_id,
                mediaId: img.media!.media_id,
                kind: img.media!.kind === "video" ? "video" : "image",
                descriptor: img.media!,
                isNew: false,
              })));
              initialExistingMediaIdsRef.current = existing.map((img) => img.media!.media_id);
              setEditMediaError(null);
              setEditing(true);
            }}>编辑</button>
            <button
              type="button"
              className="msg-action-btn"
              disabled={deletingPost}
              onClick={() => {
                if (confirmingDelete) confirmDelete();
                else setConfirmingDelete(true);
              }}
            >
              {deletingPost ? "删除中…" : confirmingDelete ? "确认删除？" : "删除"}
            </button>
          </div>
        )}
      </header>

      {editing && (
        <div className="post-edit-fullscreen" role="dialog" aria-modal="true" aria-label="编辑帖子">
          <header className="post-edit-head">
            <button type="button" className="icon-btn-40" onClick={cancelEdit} aria-label="取消编辑" title="取消" disabled={savingEdit}>
              <IconBack width={22} height={22} />
            </button>
            <span className="post-edit-title">编辑帖子</span>
            <button
              type="button"
              className="btn btn-primary post-edit-save"
              disabled={savingEdit || editUploading || !editBody.trim()}
              onClick={saveEdit}
            >
              {savingEdit ? "保存中…" : "重新发布"}
            </button>
          </header>
          <div className="post-edit-body">
            <fieldset disabled={savingEdit} style={{ border: 0, padding: 0, margin: 0, minWidth: 0, display: "contents" }}>
            <input
              ref={editTitleRef}
              className="field"
              value={editTitle}
              onChange={(e) => setEditTitle(e.target.value)}
              maxLength={128}
              placeholder="标题（必填）"
              aria-label="帖子标题"
            />
            <textarea
              className="field post-edit-body-input"
              value={editBody}
              onChange={(e) => setEditBody(e.target.value)}
              rows={6}
              placeholder="正文（必填）"
              aria-label="帖子正文"
            />

            <div className="post-edit-media">
              <div className="post-edit-media-head">
                <span className="post-edit-media-label">图片/视频 {editImages.length}/9</span>
                <label className="post-editor-image-btn" aria-label="添加图片或视频">
                  <IconImage width={18} height={18} />
                  <span>添加</span>
                  <input
                    type="file"
                    accept="image/*,video/*"
                    multiple
                    hidden
                    disabled={savingEdit || editUploading || editImages.length >= 9}
                    onChange={async (e) => {
                      const files = Array.from(e.target.files ?? []);
                      e.target.value = "";
                      await uploadEditImages(files);
                    }}
                  />
                </label>
              </div>
              {editImages.length > 0 && (
                <div className="post-edit-media-grid" aria-label={`已添加 ${editImages.length} 个媒体`}>
                  {editImages.map((item) => (
                    <div className="post-editor-image" key={item.key}>
                      {item.isNew && item.kind === "video" ? (
                        <video className="post-edit-media-el" src={`${item.localUrl}#t=0.1`} muted playsInline preload="metadata" />
                      ) : item.isNew ? (
                        <img className="post-edit-media-el" src={item.localUrl} alt="待发布媒体" />
                      ) : item.kind === "video" ? (
                        <PostVideoCover media={item.descriptor!} className="post-edit-media-el" ariaLabel="已选视频" />
                      ) : (
                        <ResourceImage
                          src={item.descriptor!.thumbnail || mediaContentUrl(item.mediaId)}
                          variant={item.descriptor!.thumbnail ? "thumb" : undefined}
                          alt="帖子图片"
                          className="post-edit-media-el"
                        />
                      )}
                      <button
                        type="button"
                        className="post-editor-image-remove"
                        aria-label="移除媒体"
                        disabled={savingEdit || editUploading}
                        onClick={() => removeEditImage(item)}
                      >
                        ×
                      </button>
                    </div>
                  ))}
                </div>
              )}
            </div>

            <VisibilitySelector
              value={editVisibility}
              onChange={setEditVisibility}
              selectedGroupIds={editAllowedGroupIds}
              onSelectedGroupIdsChange={setEditAllowedGroupIds}
              initialGroupId={post.group}
              lockGroup={!!post.group}
            />
            {editMediaError && <p className="post-editor-error" role="alert">{editMediaError}</p>}
            {actionError && <p className="post-editor-error" role="alert">{actionError}</p>}
            </fieldset>
          </div>
        </div>
      )}

      <motion.div
        className="post-detail-scroll post-detail-background"
        {...backgroundInert}
        ref={scrollRef}
        onScroll={(event) => {
          const node = event.currentTarget;
          if (!editing && !commentPage.error && !commentPage.loading && commentPage.hasMore
            && node.scrollHeight > node.clientHeight && node.scrollHeight - node.scrollTop - node.clientHeight < 240) void commentPage.loadMore();
        }}
        inherit={false}
        initial={reduced ? false : usesRoomEntryAnimation ? "out" : "enter"}
        animate={usesRoomEntryAnimation ? "in" : "center"}
        variants={usesRoomEntryAnimation ? surfaceEntryVariants(reduced) : panelVariants(reduced, "right", "left")}
      >
        <article className={`post-card post-detail-card ${usesRoomEntryAnimation ? "reveal" : ""} ${usesRoomEntryAnimation && step === 1 ? "is-in" : ""}`}>
          <div className="post-card-main">
            <header className="post-card-head">
              <Avatar
                label={post.author.nickname || post.author.username}
                size={36}
                online={presenceOnline(onlineUsers, post.author)}
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
                          <PostVideoCover
                            media={media}
                            className="post-card-video-el"
                            ariaLabel="帖子视频"
                            warmUp
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
            <span className="post-card-stat">
              <IconEye width={16} height={16} />
              {post.view_count ?? 0}
            </span>
            <FavoriteButton targetType="post" targetId={post.id} compact className="post-card-fav" />
          </footer>
        </article>

        <div className={`post-detail-comments ${usesRoomEntryAnimation ? "reveal" : ""} ${usesRoomEntryAnimation && step === 1 ? "is-in" : ""}`}>
          {!commentPage.loaded && commentPage.loading && <div role="status" aria-label="正在加载评论">正在加载评论…</div>}
          {commentPage.stale && <button type="button" className="btn btn-ghost" disabled={commentPage.loading} onClick={() => void commentPage.refresh()}>刷新评论</button>}
          {(commentPage.loaded || commentPage.items.length > 0) && <CommentList
            comments={commentPage.items}
            onSend={sendComment}
            onDelete={deleteComment}
            replyTarget={replyTarget}
            onReply={setReplyTarget}
            onReplyClear={() => setReplyTarget(null)}
            hideComposer
            revealItems={usesRoomEntryAnimation}
            suppressEntry={commentPage.suppressEntry}
          />}
          <StablePaginationFooter className="home-load-more" aria-live="polite">
            {commentPage.error ? <div role="alert"><span>{commentPage.error}</span><button type="button" className="btn btn-ghost" onClick={() => void commentPage.retry()}>{commentPage.errorKind === "append" ? "重试加载更多评论" : "重试评论"}</button></div>
              : commentPage.loading && commentPage.loaded ? <span role="status">正在加载更多评论…</span>
              : commentPage.hasMore ? <button type="button" className="btn btn-ghost" onClick={() => void commentPage.loadMore()}>加载更多评论</button>
              : commentPage.loaded && commentPage.items.length > 0 ? <span>已加载全部评论</span> : null}
          </StablePaginationFooter>
        </div>
      </motion.div>
      <CommentComposer
        className="post-detail-composer post-detail-background"
        inert={editing}
        // 底部面板在所有布局都由自己的 20px/300ms 动画持有，不叠加旧 100% 位移。
        inputEntered
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
    </div>,
  );
}
