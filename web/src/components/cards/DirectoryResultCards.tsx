import type { ReactNode } from "react";
import type { ChatMessage, Favorite, FavoriteMessageTarget, SearchGroupItem } from "../../api/types";
import { Avatar } from "../Avatar";
import { IconMessage } from "../icons";
import { PostCard } from "../posts/PostCard";
import { LiveChannelCard } from "../live/LiveChannelCard";
import { VoiceChannelCard } from "../voice/VoiceChannelCard";
import { GameRoomCard } from "../boardgame/GameRoomCard";
import { MediaContent } from "../chat/MediaContent";
import type { GameCardData, LiveCardData, PostCardData, VoiceCardData } from "./cardData";
import "../../styles/typed-result-cards.css";

type GroupCardData = Partial<SearchGroupItem> & { id: string; title: string; member_count?: number };

/** 收藏消息卡片走 MediaContent 真实渲染的媒体类型（与 MessageBubble 同一集合） */
const MESSAGE_MEDIA_TYPES = new Set(["image", "voice", "file", "emoji", "video", "mixed"]);

export function GroupResultCard({ group, onOpen, entryLabel, action }: {
  group: GroupCardData;
  onOpen: () => void;
  entryLabel?: string;
  action?: ReactNode;
}) {
  return <article className="typed-group-card">
    <button type="button" className="typed-group-main" onClick={onOpen}>
      <Avatar label={group.title} size={44} imageUrl={group.avatar || null} />
      <span className="typed-group-copy"><strong>{group.title}</strong>
        <span className="typed-card-meta">
          {typeof group.member_count === "number" && <span>{group.member_count} 人</span>}
          {group.join_policy && <span>{group.join_policy === "public" ? "公开群聊" : "申请制群聊"}</span>}
        </span>
      </span>
      {entryLabel && <span className="search-row-action">{entryLabel}</span>}
    </button>
    {action}
  </article>;
}

/** A favorite wraps the same scene cards, replacing their favorite control with one direct removal. */
export function FavoriteResultCard({ favorite, onOpen, action }: {
  favorite: Favorite;
  onOpen: () => void;
  action: ReactNode;
}) {
  const target = favorite.target;
  if (target == null) return <article className="typed-unavailable-card">
    <button type="button" className="favorite-item-main" disabled>内容不可用</button>{action}
  </article>;
  const id = favorite.target_id;
  switch (favorite.target_type) {
    case "post": {
      const post = target as PostCardData & { raw_title?: string };
      return <PostCard post={{ ...post, id, title: post.raw_title ?? post.title }} onOpen={onOpen} action={action} previewOnly />;
    }
    case "live":
      return <LiveChannelCard channel={{ ...(target as LiveCardData), id, title: String(target.title ?? "直播间") }} onEnter={onOpen} action={action} />;
    case "voice":
      return <VoiceChannelCard channel={{ ...(target as VoiceCardData), id, name: String(target.name ?? "语音房") }} onEnter={onOpen} action={action} browsing />;
    case "game":
      return <GameRoomCard room={{ ...(target as GameCardData), id, name: String(target.name ?? "桌游房") }} onEnter={onOpen} action={action} />;
    case "message": {
      const msg = target as Partial<FavoriteMessageTarget>;
      // 构造聊天气泡形状：收藏卡片复用 MediaContent 真实渲染媒体
      // （descriptor 缺失时按 media_id 补拉，与 WS 帧路径同一契约）。
      const message: ChatMessage = {
        id: msg.id ?? favorite.target_id,
        conversation_id: msg.conversation_id ?? "",
        sender_id: msg.sender_id ?? "",
        type: msg.type ?? "text",
        content: msg.content ?? "",
        media_id: msg.media_id ?? null,
        media: null,
        segments: msg.segments ?? null,
        reply_to: msg.reply_to ?? null,
        status: msg.status ?? "sent",
        seq: msg.seq ?? 0,
        created_at: msg.created_at ?? "",
      };
      const recalled = message.status === "recalled";
      const isMedia = MESSAGE_MEDIA_TYPES.has(message.type);
      const canOpen = Boolean(msg.conversation_id);
      // 整卡可点（空白处也跳转）：媒体本体与取消收藏按钮自带交互并
      // stopPropagation，不触发跳转；主按钮 stopPropagation 避免事件
      // 冒泡到整卡 onClick 重复跳转。
      return (
        <article
          className={`typed-message-card${canOpen ? " is-openable" : ""}`}
          onClick={canOpen ? onOpen : undefined}
        >
          <button
            type="button"
            className="typed-message-main"
            onClick={(event) => { event.stopPropagation(); onOpen(); }}
            disabled={!canOpen}
          >
            <span className="typed-message-heading"><IconMessage width={18} height={18} />
              <span>{typeof msg.sender_nickname === "string" && msg.sender_nickname ? msg.sender_nickname : "消息"}</span>
            </span>
            {recalled ? (
              <span className="typed-message-recalled">该消息已撤回</span>
            ) : message.type === "poke" ? (
              <span className="typed-message-recalled">戳一戳消息</span>
            ) : !isMedia ? (
              <blockquote>{message.content}</blockquote>
            ) : null}
          </button>
          {/* 媒体本体独立于跳转按钮：图片/语音/文件自带交互（查看/播放/下载），
              点击媒体不触发跳转；点击头部/文本/空白区域跳转到原消息位置。 */}
          {!recalled && isMedia && (
            <div className="typed-message-media" onClick={(event) => event.stopPropagation()}>
              <MediaContent msg={message} />
            </div>
          )}
          {action}
        </article>
      );
    }
  }
}
