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
  GroupInvite,
  GroupJoinRequest,
  SubGroup,
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

/** POST /chat/conversations/group/ —— 建群 {title, member_ids[]}（后端 GroupCreateView 真实挂载路由） */
export function createGroupConversation(payload: {
  title: string;
  member_ids: string[];
}) {
  return apiRequest<ConversationDetail>("/chat/conversations/group/", {
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
  if (params.subgroup_id != null) qs.set("subgroup_id", String(params.subgroup_id));
  const suffix = qs.toString() ? `?${qs.toString()}` : "";
  return apiRequest<ChatMessage[]>(`/chat/conversations/${convId}/messages/${suffix}`);
}

/* ---------- 群聊子群 ---------- */

/** GET /chat/conversations/<id>/subgroups/ —— 子群列表（含本人未读） */
export function listSubgroups(convId: string) {
  return apiRequest<SubGroup[]>(`/chat/conversations/${convId}/subgroups/`);
}

/** POST /chat/conversations/<id>/subgroups/ —— 创建子群（仅群主/管理员） */
export function createSubgroup(convId: string, name: string) {
  return apiRequest<SubGroup>(`/chat/conversations/${convId}/subgroups/`, {
    method: "POST",
    body: { name },
  });
}

/** PATCH /chat/conversations/<id>/subgroups/<sid>/ —— 子群改名/禁言开关（仅群主/管理员） */
export function updateSubgroup(
  convId: string,
  subgroupId: string,
  patch: { name?: string; muted?: boolean },
) {
  return apiRequest<SubGroup>(
    `/chat/conversations/${convId}/subgroups/${subgroupId}/`,
    { method: "PATCH", body: patch },
  );
}

/** PATCH /chat/conversations/<id>/subgroups/<sid>/ —— 子群改名（仅群主/管理员） */
export function renameSubgroup(convId: string, subgroupId: string, name: string) {
  return updateSubgroup(convId, subgroupId, { name });
}

/** DELETE /chat/conversations/<id>/subgroups/<sid>/ —— 删除子群（消息归默认组；默认组不可删） */
export function deleteSubgroup(convId: string, subgroupId: string) {
  return apiRequest<{ detail: string }>(
    `/chat/conversations/${convId}/subgroups/${subgroupId}/`,
    { method: "DELETE" },
  );
}

/** POST /chat/conversations/<id>/subgroups/<sid>/read/ —— 把该子群标已读（本人） */
export function markSubgroupRead(convId: string, subgroupId: string) {
  return apiRequest<{ marked: number }>(
    `/chat/conversations/${convId}/subgroups/${subgroupId}/read/`,
    { method: "POST" },
  );
}

/** POST /chat/conversations/<id>/messages/ —— 发消息（幂等） */
export function sendMessage(convId: string, payload: CreateMessagePayload) {
  return apiRequest<ChatMessage>(`/chat/conversations/${convId}/messages/`, {
    method: "POST",
    body: payload,
  });
}

/** POST /chat/conversations/<id>/messages/ —— 戳一戳（type=poke，content=目标用户 id）。
 *  免打扰轻互动：落库进历史，但不产生未读/红点/已读回执。 */
export function sendPoke(convId: string, targetUserId: string) {
  return apiRequest<ChatMessage>(`/chat/conversations/${convId}/messages/`, {
    method: "POST",
    body: {
      type: "poke" as const,
      content: targetUserId,
      idempotency_key: crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random()}`,
    },
  });
}

/** POST /chat/conversations/<id>/read/ —— 将会话当前消息全部标已读 */
export function markConversationRead(
  convId: string,
  payload: { through_seq?: number; exclude_message_ids?: string[]; preserve_special?: boolean } = {},
) {
  return apiRequest<{ detail: string }>(`/chat/conversations/${convId}/read/`, {
    method: "POST",
    body: payload,
  });
}

/** POST /chat/conversations/<id>/pin/ —— 置顶/取消置顶会话（本人视图） */
export function togglePinConversation(
  convId: string,
  pinned: boolean,
) {
  return apiRequest<{ pinned: boolean; detail: string }>(
    `/chat/conversations/${convId}/pin/`,
    { method: "POST", body: { pinned } },
  );
}

/** POST /chat/conversations/<id>/hide/ —— 从本人列表删除（隐藏）会话，不删消息 */
export function hideConversation(convId: string) {
  return apiRequest<{ detail: string; hidden: boolean }>(
    `/chat/conversations/${convId}/hide/`,
    { method: "POST" },
  );
}

/** POST /chat/conversations/<id>/messages/<mid>/read/ —— 标已读 */
export function markMessageRead(convId: string, messageId: string, exact = false) {
  return apiRequest<{ detail: string }>(
    `/chat/conversations/${convId}/messages/${messageId}/read/`,
    { method: "POST", body: exact ? { exact: true } : undefined },
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
export function setMemberRole(convId: string, userId: string, role: "member" | "admin") {
  return apiRequest<ConversationDetail>(`/chat/conversations/${convId}/members/${encodeURIComponent(userId)}/role/`, {
    method: "PATCH", body: { role },
  });
}

export function transferGroupOwner(convId: string, userId: string) {
  return apiRequest<ConversationDetail>(`/chat/conversations/${convId}/transfer-owner/`, { method: "POST", body: { user_id: userId } });
}

export function leaveGroup(convId: string) {
  return apiRequest<{ left: boolean }>(`/chat/conversations/${convId}/leave/`, { method: "POST" });
}

export function dissolveGroup(convId: string) {
  return apiRequest<{ deleted: boolean }>(`/chat/conversations/${convId}/dissolve/`, { method: "DELETE" });
}

export type GroupJoinResponse = GroupJoinRequest | { status: "accepted"; conversation_id: string };

export function applyToGroup(convId: string, message: string) {
  return apiRequest<GroupJoinResponse>(`/chat/conversations/${convId}/join-requests/`, { method: "POST", body: { message } });
}

export function toggleMute(convId: string, userId: string, muted: boolean) {
  return apiRequest<{ detail: string; muted: boolean }>(
    `/chat/conversations/${convId}/members/${encodeURIComponent(userId)}/mute/`,
    { method: "POST", body: { muted } },
  );
}

/** PATCH /chat/conversations/<id>/ —— 改群标题/公告/头像（群管理员） */
export function patchConversation(
  convId: string,
  payload: { title?: string; announcement?: string; avatar?: string; join_policy?: "public" | "application" },
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

/* ---------- 群申请/邀请（S2，开发文档 §1.2） ---------- */

/** GET /chat/conversations/<id>/join-requests/ —— 待审批入群申请列表（owner/admin） */
export function listJoinRequests(convId: string) {
  return apiRequest<GroupJoinRequest[]>(
    `/chat/conversations/${convId}/join-requests/`,
  );
}

/** POST /chat/join-requests/<id>/action/ —— 同意/拒绝入群申请 */
export function actionJoinRequest(requestId: number, action: "accept" | "reject") {
  return apiRequest<{ detail: string }>(`/chat/join-requests/${requestId}/action/`, {
    method: "POST",
    body: { action },
  });
}

/** GET /chat/me/invites/ —— 我收到的入群邀请 */
export function listMyInvites() {
  return apiRequest<GroupInvite[]>("/chat/me/invites/");
}

/** GET /chat/leave-notices/ —— 当前用户未读退群通知 */
export function listLeaveNotices() {
  return apiRequest<import("./types").GroupMemberLeaveNotice[]>("/chat/leave-notices/");
}

/** POST /chat/leave-notices/<id>/read/ —— 标记退群通知已读 */
export function readLeaveNotice(noticeId: number) {
  return apiRequest<{ read: boolean }>(`/chat/leave-notices/${noticeId}/read/`, { method: "POST" });
}

/** POST /chat/invites/<id>/action/ —— 接受/拒绝入群邀请 */
export function actionGroupInvite(inviteId: number, action: "accept" | "reject") {
  return apiRequest<{ detail: string }>(`/chat/invites/${inviteId}/action/`, {
    method: "POST",
    body: { action },
  });
}
