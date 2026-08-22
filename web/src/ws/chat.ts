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

/** 收到 WS 帧的通用处理器（供测试/扩展监听） */
export type ChatFrameHandler = (frame: ChatServerFrame) => void;

export class ChatWSClient {
  private ws: WebSocket | null = null;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private attempt = 0;
  private manualClosed = false;
  /** 已订阅的会话 id 集合（重连后据此发 resume） */
  private subscribed = new Set<string>();
  private handlers = new Set<ChatFrameHandler>();

  /** 连接状态（供 UI 展示"连接中"） */
  connection: "connecting" | "online" | "offline" = "offline";

  connect() {
    const access = useAuthStore.getState().accessToken;
    if (!access) return;
    this.manualClosed = false;
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
      // 重连成功：对已订阅会话逐条 resume 补发
      for (const convId of this.subscribed) {
        this.sendResume(convId);
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
          status: "sent",
          seq: d.seq,
          created_at: d.ts,
        };
        message.upsertMessage(d.conversation_id, msg);
        // 未打开会话 → 未读数 +1
        chat.bumpUnread(d.conversation_id);
        // 实时刷新会话列表的最新一条消息预览（会话仍在本地位列表时）。
        // 若该会话被"删除"（隐藏）不在此列表，服务端已自动取消隐藏，
        // 下次 listConversations 刷新即重新出现。
        const conv = chat.conversations.find((c) => c.id === d.conversation_id);
        const isActive = chat.activeConversationId === d.conversation_id;
        if (isActive) {
          // 正在聊天：对方消息立即标已读（不计入红点），确认后刷新红点。
          const me = useAuthStore.getState().currentUser;
          if (me && String(d.sender_id) !== String(me.id)) {
            chatApi
              .markMessageRead(d.conversation_id, d.message_id)
              .then(() => useBadgesStore.getState().fetch())
              .catch(() => { /* 已读失败下次打开重试 */ });
          }
        } else if (!conv || conv.type === "private") {
          // 私信新消息（未打开）→ 全局消息入口红点（private_unread）实时刷新；
          // 群未读不进消息中心红点（属群卡片/ServerRail 角标），故群消息不拉 badges。
          void useBadgesStore.getState().fetch();
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
        }
        break;
      }
      case "message.recall": {
        const d = frame.data;
        message.setRecalled(d.conversation_id, d.message_id);
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
          .then((channel) => useVoiceStore.getState().upsertChannel(channel))
          .catch(() => { /* 403/404：当前用户不可见或频道已删除，忽略提示 */ });
        break;
      }
      case "voice.channel.deleted": {
        const d = frame.data;
        useVoiceStore.getState().removeChannel(d.channel_id);
        break;
      }
      case "voice.channel.member_count_changed": {
        // 有人加入/离开/被踢/超时清理 → 目录列表实时刷新人数（轮播「N人在xx连麦」）
        const d = frame.data;
        useVoiceStore.getState().patchChannel(d.channel_id, {
          member_count: d.member_count,
        });
        break;
      }
      case "live.channel.created": {
        this.reconcileLiveChannel(frame.data.channel_id);
        break;
      }
      case "live.channel.status.changed": {
        this.reconcileLiveChannel(frame.data.channel_id);
        break;
      }
      case "live.channel.deleted": {
        const d = frame.data;
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
          .then((post) => usePostsStore.getState().upsertPost(post))
          .catch(() => { /* 当前用户不可见或帖子已删除，忽略提示 */ });
        break;
      }
      case "post.deleted": {
        const d = frame as import("../api/types").PostDeletedFrame;
        usePostsStore.getState().removePost(Number(d.post_id));
        break;
      }
      case "post.updated": {
        // 帖子被编辑（标题/正文/可见性）→ 拉完整帖子 upsert（轮播「最新帖」实时刷新）
        const d = frame as import("../api/types").PostUpdatedFrame;
        const postId = Number(d.post.id);
        if (!postId) break;
        void postsApi
          .getPost(postId)
          .then((post) => usePostsStore.getState().upsertPost(post))
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
          status: "sent",
          seq: d.seq,
          created_at: d.ts,
        };
        message.upsertMessage(d.conversation_id, msg);
        chat.bumpUnread(d.conversation_id);
        const conv = chat.conversations.find((c) => c.id === d.conversation_id);
        if (chat.activeConversationId === d.conversation_id) {
          // 正在聊天：爱莉回复立即标已读（不计红点），确认后刷新红点
          const me = useAuthStore.getState().currentUser;
          if (me && String(d.sender_id) !== String(me.id)) {
            chatApi
              .markMessageRead(d.conversation_id, d.message_id)
              .then(() => useBadgesStore.getState().fetch())
              .catch(() => { /* 已读失败下次打开重试 */ });
          }
        } else if (!conv || conv.type === "private") {
          // 爱莉回复多为私信：私信未读 → 全局消息入口红点实时刷新
          void useBadgesStore.getState().fetch();
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
