/**
 * PostCard —— 帖子卡（信息流，design.md §12.8，R-P1）。
 *
 * 头部：作者头像(光环) + 昵称 + 时间；正文 15px 超 3 行折叠"展开/收起"；
 * 图片九宫格（1 图大图 / 多图 3 列，缩略图）；底排评论数 + 收藏（激活态填 --pink-500）。
 * 点击进入帖子详情（onOpen，父级 navigate）。
 */
import { useState } from "react";
import type { Post } from "../../api/types";
import { Avatar } from "../Avatar";
import { IconHeart, IconMessage } from "../icons";
import { ResourceImage } from "../ResourceImage";

function formatTime(iso: string): string {
  try {
    const d = new Date(iso);
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
  favorited,
  onOpen,
  onToggleFavorite,
}: {
  post: Post;
  favorited: boolean;
  onOpen: () => void;
  onToggleFavorite: () => void;
}) {
  const [expanded, setExpanded] = useState(false);
  const images = post.images.filter((i) => i.media?.thumbnail);
  const longBody = post.body.length > 120;

  return (
    <article className="post-card">
      <button type="button" className="post-card-main" onClick={onOpen} aria-label={`查看帖子`}>
        <header className="post-card-head">
          <Avatar
            label={post.author.nickname || post.author.username}
            size={36}
            online={post.author.online}
            imageUrl={post.author.avatar || null}
          />
          <span className="post-card-nick">{post.author.nickname || post.author.username}</span>
          <span className="post-card-time">{formatTime(post.created_at)}</span>
        </header>
        {post.title && <h3 className="post-card-title">{post.title}</h3>}
        <p className={`post-card-body ${expanded ? "is-expanded" : ""}`}>{post.body}</p>
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
        {images.length > 0 && (
          <div className={`post-card-images count-${Math.min(images.length, 9)}`}>
            {images.slice(0, 9).map((img) => (
              <ResourceImage
                key={img.id}
                src={img.media!.thumbnail!}
                alt="帖子图片"
                loading="lazy"
                className="post-card-img"
              />
            ))}
          </div>
        )}
      </button>
      <footer className="post-card-foot">
        <span className="post-card-stat">
          <IconMessage width={16} height={16} />
          {post.comment_count}
        </span>
        <button
          type="button"
          className={`post-card-fav ${favorited ? "is-favorited" : ""}`}
          onClick={onToggleFavorite}
          aria-label={favorited ? "取消收藏" : "收藏"}
          aria-pressed={favorited}
        >
          <IconHeart width={18} height={18} fill={favorited ? "currentColor" : "none"} />
        </button>
      </footer>
    </article>
  );
}
