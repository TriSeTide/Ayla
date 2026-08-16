/**
 * Presence WebSocket 客户端（单例）。
 *
 * - 路径 /ws/presence/?token=<jwt>（AuthMiddlewareStack，JWT query token）
 * - 握手失败（4401 未认证）→ 断开且不重连
 * - 心跳：每 25s 发 ping，服务端回 pong（保活 Redis TTL）
 * - 断线：指数退避重连 1s→2s→4s→...→上限 30s；重连成功重置退避
 * - 收到 presence.update（增量）→ 更新 store；presence.self → 记录自身 id
 */
import { useAuthStore } from "../stores/auth";
import { usePresenceStore } from "../stores/presence";
import { useRealtimeStore } from "../stores/realtime";

export const WS_BASE_URL = (import.meta.env.VITE_WS_BASE_URL as string | undefined) ?? "";

const HEARTBEAT_INTERVAL_MS = 25_000;
const MAX_RECONNECT_DELAY_MS = 30_000;
const BASE_RECONNECT_DELAY_MS = 1_000;

type MessageHandler = (msg: { type: string; data?: unknown }) => void;

export class PresenceClient {
  private ws: WebSocket | null = null;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private attempt = 0;
  private manualClosed = false;
  private handlers = new Set<MessageHandler>();

  /** 登录后由 auth 恢复流程调用；logout 前调用 disconnect() */
  connect() {
    const access = useAuthStore.getState().accessToken;
    if (!access) return;
    this.manualClosed = false;
    usePresenceStore.getState().setConnection("connecting");
    useRealtimeStore.getState().setStatus("presence", "connecting");
    this.open(access);
  }

  private open(access: string) {
    const url = `${WS_BASE_URL}/ws/presence/?token=${encodeURIComponent(access)}`;
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
      usePresenceStore.getState().setConnection("online");
      useRealtimeStore.getState().setStatus("presence", "online");
      this.startHeartbeat();
    };

    ws.onmessage = (ev) => {
      let msg: { type: string; data?: unknown };
      try {
        msg = JSON.parse(ev.data as string) as { type: string; data?: unknown };
      } catch {
        return;
      }
      this.dispatch(msg);
    };

    ws.onclose = () => {
      this.stopHeartbeat();
      usePresenceStore.getState().setConnection("offline");
      useRealtimeStore.getState().setStatus("presence", this.manualClosed ? "offline" : "connecting");
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
    usePresenceStore.getState().setConnection("connecting");
    useRealtimeStore.getState().setStatus("presence", "connecting");
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

  private dispatch(msg: { type: string; data?: unknown }) {
    const store = usePresenceStore.getState();
    if (msg.type === "presence.update") {
      const data = msg.data as { user_id: string; status: string } | undefined;
      if (data?.user_id) {
        if (data.status === "offline") store.removeUser(data.user_id);
        else store.setUser(data.user_id, data.status);
      }
    }
    for (const h of this.handlers) h(msg);
  }

  onMessage(handler: MessageHandler): () => void {
    this.handlers.add(handler);
    return () => this.handlers.delete(handler);
  }

  /** 显式断开（登出时调用）：不自动重连 */
  disconnect() {
    this.manualClosed = true;
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
    usePresenceStore.getState().reset();
    useRealtimeStore.getState().setStatus("presence", "offline");
  }
}

/** 单例（避免多组件各连一条） */
export const presenceClient = new PresenceClient();
