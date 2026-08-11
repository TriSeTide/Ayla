/**
 * 与 Ayla/backend 序列化器对齐的 TS 类型。
 * 契约来源：backend/apps/accounts/serializers.py（UserPublicSerializer / RegisterSerializer / ProfileSerializer）
 * 注意：user.id 为字符串（UUID），与后端 CharField 对齐。
 */

/** UserPublicSerializer 字段 */
export interface UserPublic {
  id: string;
  username: string;
  nickname: string;
  avatar: string;
  signature: string;
  /** User.status：online / away / dnd / invisible */
  status: string;
  /** 实时在线（Redis presence，隐身对外视为离线） */
  online: boolean;
  /** ISO 时间字符串 */
  date_joined: string;
}

/** 注册入参（RegisterSerializer） */
export interface RegisterPayload {
  username: string;
  email: string;
  password: string;
  nickname?: string;
}

/** 登录入参（SimpleJWT TokenObtainPairView） */
export interface LoginPayload {
  username: string;
  password: string;
}

/** 令牌对 */
export interface TokenPair {
  access: string;
  refresh: string;
}

/** POST /auth/register/ 返回 */
export interface RegisterResult {
  user: UserPublic;
  access: string;
  refresh: string;
}

/** POST /auth/login/ 返回（ROTATE_REFRESH_TOKENS=True 时 refresh 也会返回） */
export interface LoginResult {
  access: string;
  refresh: string;
}

/** POST /auth/refresh/ 返回：旋转开启时同时返回新 refresh */
export interface RefreshResult {
  access: string;
  refresh?: string;
}

/** 个人资料修改（ProfileSerializer 字段） */
export interface ProfileUpdatePayload {
  nickname?: string;
  avatar?: string;
  signature?: string;
  status?: string;
}

/** 好友关系（FriendshipSerializer） */
export interface Friendship {
  id: number;
  user: UserPublic;
  created_at: string;
}

/** 好友申请（FriendRequestSerializer） */
export interface FriendRequest {
  id: number;
  from_user: UserPublic;
  to_user: UserPublic;
  message: string;
  status: "pending" | "accepted" | "rejected";
  created_at: string;
}

/** 发起好友申请入参 */
export interface FriendRequestPayload {
  to_user_id: string;
  message?: string;
}

/** 后端 DRF 错误结构：{detail} 或 {field: [msg]} 或 {field: msg} */
export type ApiErrorBody = Record<string, unknown>;

/* ================= M5-2 聊天域（对齐 backend/apps/chat/serializers.py） ================= */

export type MessageType = "text" | "image" | "voice" | "file" | "emoji" | "system";
export type MessageStatus = "sent" | "delivered" | "read" | "recalled";

/** MessageSerializer 字段（id/conversation_id/sender_id 均为字符串） */
export interface ChatMessage {
  id: string;
  conversation_id: string;
  sender_id: string;
  type: MessageType;
  content: string;
  media_id: string | null;
  reply_to: string | null;
  status: MessageStatus;
  /** 会话内单调递增序号（补发/分页游标） */
  seq: number;
  /** ISO 时间 */
  created_at: string;
}

/** ConversationMemberSerializer 字段 */
export interface ConversationMember {
  id: string;
  user: UserPublic;
  role: "member" | "admin" | "owner";
  muted: boolean;
  joined_at: string;
}

export type ConversationType = "private" | "group";

/** ConversationListSerializer 字段（会话列表用） */
export interface ConversationSummary {
  id: string;
  type: ConversationType;
  title: string;
  announcement: string;
  owner_id: string;
  members: ConversationMember[];
  my_role: "member" | "admin" | "owner" | null;
  member_count: number;
  unread_count: number;
  created_at: string;
  /** 私聊对端用户（ConversationListSerializer 补充） */
  peer: UserPublic | null;
}

/** ConversationSerializer 字段（详情用，比列表少 peer） */
export interface ConversationDetail {
  id: string;
  type: ConversationType;
  title: string;
  announcement: string;
  owner_id: string;
  members: ConversationMember[];
  my_role: "member" | "admin" | "owner" | null;
  member_count: number;
  unread_count: number;
  created_at: string;
}

/** CreateMessageSerializer 入参 */
export interface CreateMessagePayload {
  type?: MessageType;
  content: string;
  reply_to?: number | null;
  idempotency_key?: string;
  media_id?: string;
}

/** 会话列表查询参数 */
export interface ConversationMessagesParams {
  before_seq?: number;
  limit?: number;
}

/* ================= M5-2 爱莉 profile（对齐 backend/apps/elysia_bridge/serializers.py） ================= */

/** ElysiaProfileSerializer 读字段 */
export interface ElysiaProfile {
  id: number;
  user: UserPublic;
  stream_id: string;
  platform: string;
  enabled: boolean;
  display_name: string;
  chat_type: "private" | "group";
  created_at: string;
}

/* ================= Chat WS 帧（对齐 backend/apps/chat/consumers.py） ================= */

export interface ChatSubscribedFrame {
  type: "chat.subscribed";
  data: { conversation_id: string; last_seq: number };
}

export interface MessageNewFrame {
  type: "message.new";
  data: {
    conversation_id: string;
    message_id: string;
    sender_id: string;
    content: string;
    type: MessageType;
    media: string | null;
    reply_to: string | null;
    seq: number;
    ts: string;
  };
}

export interface MessageRecallFrame {
  type: "message.recall";
  data: { conversation_id: string; message_id: string; seq: number };
}

export interface MessageReadFrame {
  type: "message.read";
  data: { conversation_id: string; message_id: string; user_id: string; seq: number };
}

export interface TypingFrame {
  type: "typing";
  data: { conversation_id: string; user_id: string; is_typing: boolean };
}

export interface HistorySyncFrame {
  type: "history.sync";
  data: { conversation_id: string; last_seq: number };
}

export interface ElysiaReplyFrame {
  type: "elysia.reply";
  data: {
    conversation_id: string;
    message_id: string;
    sender_id: string;
    content: string;
    type: MessageType;
    seq: number;
    event_id: string;
    ts: string;
  };
}

export interface ChatErrorFrame {
  type: "error";
  detail: string;
}

export interface PongFrame {
  type: "pong";
  ts: number;
}

export type ChatServerFrame =
  | ChatSubscribedFrame
  | MessageNewFrame
  | MessageRecallFrame
  | MessageReadFrame
  | TypingFrame
  | HistorySyncFrame
  | ElysiaReplyFrame
  | ChatErrorFrame
  | PongFrame;
