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
import { useChatStore } from "../stores/chat";
import { useMessageStore } from "../stores/message";
import { WS_BASE_URL } from "./presence";
import type { ChatMessage, ChatServerFrame } from "../api/types";
import { useRealtimeStore } from "../stores/realtime";
import { useNoticeStore } from "../stores/notices";

const HEARTBEAT_INTERVAL_MS = 30_000;
const MAX_RECONNECT_DELAY_MS = 30_000;
const BASE_RECONNECT_DELAY_MS = 1_000;

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
          reply_to: d.reply_to,
          status: "sent",
          seq: d.seq,
          created_at: d.ts,
        };
        message.upsertMessage(d.conversation_id, msg);
        // 未打开会话 → 未读数 +1
        chat.bumpUnread(d.conversation_id);
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
        break;
      }
      case "group.request.resolved": {
        const data = notificationFrame.data ?? {};
        const status = data.status === "accepted" ? "已通过" : "已拒绝";
        notices.push({ kind: "group.request.resolved", title: "入群申请有结果", detail: `${data.conversation_title ?? "群聊"}：你的申请${status}` });
        break;
      }
      case "group.invite.new": {
        const data = notificationFrame.data ?? {};
        notices.push({ kind: "group.invite.new", title: "收到新的群邀请", detail: `${data.inviter_name ?? "有人"} 邀请你加入 ${data.conversation_title ?? "群聊"}` });
        break;
      }
      case "group.member.left": {
        const data = notificationFrame.data ?? {};
        notices.push({ kind: "group.member.left", title: "群成员已离开", detail: `${data.conversation_title ?? "群聊"}：${data.member_name ?? "一位成员"} 已离开` });
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
