/**
 * 分享 payload 组装纯函数（六类来源 → SharePayload 契约，可单测）。
 * 与后端 CreateMessageSerializer.SHARE_TYPES 契约一致；
 * cover 只接受站内相对路径（/ 开头），其余归一为 null。
 */
import type { SharePayload, ShareType } from "../api/types";

function normalizeCover(cover: string | null | undefined): string | null {
  if (typeof cover === "string" && cover.startsWith("/") && cover.length > 1) return cover;
  return null;
}

function s(value: unknown): string {
  const t = String(value ?? "").trim();
  return t;
}

/** 群聊分享：群 id/群名/群头像/成员数/加入方式（join_policy 供 GROUP REQUEST 弹窗识别公开/申请制） */
export function groupSharePayload(conv: {
  id: string | number;
  title: string;
  avatar?: string | null;
  member_count?: number;
  join_policy?: "public" | "application" | null;
}): SharePayload {
  const extra: Record<string, unknown> = {};
  if (typeof conv.member_count === "number" && conv.member_count > 0) {
    extra.member_count = conv.member_count;
  }
  if (conv.join_policy) {
    extra.join_policy = conv.join_policy;
  }
  return {
    share_type: "group",
    target_id: String(conv.id),
    title: s(conv.title),
    cover: normalizeCover(conv.avatar),
    subtitle: typeof conv.member_count === "number" && conv.member_count > 0 ? `${conv.member_count} 人` : null,
    extra,
  };
}

/** 语音房分享：频道 id/房名/在线人数/群归属（群内场景带 group_id） */
export function voiceSharePayload(ch: {
  id: string | number;
  name: string;
  member_count?: number | null;
  group_id?: string | null;
}): SharePayload {
  return {
    share_type: "voice",
    target_id: String(ch.id),
    title: s(ch.name),
    cover: null,
    subtitle: typeof ch.member_count === "number" && ch.member_count > 0 ? `${ch.member_count} 人` : null,
    extra: ch.group_id ? { group_id: String(ch.group_id) } : null,
  };
}

/** 直播间分享：频道 id/标题/封面/主播名/群归属 */
export function liveSharePayload(ch: {
  id: string | number;
  title: string;
  cover?: string | null;
  owner_name?: string | null;
  group_id?: string | null;
}): SharePayload {
  return {
    share_type: "live",
    target_id: String(ch.id),
    title: s(ch.title),
    cover: normalizeCover(ch.cover),
    subtitle: ch.owner_name ? s(ch.owner_name) : null,
    extra: ch.group_id ? { group_id: String(ch.group_id) } : null,
  };
}

/** 帖子分享：帖子 id/标题/正文首句摘要/群归属/首图封面 */
export function postSharePayload(
  post: { id: number; title: string; body?: string; group?: string | null },
  cover?: string | null,
): SharePayload {
  const body = s(post.body).replace(/\s+/g, " ");
  const subtitle = body ? (body.length > 24 ? `${body.slice(0, 24)}…` : body) : null;
  return {
    share_type: "post",
    target_id: String(post.id),
    title: s(post.title),
    cover: normalizeCover(cover),
    subtitle,
    extra: post.group ? { group_id: String(post.group) } : null,
  };
}

/** 桌游室分享：房间 id/房名/群归属 */
export function boardgameSharePayload(room: {
  id: number;
  name: string;
  group?: string | null;
  game_type?: string | null;
}): SharePayload {
  const extra: Record<string, unknown> = {};
  if (room.group) extra.group_id = String(room.group);
  if (room.game_type) extra.game_type = room.game_type;
  return {
    share_type: "boardgame",
    target_id: String(room.id),
    title: s(room.name),
    cover: null,
    subtitle: room.game_type ? s(room.game_type) : null,
    extra: Object.keys(extra).length ? extra : null,
  };
}

/** 用户分享（名片）：用户 id/昵称/头像 */
export function userSharePayload(user: {
  id: string;
  nickname?: string | null;
  username?: string;
  avatar?: string | null;
}): SharePayload {
  return {
    share_type: "user",
    target_id: String(user.id),
    title: s(user.nickname) || s(user.username) || "用户",
    cover: normalizeCover(user.avatar),
    subtitle: null,
    extra: null,
  };
}

/** 六类组装的分发（测试/通用入口用） */
export const SHARE_PAYLOAD_BUILDERS: Record<ShareType, (arg: never) => SharePayload> = {
  group: groupSharePayload as never,
  voice: voiceSharePayload as never,
  live: liveSharePayload as never,
  post: postSharePayload as never,
  boardgame: boardgameSharePayload as never,
  user: userSharePayload as never,
};
