/**
 * CommentList —— 评论列表 + 发评论（R-P4）。
 *
 * 每条：头像 + 昵称 + 时间 + 内容（支持回复，reply_to 显示"回复 @昵称"）；
 * 发评论：正文 + 可选回复某条（reply_to 须在本帖内，后端校验）。
 * 评论作者可删（is_author）。
 */
import { useState } from "react";
import type { PostComment } from "../../api/types";
import { Avatar } from "../Avatar";

function formatTime(iso: string): string {
  try {
    return new Date(iso).toLocaleString("zh-CN");
  } catch {
    return "";
  }
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
  onSend: (body: string, replyTo: number | null) => Promise<void>;
  /** 仅评论作者可删 */
  onDelete: (comment: PostComment) => void;
  replyTarget: PostComment | null;
  onReply: (comment: PostComment) => void;
  onReplyClear: () => void;
}) {
  const [body, setBody] = useState("");
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async () => {
    const trimmed = body.trim();
    if (!trimmed || sending) return;
    setSending(true);
    setError(null);
    try {
      await onSend(trimmed, replyTarget ? Number(replyTarget.id) : null);
      setBody("");
      if (replyTarget) onReplyClear();
    } catch (e) {
      setError(e instanceof Error ? e.message : "发送失败");
    } finally {
      setSending(false);
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
        <div className="composer-row">
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
            disabled={sending || !body.trim()}
            onClick={() => void submit()}
          >
            发送
          </button>
        </div>
      </div>
    </div>
  );
}
