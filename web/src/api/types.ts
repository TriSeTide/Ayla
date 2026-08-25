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
  /** 跨页面媒体活动事实，由后端生命周期维护。 */
  is_in_voice?: boolean;
  voice_room_id?: number | null;
  is_live?: boolean;
  live_room_id?: number | null;
  /** GET /users/<id>/ 追加：与当前用户的好友关系 */
  relation?: "self" | "friend" | "pending_sent" | "pending_received" | "none";
  /** 是否向他人展示内容（发帖/直播间/桌游）；他人主页据此显示"他的内容"卡片 */
  show_content?: boolean;
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
  show_content?: boolean;
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
  handled_at?: string | null;
}

/** 发起好友申请入参 */
export interface FriendRequestPayload {
  to_user_id: string;
  message?: string;
}

/** 后端 DRF 错误结构：{detail} 或 {field: [msg]} 或 {field: msg} */
export type ApiErrorBody = Record<string, unknown>;

/* ================= M5-2 聊天域（对齐 backend/apps/chat/serializers.py） ================= */

export type MessageType =
  | "text" | "image" | "voice" | "file" | "emoji" | "video" | "mixed" | "system";
export type MessageStatus = "sent" | "delivered" | "read" | "recalled";

/** 媒体种类（与 backend apps/media/models.py MediaObject.kind 对齐） */
export type MediaKind = "image" | "voice" | "file" | "emoji" | "video";

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

/** 图文混排段（type=mixed 消息；对齐 backend chat/serializers.expand_segments） */
export type MediaSegment =
  | { type: "text"; text: string }
  | {
      type: "image" | "video";
      media_id: string;
      /** 服务端展开的 descriptor；乐观发送中（未上传）为 null */
      media?: MediaDescriptor | null;
    };

/** 乐观消息的本地媒体预览（未上传，仅本端可见；渲染与重试用） */
export interface LocalMediaPreview {
  /** 段内唯一 id（与 segments 中媒体段一一对应） */
  id: string;
  kind: "image" | "video";
  mimeType: string;
  /** objectURL（渲染）；组件卸载/消息删除时 revoke */
  url: string;
  /** 原始 File（重试重传用；仅乐观消息持有） */
  file: File;
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
  /** 图文混排段（type=mixed；媒体段带完整 descriptor；旧消息/单媒体为 null） */
  segments?: MediaSegment[] | null;
  reply_to: string | null;
  status: MessageStatus;
  /** 会话内单调递增序号（补发/分页游标） */
  seq: number;
  /** ISO 时间 */
  created_at: string;
  /* ---- 以下为应用侧乐观发送字段（非后端契约） ---- */
  /** 乐观发送中（气泡左上角加载态；seq=0，排序置底） */
  pending?: boolean;
  /** 发送失败（气泡左上角失败态，可重试/删除） */
  sendFailed?: boolean;
  /** 上传进度百分比 0-100（有本地媒体且上传未完成；null/undefined = 无媒体或已上传完成） */
  uploadProgress?: number | null;
  /** 乐观消息幂等键（重试复用，服务端去重） */
  idempotencyKey?: string;
  /** 乐观消息的本地媒体预览（未上传时渲染本地；与 segments 媒体段按序对应） */
  localMedia?: LocalMediaPreview[];
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

/** 会话最新一条消息摘要（会话列表预览用，无消息为 null） */
export interface LastMessagePreview {
  seq: number;
  type: MessageType;
  content: string;
  sender_id: string | null;
  sender_name: string;
  status: string;
  created_at: string | null;
  /** 混排摘要文案（后端生成：混排消息「文本文本[视频]文本[图片]」；
   *  单媒体 [图片] 占位、文本取 content、撤回 [已撤回]；旧后端缺失时前端兜底） */
  preview?: string;
}

/** ConversationListSerializer 字段（会话列表用） */
export interface ConversationSummary {
  id: string;
  type: ConversationType;
  title: string;
  announcement: string;
  /** 群头像（媒体 content URL，仅群聊；私聊为空串） */
  avatar: string;
  join_policy?: "public" | "application";
  owner_id: string;
  members: ConversationMember[];
  my_role: "member" | "admin" | "owner" | null;
  member_count: number;
  unread_count: number;
  /** 本人视图是否置顶（M5 会话管理；旧后端/旧数据可能缺失） */
  is_pinned?: boolean;
  /** 最新一条消息预览（无消息为 null；旧后端可能缺失） */
  last_message?: LastMessagePreview | null;
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
  join_policy?: "public" | "application";
  owner_id: string;
  members: ConversationMember[];
  my_role: "member" | "admin" | "owner" | null;
  member_count: number;
  unread_count: number;
  is_pinned?: boolean;
  last_message?: LastMessagePreview | null;
  created_at: string;
}

/** CreateMessageSerializer 入参 */
export interface CreateMessagePayload {
  type?: MessageType;
  content: string;
  reply_to?: number | null;
  idempotency_key?: string;
  media_id?: string;
  /** 图文混排段（与 media_id 二选一；至少一个媒体段；服务端强制 type=mixed） */
  segments?: ({ type: "text"; text: string } | { type: "image" | "video"; media_id: string })[];
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
    /** WS 帧携带完整 descriptor 对象（backend consumers.py 直传 _media_descriptor）；历史兼容字符串 media_id */
    media: MediaDescriptor | string | null;
    /** 图文混排段（type=mixed；媒体段带 descriptor；旧后端缺失为 null） */
    segments?: MediaSegment[] | null;
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

export interface GroupRequestNewFrame {
  type: "group.request.new";
  data: {
    request_id: string;
    conversation_id: string;
    conversation_title: string;
    applicant_id: string;
    applicant_name: string;
  };
}

export interface GroupRequestResolvedFrame {
  type: "group.request.resolved";
  data: {
    request_id: string;
    conversation_id: string;
    conversation_title: string;
    status: string;
    handled_by_id: string;
    handled_at: string | null;
  };
}

export interface GroupInviteNewFrame {
  type: "group.invite.new";
  data: {
    invite_id: string;
    conversation_id: string;
    conversation_title: string;
    inviter_id: string;
    inviter_name: string;
    created_at: string | null;
  };
}

export interface FriendRequestNewFrame {
  type: "friend.request.new";
  data: {
    request_id: string;
    from_user_id: string;
    from_user_name: string;
    message: string;
    created_at: string | null;
  };
}

export interface FriendRequestResolvedFrame {
  type: "friend.request.resolved";
  data: {
    request_id: string;
    status: "accepted" | "rejected";
    handled_at: string | null;
  };
}

export interface GroupMemberLeftFrame {
  type: "group.member.left";
  data: {
    conversation_id: string;
    conversation_title: string;
    member_id: string;
    member_name: string;
  };
}

export interface GroupCreatedFrame {
  type: "group.created";
  conversation: {
    id: string;
    type: "group";
    title: string;
    announcement: string;
    owner_id: string;
    avatar: string;
    created_at: string;
  };
}

export interface GroupJoinedFrame {
  type: "group.joined";
  conversation: {
    id: string;
    type: "group";
    title: string;
    announcement: string;
    owner_id: string;
    avatar: string;
    created_at: string;
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

export interface VoiceChannelCreatedFrame {
  type: "voice.channel.created";
  data: {
    channel_id: string;
  };
}

export interface VoiceChannelDeletedFrame {
  type: "voice.channel.deleted";
  data: {
    channel_id: string;
  };
}

export interface VoiceChannelMemberCountChangedFrame {
  type: "voice.channel.member_count_changed";
  data: {
    channel_id: string;
    member_count: number;
  };
}

export interface LiveChannelCreatedFrame {
  type: "live.channel.created";
  data: {
    channel_id: number;
    title: string;
    owner_id: string;
    visibility: "public" | "friends" | "group";
    group_id: string | null;
    status: LiveChannelStatus;
    created_at: string;
  };
}

export interface LiveChannelStatusChangedFrame {
  type: "live.channel.status.changed";
  data: {
    channel_id: number;
    status: LiveChannelStatus;
  };
}

export interface LiveChannelDeletedFrame {
  type: "live.channel.deleted";
  data: {
    channel_id: number;
  };
}

export interface LiveChannelUpdatedFrame {
  type: "live.channel.updated";
  data: {
    channel_id: number;
    title: string;
    owner_id: string;
    visibility: "public" | "friends" | "group";
    group_id: string | null;
    status: LiveChannelStatus;
    created_at: string;
  };
}

export interface PostCreatedFrame {
  type: "post.created";
  post: {
    id: string;
    title: string;
    body: string;
    owner_id: string;
    group_id: string | null;
    visibility: string;
    created_at: string;
  };
}

export interface PostDeletedFrame {
  type: "post.deleted";
  post_id: string;
}

export interface PostUpdatedFrame {
  type: "post.updated";
  post: {
    id: string;
    title: string;
    body: string;
    owner_id: string;
    group_id: string | null;
    visibility: string;
    created_at: string;
  };
}

export interface CommentCreatedFrame {
  type: "comment.created";
  data: {
    post_id: string;
    comment: PostComment;
    comment_count: number;
  };
}

export interface CommentDeletedFrame {
  type: "comment.deleted";
  data: {
    post_id: string;
    comment_id: number;
    comment_count: number;
  };
}

export type ChatServerFrame =
  | ChatSubscribedFrame
  | MessageNewFrame
  | MessageRecallFrame
  | MessageReadFrame
  | TypingFrame
  | HistorySyncFrame
  | ElysiaReplyFrame
  | GroupRequestNewFrame
  | GroupRequestResolvedFrame
  | GroupInviteNewFrame
  | GroupMemberLeftFrame
  | GroupCreatedFrame
  | GroupJoinedFrame
  | FriendRequestNewFrame
  | FriendRequestResolvedFrame
  | VoiceChannelCreatedFrame
  | VoiceChannelDeletedFrame
  | VoiceChannelMemberCountChangedFrame
  | LiveChannelCreatedFrame
  | LiveChannelStatusChangedFrame
  | LiveChannelDeletedFrame
  | LiveChannelUpdatedFrame
  | PostCreatedFrame
  | PostDeletedFrame
  | PostUpdatedFrame
  | CommentCreatedFrame
  | CommentDeletedFrame
  | BoardgameRoomCreatedFrame
  | BoardgameRoomDeletedFrame
  | BoardgameRoomUpdatedFrame
  | ChatErrorFrame
  | PongFrame;

/* ================= M5-3 语音域（对齐 backend/apps/voice/serializers.py + views.py） ================= */

/** VoiceChannelSerializer 字段 + 列表/详情视图补充的 member_count/mine */
export interface VoiceChannelDescriptor {
  id: string;
  name: string;
  room_name: string;
  owner_id: string;
  /** 创建者显示名（nickname||username；null=未知；群"新内容"事件描述用） */
  owner_nickname?: string | null;
  member_count: number;
  /** S1：可见性 public/friends/group（来源标识） */
  visibility: "public" | "friends" | "group";
  /** S1：群归属（一级 tab 创建为 null；群内创建为该群 id 字符串） */
  group: string | null;
  /** S1：群归属名（group 非空时的群标题，否则 null） */
  group_name: string | null;
  allowed_group_ids?: string[];
  allowed_group_names?: string[];
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

/** 语音房独立聊天消息（不进入群聊 Message）。 */
export interface VoiceChatMessage {
  id: string;
  channel_id: string;
  sender: {
    user_id: string;
    nickname: string;
    avatar: string;
  };
  content: string;
  media_id: string | null;
  media: MediaDescriptor | null;
  created_at: string;
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
  /** S1：visibility=group 时的白名单群 id 列表（后端 serializers 恒返回 str 数组；可选字段兼容旧响应） */
  allowed_group_ids?: string[];
  allowed_group_names?: string[];
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
  media_id?: string | null;
  media?: MediaDescriptor | null;
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
  media_id?: string | null;
  media?: MediaDescriptor | null;
  created_at: string;
}

export interface LiveErrorFrame {
  type: "error";
  detail: string;
}

export type LiveServerFrame = DanmakuFrame | LiveErrorFrame | PongFrame;

/* ================= S4 Boardgame WS 帧（对齐 backend/apps/boardgame/services.py） ================= */

export interface BoardgameRoomCreatedFrame {
  type: "boardgame.room.created";
  room: {
    id: string;
    name: string;
    owner_id: string;
    group_id: string | null;
    visibility: string;
    game_type: string;
    status: string;
    created_at: string;
  };
}

export interface BoardgameRoomDeletedFrame {
  type: "boardgame.room.deleted";
  room_id: string;
}

export interface BoardgameRoomUpdatedFrame {
  type: "boardgame.room.updated";
  room: {
    id: string;
    name: string;
    owner_id: string;
    group_id: string | null;
    visibility: string;
    game_type: string;
    status: string;
    created_at: string;
  };
}

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
  allowed_group_ids?: string[];
  allowed_group_names?: string[];
  images: PostImage[];
  comment_count: number;
  is_author: boolean;
  created_at: string;
  updated_at: string;
}

/** 评论（CommentSerializer：支持图文同发 images[]，media_id/media 为旧单图兼容） */
export interface PostComment {
  id: number;
  post_id: string;
  author: UserPublic;
  author_id: string;
  body: string;
  media_id: string | null;
  media: MediaDescriptor | null;
  /** 图文同发的全部媒体 descriptor（含旧 media_id 单图） */
  images: MediaDescriptor[];
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

export type FavoriteTargetType = "post" | "message" | "live" | "voice" | "game" | "group";

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
  allowed_group_ids?: string[];
  allowed_group_names?: string[];
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

/** 持久化退群通知（chat.GroupMemberLeaveNoticeSerializer） */
export interface GroupMemberLeaveNotice {
  id: number;
  conversation_id: string;
  conversation_title: string;
  member_name: string;
  read_at: string | null;
  created_at: string;
}

/* ================= S5 聚合搜索（对齐 backend/apps/search） ================= */

/** 群搜索结果项（轻量 dict） */
export interface SearchGroupItem {
  id: string;
  type: "group";
  title: string;
  /** 加入方式：public=直接加入 / application=申请制（旧数据缺失时按申请制兜底） */
  join_policy?: "public" | "application";
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
