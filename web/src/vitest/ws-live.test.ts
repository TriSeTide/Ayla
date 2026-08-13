/**
 * ws/live.ts 契约测试（M5-4 文档 §7.1，对齐 backend/apps/live/consumers.py）：
 * - connect 拼接 /ws/live/<id>/?token=；danmaku 帧经 onFrame 分发（含 sender）
 * - ping 心跳；pong/error 帧不炸
 * - close(4401) → unauthorized 回调且不重连；close(4404) → channel_not_found 且不重连
 * - 断线指数退避重连；重连成功触发 onReconnected（供历史对账）
 * - disconnect 后不重连
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { LiveWSClient } from "../ws/live";
import { useAuthStore } from "../stores/auth";
import { useLiveStore } from "../stores/live";

type WSInstance = {
  url: string;
  readyState: number;
  send: ReturnType<typeof vi.fn>;
  close: ReturnType<typeof vi.fn>;
  _open: () => void;
  _message: (data: string) => void;
  _close: (code?: number) => void;
};

let instances: WSInstance[] = [];

class MockWebSocket {
  static OPEN = 1;
  static CONNECTING = 0;
  static CLOSED = 3;
  readyState = MockWebSocket.CONNECTING;

  onopen: (() => void) | null = null;
  onmessage: ((ev: { data: string }) => void) | null = null;
  onclose: ((ev: { code: number }) => void) | null = null;
  onerror: (() => void) | null = null;
  send = vi.fn();
  close = vi.fn();

  _open = () => {
    this.readyState = MockWebSocket.OPEN;
    this.onopen?.();
  };
  _message = (data: string) => this.onmessage?.({ data });
  _close = (code = 1000) => {
    this.readyState = MockWebSocket.CLOSED;
    this.onclose?.({ code });
  };

  constructor(public url: string) {
    const self = this as unknown as WSInstance;
    instances.push(self);
    setTimeout(() => self._open(), 0);
  }
}

function fire(instance: WSInstance, data: unknown) {
  instance._message(JSON.stringify(data));
}

beforeEach(() => {
  instances = [];
  vi.stubGlobal("WebSocket", MockWebSocket);
  vi.useFakeTimers();
  useAuthStore.setState({ accessToken: "acc", refreshToken: "ref" });
  useLiveStore.getState().reset();
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  useAuthStore.setState({ accessToken: null, refreshToken: null });
  useLiveStore.getState().reset();
});

describe("LiveWSClient", () => {
  it("connect → /ws/live/<id>/?token=；online 状态回调", () => {
    const client = new LiveWSClient();
    const states: string[] = [];
    client.onConnectionChange = (c) => states.push(c);
    client.connect(7);
    vi.runOnlyPendingTimers();
    expect(instances[0].url).toBe("/ws/live/7/?token=acc");
    expect(client.connection).toBe("online");
    expect(states).toContain("online");
    client.disconnect();
  });

  it("danmaku 帧 → onFrame 分发（sender/content 原样）", () => {
    const client = new LiveWSClient();
    client.connect(7);
    vi.runOnlyPendingTimers();
    const seen: unknown[] = [];
    const off = client.onFrame((f) => seen.push(f));
    fire(instances[0], {
      type: "danmaku",
      id: "12",
      sender: { id: "u1", nickname: "汐汐" },
      content: "来了",
      created_at: "2026-08-13T00:00:00Z",
    });
    expect(seen).toHaveLength(1);
    expect(seen[0]).toMatchObject({
      type: "danmaku",
      id: "12",
      content: "来了",
      sender: { id: "u1", nickname: "汐汐" },
    });
    off();
    client.disconnect();
  });

  it("pong/error 帧正常分发不炸；心跳每 30s 发 ping", () => {
    const client = new LiveWSClient();
    client.connect(7);
    vi.runOnlyPendingTimers();
    const ws = instances[0];
    fire(ws, { type: "pong", ts: 123 });
    fire(ws, { type: "error", detail: "unknown type ..." });
    vi.advanceTimersByTime(30_000);
    const sent = ws.send.mock.calls.map((c) => JSON.parse(c[0] as string));
    expect(sent.some((m) => m.type === "ping")).toBe(true);
    client.disconnect();
  });

  it("close(4401) → unauthorized 回调，不重连", () => {
    const client = new LiveWSClient();
    const reasons: string[] = [];
    client.onClosedByServer = (r) => reasons.push(r);
    client.connect(7);
    vi.runOnlyPendingTimers();
    instances[0]._close(4401);
    vi.advanceTimersByTime(60_000);
    expect(reasons).toEqual(["unauthorized"]);
    expect(instances).toHaveLength(1);
  });

  it("close(4404) → channel_not_found 回调，不重连", () => {
    const client = new LiveWSClient();
    const reasons: string[] = [];
    client.onClosedByServer = (r) => reasons.push(r);
    client.connect(999);
    vi.runOnlyPendingTimers();
    instances[0]._close(4404);
    vi.advanceTimersByTime(60_000);
    expect(reasons).toEqual(["channel_not_found"]);
    expect(instances).toHaveLength(1);
  });

  it("异常断线 → 指数退避重连；重连成功触发 onReconnected（对账钩子）", () => {
    const client = new LiveWSClient();
    let reconnected = 0;
    client.onReconnected = () => {
      reconnected += 1;
    };
    client.connect(7);
    vi.runOnlyPendingTimers();
    expect(instances).toHaveLength(1);

    // 异常断开（非 4401/4404）
    instances[0]._close(1006);
    vi.advanceTimersByTime(1_000);
    expect(instances).toHaveLength(2);
    instances[1]._open();
    expect(reconnected).toBe(1);
    expect(client.connection).toBe("online");
    client.disconnect();
  });

  it("disconnect → 不重连；切换频道先断旧连接", () => {
    const client = new LiveWSClient();
    client.connect(7);
    vi.runOnlyPendingTimers();
    client.disconnect();
    instances[0]._close();
    vi.advanceTimersByTime(10_000);
    expect(instances).toHaveLength(1);

    // 切换频道：旧连接被 close，新连接用新 id
    client.connect(7);
    vi.runOnlyPendingTimers();
    client.connect(8);
    vi.runOnlyPendingTimers();
    expect(instances[1].close).toHaveBeenCalled();
    expect(instances[instances.length - 1].url).toBe("/ws/live/8/?token=acc");
    client.disconnect();
  });
});
