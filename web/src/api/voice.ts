/**
 * 语音 API：频道 REST（M5-3 §3）。
 *
 * 契约来源：backend/apps/voice/views.py（挂 /api/v1/voice/）。
 *
 * 错误语义（调用方按 ApiError.status 分支提示，不静默吞掉）：
 * - join：LiveKit 未配置 → 503；频道不存在 → 404
 * - heartbeat：非成员 → 403（调用方应视为已被移出，本地重置）
 *
 * 纪律：LiveKit token 是媒体凭据，本层不打日志、不缓存跨房间复用。
 */
import { apiRequest } from "./client";
import { useAuthStore } from "../stores/auth";
import { mediaPageQuery, type MediaPage, type MediaPageParams } from "./mediaPagination";
import { directoryQuery, type DirectoryPage, type DirectoryParams } from "./directory";
import type {
  VoiceChannelDescriptor,
  VoiceChannelMemberDescriptor,
  VoiceChatMessage,
  VoiceJoinResult,
  VoiceMediaTokenResult,
} from "./types";

/* ---------- 频道 REST ---------- */

/** GET /voice/channels/ —— 频道列表（含 member_count/mine；?scope=group:<id> 群内过滤） */
export function listVoiceChannels(params?: { scope?: string }) {
  const query = params?.scope ? `?scope=${encodeURIComponent(params.scope)}` : "";
  return apiRequest<VoiceChannelDescriptor[]>(`/voice/channels/${query}`);
}

export function listVoiceChannelsPage(params: DirectoryParams & {
  /** 分类选项卡：public/friends/group（后端过滤） */
  visibility?: "public" | "friends" | "group";
  /** 分类选项卡：只看我的好友发布的内容（作者是好友） */
  friends?: boolean;
  /** 分类选项卡：有人（member_count>0） */
  occupied?: boolean;
  /** 分类选项卡：我的（owner_id=当前用户） */
  owner?: string;
} = {}) {
  const query = directoryQuery(params);
  if (params.visibility) query.set("visibility", params.visibility);
  if (params.friends) query.set("friends", "1");
  if (params.occupied) query.set("occupied", "1");
  if (params.owner) query.set("owner", params.owner);
  return apiRequest<DirectoryPage<VoiceChannelDescriptor>>(`/voice/channels/?${query}`);
}

/** POST /voice/channels/ —— 建频道（name 空 → 400；group 可选，群内创建归属该群） */
export function createVoiceChannel(name: string, group?: string | null, payload: { visibility?: "public" | "friends" | "group"; allowed_group_ids?: string[] } = {}) {
  return apiRequest<VoiceChannelDescriptor>("/voice/channels/", {
    method: "POST",
    body: { name, ...(group ? { group } : {}), ...payload },
  });
}

/** GET /voice/channels/<id>/ —— 详情（含 member_count/mine） */
export function getVoiceChannel(channelId: string) {
  return apiRequest<VoiceChannelDescriptor>(
    `/voice/channels/${encodeURIComponent(channelId)}/`,
  );
}

/** PATCH /voice/channels/<id>/ —— 改名（仅 owner，否则 403） */
export function renameVoiceChannel(channelId: string, name: string) {
  return apiRequest<VoiceChannelDescriptor>(
    `/voice/channels/${encodeURIComponent(channelId)}/`,
    { method: "PATCH", body: { name } },
  );
}

/**
 * POST /voice/channels/<id>/join/ —— 加入频道（成员落表，幂等）。
 *
 * 响应带 `media` 旁路字段：服务端裁决 transport（livekit | ws_relay），并**同时下发**
 * 两种配置，使客户端可在 LiveKit 连接失败时原地降级到 WS 中继而无需二次请求。
 * 本层只做类型透传，不解析/不缓存 token。
 */
export function joinVoiceChannel(channelId: string) {
  return apiRequest<VoiceJoinResult>(
    `/voice/channels/${encodeURIComponent(channelId)}/join/`,
    { method: "POST" },
  );
}

/**
 * POST /voice/channels/<id>/media-token/ —— 续签媒体 token（长时通话用）。
 * 响应 `media` 与 join 同一套形状；调用方按 media.livekit.ttl 提前续签。
 */
export function fetchVoiceMediaToken(channelId: string) {
  return apiRequest<VoiceMediaTokenResult>(
    `/voice/channels/${encodeURIComponent(channelId)}/media-token/`,
    { method: "POST" },
  );
}

/** POST /voice/channels/<id>/leave/ —— 离开（幂等，重复离开返回同样结果） */
export function actionVoiceMember(channelId: string, userId: string, action: "kick" | "transfer") {
  return apiRequest<VoiceChannelDescriptor>(`/voice/channels/${encodeURIComponent(channelId)}/members/${encodeURIComponent(userId)}/action/`, { method: "POST", body: { action } });
}

export function deleteVoiceChannel(channelId: string) {
  return apiRequest<{ deleted: boolean }>(`/voice/channels/${encodeURIComponent(channelId)}/`, { method: "DELETE" });
}

export function leaveVoiceChannel(channelId: string, accessToken?: string) {
  return apiRequest<{ left: boolean }>(
    `/voice/channels/${encodeURIComponent(channelId)}/leave/`,
    { method: "POST", ...(accessToken == null ? {} : {
      // A cancelled join may finish after logout. Compensation belongs to the
      // original account and must never refresh/retry with a later account.
      auth: false, noRetry401: true, headers: { Authorization: `Bearer ${accessToken}` },
    }) },
  );
}

/** POST /voice/channels/<id>/heartbeat/ —— presence 心跳；非成员 → 403 */
export function heartbeatVoiceChannel(channelId: string) {
  return apiRequest<{ ok: boolean }>(
    `/voice/channels/${encodeURIComponent(channelId)}/heartbeat/`,
    { method: "POST" },
  );
}

/** Complete runtime reconciliation, assembled from bounded reads before publishing. */
export async function listVoiceChannelMembers(channelId: string) {
  const owner = useAuthStore.getState().currentUser?.id;
  const rows = new Map<string, VoiceChannelMemberDescriptor>();
  const seenCursors = new Set<string>();
  let cursor: string | null = null;
  do {
    if (useAuthStore.getState().currentUser?.id !== owner) throw new DOMException("成员对账所属账号已改变", "AbortError");
    const page = await listVoiceChannelMembersPage(channelId, { cursor, limit: 100 });
    if (useAuthStore.getState().currentUser?.id !== owner) throw new DOMException("成员对账所属账号已改变", "AbortError");
    page.results.forEach((member) => rows.set(member.user_id, member));
    if (!page.has_more) return [...rows.values()];
    if (!page.next_cursor || seenCursors.has(page.next_cursor) || !page.results.length) {
      throw new Error("成员对账分页响应缺少有效的继续位置，请重试");
    }
    seenCursors.add(page.next_cursor);
    cursor = page.next_cursor;
  } while (cursor);
  return [...rows.values()];
}

/** Visible member pages; connection reconciliation retains its complete snapshot. */
export function listVoiceChannelMembersPage(channelId: string, params: MediaPageParams = {}) {
  return apiRequest<MediaPage<VoiceChannelMemberDescriptor>>(
    `/voice/channels/${encodeURIComponent(channelId)}/members/?${mediaPageQuery({ limit: 20, ...params })}`,
  );
}

/** GET /voice/channels/<id>/messages/ —— 语音房独立聊天历史 */
export function listVoiceChatMessages(channelId: string, limit = 100) {
  return apiRequest<VoiceChatMessage[]>(
    `/voice/channels/${encodeURIComponent(channelId)}/messages/?limit=${limit}`,
  );
}

export function listVoiceChatMessagesPage(channelId: string, params: MediaPageParams = {}) {
  return apiRequest<MediaPage<VoiceChatMessage>>(
    `/voice/channels/${encodeURIComponent(channelId)}/messages/?${mediaPageQuery(params)}`,
  );
}

/** POST /voice/channels/<id>/messages/ —— 语音房独立聊天（可带图片） */
export function sendVoiceChatMessage(
  channelId: string,
  payload: { content: string; media_id?: string | null },
) {
  return apiRequest<VoiceChatMessage>(
    `/voice/channels/${encodeURIComponent(channelId)}/messages/`,
    { method: "POST", body: payload },
  );
}
