/**
 * CommentList —— 评论列表 + 发评论（R-P4，M5-2.1 支持图片评论）。
 *
 * 每条：头像 + 昵称 + 时间 + 内容（支持回复，reply_to 显示"回复 @昵称"）+ 可选图片；
 * 发评论：正文 + 可选图片（先上传 media → 再发送 media_id）+ 可选回复某条；
 * 图片失败保留文件可重试；评论作者可删（is_author）。
 */
import type { PostComment } from "../../api/types";
import { Avatar } from "../Avatar";
import { CommentComposer } from "./CommentComposer";
import { ResourceImage } from "../ResourceImage";
import { staggerDelay } from "../../hooks/useRevealOnEnter";
import { useAuthStore } from "../../stores/auth";
import { goUserProfile } from "../../utils/navigation";
import type { CSSProperties } from "react";

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
  hideComposer = false,
  revealItems = false,
}: {
  comments: PostComment[];
  onSend: (body: string, replyTo: number | null, mediaId?: string | null) => Promise<void>;
  /** 仅评论作者可删 */
  onDelete: (comment: PostComment) => void;
  replyTarget: PostComment | null;
  onReply: (comment: PostComment) => void;
  onReplyClear: () => void;
  /** 是否隐藏评论输入框（用于详情页，输入框固定在底部） */
  hideComposer?: boolean;
  /** 详情页入场：每条评论逐条浮入（stagger，直播间节奏） */
  revealItems?: boolean;
}) {
  const byId = new Map(comments.map((c) => [c.id, c]));
  const currentUserId = useAuthStore((s) => s.currentUser?.id);

  return (
    <div className="comment-list">
      <ul className="comment-list-items">
        {comments.length === 0 ? (
          <li className="comment-empty">还没有评论</li>
        ) : (
          comments.map((c, idx) => {
            const replyTo = c.reply_to != null ? byId.get(Number(c.reply_to)) : undefined;
            const delay = revealItems ? staggerDelay(idx) : 0;
            return (
              <li
                key={c.id}
                className={`comment-item ${revealItems ? "reveal-item" : ""}`}
                style={revealItems ? ({ ["--reveal-delay" as string]: `${delay}ms` } as CSSProperties) : undefined}
              >
                <Avatar
                  label={c.author.nickname || c.author.username}
                  size={32}
                  online={c.author.online}
                  imageUrl={c.author.avatar || null}
                  onClick={() => goUserProfile(currentUserId, c.author.id)}
                  ariaLabel={`查看 ${c.author.nickname || c.author.username} 的个人主页`}
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

      {!hideComposer && (
        <CommentComposer
          onSend={onSend}
          replyTarget={replyTarget}
          onReplyClear={onReplyClear}
        />
      )}
    </div>
  );
}
