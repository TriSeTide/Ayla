/**
 * ws/chat.ts 契约测试（文档 §7.1）：
 * - subscribe 发送 subscribe 帧
 * - 收到 message.new → 消息 store 更新 + 未打开会话未读 +1
 * - 收到 message.recall / message.read / typing → 正确路由
 * - 收到 elysia.reply → 爱莉消息渲染（前端不生成内容）
 * - 重连后按各会话 lastSeq 发 resume（补发基线）
 * - 心跳 ping
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ChatWSClient } from "../ws/chat";
import { useAuthStore } from "../stores/auth";
import { useChatStore } from "../stores/chat";
import { useMessageStore } from "../stores/message";
import { useNoticeStore } from "../stores/notices";

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

function lastSend(instance: WSInstance): unknown {
  const calls = instance.send.mock.calls;
  return calls.length ? JSON.parse(calls[calls.length - 1][0]) : null;
}

beforeEach(() => {
  instances = [];
  vi.stubGlobal("WebSocket", MockWebSocket);
  vi.useFakeTimers();
  useAuthStore.setState({ accessToken: "acc", refreshToken: "ref" });
  useChatStore.getState().reset();
  useMessageStore.getState().reset();
  useNoticeStore.getState().clear();
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  useAuthStore.setState({ accessToken: null, refreshToken: null });
  useChatStore.getState().reset();
  useMessageStore.getState().reset();
  useNoticeStore.getState().clear();
});

describe("ChatWSClient", () => {
  it("用户级群成员离开事件进入实时通知 store", () => {
    const client = new ChatWSClient();
    client.connect();
    vi.runOnlyPendingTimers();
    fire(instances[0], {
      type: "group.member.left",
      data: { conversation_id: "g1", conversation_title: "测试群", member_id: "u2", member_name: "小明" },
    });
    expect(useNoticeStore.getState().notices[0]).toMatchObject({
      kind: "group.member.left",
      title: "群成员已离开",
      detail: "测试群：小明 已离开",
    });
    client.disconnect();
  });

  it("connect → 建立连接；subscribe 发送 subscribe 帧", () => {
    const client = new ChatWSClient();
    client.connect();
    vi.runOnlyPendingTimers();
    const ws = instances[0];
    expect(client.connection).toBe("online");

    client.subscribe(["1", "2"]);
    expect(lastSend(ws)).toEqual({ type: "subscribe", conversation_ids: ["1", "2"] });
    client.disconnect();
  });

  it("message.new → 消息 store upsert；未打开会话未读 +1", () => {
    const client = new ChatWSClient();
    client.connect();
    vi.runOnlyPendingTimers();
    const ws = instances[0];

    // 已有会话列表（c2 未打开）
    useChatStore.getState().setConversations([
      {
        id: "c1",
        type: "private",
        title: "x",
        announcement: "",
        avatar: "",
        owner_id: "o",
        members: [],
        my_role: "member",
        member_count: 2,
        unread_count: 0,
        created_at: new Date().toISOString(),
        peer: null,
      },
      {
        id: "c2",
        type: "private",
        title: "y",
        announcement: "",
        avatar: "",
        owner_id: "o",
        members: [],
        my_role: "member",
        member_count: 2,
        unread_count: 0,
        created_at: new Date().toISOString(),
        peer: null,
      },
    ]);
    useChatStore.getState().openConversation("c1");

    fire(ws, {
      type: "message.new",
      data: {
        conversation_id: "c2",
        message_id: "m42",
        sender_id: "peer",
        content: "你好",
        type: "text",
        media: null,
        reply_to: null,
        seq: 3,
        ts: "2026-08-10T00:00:00Z",
      },
    });

    const msg = useMessageStore.getState().buckets["c2"];
    expect(msg.messages).toHaveLength(1);
    expect(msg.messages[0].content).toBe("你好");
    expect(msg.lastSeq).toBe(3);
    // c2 未打开 → 未读 +1；c1 打开 → 不加
    expect(useChatStore.getState().conversations.find((c) => c.id === "c2")?.unread_count).toBe(1);
    expect(useChatStore.getState().conversations.find((c) => c.id === "c1")?.unread_count).toBe(0);
    client.disconnect();
  });

  it("message.recall → 对应消息置 recalled", () => {
    const client = new ChatWSClient();
    client.connect();
    vi.runOnlyPendingTimers();
    const ws = instances[0];

    useMessageStore.getState().upsertMessage("c1", {
      id: "m1",
      conversation_id: "c1",
      sender_id: "peer",
      type: "text",
      content: "hi",
      media_id: null,
      reply_to: null,
      status: "sent",
      seq: 1,
      created_at: new Date().toISOString(),
    });

    fire(ws, { type: "message.recall", data: { conversation_id: "c1", message_id: "m1", seq: 1 } });
    expect(useMessageStore.getState().buckets["c1"].messages[0].status).toBe("recalled");
    client.disconnect();
  });

  it("message.read → 更新对端已读态", () => {
    const client = new ChatWSClient();
    client.connect();
    vi.runOnlyPendingTimers();
    const ws = instances[0];

    fire(ws, {
      type: "message.read",
      data: { conversation_id: "c1", message_id: "m1", user_id: "peer", seq: 1 },
    });
    expect(useMessageStore.getState().readMarks["c1"]?.["m1"]).toContain("peer");
    client.disconnect();
  });

  it("typing 帧 → 通过 onFrame 通知 UI", () => {
    const client = new ChatWSClient();
    client.connect();
    vi.runOnlyPendingTimers();
    const ws = instances[0];

    const seen: string[] = [];
    const off = client.onFrame((f) => {
      if (f.type === "typing") seen.push(f.data.user_id);
    });
    fire(ws, {
      type: "typing",
      data: { conversation_id: "c1", user_id: "peer", is_typing: true },
    });
    expect(seen).toEqual(["peer"]);
    off();
    client.disconnect();
  });

  it("elysia.reply → 爱莉消息 upsert（内容来自服务端投影，前端不生成）", () => {
    const client = new ChatWSClient();
    client.connect();
    vi.runOnlyPendingTimers();
    const ws = instances[0];

    fire(ws, {
      type: "elysia.reply",
      data: {
        conversation_id: "c1",
        message_id: "e99",
        sender_id: "elysia-user",
        content: "你好，这是爱莉的回复",
        type: "text",
        seq: 8,
        event_id: "evt-1",
        ts: "2026-08-10T00:01:00Z",
      },
    });
    const bucket = useMessageStore.getState().buckets["c1"];
    expect(bucket.messages).toHaveLength(1);
    expect(bucket.messages[0].sender_id).toBe("elysia-user");
    expect(bucket.messages[0].content).toBe("你好，这是爱莉的回复");
    expect(bucket.lastSeq).toBe(8);
    client.disconnect();
  });

  it("断线重连后：对已订阅会话发 resume（last_message_seq=该会话 lastSeq）", () => {
    const client = new ChatWSClient();
    client.connect();
    vi.runOnlyPendingTimers();
    useMessageStore.getState().upsertMessage("c1", {
      id: "m1",
      conversation_id: "c1",
      sender_id: "me",
      type: "text",
      content: "hi",
      media_id: null,
      reply_to: null,
      status: "sent",
      seq: 5,
      created_at: new Date().toISOString(),
    });
    client.subscribe(["c1"]);

    // 断开 → 自动重连
    instances[0]._close();
    vi.advanceTimersByTime(1000);
    expect(instances).toHaveLength(2);
    const ws2 = instances[1];
    // 触发 ws2 open（MockWebSocket 用 setTimeout(0) 自开）
    ws2._open();
    // 重连后 open 时发 resume
    expect(lastSend(ws2)).toEqual({
      type: "resume",
      conversation_id: "c1",
      last_message_seq: 5,
    });
    client.disconnect();
  });

  it("心跳：open 后每 30s 发 ping", () => {
    const client = new ChatWSClient();
    client.connect();
    vi.runOnlyPendingTimers();
    const ws = instances[0];
    vi.advanceTimersByTime(30_000);
    const sent = ws.send.mock.calls.map((c) => JSON.parse(c[0]));
    expect(sent.some((m) => m.type === "ping")).toBe(true);
    client.disconnect();
  });

  it("显式 disconnect → 不重连", () => {
    const client = new ChatWSClient();
    client.connect();
    vi.runOnlyPendingTimers();
    client.disconnect();
    instances[0]._close();
    vi.advanceTimersByTime(10_000);
    expect(instances).toHaveLength(1);
  });
});
