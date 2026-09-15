/**
 * 分享消息路由解析与展示文案。
 * 与 App.tsx 路由表对齐：
 *   group     → /group/:id
 *   voice     → /group/:groupId/voice/:channelId（群内有条目）| /voice/:channelId
 *   live      → /group/:groupId/live/:channelId（群内有条目）| /live/:channelId
 *   post      → /group/:groupId/posts/:postId（群内有条目）| /posts/:postId
 *   boardgame → /group/:groupId/games（群内有条目）| /games/:roomId
 *   user      → /user/:userId
 *
 * 跳转分流（2026-09-15 用户定稿）：群聊里点击分享消息时，若分享目标在该群
 * 目录中有对应条目 → 跳群内路径进入；没有 → 跳群外路径。存在性检查走
 * 各域 scope=group:<id> 目录接口（量级小，足够判断；失败保守回落群外）。
 * 从分享卡片进入的页面：调用方 navigate 携带 state.fromShare=true，群内场景
 * 对 fromShare 免白名单校验（任何人点进都能看到）。
 */
import type { SharePayload, ShareType } from "../api/types";
import * as boardgameApi from "../api/boardgame";
import * as liveApi from "../api/live";
import * as postsApi from "../api/posts";
import * as voiceApi from "../api/voice";

/** 分享来源展示名（转发卡片图标说明/预览兜底） */
export const SHARE_TYPE_LABELS: Record<ShareType, string> = {
  group: "群聊",
  voice: "语音房",
  live: "直播间",
  post: "帖子",
  boardgame: "桌游室",
  user: "用户",
};

export const SHARE_TYPES: ShareType[] = [
  "group",
  "voice",
  "live",
  "post",
  "boardgame",
  "user",
];

/** 群内路径（groupId 上下文中展示/直用；boardgame 为群内桌游场景页） */
function inGroupRoute(shareType: ShareType, groupId: string, targetId: string): string {
  const g = encodeURIComponent(groupId);
  const id = encodeURIComponent(targetId);
  switch (shareType) {
    case "group":
      return `/group/${id}`;
    case "voice":
      return `/group/${g}/voice/${id}`;
    case "live":
      return `/group/${g}/live/${id}`;
    case "post":
      return `/group/${g}/posts/${id}`;
    case "boardgame":
      return `/group/${g}/games`;
    case "user":
      return `/user/${id}`;
    default:
      return `/group/${g}`;
  }
}

/** 群外路径（大厅/列表/详情） */
function outRoute(shareType: ShareType, targetId: string): string {
  const id = encodeURIComponent(targetId);
  switch (shareType) {
    case "group":
      return `/group/${id}`;
    case "voice":
      return `/voice/${id}`;
    case "live":
      return `/live/${id}`;
    case "post":
      return `/posts/${id}`;
    case "boardgame":
      return `/games/${id}`;
    case "user":
      return `/user/${id}`;
    default:
      return `/group/${id}`;
  }
}

/** 目标在该群的目录条目 id 集合（scope=group:<id>；量级小足够判断；失败空集回落群外） */
async function groupEntryIds(shareType: ShareType, groupId: string): Promise<Set<string>> {
  const scope = `group:${groupId}`;
  try {
    switch (shareType) {
      case "voice": {
        const items = await voiceApi.listVoiceChannels({ scope });
        return new Set((items ?? []).map((c) => String(c.id)));
      }
      case "live": {
        const items = await liveApi.listLiveChannels({ scope });
        return new Set((items ?? []).map((c) => String(c.id)));
      }
      case "post": {
        const page = await postsApi.listPosts({ scope: scope as never });
        return new Set((page?.results ?? []).map((p) => String(p.id)));
      }
      case "boardgame": {
        const items = await boardgameApi.listGameRooms({ scope });
        return new Set((items ?? []).map((r) => String(r.id)));
      }
      default:
        return new Set();
    }
  } catch {
    return new Set();
  }
}

/**
 * 点击跳转分流（异步）：群聊上下文（groupId 非空）时先查群内条目，
 * 命中 → 群内路径；未命中/群外 → 群外路径。目录读取失败保守回落群外。
 */
export async function resolveShareTarget(
  payload: SharePayload | null | undefined,
  groupId?: string | null,
): Promise<string | null> {
  if (!payload || !payload.target_id || !SHARE_TYPES.includes(payload.share_type)) return null;
  const targetId = String(payload.target_id);
  if (groupId) {
    const ids = await groupEntryIds(payload.share_type, groupId);
    if (ids.has(targetId)) return inGroupRoute(payload.share_type, groupId, targetId);
  }
  return outRoute(payload.share_type, targetId);
}

/** 静态路由（不做存在性检查；测试/展示用：groupId 非空即群内路径） */
export function shareTargetRoute(
  payload: SharePayload | null | undefined,
  groupId?: string | null,
): string | null {
  if (!payload || !payload.target_id || !SHARE_TYPES.includes(payload.share_type)) return null;
  const targetId = String(payload.target_id);
  if (groupId) return inGroupRoute(payload.share_type, groupId, targetId);
  return outRoute(payload.share_type, targetId);
}

/** 会话列表/引用预览兜底文案：「[分享]标题」（后端 preview 缺失时前端使用） */
export function sharePreviewText(payload: SharePayload | null | undefined, content?: string): string {
  const title = payload?.title?.trim();
  if (title) return `[分享]${title}`;
  const c = (content ?? "").trim();
  return c ? `[分享]${c}` : "[分享]";
}
