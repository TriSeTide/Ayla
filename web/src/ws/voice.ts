/**
 * Voice WebSocket 客户端（单例，M5-3 §3.2 / §4.4；骨架对齐 ws/chat.ts）。
 *
 * - 路径 /ws/voice/?token=<jwt>；未认证 → 服务端 close(4401)
 * - subscribe {channel_ids}：仅当我已是成员时服务端回 voice.subscribed 并 group_add；
 *   非成员/不存在频道被静默忽略——因此必须先 REST join 成功再 subscribe
 * - 断线重连：指数退避 1s→2s→...→30s；重连成功后对已订阅频道重发 subscribe，
 *   并通过 onReconnected 回调触发 members/ 对账（voice.state 无补发语义）
 * - 心跳：每 30s 发 ping（对齐 chat WS 节奏）
 * - 事件分发：voice.state → voice store；voice.subscribed/pong/error → handlers
 */
import { useAuthStore } from "../stores/auth";
import { useVoiceStore } from "../stores/voice";
import { WS_BASE_URL } from "./presence";
import type { VoiceServerFrame } from "../api/types";
import { useRealtimeStore } from "../stores/realtime";

const HEARTBEAT_INTERVAL_MS = 30_000;
const MAX_RECONNECT_DELAY_MS = 30_000;
const BASE_RECONNECT_DELAY_MS = 1_000;

/** 收到 WS 帧的通用处理器（供测试/扩展监听） */
export type VoiceFrameHandler = (frame: VoiceServerFrame) => void;

export class VoiceWSClient {
  private ws: WebSocket | null = null;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private attempt = 0;
  private manualClosed = false;
  /** 已订阅的频道 id 集合（重连后据此重发 subscribe） */
  private subscribed = new Set<string>();
  private handlers = new Set<VoiceFrameHandler>();
  /** 重连成功回调（hook 在此触发 members/ 对账） */
  private reconnectHandlers = new Set<() => void>();

  /** 连接状态（供 UI 展示） */
  connection: "connecting" | "online" | "offline" = "offline";

  connect() {
    const access = useAuthStore.getState().accessToken;
    if (!access) return;
    if (this.ws && this.ws.readyState === WebSocket.OPEN) return;
    this.manualClosed = false;
    this.setConnection("connecting");
    this.open(access);
  }

  private setConnection(s: "connecting" | "online" | "offline") {
    this.connection = s;
    useVoiceStore.getState().setWsConnection(s);
    useRealtimeStore.getState().setStatus("voice", s === "online" ? "online" : s === "connecting" ? "connecting" : "offline");
  }

  private open(access: string) {
    const url = `${WS_BASE_URL}/ws/voice/?token=${encodeURIComponent(access)}`;
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
      this.setConnection("online");
      this.startHeartbeat();
      if (this.subscribed.size > 0) {
        // 重连成功：voice.state 无补发语义，重发 subscribe 并对账成员
        this.sendJson({ type: "subscribe", channel_ids: [...this.subscribed] });
        for (const h of this.reconnectHandlers) h();
      }
    };

    ws.onmessage = (ev) => {
      let frame: VoiceServerFrame;
      try {
        frame = JSON.parse(ev.data as string) as VoiceServerFrame;
      } catch {
        return;
      }
      this.dispatch(frame);
    };

    ws.onclose = () => {
      this.stopHeartbeat();
      this.setConnection("offline");
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
    this.setConnection("connecting");
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

  /** 订阅频道（join 成功后调用，幂等）；未连接时先连接 */
  subscribe(channelIds: string[]) {
    for (const id of channelIds) this.subscribed.add(id);
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.sendJson({ type: "subscribe", channel_ids: channelIds });
    } else {
      // 未连接：先连上，onopen 会重发整个集合
      this.connect();
    }
  }

  /** 本地退订（离开频道时调用；服务端无退订帧，清本地集合即可） */
  unsubscribe(channelId: string) {
    this.subscribed.delete(channelId);
  }

  /** 重连成功回调注册（触发 members 对账）；返回解注册函数 */
  onReconnected(handler: () => void): () => void {
    this.reconnectHandlers.add(handler);
    return () => this.reconnectHandlers.delete(handler);
  }

  /** 当前是否已订阅某频道（测试用） */
  isSubscribed(channelId: string): boolean {
    return this.subscribed.has(channelId);
  }

  sendJson(payload: unknown) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(payload));
    }
  }

  // ---------- 事件分发 ----------

  private dispatch(frame: VoiceServerFrame) {
    if (frame.type === "voice.state") {
      const d = frame.data;
      useVoiceStore.getState().applyVoiceState(d.channel_id, d.user_id, d.state, d.ts);
    }
    // voice.subscribed / pong / error：只透传给 handlers
    for (const h of this.handlers) h(frame);
  }

  onFrame(handler: VoiceFrameHandler): () => void {
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
    this.setConnection("offline");
  }
}

/** 单例（避免多组件各连一条） */
export const voiceWS = new VoiceWSClient();
