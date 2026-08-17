/**
 * CommentList —— 评论列表 + 发评论（R-P4，M5-2.1 支持图片评论）。
 *
 * 每条：头像 + 昵称 + 时间 + 内容（支持回复，reply_to 显示"回复 @昵称"）+ 可选图片；
 * 发评论：正文 + 可选图片（先上传 media → 再发送 media_id）+ 可选回复某条；
 * 图片失败保留文件可重试；评论作者可删（is_author）。
 */
import { useState } from "react";
import type { PostComment } from "../../api/types";
import { uploadMediaFile } from "../../api/media";
import { Avatar } from "../Avatar";
import { ResourceImage } from "../ResourceImage";
import { IconImage } from "../icons";

function formatTime(iso: string): string {
  try {
    return new Date(iso).toLocaleString("zh-CN");
  } catch {
    return "";
  }
}

/** 评论图片：内部媒体带 Bearer 鉴权读取（原生 img 会 401） */
function CommentImage({ comment }: { comment: PostComment }) {
  const media = comment.media;
  if (!media || !comment.media_id) return null;
  const thumb = media.thumbnail ? `/api/v1/media/${comment.media_id}/thumbnail` : null;
  const src = thumb ?? `/api/v1/media/${comment.media_id}/content`;
  return (
    <ResourceImage
      src={src}
      alt={comment.body || "评论图片"}
      className="comment-image"
      loading="lazy"
      fallback={<span className="skeleton" style={{ width: 160, height: 120, borderRadius: 10 }} />}
    />
  );
}

export function CommentList({
  comments,
  onSend,
  onDelete,
  replyTarget,
  onReply,
  onReplyClear,
}: {
  comments: PostComment[];
  onSend: (body: string, replyTo: number | null, mediaId?: string | null) => Promise<void>;
  /** 仅评论作者可删 */
  onDelete: (comment: PostComment) => void;
  replyTarget: PostComment | null;
  onReply: (comment: PostComment) => void;
  onReplyClear: () => void;
}) {
  const [body, setBody] = useState("");
  const [sending, setSending] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [failedMedia, setFailedMedia] = useState<File | null>(null);

  const sendComment = async (mediaId?: string | null) => {
    const trimmed = body.trim();
    if ((!trimmed && !mediaId) || sending) return;
    setSending(true);
    setError(null);
    try {
      await onSend(trimmed || (mediaId ? "图片" : ""), replyTarget ? Number(replyTarget.id) : null, mediaId ?? null);
      setBody("");
      setFailedMedia(null);
      if (replyTarget) onReplyClear();
    } catch (e) {
      setError(e instanceof Error ? e.message : "发送失败");
    } finally {
      setSending(false);
    }
  };

  const sendImageFile = async (file: File) => {
    if (sending || uploading) return;
    setUploading(true);
    setError(null);
    setFailedMedia(null);
    try {
      const uploaded = await uploadMediaFile(file, "image");
      await sendComment(uploaded.media_id);
    } catch (err) {
      setFailedMedia(file);
      setError(err instanceof Error ? err.message : "图片发送失败");
    } finally {
      setUploading(false);
    }
  };

  const byId = new Map(comments.map((c) => [c.id, c]));

  return (
    <div className="comment-list">
      <ul className="comment-list-items">
        {comments.length === 0 ? (
          <li className="comment-empty">还没有评论</li>
        ) : (
          comments.map((c) => {
            const replyTo = c.reply_to != null ? byId.get(Number(c.reply_to)) : undefined;
            return (
              <li key={c.id} className="comment-item">
                <Avatar
                  label={c.author.nickname || c.author.username}
                  size={32}
                  online={c.author.online}
                  imageUrl={c.author.avatar || null}
                />
                <div className="comment-body">
                  <span className="comment-nick">{c.author.nickname || c.author.username}</span>
                  <span className="comment-time">{formatTime(c.created_at)}</span>
                  {replyTo && (
                    <span className="comment-reply-hint">
                      回复 @{replyTo.author.nickname || replyTo.author.username}
                    </span>
                  )}
                  {c.media_id && c.media && <CommentImage comment={c} />}
                  <p className="comment-text">{c.body}</p>
                  <div className="comment-actions">
                    <button type="button" className="comment-action" onClick={() => onReply(c)}>
                      回复
                    </button>
                    {c.is_author && (
                      <button type="button" className="comment-action comment-del" onClick={() => onDelete(c)}>
                        删除
                      </button>
                    )}
                  </div>
                </div>
              </li>
            );
          })
        )}
      </ul>

      <div className="comment-composer">
        {replyTarget && (
          <div className="comment-reply-bar">
            回复 @{replyTarget.author.nickname || replyTarget.author.username}
            <button type="button" className="comment-action" onClick={onReplyClear}>
              取消
            </button>
          </div>
        )}
        {error && <p className="post-editor-error">{error}</p>}
        {failedMedia && (
          <button
            type="button"
            className="msg-action-btn"
            disabled={uploading}
            onClick={() => {
              const f = failedMedia;
              setFailedMedia(null);
              setError(null);
              void sendImageFile(f);
            }}
          >
            重试图片
          </button>
        )}
        <div className="composer-row">
          <label className="composer-tool-btn" aria-label="评论发送图片">
            <IconImage width={18} height={18} />
            <input type="file" accept="image/*" hidden onChange={async (e) => {
              const file = e.target.files?.[0];
              e.target.value = "";
              if (!file || sending || uploading) return;
              await sendImageFile(file);
            }} />
          </label>
          <textarea
            className="field composer-input"
            placeholder="写评论…"
            rows={1}
            value={body}
            onChange={(e) => setBody(e.target.value)}
          />
          <button
            type="button"
            className="btn btn-primary"
            disabled={sending || uploading || (!body.trim() && !failedMedia)}
            onClick={() => void sendComment()}
          >
            {sending || uploading ? "发送中…" : "发送"}
          </button>
        </div>
      </div>
    </div>
  );
}
