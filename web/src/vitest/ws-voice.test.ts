/**
 * ws/voice.ts 契约测试（mock WS，M5-3 §7.1；骨架对齐 ws-chat.test.ts）：
 * - subscribe 发送 {type:"subscribe", channel_ids} 帧
 * - voice.state → store 合并（joined/left）
 * - voice.subscribed / pong / error → 只透传 handlers，不动 store
 * - 断线重连后自动重 subscribe + 触发 onReconnected（对账钩子）
 * - 未连接时 subscribe 先触发 connect
 * - 心跳 ping；显式 disconnect 不重连
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { VoiceWSClient } from "../ws/voice";
import { useAuthStore } from "../stores/auth";
import { useVoiceStore } from "../stores/voice";

type WSInstance = {
  readyState: number;
  send: ReturnType<typeof vi.fn>;
  close: ReturnType<typeof vi.fn>;
  _open: () => void;
  _message: (data: string) => void;
  _close: () => void;
};

let instances: WSInstance[] = [];

class MockWebSocket {
  static OPEN = 1;
  static CONNECTING = 0;
  static CLOSED = 3;
  readyState = MockWebSocket.CONNECTING;

  onopen: (() => void) | null = null;
  onmessage: ((ev: { data: string }) => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;
  send = vi.fn();
  close = vi.fn();

  _open = () => {
    this.readyState = MockWebSocket.OPEN;
    this.onopen?.();
  };
  _message = (data: string) => this.onmessage?.({ data });
  _close = () => {
    this.readyState = MockWebSocket.CLOSED;
    this.onclose?.();
  };

  constructor(_url: string) {
    const self = this as unknown as WSInstance;
    instances.push(self);
    setTimeout(() => self._open(), 0);
  }
}

function fire(instance: WSInstance, data: unknown) {
  instance._message(JSON.stringify(data));
}

function sentFrames(instance: WSInstance): unknown[] {
  return instance.send.mock.calls.map((c) => JSON.parse(c[0]));
}

beforeEach(() => {
  instances = [];
  vi.stubGlobal("WebSocket", MockWebSocket);
  vi.useFakeTimers();
  useAuthStore.setState({ accessToken: "acc", refreshToken: "ref" });
  useVoiceStore.getState().reset();
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  useAuthStore.setState({ accessToken: null, refreshToken: null });
  useVoiceStore.getState().reset();
});

describe("VoiceWSClient", () => {
  it("connect → 建立连接；subscribe 发送 subscribe 帧", () => {
    const client = new VoiceWSClient();
    client.connect();
    vi.runOnlyPendingTimers();
    const ws = instances[0];
    expect(client.connection).toBe("online");

    client.subscribe(["1", "2"]);
    expect(sentFrames(ws)).toContainEqual({ type: "subscribe", channel_ids: ["1", "2"] });
    client.disconnect();
  });

  it("voice.state → store 合并（joined → 成员写入）", () => {
    const client = new VoiceWSClient();
    client.connect();
    vi.runOnlyPendingTimers();
    const ws = instances[0];

    useVoiceStore.getState().enterChannel("ch1", []);
    fire(ws, {
      type: "voice.state",
      data: { channel_id: "ch1", user_id: "u1", state: "joined", ts: "t1" },
    });
    expect(useVoiceStore.getState().members["u1"]).toBeDefined();

    fire(ws, {
      type: "voice.state",
      data: { channel_id: "ch1", user_id: "u1", state: "left", ts: "t2" },
    });
    expect(useVoiceStore.getState().members["u1"]).toBeUndefined();
    client.disconnect();
  });

  it("voice.subscribed / pong / error 只透传 handlers，不动 store", () => {
    const client = new VoiceWSClient();
    client.connect();
    vi.runOnlyPendingTimers();
    const ws = instances[0];

    const seen: string[] = [];
    const off = client.onFrame((f) => seen.push(f.type));
    fire(ws, { type: "voice.subscribed", data: { channel_id: "ch1" } });
    fire(ws, { type: "pong", ts: 123 });
    fire(ws, { type: "error", detail: "unknown type foo" });
    expect(seen).toEqual(["voice.subscribed", "pong", "error"]);
    expect(useVoiceStore.getState().members).toEqual({});
    off();
    client.disconnect();
  });

  it("断线重连后：自动重 subscribe 已订阅频道 + 触发 onReconnected 对账钩子", () => {
    const client = new VoiceWSClient();
    client.connect();
    vi.runOnlyPendingTimers();
    client.subscribe(["ch1"]);

    let reconnected = 0;
    client.onReconnected(() => {
      reconnected += 1;
    });

    instances[0]._close();
    vi.advanceTimersByTime(1000);
    expect(instances).toHaveLength(2);
    const ws2 = instances[1];
    ws2._open();
    expect(sentFrames(ws2)).toContainEqual({ type: "subscribe", channel_ids: ["ch1"] });
    expect(reconnected).toBe(1);
    client.disconnect();
  });

  it("unsubscribe 后重连不再订阅该频道", () => {
    const client = new VoiceWSClient();
    client.connect();
    vi.runOnlyPendingTimers();
    client.subscribe(["ch1", "ch2"]);
    client.unsubscribe("ch1");

    instances[0]._close();
    vi.advanceTimersByTime(1000);
    const ws2 = instances[1];
    ws2._open();
    expect(sentFrames(ws2)).toContainEqual({ type: "subscribe", channel_ids: ["ch2"] });
    client.disconnect();
  });

  it("未连接时 subscribe → 先触发 connect，open 后补发", () => {
    const client = new VoiceWSClient();
    client.subscribe(["ch9"]); // 未 connect
    vi.runOnlyPendingTimers();
    expect(instances).toHaveLength(1);
    expect(sentFrames(instances[0])).toContainEqual({
      type: "subscribe",
      channel_ids: ["ch9"],
    });
    client.disconnect();
  });

  it("心跳：open 后每 30s 发 ping", () => {
    const client = new VoiceWSClient();
    client.connect();
    vi.runOnlyPendingTimers();
    const ws = instances[0];
    vi.advanceTimersByTime(30_000);
    expect(sentFrames(ws).some((m) => (m as { type: string }).type === "ping")).toBe(true);
    client.disconnect();
  });

  it("显式 disconnect → 不重连", () => {
    const client = new VoiceWSClient();
    client.connect();
    vi.runOnlyPendingTimers();
    client.disconnect();
    instances[0]._close();
    vi.advanceTimersByTime(10_000);
    expect(instances).toHaveLength(1);
  });
});
