/**
 * CommentList —— 评论列表 + 发评论（图文同发）。
 *
 * 每条：头像 + 昵称 + 时间 + 正文 + images[] 缩略图（点击弹窗看原图）
 * + 可选回复（reply_to 显示"回复 @昵称"）；评论作者可删（is_author）。
 * 发评论：正文与图片一起发送（Composer 支持多选 ≤4 张，预签名直传）。
 */
import { useState } from "react";
import type { MediaDescriptor, PostComment } from "../../api/types";
import { Avatar } from "../Avatar";
import { ImageViewer } from "../chat/ImageViewer";
import { CommentComposer } from "./CommentComposer";
import { ResourceImage } from "../ResourceImage";
import { mediaContentUrl } from "../../api/media";
import { staggerDelay } from "../../hooks/useRevealOnEnter";
import { useAuthStore } from "../../stores/auth";
import { usePresenceStore } from "../../stores/presence";
import { presenceOnline, withLiveStatus } from "../../utils/displayStatus";
import { goUserProfile } from "../../utils/navigation";
import type { CSSProperties } from "react";

function formatTime(iso: string): string {
  try {
    return new Date(iso).toLocaleString("zh-CN");
  } catch {
    return "";
  }
}

/** 评论图片缩略块：thumbnail 优先（variant=thumb 签缩略图对象），无则回退原图 content */
function CommentThumb({ mediaId, media }: { mediaId: string; media: MediaDescriptor | null }) {
  const thumb = media?.thumbnail || null;
  return (
    <ResourceImage
      src={thumb || mediaContentUrl(mediaId)}
      variant={thumb ? "thumb" : undefined}
      alt="评论图片"
      className="comment-image"
      loading="lazy"
      fallback={<span className="skeleton" style={{ width: 120, height: 90, borderRadius: 10 }} />}
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
  /** body + 图片 mediaId 列表一起提交（图文同发） */
  onSend: (body: string, replyTo: number | null, imageIds: string[]) => Promise<void>;
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
  const onlineUsers = usePresenceStore((s) => s.users);
  const onlineStatuses = usePresenceStore((s) => s.statuses);
  // 查看器状态：某条评论的图片原图画廊
  const [viewer, setViewer] = useState<{ commentId: number; index: number } | null>(null);

  return (
    <div className="comment-list">
      <ul className="comment-list-items">
        {comments.length === 0 ? (
          <li className="comment-empty">还没有评论</li>
        ) : (
          comments.map((c, idx) => {
            const replyTo = c.reply_to != null ? byId.get(Number(c.reply_to)) : undefined;
            const delay = revealItems ? staggerDelay(idx) : 0;
            // 该评论的全部图片 descriptor（新 images[] 或旧单图兼容）
            const imgs = (c.images && c.images.length > 0
              ? c.images
              : c.media
                ? [c.media]
                : []
            ).filter(Boolean);
            return (
              <li
                key={c.id}
                className={`comment-item ${revealItems ? "reveal-item" : ""}`}
                style={revealItems ? ({ ["--reveal-delay" as string]: `${delay}ms` } as CSSProperties) : undefined}
              >
                <Avatar
                  label={c.author.nickname || c.author.username}
                  size={32}
                  online={presenceOnline(onlineUsers, withLiveStatus(onlineStatuses, c.author))}
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
                  {imgs.length > 0 && (
                    <div className={`comment-images count-${Math.min(imgs.length, 4)}`}>
                      {imgs.map((media, i) => (
                        <button
                          key={media.media_id + i}
                          type="button"
                          className="comment-image-btn"
                          onClick={() => setViewer({ commentId: c.id, index: i })}
                          aria-label={`查看评论图片 ${i + 1}/${imgs.length}`}
                        >
                          <CommentThumb mediaId={media.media_id} media={media} />
                        </button>
                      ))}
                    </div>
                  )}
                  {c.body && <p className="comment-text">{c.body}</p>}
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
                {/* 图片原图查看器（Portal 全屏，支持保存） */}
                {viewer?.commentId === c.id && imgs[viewer.index] && (
                  <ImageViewer
                    media={imgs[viewer.index]}
                    alt={c.body || `评论图片 ${viewer.index + 1}`}
                    onClose={() => setViewer(null)}
                  />
                )}
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
