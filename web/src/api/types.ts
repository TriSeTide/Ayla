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

/** 媒体种类（与 backend apps/media/models.py MediaObject.kind 对齐） */
export type MediaKind = "image" | "voice" | "file" | "emoji";

/** MediaObjectSerializer 字段（M4-3：media 是 descriptor 对象，非裸 media_id） */
export interface MediaDescriptor {
  media_id: string;
  kind: MediaKind;
  mime_type: string;
  size: number;
  status: string;
  width: number | null;
  height: number | null;
  /** 秒（voice） */
  duration: number | null;
  /** 相对路径 /api/v1/media/{id}/thumbnail（无缩略图则 null） */
  thumbnail: string | null;
  /** 相对路径 /api/v1/media/{id}/waveform（无波形则 null） */
  waveform: string | null;
  /** ISO 时间 */
  created_at: string;
}

/** MessageSerializer 字段（id/conversation_id/sender_id 均为字符串） */
export interface ChatMessage {
  id: string;
  conversation_id: string;
  sender_id: string;
  type: MessageType;
  content: string;
  media_id: string | null;
  /**
   * M4-3+：媒体 descriptor 对象（REST 序列化返回）。
   * 可选：WS 帧到达时只有字符串 media_id，descriptor 由前端异步补拉后合并。
   */
  media?: MediaDescriptor | null;
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
  /** 群头像（媒体 content URL，仅群聊；私聊为空串） */
  avatar: string;
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
  /** 群头像（媒体 content URL，仅群聊；私聊为空串） */
  avatar: string;
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
    /** WS 协议仍是字符串 media_id（backend consumers.py 直传 msg.media_id）；descriptor 由前端补拉 */
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

/* ================= M5-3 语音域（对齐 backend/apps/voice/serializers.py + views.py） ================= */

/** VoiceChannelSerializer 字段 + 列表/详情视图补充的 member_count/mine */
export interface VoiceChannelDescriptor {
  id: string;
  name: string;
  room_name: string;
  owner_id: string;
  member_count: number;
  /** S1：可见性 public/friends/group（来源标识） */
  visibility: "public" | "friends" | "group";
  /** S1：群归属（一级 tab 创建为 null；群内创建为该群 id 字符串） */
  group: string | null;
  /** S1：群归属名（group 非空时的群标题，否则 null） */
  group_name: string | null;
  /** 我是否在该频道（列表/详情视图注入） */
  mine: boolean;
  created_at: string;
}

/** VoiceChannelMemberSerializer 字段 */
export interface VoiceChannelMemberDescriptor {
  id: number;
  user_id: string;
  joined_at: string;
  last_seen_at: string;
}

/** POST /voice/channels/<id>/join/ 返回（LiveKit 媒体凭据，禁止打日志） */
export interface VoiceJoinResult {
  channel_id: string;
  room_name: string;
  token: string;
  ws_url: string;
  /** token TTL（秒，默认 600） */
  ttl: number;
  joined: boolean;
}

/* ---------- 爱莉语音编排（对齐 elysia_bridge/views.py ElysiaVoiceCall*） ---------- */

/** _call_status_data 暴露的安全字段 */
export interface ElysiaVoiceCallStatus {
  call_id: string;
  episode_id: string | null;
  state: string;
  mode: string;
  provider: string;
  created_at: string;
  updated_at: string;
  resumable: boolean;
  connected: boolean;
  input_audio_bytes: number;
  output_audio_bytes: number;
  interruptions: number;
  failure_reason: string | null;
}

/** _ticket_data（WS ticket 信息，不含 secret） */
export interface ElysiaVoiceConnection {
  url: string;
  resource: string;
  subprotocol: string;
  expires_at: string;
}

/** POST /elysia/voice-calls/ 返回（reused=true 为单并发复用的正常路径） */
export interface ElysiaVoiceCallCreateResult {
  call: ElysiaVoiceCallStatus;
  connection: ElysiaVoiceConnection | null;
  reused: boolean;
}

/** POST .../text/ 与 .../end/ 返回 */
export interface ElysiaVoiceCommandResult {
  command_id: string;
  status: string;
  accepted: boolean;
}

/** POST .../poll/ 返回（增量转写投影计数，中性展示） */
export interface ElysiaVoicePollResult {
  projected: unknown[];
  total: number;
}

/* ---------- Voice WS 帧（对齐 backend/apps/voice/consumers.py） ---------- */

/** voice.state 的 state 枚举 */
export type VoiceMemberEventState = "joined" | "left" | "heartbeat" | "muted" | "unmuted";

export interface VoiceSubscribedFrame {
  type: "voice.subscribed";
  data: { channel_id: string };
}

export interface VoiceStateFrame {
  type: "voice.state";
  data: {
    channel_id: string;
    user_id: string;
    state: VoiceMemberEventState;
    ts: string;
  };
}

export interface VoiceErrorFrame {
  type: "error";
  detail: string;
}

export type VoiceServerFrame =
  | VoiceSubscribedFrame
  | VoiceStateFrame
  | VoiceErrorFrame
  | PongFrame;

/* ================= M5-4 直播域（对齐 backend/apps/live/serializers.py + views.py + consumers.py） ================= */

/** 频道乐观标记（应用侧，非 SRS 实时判定） */
export type LiveChannelStatus = "idle" | "live" | "ended";

/**
 * LiveChannelSerializer 字段。
 * 注意：stream_key / rtmp_url 仅 owner 可见（他人为 null），属正常契约而非缺陷。
 */
export interface LiveChannelDescriptor {
  id: number;
  title: string;
  description?: string;
  /** 内部媒体 content URL；为空时使用默认封面占位 */
  cover?: string;
  /** 乐观标记（应用侧）；真实在播判定以 GET /status/ 为准 */
  status: LiveChannelStatus;
  owner_id: string;
  /** 主播展示名（后端列表直接带，nickname 为空回退 username；null=未知） */
  owner_nickname: string | null;
  is_owner: boolean;
  /** S1：可见性 public/friends/group（来源标识） */
  visibility: "public" | "friends" | "group";
  /** S1：群归属（一级 tab 创建为 null；群内创建为该群 id 字符串） */
  group: string | null;
  /** S1：群归属名（group 非空时的群标题，否则 null） */
  group_name: string | null;
  /** 仅 owner 非 null（推流指纹，禁止写日志/给观众组件） */
  stream_key: string | null;
  /** 仅 owner 非 null */
  rtmp_url: string | null;
  /** 全员可见（HLS 播放地址） */
  hls_url: string;
  /** 全员可见（HTTP-FLV 备选地址） */
  flv_url: string;
  started_at: string | null;
  ended_at: string | null;
  created_at: string;
}

/** GET /live/channels/<id>/status/ 的 SRS 实时判定 */
export type LiveSrsStatus = "live" | "idle" | "degraded";

/**
 * GET /live/channels/<id>/status/ 响应体（services.py）。
 * degraded = SRS 不可用（服务状态未知），**不是未在播**，UI 必须中性提示。
 */
export interface LiveStatusResult {
  status: LiveSrsStatus;
  /** "srs" | "srs_unavailable" */
  source: string;
  detail: string | null;
  /** 应用侧乐观标记原样回显 */
  optimistic: LiveChannelStatus;
}

/** 弹幕条目（POST 201 含 channel_id；GET 历史条目无 channel_id） */
export interface DanmakuItem {
  id: string;
  channel_id?: string;
  sender: {
    user_id: string;
    nickname: string;
    avatar: string;
  };
  content: string;
  created_at: string;
}

/* ---------- 弹幕 WS 帧（对齐 backend/apps/live/consumers.py） ---------- */

/** 服务端 → 客户端：弹幕广播（发送者自己的 WS 也收到回帧，单一数据流） */
export interface DanmakuFrame {
  type: "danmaku";
  id: string;
  sender: {
    id: string;
    nickname: string;
    avatar?: string;
  };
  content: string;
  created_at: string;
}

export interface LiveErrorFrame {
  type: "error";
  detail: string;
}

export type LiveServerFrame = DanmakuFrame | LiveErrorFrame | PongFrame;

/* ================= S6 群动态 highlights（对齐 backend/apps/chat/services.py） ================= */

/**
 * 群动态封面项。三类：live（封面无图）、post（有配图帖，首图缩略图）、game（无图）。
 * cover_url 为 null 表示该类型无封面字段（前端回退群头像/占位）。
 * target_url 为后端返回的相对路径（如 /live/1、/posts/1、/games/1）。
 */
export interface GroupHighlight {
  type: "live" | "post" | "game";
  title: string;
  cover_url: string | null;
  target_url: string;
  /** ISO 时间 */
  created_at: string;
}

/** GET /chat/conversations/highlights/?ids= 返回：{群 id 字符串: 动态封面列表} */
export type ConversationHighlightsMap = Record<string, GroupHighlight[]>;

/* ================= S3 帖子域（对齐 backend/apps/posts/serializers.py） ================= */

/** 帖子配图（PostImageSerializer：media 为完整 descriptor） */
export interface PostImage {
  id: number;
  media: MediaDescriptor | null;
  order: number;
}

/** 帖子（PostSerializer）：author 内联 UserPublic，含 images/comment_count/is_author */
export interface Post {
  id: number;
  author: UserPublic;
  author_id: string;
  title: string;
  body: string;
  visibility: "public" | "friends" | "group";
  group: string | null;
  group_name: string | null;
  images: PostImage[];
  comment_count: number;
  is_author: boolean;
  created_at: string;
  updated_at: string;
}

/** 评论（CommentSerializer） */
export interface PostComment {
  id: number;
  post_id: string;
  author: UserPublic;
  author_id: string;
  body: string;
  reply_to: string | null;
  is_author: boolean;
  created_at: string;
}

/** 信息流分页响应（PostListView.get） */
export interface PostListPage {
  results: Post[];
  next_cursor: string | null;
  has_more: boolean;
}

/** 帖子信息流 scope：feed（全可见）/ mine（我的）/ group:<id>（群内） */
export type PostScope = "feed" | "mine" | `group:${string}`;

/* ================= S6 收藏域（对齐 backend/apps/favorites/serializers.py） ================= */

export type FavoriteTargetType = "post" | "live" | "voice" | "game" | "group";

/** 收藏条目（FavoriteSerializer） */
export interface Favorite {
  id: number;
  user_id: string;
  target_type: FavoriteTargetType;
  target_id: string;
  target: Record<string, unknown> | null;
  created_at: string;
}

/* ================= S4 桌游域（对齐 backend/apps/boardgame/serializers.py） ================= */

/** 桌游室成员（GameRoomMemberSerializer） */
export interface GameRoomMember {
  id: number;
  user: UserPublic;
  user_id: string;
  seat: number;
  joined_at: string;
}

/** 桌游室（GameRoomSerializer） */
export interface GameRoom {
  id: number;
  name: string;
  owner: UserPublic;
  owner_id: string;
  visibility: "public" | "friends" | "group";
  group: string | null;
  group_name: string | null;
  /** 游戏类型（默认 boardgame，玩法后续） */
  game_type: string;
  /** waiting（等待中）/ playing（对局中）/ ended（已结束） */
  status: "waiting" | "playing" | "ended";
  members: GameRoomMember[];
  member_count: number;
  is_owner: boolean;
  is_member: boolean;
  created_at: string;
}

/* ================= S2 群申请/邀请 + badges（对齐 backend） ================= */

/** GET /me/badges/ 聚合（accounts.BadgesView） */
export interface Badges {
  private_unread: number;
  group_unread: number;
  friend_requests: number;
  group_invites: number;
  join_requests_pending: number;
}

/** 入群申请（chat.GroupJoinRequestSerializer） */
export interface GroupJoinRequest {
  id: number;
  conversation_id: string;
  conversation_title: string;
  applicant: UserPublic;
  message: string;
  status: "pending" | "accepted" | "rejected";
  handled_by_id: string | null;
  handled_at: string | null;
  created_at: string;
}

/** 入群邀请（chat.GroupInviteSerializer） */
export interface GroupInvite {
  id: number;
  conversation_id: string;
  conversation_title: string;
  inviter: UserPublic;
  invitee: UserPublic;
  status: "pending" | "accepted" | "rejected";
  handled_at: string | null;
  created_at: string;
}

/* ================= S5 聚合搜索（对齐 backend/apps/search） ================= */

/** 群搜索结果项（轻量 dict） */
export interface SearchGroupItem {
  id: string;
  type: "group";
  title: string;
  created_at: string;
}

/** 某类结果组（items + 截断前匹配总数） */
export interface SearchGroup<T> {
  items: T[];
  total: number;
}

/** GET /search/ 返回：按请求类型分组（只含被请求类型） */
export interface SearchResults {
  users?: SearchGroup<UserPublic>;
  groups?: SearchGroup<SearchGroupItem>;
  posts?: SearchGroup<Post>;
  lives?: SearchGroup<LiveChannelDescriptor>;
  games?: SearchGroup<GameRoom>;
}
