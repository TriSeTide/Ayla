import type { ReactNode } from "react";
import type { Favorite, SearchGroupItem } from "../../api/types";
import { Avatar } from "../Avatar";
import { IconMessage } from "../icons";
import { PostCard } from "../posts/PostCard";
import { LiveChannelCard } from "../live/LiveChannelCard";
import { VoiceChannelCard } from "../voice/VoiceChannelCard";
import { GameRoomCard } from "../boardgame/GameRoomCard";
import type { GameCardData, LiveCardData, PostCardData, VoiceCardData } from "./cardData";
import "../../styles/typed-result-cards.css";

type GroupCardData = Partial<SearchGroupItem> & { id: string; title: string; member_count?: number };

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
    case "group":
      return <GroupResultCard group={{ ...(target as GroupCardData), id, title: String(target.title ?? "群聊") }} onOpen={onOpen} action={action} />;
    case "message":
      return <article className="typed-message-card">
        <button type="button" className="typed-message-main" onClick={onOpen} disabled={!target.conversation_id}>
          <span className="typed-message-heading"><IconMessage width={18} height={18} />
            <span>{typeof target.sender_nickname === "string" ? target.sender_nickname : "消息"}</span>
          </span>
          {typeof target.content === "string" && <blockquote>{target.content}</blockquote>}
        </button>{action}
      </article>;
  }
}
