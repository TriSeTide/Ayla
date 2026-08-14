/**
 * 语音 API：频道 REST + 爱莉 voice-calls 编排端点（M5-3 §3）。
 *
 * 契约来源：
 * - backend/apps/voice/views.py（挂 /api/v1/voice/）
 * - backend/apps/elysia_bridge/views.py ElysiaVoiceCall*（挂 /api/v1/elysia/）
 *
 * 错误语义（调用方按 ApiError.status 分支提示，不静默吞掉）：
 * - join：LiveKit 未配置 → 503；频道不存在 → 404
 * - heartbeat：非成员 → 403（调用方应视为已被移出，本地重置）
 * - 爱莉编排：profile 未初始化/禁用 → 503；Elysium 侧错误 → 502 {detail, code}
 *
 * 纪律：LiveKit token 是媒体凭据，本层不打日志、不缓存跨房间复用。
 */
import { apiRequest } from "./client";
import type {
  ElysiaVoiceCallCreateResult,
  ElysiaVoiceCallStatus,
  ElysiaVoiceCommandResult,
  ElysiaVoicePollResult,
  VoiceChannelDescriptor,
  VoiceChannelMemberDescriptor,
  VoiceJoinResult,
} from "./types";

/* ---------- 频道 REST ---------- */

/** GET /voice/channels/ —— 频道列表（含 member_count/mine） */
export function listVoiceChannels() {
  return apiRequest<VoiceChannelDescriptor[]>("/voice/channels/");
}

/** POST /voice/channels/ —— 建频道（name 空 → 400；group 可选，群内创建归属该群） */
export function createVoiceChannel(name: string, group?: string | null) {
  return apiRequest<VoiceChannelDescriptor>("/voice/channels/", {
    method: "POST",
    body: group ? { name, group } : { name },
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
 * POST /voice/channels/<id>/join/ —— 加入频道拿 LiveKit token。
 * 成员落表幂等（重复 join 安全）；LiveKit 未配置 → 503。
 */
export function joinVoiceChannel(channelId: string) {
  return apiRequest<VoiceJoinResult>(
    `/voice/channels/${encodeURIComponent(channelId)}/join/`,
    { method: "POST" },
  );
}

/** POST /voice/channels/<id>/leave/ —— 离开（幂等，重复离开返回同样结果） */
export function leaveVoiceChannel(channelId: string) {
  return apiRequest<{ left: boolean }>(
    `/voice/channels/${encodeURIComponent(channelId)}/leave/`,
    { method: "POST" },
  );
}

/** POST /voice/channels/<id>/heartbeat/ —— presence 心跳；非成员 → 403 */
export function heartbeatVoiceChannel(channelId: string) {
  return apiRequest<{ ok: boolean }>(
    `/voice/channels/${encodeURIComponent(channelId)}/heartbeat/`,
    { method: "POST" },
  );
}

/** GET /voice/channels/<id>/members/ —— 当前成员列表（WS 重连后对账用） */
export function listVoiceChannelMembers(channelId: string) {
  return apiRequest<VoiceChannelMemberDescriptor[]>(
    `/voice/channels/${encodeURIComponent(channelId)}/members/`,
  );
}

/* ---------- 爱莉语音编排（/api/v1/elysia/voice-calls/） ---------- */

/**
 * POST /elysia/voice-calls/ —— 创建/复用爱莉 Voice Live 通话。
 * 单并发：活跃通话未结束则复用，返回 reused=true（正常路径，不是冲突）。
 */
export function createElysiaVoiceCall(mode = "auto") {
  return apiRequest<ElysiaVoiceCallCreateResult>("/elysia/voice-calls/", {
    method: "POST",
    body: { mode },
  });
}

/** GET /elysia/voice-calls/<call_id>/ —— 通话状态 */
export function getElysiaVoiceCall(callId: string) {
  return apiRequest<{ call: ElysiaVoiceCallStatus }>(
    `/elysia/voice-calls/${encodeURIComponent(callId)}/`,
  );
}

/**
 * POST /elysia/voice-calls/<call_id>/text/ —— 文本注入（真人想对爱莉说的话）。
 * 空文本 → 400（前端应先拦截不发）；服务端带 Idempotency-Key，重试安全。
 */
export function sendElysiaVoiceText(callId: string, text: string) {
  return apiRequest<ElysiaVoiceCommandResult>(
    `/elysia/voice-calls/${encodeURIComponent(callId)}/text/`,
    { method: "POST", body: { text } },
  );
}

/** POST /elysia/voice-calls/<call_id>/end/ —— 结束通话（幂等，重复点击安全） */
export function endElysiaVoiceCall(callId: string) {
  return apiRequest<ElysiaVoiceCommandResult>(
    `/elysia/voice-calls/${encodeURIComponent(callId)}/end/`,
    { method: "POST" },
  );
}

/**
 * POST /elysia/voice-calls/<call_id>/poll/ —— 增量转写投影。
 * 把 final transcript 投影为爱莉消息（幂等，重复轮询不重复落库）。
 * 爱莉发言渲染在聊天链（M5-2 爱莉会话），语音页只展示计数。
 */
export function pollElysiaVoiceCall(callId: string) {
  return apiRequest<ElysiaVoicePollResult>(
    `/elysia/voice-calls/${encodeURIComponent(callId)}/poll/`,
    { method: "POST" },
  );
}
