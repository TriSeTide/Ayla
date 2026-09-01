/**
 * ws/presence.ts 测试：收到 presence.update → store 更新；断开退避重连序列。
 *
 * 通过注入 MockWebSocket 观察：
 * - 消息帧解析 → store 增量合并
 * - 断开后按 1s→2s→4s 指数退避重连（fake timers）
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PresenceClient } from "../ws/presence";
import { useAuthStore } from "../stores/auth";
import { usePresenceStore } from "../stores/presence";

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

beforeEach(() => {
  instances = [];
  vi.stubGlobal("WebSocket", MockWebSocket);
  vi.useFakeTimers();
  useAuthStore.setState({ accessToken: "acc", refreshToken: "ref" });
  usePresenceStore.getState().reset();
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  useAuthStore.setState({ accessToken: null, refreshToken: null });
  usePresenceStore.getState().reset();
});

describe("PresenceClient", () => {
  it("收到 presence.update → store 增量更新", () => {
    const client = new PresenceClient();
    client.connect();
    vi.runOnlyPendingTimers(); // 触发 setTimeout open
    const ws = instances[0];
    expect(usePresenceStore.getState().connection).toBe("online");

    fire(ws, { type: "presence.update", data: { user_id: "u1", status: "online" } });
    fire(ws, { type: "presence.update", data: { user_id: "u2", status: "away" } });
    // 非 offline 统一归一为 online（presence 只区分在线/离线）
    expect(usePresenceStore.getState().users).toEqual({ u1: "online", u2: "online" });

    fire(ws, { type: "presence.update", data: { user_id: "u1", status: "offline" } });
    // offline 保留记录（已知状态），供显示层区分「未收到」与「已离线」
    expect(usePresenceStore.getState().users).toEqual({ u1: "offline", u2: "online" });

    client.disconnect();
  });

  it("断开 → 指数退避重连（1s→2s→4s），重连成功重置退避", () => {
    const client = new PresenceClient();
    client.connect();
    vi.runOnlyPendingTimers();
    expect(instances).toHaveLength(1);

    // 第一次断开
    instances[0]._close();
    vi.advanceTimersByTime(1000); // 第一次退避 1s
    expect(instances).toHaveLength(2);

    // 第二次断开 → 2s
    instances[1]._close();
    vi.advanceTimersByTime(2000);
    expect(instances).toHaveLength(3);

    // 第三次断开 → 4s
    instances[2]._close();
    vi.advanceTimersByTime(4000);
    expect(instances).toHaveLength(4);

    // 新连接打开 → 重置退避
    instances[3]._open();
    instances[3]._close();
    vi.advanceTimersByTime(1000); // 应是 1s，而非 8s
    expect(instances).toHaveLength(5);

    client.disconnect();
  });

  it("心跳：open 后周期发 ping", () => {
    const client = new PresenceClient();
    client.connect();
    vi.runOnlyPendingTimers();
    const ws = instances[0];
    expect(ws.send).not.toHaveBeenCalled();

    vi.advanceTimersByTime(25_000);
    expect(ws.send).toHaveBeenCalledTimes(1);
    expect(ws.send.mock.calls[0][0]).toContain('"ping"');

    vi.advanceTimersByTime(25_000);
    expect(ws.send).toHaveBeenCalledTimes(2);

    client.disconnect();
  });

  it("显式 disconnect → 不重连", () => {
    const client = new PresenceClient();
    client.connect();
    vi.runOnlyPendingTimers();
    client.disconnect();
    instances[0]._close();
    vi.advanceTimersByTime(10_000);
    expect(instances).toHaveLength(1);
  });
});
