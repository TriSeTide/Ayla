/**
 * PostCard —— 帖子卡（信息流，design.md §12.8，R-P1）。
 *
 * 头部：作者头像(光环) + 昵称 + 时间；正文 15px 超 3 行折叠"展开/收起"；
 * 图片九宫格（1 图大图 / 多图 3 列，缩略图）；底排评论数 + 收藏（激活态填 --pink-500）。
 * 点击进入帖子详情（onOpen，父级 navigate）。
 */
import { useState, type ReactNode } from "react";
import { cardVisibilityLabels, type PostCardData } from "../cards/cardData";
import { Avatar } from "../Avatar";
import { IconEye, IconMessage } from "../icons";
import { FavoriteButton } from "../FavoriteButton";
import { ResourceImage } from "../ResourceImage";
import { PostVideoCover } from "./PostVideoCover";
import { mediaContentUrl } from "../../api/media";
import { useAuthStore } from "../../stores/auth";
import { usePresenceStore } from "../../stores/presence";
import { presenceOnline, presenceStatus } from "../../utils/displayStatus";
import { goUserProfile } from "../../utils/navigation";

function formatTime(iso: string): string {
  try {
    const d = new Date(iso);
    if (!Number.isFinite(d.getTime())) return "";
    const now = new Date();
    const diff = now.getTime() - d.getTime();
    if (diff < 60_000) return "刚刚";
    if (diff < 3600_000) return `${Math.floor(diff / 60_000)} 分钟前`;
    if (diff < 86400_000) return `${Math.floor(diff / 3600_000)} 小时前`;
    return d.toLocaleDateString("zh-CN");
  } catch {
    return "";
  }
}

export function PostCard({
  post,
  onOpen,
  action,
  previewOnly = false,
}: {
  post: PostCardData;
  onOpen: () => void;
  action?: ReactNode;
  /** Directory cards never mount a video decoder, including videos without posters. */
  previewOnly?: boolean;
}) {
  const [expanded, setExpanded] = useState(false);
  const currentUserId = useAuthStore((s) => s.currentUser?.id);
  const onlineUsers = usePresenceStore((s) => s.users);
  const onlineStatuses = usePresenceStore((s) => s.statuses);
  // 媒体列表（图片/视频封面统一走 thumbnail 缩略图；视频无海报帧才降级首帧预览）
  const mediaList = (post.images ?? []).filter((i) => i.media);
  const body = post.body ?? "";
  const longBody = body.length > 120;
  const author = post.author;
  const authorName = author?.nickname || author?.username || post.author_nickname;
  const liveAuthor = author?.id
    ? { id: author.id, status: presenceStatus(onlineStatuses, { id: author.id, status: author.status ?? "auto" }), online: author.online ?? false }
    : undefined;

  const visibilityLabels = cardVisibilityLabels(post);

  return (
    <article className="post-card">
      <div className="post-card-main" onClick={onOpen}>
        <header className="post-card-head">
          {authorName && <Avatar
            label={authorName}
            size={36}
            online={liveAuthor ? presenceOnline(onlineUsers, liveAuthor) : undefined}
            imageUrl={author?.avatar || null}
            onClick={author?.id ? (e) => {
              e.stopPropagation();
              goUserProfile(currentUserId, author.id!);
            } : undefined}
            ariaLabel={`查看 ${authorName} 的个人主页`}
          />}
          {authorName && <span className="post-card-nick">{authorName}</span>}
          {post.created_at && <span className="post-card-time">{formatTime(post.created_at)}</span>}
          {visibilityLabels.length > 0 && (
            <div className="post-card-tags">
              {visibilityLabels.map((label, idx) => (
                <span key={idx} className="post-card-tag">{label}</span>
              ))}
            </div>
          )}
        </header>
        {post.title && <h3 className="post-card-title">{post.title}</h3>}
        <p className={`post-card-body ${expanded ? "is-expanded" : ""}`}>{body}</p>
        {longBody && (
          <button
            type="button"
            className="post-card-fold"
            onClick={(e) => {
              e.stopPropagation();
              setExpanded((v) => !v);
            }}
          >
            {expanded ? "收起" : "展开"}
          </button>
        )}
        {mediaList.length > 0 && (
          <div className={`post-card-images count-${Math.min(mediaList.length, 9)}`}>
            {mediaList.slice(0, 9).map((img) => {
              const media = img.media;
              if (!media) return null;
              return media.kind === "video" ? (
                // 视频卡片：海报帧封面秒出（有 thumbnail 渲染签名缩略图，
                // 不挂 <video> 拉流；无 thumbnail 降级首帧预览）+ 播放角标。
                // thumbnail 是图片/视频共用的派生对象路径，绝不可当 video src
                <div key={img.id} className="post-card-img post-card-video">
                  {previewOnly && !media.thumbnail ? <span className="post-card-video-placeholder" aria-label="帖子视频">视频</span>
                    : <PostVideoCover media={media} className="post-card-video-el" ariaLabel="帖子视频" />}
                  <span className="post-card-video-badge" aria-hidden="true">▶</span>
                </div>
              ) : (
                // 图片卡片：缩略图变体（320px JPEG）优先，无缩略图回退原图；
                // variant=thumb 让 :sign 签发 thumbnail 对象而非 original
                <ResourceImage
                  key={img.id}
                  src={media.thumbnail || mediaContentUrl(media.media_id)}
                  variant={media.thumbnail ? "thumb" : undefined}
                  alt="帖子图片"
                  loading="lazy"
                  className="post-card-img"
                />
              );
            })}
          </div>
        )}
      </div>
      <footer className="post-card-foot">
        <button type="button" className="post-card-open" onClick={onOpen} aria-label="查看帖子">查看帖子</button>
        {typeof post.comment_count === "number" && <span className="post-card-stat">
          <IconMessage width={16} height={16} />
          {post.comment_count}
        </span>}
        {typeof post.view_count === "number" && <span className="post-card-stat">
          <IconEye width={16} height={16} />
          {post.view_count}
        </span>}
        {action === undefined ? <FavoriteButton targetType="post" targetId={post.id} compact className="post-card-fav" /> : action}
      </footer>
    </article>
  );
}
