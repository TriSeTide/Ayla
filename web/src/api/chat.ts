/**
 * 聊天 REST API：与 backend/apps/chat/views.py 真实契约对齐。
 * 路径挂 /api/v1/chat/（client.ts 已加 /api/v1 前缀）。
 *
 * 幂等语义（严格按 M4-2 验收）：
 * - 同 idempotency_key + 同 conversation + 同 sender 重复 POST → 200 + 原消息；
 * - 同 key 内容/type 不同 → 409；
 * - key 被其他会话使用 → 409。
 */
import { apiRequest } from "./client";
import type {
  ChatMessage,
  ConversationDetail,
  ConversationHighlightsMap,
  ConversationMessagesParams,
  ConversationSummary,
  CreateMessagePayload,
} from "./types";

/** GET /chat/conversations/ —— 当前用户会话列表 */
export function listConversations() {
  return apiRequest<ConversationSummary[]>("/chat/conversations/");
}

/** POST /chat/conversations/private/ —— 开启/获取私聊会话 {user_id} */
export function openPrivateConversation(userId: string) {
  return apiRequest<ConversationDetail>("/chat/conversations/private/", {
    method: "POST",
    body: { user_id: userId },
  });
}

/** POST /chat/conversations/ —— 建群 {title, member_ids[]} */
export function createGroupConversation(payload: {
  title: string;
  member_ids: string[];
}) {
  return apiRequest<ConversationDetail>("/chat/conversations/", {
    method: "POST",
    body: payload,
  });
}

/** GET /chat/conversations/<id>/ —— 会话详情 */
export function getConversation(convId: string) {
  return apiRequest<ConversationDetail>(`/chat/conversations/${convId}/`);
}

/** GET /chat/conversations/<id>/messages/?before_seq=&limit= —— 历史分页 */
export function listMessages(convId: string, params: ConversationMessagesParams = {}) {
  const qs = new URLSearchParams();
  if (params.before_seq != null) qs.set("before_seq", String(params.before_seq));
  if (params.limit != null) qs.set("limit", String(params.limit));
  const suffix = qs.toString() ? `?${qs.toString()}` : "";
  return apiRequest<ChatMessage[]>(`/chat/conversations/${convId}/messages/${suffix}`);
}

/** POST /chat/conversations/<id>/messages/ —— 发消息（幂等） */
export function sendMessage(convId: string, payload: CreateMessagePayload) {
  return apiRequest<ChatMessage>(`/chat/conversations/${convId}/messages/`, {
    method: "POST",
    body: payload,
  });
}

/** POST /chat/conversations/<id>/messages/<mid>/read/ —— 标已读 */
export function markMessageRead(convId: string, messageId: string) {
  return apiRequest<{ detail: string }>(
    `/chat/conversations/${convId}/messages/${messageId}/read/`,
    { method: "POST" },
  );
}

/** POST /chat/conversations/<id>/messages/<mid>/recall/ —— 撤回（限时 120s、仅发送者） */
export function recallMessage(convId: string, messageId: string) {
  return apiRequest<ChatMessage>(
    `/chat/conversations/${convId}/messages/${messageId}/recall/`,
    { method: "POST" },
  );
}

/** POST /chat/conversations/<id>/typing/ —— 声明输入中（触发 typing 广播） */
export function declareTyping(convId: string, isTyping: boolean) {
  return apiRequest<{ detail: string }>(`/chat/conversations/${convId}/typing/`, {
    method: "POST",
    body: { is_typing: isTyping },
  });
}

/** POST /chat/conversations/<id>/members/ —— 加人（群管理员） */
export function addMembers(convId: string, userIds: string[]) {
  return apiRequest<ConversationDetail>(`/chat/conversations/${convId}/members/`, {
    method: "POST",
    body: { user_ids: userIds },
  });
}

/** DELETE /chat/conversations/<id>/members/<user_id>/ —— 踢人（群管理员） */
export function removeMember(convId: string, userId: string) {
  return apiRequest<void>(`/chat/conversations/${convId}/members/${encodeURIComponent(userId)}/`, {
    method: "DELETE",
  });
}

/** POST /chat/conversations/<id>/members/<user_id>/mute/ —— 禁言/解除 */
export function toggleMute(convId: string, userId: string, muted: boolean) {
  return apiRequest<{ detail: string; muted: boolean }>(
    `/chat/conversations/${convId}/members/${encodeURIComponent(userId)}/mute/`,
    { method: "POST", body: { muted } },
  );
}

/** PATCH /chat/conversations/<id>/ —— 改群标题/公告（群管理员） */
export function patchConversation(
  convId: string,
  payload: { title?: string; announcement?: string },
) {
  return apiRequest<ConversationDetail>(`/chat/conversations/${convId}/`, {
    method: "PATCH",
    body: payload,
  });
}

/** GET /chat/conversations/highlights/?ids=1,2,3 —— 批量群动态封面（S6） */
export function fetchHighlights(convIds: string[]) {
  if (convIds.length === 0) return Promise.resolve<ConversationHighlightsMap>({});
  const qs = new URLSearchParams({ ids: convIds.join(",") });
  return apiRequest<ConversationHighlightsMap>(
    `/chat/conversations/highlights/?${qs.toString()}`,
  );
}
