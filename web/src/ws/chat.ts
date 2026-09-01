/**
 * Chat WebSocket 客户端（单例，文档 §4.6 / §2 ws/chat.ts）。
 *
 * - 路径 /ws/chat/?token=<jwt>（AuthMiddlewareStack，JWT query token）
 * - 单例连接：subscribe 当前会话列表；打开会话时增量 subscribe 单个 conv_id
 * - 断开重连：指数退避 1s→2s→...→30s 上限；重连成功后对每个已订阅会话
 *   发 resume {last_message_seq: <该会话 lastSeq>} 补发
 * - 心跳：每 30s 发 ping（保活，Redis TTL）
 * - 事件分发：message.new/recall/read/typing/elysia.reply/history.sync → 对应 store/handler
 */
import { useAuthStore } from "../stores/auth";
import { useBadgesStore } from "../stores/badges";
import { useChatStore } from "../stores/chat";
import { useMessageStore } from "../stores/message";
import { WS_BASE_URL } from "./presence";
import type {
  ChatMessage,
  ChatServerFrame,
  ConversationSummary,
} from "../api/types";
import { useRealtimeStore } from "../stores/realtime";
import { useNoticeStore } from "../stores/notices";
import { useVoiceStore } from "../stores/voice";
import { usePostsStore } from "../stores/posts";
import { useLiveStore } from "../stores/live";
import * as postsApi from "../api/posts";
import * as liveApi from "../api/live";
import { useBoardgameStore } from "../stores/boardgame";
import * as chatApi from "../api/chat";
import * as voiceApi from "../api/voice";
import * as boardgameApi from "../api/boardgame";
import { applyFavoriteChanged } from "../components/FavoriteButton";
import { segmentPreview } from "../utils/segment";

const HEARTBEAT_INTERVAL_MS = 30_000;
const MAX_RECONNECT_DELAY_MS = 30_000;
const BASE_RECONNECT_DELAY_MS = 1_000;

/** 由会话信息推断消息发送者的显示名（会话列表预览用）。 */
function previewSenderName(conv: ConversationSummary, senderId: string): string {
  const me = useAuthStore.getState().currentUser;
  if (me && String(senderId) === String(me.id)) {
    return me.nickname || me.username || "";
  }
  if (conv.type === "private" && conv.peer) {
    return conv.peer.nickname || conv.peer.username || "";
  }
  const member = conv.members.find((m) => String(m.user.id) === String(senderId));
  if (member) {
    return member.user.nickname || member.user.username || "";
  }
  return "";
}

/** 从「归属群 + 白名单群」提取该内容可见的群 id 集合（bump 排序用；去重、过滤空值）。 */
function visibleGroupIds(descriptor: {
  group?: string | null;
  allowed_group_ids?: string[] | null;
}): string[] {
  const ids = new Set<string>();
  if (descriptor.group) ids.add(String(descriptor.group));
  for (const id of descriptor.allowed_group_ids ?? []) {
    if (id != null) ids.add(String(id));
  }
  return [...ids];
}

/** bump 一段可见群 id 的「最近收到新内容」时间戳（单调，往前排）。 */
function bumpGroups(ids: string[]) {
  const chat = useChatStore.getState();
  for (const id of ids) chat.bumpGroupActivity(id);
}

/** 收到 WS 帧的通用处理器（供测试/扩展监听） */
export type ChatFrameHandler = (frame: ChatServerFrame) => void;

export class ChatWSClient {
  private ws: WebSocket | null = null;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private attempt = 0;
  private manualClosed = false;
  /** 是否曾成功建立过连接：区分首次连接（补发 subscribe）与断线重连（resume 补发）。 */
  private hasConnectedOnce = false;
  /** 已订阅的会话 id 集合（重连后据此发 resume） */
  private subscribed = new Set<string>();
  private handlers = new Set<ChatFrameHandler>();

  /** 连接状态（供 UI 展示"连接中"） */
  connection: "connecting" | "online" | "offline" = "offline";

  connect() {
    const access = useAuthStore.getState().accessToken;
    if (!access) return;
    this.manualClosed = false;
    // 新连接会话（登录/刷新）：重置首连标记，让 onopen 走「补发 subscribe」而非 resume。
    this.hasConnectedOnce = false;
    this.connection = "connecting";
    useRealtimeStore.getState().setStatus("chat", "connecting");
    this.open(access);
  }

  private open(access: string) {
    const url = `${WS_BASE_URL}/ws/chat/?token=${encodeURIComponent(access)}`;
    let ws: WebSocket;
    try {
      ws = new WebSocket(url);
    } catch {
      this.scheduleReconnect();
      return;
    }
    this.ws = ws;

    ws.onopen = () => {
      this.attempt = 0;
      this.connection = "online";
      useRealtimeStore.getState().setStatus("chat", "online");
      this.startHeartbeat();
      if (this.hasConnectedOnce) {
        // 断线重连：对已订阅会话逐条 resume，补发断线期间漏掉的消息。
        for (const convId of this.subscribed) {
          this.sendResume(convId);
        }
      } else {
        // 首次连接：连接建立前 subscribe 的帧因 WS 尚未 OPEN 被 sendJson 静默丢弃，
        // 这里批量补发 subscribe（仅订阅，不补发历史）。若改用 resume，此时各会话
        // bucket 尚未加载历史（lastSeq=0），后端会补发 seq>0 的全部消息——
        // 正是「刷新群聊时一口气加载所有历史消息」的根因。
        this.hasConnectedOnce = true;
        if (this.subscribed.size > 0) {
          this.sendJson({ type: "subscribe", conversation_ids: [...this.subscribed] });
        }
      }
    };

    ws.onmessage = (ev) => {
      let frame: ChatServerFrame;
      try {
        frame = JSON.parse(ev.data as string) as ChatServerFrame;
      } catch {
        return;
      }
      this.dispatch(frame);
    };

    ws.onclose = () => {
      this.stopHeartbeat();
      this.connection = "offline";
      useRealtimeStore.getState().setStatus("chat", this.manualClosed ? "offline" : "connecting");
      if (!this.manualClosed) this.scheduleReconnect();
    };

    ws.onerror = () => {
      // onclose 会随后触发，统一走重连逻辑
    };
  }

  private scheduleReconnect() {
    const delay = Math.min(
      BASE_RECONNECT_DELAY_MS * 2 ** this.attempt,
      MAX_RECONNECT_DELAY_MS,
    );
    this.attempt += 1;
    this.connection = "connecting";
    useRealtimeStore.getState().setStatus("chat", "connecting");
    this.reconnectTimer = setTimeout(() => {
      const access = useAuthStore.getState().accessToken;
      if (!access || this.manualClosed) return;
      this.open(access);
    }, delay);
  }

  private startHeartbeat() {
    this.stopHeartbeat();
    this.heartbeatTimer = setInterval(() => {
      if (this.ws?.readyState === WebSocket.OPEN) {
        this.ws.send(JSON.stringify({ type: "ping", ts: Date.now() }));
      }
    }, HEARTBEAT_INTERVAL_MS);
  }

  private stopHeartbeat() {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
  }

  // ---------- 对外：订阅/退订 ----------

  /** 订阅一批会话（打开会话/加载列表时调用，幂等） */
  subscribe(convIds: string[]) {
    for (const id of convIds) this.subscribed.add(id);
    this.sendJson({ type: "subscribe", conversation_ids: convIds });
  }

  /** 退订单个会话（关闭会话时调用） */
  unsubscribe(convId: string) {
    this.subscribed.delete(convId);
    // 服务端无独立退订帧；重连时不再 resume 即可
  }

  /** 补发：带 last_message_seq（重连/打开会话时调用） */
  resume(convId: string) {
    this.subscribed.add(convId);
    this.sendResume(convId);
  }

  private sendResume(convId: string) {
    const lastSeq = useMessageStore.getState().buckets[convId]?.lastSeq ?? 0;
    this.sendJson({ type: "resume", conversation_id: convId, last_message_seq: lastSeq });
  }

  sendJson(payload: unknown) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(payload));
    }
  }

  // ---------- 事件分发 ----------

  private liveReconciliations = new Map<number, Promise<void>>();

  private reconcileLiveChannel(channelId: number) {
    // WS frames are invalidations, not authority: REST applies the requesting
    // user's current visibility and provides the complete descriptor. Coalesce
    // duplicate frames while a reconciliation is still in flight.
    if (this.liveReconciliations.has(channelId)) return;
    const reconciliation = liveApi.getLiveChannel(channelId)
      .then((channel) => useLiveStore.getState().upsertChannel(channel))
      .catch(() => useLiveStore.getState().removeChannel(channelId))
      .finally(() => this.liveReconciliations.delete(channelId));
    this.liveReconciliations.set(channelId, reconciliation);
  }

  private dispatch(frame: ChatServerFrame) {
    const chat = useChatStore.getState();
    const message = useMessageStore.getState();
    const notices = useNoticeStore.getState();
    const notificationFrame = frame as ChatServerFrame & { type: string; data?: Record<string, string | null> };

    switch (frame.type) {
      case "message.new": {
        const d = frame.data;
        // 后端 WS 帧 media 字段是 MediaDescriptor 对象（或 null）；历史兼容字符串 media_id
        const wsMedia = d.media;
        const wsMediaId = typeof wsMedia === "string" ? wsMedia : (wsMedia?.media_id ?? null);
        const currentUserId = useAuthStore.getState().currentUser?.id;
        const msg: ChatMessage = {
          id: d.message_id,
          conversation_id: d.conversation_id,
          sender_id: d.sender_id,
          type: d.type,
          content: d.content,
          media_id: wsMediaId,
          media: typeof wsMedia === "string" ? null : wsMedia,
          segments: d.segments ?? null,
          reply_to: d.reply_to,
          reply_to_seq: d.reply_to_seq ?? null,
          read_by_me: false,
          status: "sent",
          seq: d.seq,
          created_at: d.ts,
          idempotencyKey: d.idempotency_key ?? undefined,
        };
        const isSelf = currentUserId != null && String(d.sender_id) === String(currentUserId);
        if (isSelf && d.idempotency_key) {
          // 自己发送的消息：用幂等键收敛本地 pending，避免 pending + 服务端双气泡。
          message.resolvePendingByKey(d.conversation_id, d.idempotency_key, msg);
        } else {
          message.upsertMessage(d.conversation_id, msg);
        }
        const isFromOther = !isSelf;
        const isMention = isFromOther && (d.segments ?? []).some(
          (segment) => segment.type === "mention" && segment.user_id === currentUserId,
        );
        const isReply = isFromOther && d.reply_to != null;
        const conv = chat.conversations.find((c) => c.id === d.conversation_id);
        const isActive = chat.activeConversationId === d.conversation_id;
        // 活跃会话还需用户在底部才视为「正在看」；翻聊天记录（不在底部）时新消息进标签。
        const atBottom = isActive && (message.viewerAtBottom[d.conversation_id] ?? true);

        if (isFromOther && atBottom) {
          // 正在底部看最新消息：直接已读（含 @/回复），不弹标签；
          // 被 @/回复的由 MessageList 直接泛光圈并滚底。
          message.markReadByMe(d.conversation_id, d.message_id);
          chatApi
            .markMessageRead(d.conversation_id, d.message_id, true)
            .then(() => useBadgesStore.getState().fetch())
            .catch(() => { /* 已读失败，下次进入会话重试 */ });
        } else if (isFromOther) {
          // 非活跃会话，或活跃但翻历史（不在底部）：进入未读投影，驱动标签。
          chat.bumpUnread(d.conversation_id, {
            seq: d.seq,
            mention: isMention,
            reply: isReply,
          });
          if (!conv || conv.type === "private") {
            // 私信新消息（未打开）→ 全局消息入口红点（private_unread）实时刷新；
            // 群未读不进消息中心红点（属群卡片/ServerRail 角标），故群消息不拉 badges。
            void useBadgesStore.getState().fetch();
          }
        }
        if (conv) {
          // 混排消息用段生成摘要（后端 WS 帧带展开 segments）；单媒体/文本走 content/占位
          const segmentsPreview = segmentPreview(d.segments ?? null);
          chat.setLastMessage(conv.id, {
            seq: d.seq,
            type: d.type,
            content: d.content,
            sender_id: d.sender_id,
            sender_name: previewSenderName(conv, d.sender_id),
            status: "sent",
            created_at: d.ts,
            preview:
              segmentsPreview ??
              (d.content ||
                (d.type === "image" ? "[图片]" : d.type === "video" ? "[视频]" : d.type === "voice" ? "[语音]" : undefined)),
          });
          // 群收到新消息（含自己发的）→ 卡片单调往前排；私聊不影响群排序。
          if (conv.type === "group") {
            chat.bumpGroupActivity(conv.id);
          }
        }
        break;
      }
      case "message.recall": {
        const d = frame.data;
        message.setRecalled(d.conversation_id, d.message_id);
        break;
      }
      case "message.poke": {
        // 戳一戳：独立帧，刻意不走 message.new 的未读/已读/红点链路。
        // 只做：消息进会话流、列表预览「A戳了戳B」、按「最近活跃」往前排。
        const d = frame.data;
        const msg: ChatMessage = {
          id: d.message_id,
          conversation_id: d.conversation_id,
          sender_id: d.sender_id,
          type: "poke",
          content: d.target_user_id,
          media_id: null,
          segments: null,
          reply_to: null,
          read_by_me: false,
          status: "sent",
          seq: d.seq,
          created_at: d.ts,
        };
        message.upsertMessage(d.conversation_id, msg);
        const conv = chat.conversations.find((c) => c.id === d.conversation_id);
        if (conv) {
          chat.setLastMessage(conv.id, {
            seq: d.seq,
            type: "poke",
            content: d.target_user_id,
            sender_id: d.sender_id,
            sender_name: d.sender_name,
            status: "sent",
            created_at: d.ts,
            preview: `${d.sender_name}戳了戳${d.target_name}`,
          });
          // 置顶但不打扰：复用「最近活跃」排序，不 bumpUnread、不拉 badges、不弹红点。
          if (conv.type === "group") {
            chat.bumpGroupActivity(conv.id);
          } else {
            chat.bumpConversationActivity(conv.id);
          }
        }
        break;
      }
      case "message.read": {
        const d = frame.data;
        message.markReadByMessage(d.conversation_id, d.message_id, d.user_id);
        break;
      }
      case "typing": {
        // 由 UI 层监听 handlers 更新 TypingIndicator
        break;
      }
      case "history.sync": {
        // 只作为补发完成信号
        message.setLastSeq(frame.data.conversation_id, frame.data.last_seq);
        break;
      }
      case "group.request.new": {
        const data = notificationFrame.data ?? {};
        notices.push({ kind: "group.request.new", title: "收到新的入群申请", detail: `${data.applicant_name ?? "有人"} 申请加入 ${data.conversation_title ?? "群聊"}` });
        void useBadgesStore.getState().fetch();
        break;
      }
      case "group.request.resolved": {
        const data = notificationFrame.data ?? {};
        const status = data.status === "accepted" ? "已通过" : "已拒绝";
        notices.push({ kind: "group.request.resolved", title: "入群申请有结果", detail: `${data.conversation_title ?? "群聊"}：你的申请${status}` });
        void useBadgesStore.getState().fetch();
        break;
      }
      case "group.invite.new": {
        const data = notificationFrame.data ?? {};
        notices.push({ kind: "group.invite.new", title: "收到新的群邀请", detail: `${data.inviter_name ?? "有人"} 邀请你加入 ${data.conversation_title ?? "群聊"}` });
        void useBadgesStore.getState().fetch();
        break;
      }
      case "friend.request.new": {
        const data = notificationFrame.data ?? {};
        notices.push({ kind: "friend.request.new", title: "收到新的好友申请", detail: `${data.from_user_name ?? "有人"} 想加你为好友` });
        void useBadgesStore.getState().fetch();
        break;
      }
      case "friend.request.resolved": {
        const data = notificationFrame.data ?? {};
        const status = data.status === "accepted" ? "已通过" : "已拒绝";
        notices.push({ kind: "friend.request.resolved", title: "好友申请有结果", detail: `你的好友申请${status}` });
        void useBadgesStore.getState().fetch();
        break;
      }
      case "group.member.left": {
        const data = notificationFrame.data ?? {};
        notices.push({ kind: "group.member.left", title: "群成员已离开", detail: `${data.conversation_title ?? "群聊"}：${data.member_name ?? "一位成员"} 已离开` });
        break;
      }
      case "group.created": {
        const d = frame as import("../api/types").GroupCreatedFrame;
        chat.upsertConversation({
          id: d.conversation.id,
          type: "group",
          title: d.conversation.title,
          announcement: d.conversation.announcement,
          avatar: d.conversation.avatar || "",
          owner_id: d.conversation.owner_id,
          members: [],
          my_role: null,
          member_count: 0,
          unread_count: 0,
          created_at: d.conversation.created_at,
          peer: null,
        });
        break;
      }
      case "group.joined": {
        const d = frame as import("../api/types").GroupJoinedFrame;
        // group.joined 已按用户组推送给新成员，只需加入会话列表。
        chat.upsertConversation({
          id: d.conversation.id,
          type: "group",
          title: d.conversation.title,
          announcement: d.conversation.announcement,
          avatar: d.conversation.avatar || "",
          owner_id: d.conversation.owner_id,
          members: [],
          my_role: "member",
          member_count: 0,
          unread_count: 0,
          created_at: d.conversation.created_at,
          peer: null,
        });
        break;
      }
      case "voice.channel.created": {
        const channelId = String(frame.data.channel_id);
        // WS 只作目录提示；以权限 REST 详情为权威，避免泄露受限频道且与列表对账。
        void voiceApi.getVoiceChannel(channelId)
          .then((channel) => {
            useVoiceStore.getState().upsertChannel(channel);
            // 新语音房创建 → 其可见群卡片往前排（单调）。
            bumpGroups(visibleGroupIds(channel));
          })
          .catch(() => { /* 403/404：当前用户不可见或频道已删除，忽略提示 */ });
        break;
      }
      case "voice.channel.deleted": {
        const d = frame.data;
        // 删除不回退排序（卡片保持在原位置）。
        useVoiceStore.getState().removeChannel(d.channel_id);
        break;
      }
      case "voice.channel.member_count_changed": {
        // 有人加入/离开/被踢/超时清理 → 目录列表实时刷新人数（轮播「N人在xx连麦」）
        const d = frame.data;
        const prev = useVoiceStore.getState().channels.find(
          (c) => c.id === String(d.channel_id),
        );
        const prevCount = prev ? Number(prev.member_count) : 0;
        useVoiceStore.getState().patchChannel(d.channel_id, {
          member_count: d.member_count,
        });
        // 有人进入（人数增加）→ 群卡片往前排；离开/被踢（人数减少）不回退。
        if (Number(d.member_count) > prevCount && prev) {
          bumpGroups(visibleGroupIds(prev));
        }
        break;
      }
      case "voice.channel.updated": {
        // 语音房改名/可见性/转让房主 → 以权限 REST 详情为权威对账（对齐 created 模式）。
        const channelId = String(frame.data.channel_id);
        void voiceApi.getVoiceChannel(channelId)
          .then((channel) => useVoiceStore.getState().upsertChannel(channel))
          .catch(() => { /* 403/404：当前用户不可见或已删除，忽略提示 */ });
        break;
      }
      case "live.channel.created": {
        this.reconcileLiveChannel(frame.data.channel_id);
        break;
      }
      case "live.channel.status.changed": {
        this.reconcileLiveChannel(frame.data.channel_id);
        if (frame.data.status === "live") {
          // 开播 → 拉详情确认可见群后 bump（单调往前排）；下播/结束不回退。
          void liveApi.getLiveChannel(frame.data.channel_id)
            .then((channel) => {
              if (channel.status === "live") bumpGroups(visibleGroupIds(channel));
            })
            .catch(() => { /* 拉详情失败忽略，排序以 reconcile 结果为准 */ });
        }
        break;
      }
      case "live.channel.deleted": {
        const d = frame.data;
        // 删除直播间不回退排序。
        useLiveStore.getState().removeChannel(d.channel_id);
        break;
      }
      case "live.channel.updated": {
        // 直播间资料编辑（标题/封面/可见性）→ 拉完整详情对账（轮播直播卡实时刷新）
        this.reconcileLiveChannel(frame.data.channel_id);
        break;
      }
      case "post.created": {
        // WS 帧只带简化字段；以权限 REST 详情为权威（作者/可见群/`images`），
        // 拉取完整帖子 upsert 到 posts store → 群"新内容"排序/列表事件描述实时刷新。
        const d = frame as import("../api/types").PostCreatedFrame;
        const postId = Number(d.post.id);
        if (!postId) break;
        void postsApi
          .getPost(postId)
          .then((post) => {
            usePostsStore.getState().upsertPost(post);
            bumpGroups(visibleGroupIds(post));
          })
          .catch(() => { /* 当前用户不可见或帖子已删除，忽略提示 */ });
        break;
      }
      case "post.deleted": {
        const d = frame as import("../api/types").PostDeletedFrame;
        // 删除不回退排序（卡片保持在原位置）。
        usePostsStore.getState().removePost(Number(d.post_id));
        break;
      }
      case "post.updated": {
        // 帖子被编辑（标题/正文/可见性）→ 拉完整帖子 upsert（轮播「最新帖」实时刷新）；
        // created_at 不变，编辑算「新内容」→ 单调 bump 使可见群卡片往前排。
        const d = frame as import("../api/types").PostUpdatedFrame;
        const postId = Number(d.post.id);
        if (!postId) break;
        void postsApi
          .getPost(postId)
          .then((post) => {
            usePostsStore.getState().upsertPost(post);
            bumpGroups(visibleGroupIds(post));
          })
          .catch(() => { /* 当前用户不可见或帖子已删除，忽略提示 */ });
        break;
      }
      case "comment.created":
      case "comment.deleted":
        // 评论事件由帖子详情页经 onFrame 订阅消费（乐观插入/移除 + 更新计数）。
        break;
      case "boardgame.room.created": {
        const d = frame.room;
        if (!d || !d.id) break;
        void boardgameApi.getGameRoom(Number(d.id))
          .then((room) => useBoardgameStore.getState().upsertRoom(room))
          .catch(() => { /* 当前用户不可见或房间已删除 */ });
        break;
      }
      case "boardgame.room.deleted": {
        useBoardgameStore.getState().removeRoom(Number(frame.room_id));
        break;
      }
      case "boardgame.room.updated": {
        // 桌游房变更（有人加入/离开/被踢/转让/编辑）→ 拉完整房间对账
        const d = frame.room;
        if (!d || !d.id) break;
        void boardgameApi.getGameRoom(Number(d.id))
          .then((room) => useBoardgameStore.getState().upsertRoom(room))
          .catch(() => { /* 当前用户不可见或房间已删除 */ });
        break;
      }
      case "favorite.changed": {
        // 收藏/取消收藏（用户级广播，仅推给收藏者本人）：同账号各界面实时同步。
        // 帖子走 posts store（favoriteByPostId）；其余类型（live/voice/game/message）
        // 走 FavoriteButton 模块缓存订阅（applyFavoriteChanged 更新缓存并通知挂载按钮）。
        const d = frame.data;
        if (d.target_type === "post") {
          usePostsStore.getState().setFavorite(
            d.target_id,
            d.action === "added" ? d.favorite_id : null,
          );
        } else {
          applyFavoriteChanged(
            d.target_type,
            d.target_id,
            d.action === "added" ? d.favorite_id : null,
          );
        }
        break;
      }
      case "elysia.reply": {
        const d = frame.data;
        const msg: ChatMessage = {
          id: d.message_id,
          conversation_id: d.conversation_id,
          sender_id: d.sender_id,
          type: d.type,
          content: d.content,
          media_id: null,
          reply_to: null,
          read_by_me: false,
          status: "sent",
          seq: d.seq,
          created_at: d.ts,
        };
        message.upsertMessage(d.conversation_id, msg);
        const conv = chat.conversations.find((c) => c.id === d.conversation_id);
        if (conv) {
          // 爱莉回复也要更新会话列表预览 + 群排序（与 message.new 对齐）。
          chat.setLastMessage(conv.id, {
            seq: d.seq,
            type: d.type,
            content: d.content,
            sender_id: d.sender_id,
            sender_name: previewSenderName(conv, d.sender_id),
            status: "sent",
            created_at: d.ts,
            preview:
              d.content ||
              (d.type === "image" ? "[图片]" : d.type === "video" ? "[视频]" : d.type === "voice" ? "[语音]" : undefined),
          });
          if (conv.type === "group") chat.bumpGroupActivity(conv.id);
        }
        const atBottom =
          chat.activeConversationId === d.conversation_id &&
          (message.viewerAtBottom[d.conversation_id] ?? true);
        if (atBottom) {
          // 正在底部看最新消息：爱莉回复直接已读，不弹标签。
          message.markReadByMe(d.conversation_id, d.message_id);
          chatApi
            .markMessageRead(d.conversation_id, d.message_id, true)
            .then(() => useBadgesStore.getState().fetch())
            .catch(() => { /* 已读失败，下次进入会话重试 */ });
        } else {
          chat.bumpUnread(d.conversation_id, { seq: d.seq });
          if (!conv || conv.type === "private") {
            // 爱莉回复多为私信：私信未读 → 全局消息入口红点实时刷新
            void useBadgesStore.getState().fetch();
          }
        }
        break;
      }
      case "chat.subscribed":
      case "pong":
      case "error":
        break;
    }

    for (const h of this.handlers) h(frame);
  }

  onFrame(handler: ChatFrameHandler): () => void {
    this.handlers.add(handler);
    return () => this.handlers.delete(handler);
  }

  /** 显式断开（登出时调用）：不自动重连 */
  disconnect() {
    this.manualClosed = true;
    this.subscribed.clear();
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.stopHeartbeat();
    if (this.ws) {
      this.ws.onclose = null;
      this.ws.close();
      this.ws = null;
    }
    this.connection = "offline";
    useRealtimeStore.getState().setStatus("chat", "offline");
  }
}

/** 单例（避免多组件各连一条） */
export const chatWS = new ChatWSClient();

/**
 * 订阅一组会话里的所有群（幂等）。
 *
 * 群消息的 message.new 只广播到 `chat_conv_{id}` 组，而主页/宽屏 ServerRail 常驻
 * 群聊列表却不打开任何群聊天，若不主动订阅就收不到群消息 → 红点/轮播消息卡/排序
 * 都不会实时刷新。这里在会话列表加载完成后统一订阅所有群。
 */
export function subscribeGroupConversations(conversations: ConversationSummary[]) {
  const groupIds = conversations
    .filter((c) => c.type === "group")
    .map((c) => c.id);
  if (groupIds.length > 0) chatWS.subscribe(groupIds);
}
