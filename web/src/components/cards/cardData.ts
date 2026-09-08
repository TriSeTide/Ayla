import type { GameRoom, LiveChannelDescriptor, Post, UserPublic, VoiceChannelDescriptor } from "../../api/types";
import { getVisibilityLabels } from "../../utils/visibility";

/** Card projections accept older summaries without inventing missing author/count/status fields. */
export type PostCardData = Partial<Omit<Post, "id" | "author">> & {
  id: string | number;
  author?: Partial<UserPublic>;
  author_nickname?: string;
};
export type LiveCardData = Partial<Omit<LiveChannelDescriptor, "id">> & { id: string | number; title: string };
export type GameCardData = Partial<Omit<GameRoom, "id">> & { id: string | number; name: string };
export type VoiceCardData = Partial<Omit<VoiceChannelDescriptor, "id">> & { id: string; name: string };

export function cardVisibilityLabels(item: Pick<LiveCardData, "visibility" | "allowed_group_names" | "group_name">) {
  return item.visibility ? getVisibilityLabels({ ...item, visibility: item.visibility }) : [];
}
