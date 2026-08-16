/**
 * 直播弹幕 WebSocket 客户端（M5-4，对齐 backend/apps/live/consumers.py）。
 *
 * - 路径 /ws/live/<channel_id>/?token=<jwt>（JWT query token，channel_id 为 int）；
 * - 关闭码：4401 未认证 / 4404 频道不存在或 id 非法（均不重连，回调给 UI）；
 * - 协议：服务端只推 danmaku/pong/error；客户端可发 ping 保活，**不能发弹幕**
 *   （发送走 REST，落库后服务端广播，自己也会收到回帧——单一数据流）；
 * - 断线重连：指数退避 1s→2s→...→30s；重连成功后触发 onReconnected 回调
 *   （由编排层拉历史弹幕对账去重，WS 无补发语义）。
 */
import { useAuthStore } from "../stores/auth";
import { WS_BASE_URL } from "./presence";
import type { LiveServerFrame } from "../api/types";
import { useRealtimeStore } from "../stores/realtime";

const HEARTBEAT_INTERVAL_MS = 30_000;
const MAX_RECONNECT_DELAY_MS = 30_000;
const BASE_RECONNECT_DELAY_MS = 1_000;

/** 服务端主动关闭的语义（4401/4404 不重连） */
export type LiveWSCloseReason = "unauthorized" | "channel_not_found" | "unknown";

export type LiveFrameHandler = (frame: LiveServerFrame) => void;

export class LiveWSClient {
  private ws: WebSocket | null = null;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private attempt = 0;
  private manualClosed = false;
  private channelId: number | null = null;
  private handlers = new Set<LiveFrameHandler>();

  /** 连接状态（供 UI 展示） */
  connection: "connecting" | "online" | "offline" = "offline";

  /** 服务端主动关闭（4401/4404）时回调；unknown 仅在手动 close 前调用 */
  onClosedByServer: ((reason: LiveWSCloseReason) => void) | null = null;
  /** 重连成功（onopen）时回调（用于弹幕历史对账） */
  onReconnected: (() => void) | null = null;
  /** 连接状态变化回调（同步到 store） */
  onConnectionChange:
    | ((conn: "connecting" | "online" | "offline") => void)
    | null = null;

  /** 连接指定频道的弹幕 WS（重复调用先断开旧连接） */
  connect(channelId: number) {
    const access = useAuthStore.getState().accessToken;
    if (!access) return;
    // 切换频道：先断开旧连接
    if (this.ws || this.channelId !== null) this.disconnect();
    this.channelId = channelId;
    this.manualClosed = false;
    this.setConnection("connecting");
    this.open(channelId, access);
  }

  private open(channelId: number, access: string) {
    const url = `${WS_BASE_URL}/ws/live/${channelId}/?token=${encodeURIComponent(access)}`;
    let ws: WebSocket;
    try {
      ws = new WebSocket(url);
    } catch {
      this.scheduleReconnect();
      return;
    }
    this.ws = ws;

    ws.onopen = () => {
      const isReconnect = this.attempt > 0;
      this.attempt = 0;
      this.setConnection("online");
      this.startHeartbeat();
      // 重连成功：通知编排层拉历史对账（WS 无补发语义）
      if (isReconnect) this.onReconnected?.();
    };

    ws.onmessage = (ev) => {
      let frame: LiveServerFrame;
      try {
        frame = JSON.parse(ev.data as string) as LiveServerFrame;
      } catch {
        return;
      }
      this.dispatch(frame);
    };

    ws.onclose = (ev) => {
      this.stopHeartbeat();
      this.setConnection("offline");
      // 4401 未认证 / 4404 频道不存在：语义性关闭，不重连
      if (ev.code === 4401) {
        this.manualClosed = true;
        this.onClosedByServer?.("unauthorized");
        return;
      }
      if (ev.code === 4404) {
        this.manualClosed = true;
        this.onClosedByServer?.("channel_not_found");
        return;
      }
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
      if (!access || this.manualClosed || this.channelId === null) return;
      this.open(this.channelId, access);
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

  private setConnection(conn: "connecting" | "online" | "offline") {
    this.connection = conn;
    useRealtimeStore.getState().setStatus("live", conn === "online" ? "online" : conn === "connecting" ? "connecting" : "offline");
    this.onConnectionChange?.(conn);
  }

  // ---------- 事件分发 ----------

  private dispatch(frame: LiveServerFrame) {
    for (const h of this.handlers) h(frame);
  }

  onFrame(handler: LiveFrameHandler): () => void {
    this.handlers.add(handler);
    return () => this.handlers.delete(handler);
  }

  /** 显式断开（退房时调用）：不自动重连 */
  disconnect() {
    this.manualClosed = true;
    this.channelId = null;
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

/** 单例（直播间同时只需一条弹幕连接） */
export const liveWS = new LiveWSClient();
