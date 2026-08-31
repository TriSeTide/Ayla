/**
 * ws/chat.ts message.poke 帧契约测试（任务 01 戳一戳）：
 * - poke 消息进会话消息流（type=poke，content=目标用户 id）；
 * - 列表预览 = 「发送者戳了戳目标」；
 * - 私信 bump conversationActivityAt（往前排）；群 bump groupActivityAt；
 * - 刻意不 bumpUnread、不拉 badges、不弹红点。
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ChatWSClient } from "../ws/chat";
import { useAuthStore } from "../stores/auth";
import { useChatStore } from "../stores/chat";
import { useMessageStore } from "../stores/message";
import { useBadgesStore } from "../stores/badges";
import * as accountsApi from "../api/accounts";

vi.mock("../api/accounts", () => ({
  getBadges: vi.fn().mockResolvedValue({}),
}));

type WSInstance = {
  readyState: number;
  send: ReturnType<typeof vi.fn>;
  close: ReturnType<typeof vi.fn>;
  _open: () => void;
  _message: (data: string) => void;
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
  send = vi.fn();
  close = vi.fn();

  _open = () => {
    this.readyState = MockWebSocket.OPEN;
    this.onopen?.();
  };
  _message = (data: string) => this.onmessage?.({ data });

  constructor(_url: string) {
    const self = this as unknown as WSInstance;
    instances.push(self);
    setTimeout(() => self._open(), 0);
  }
}

function fire(instance: WSInstance, data: unknown) {
  instance._message(JSON.stringify(data));
}

function baseConversation(id: string, type: "private" | "group") {
  return {
    id,
    type,
    title: type === "group" ? "测试群" : "小乙",
    announcement: "",
    avatar: "",
    owner_id: "me",
    members: [],
    my_role: "member" as const,
    member_count: 2,
    unread_count: 0,
    created_at: "2026-08-21T00:00:00Z",
    peer: type === "private" ? { id: "peer1", nickname: "小乙" } : null,
  };
}

function pokeFrame(overrides: Record<string, unknown> = {}) {
  return {
    type: "message.poke",
    data: {
      conversation_id: "c1",
      message_id: "poke1",
      sender_id: "peer1",
      sender_name: "小乙",
      target_user_id: "me",
      target_name: "我",
      seq: 5,
      ts: "2026-08-21T00:00:05Z",
      ...overrides,
    },
  };
}

beforeEach(() => {
  instances = [];
  vi.stubGlobal("WebSocket", MockWebSocket);
  vi.useFakeTimers();
  useAuthStore.setState({ accessToken: "acc", refreshToken: "ref", currentUser: { id: "me" } as never });
  useChatStore.getState().reset();
  useMessageStore.getState().reset();
  useBadgesStore.getState().reset();
  vi.mocked(accountsApi.getBadges).mockClear();
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  useAuthStore.setState({ accessToken: null, refreshToken: null, currentUser: null });
  useChatStore.getState().reset();
  useMessageStore.getState().reset();
  useBadgesStore.getState().reset();
});

describe("ChatWSClient message.poke", () => {
  it("私信：poke 进消息流 + 预览「小乙戳了戳我」+ 活跃置顶，不 bumpUnread、不拉 badges", () => {
    useChatStore.getState().setConversations([baseConversation("c1", "private") as never]);
    const client = new ChatWSClient();
    client.connect();
    vi.advanceTimersByTime(10);
    const ws = instances[0];

    fire(ws, pokeFrame());

    const msg = useMessageStore.getState().buckets["c1"]?.messages[0];
    expect(msg?.type).toBe("poke");
    expect(msg?.content).toBe("me");
    expect(msg?.seq).toBe(5);

    const conv = useChatStore.getState().conversations[0];
    expect(conv.last_message?.preview).toBe("小乙戳了戳我");
    expect(conv.unread_count).toBe(0); // 不 bumpUnread

    // 私信活跃置顶时间戳被 bump（单调）
    expect(useChatStore.getState().conversationActivityAt["c1"]).toBeGreaterThan(0);
    // 群活跃时间戳不被误 bump
    expect(useChatStore.getState().groupActivityAt["c1"]).toBeUndefined();
    // 不拉 badges（无红点刷新）
    expect(accountsApi.getBadges).not.toHaveBeenCalled();

    client.disconnect();
  });

  it("群聊：poke 只 bump groupActivityAt，不 bump 私信活跃", () => {
    useChatStore.getState().setConversations([baseConversation("g1", "group") as never]);
    const client = new ChatWSClient();
    client.connect();
    vi.advanceTimersByTime(10);
    const ws = instances[0];

    fire(ws, pokeFrame({ conversation_id: "g1", sender_name: "群友B", target_user_id: "me", target_name: "我" }));

    const conv = useChatStore.getState().conversations[0];
    expect(conv.last_message?.preview).toBe("群友B戳了戳我");
    expect(conv.unread_count).toBe(0);
    expect(useChatStore.getState().groupActivityAt["g1"]).toBeGreaterThan(0);
    expect(useChatStore.getState().conversationActivityAt["g1"]).toBeUndefined();

    client.disconnect();
  });

  it("重复同 seq poke 帧幂等（message store 按 seq 去重）", () => {
    useChatStore.getState().setConversations([baseConversation("c1", "private") as never]);
    const client = new ChatWSClient();
    client.connect();
    vi.advanceTimersByTime(10);
    const ws = instances[0];

    fire(ws, pokeFrame());
    fire(ws, pokeFrame());

    const bucket = useMessageStore.getState().buckets["c1"];
    expect(bucket?.messages.filter((m) => m.seq === 5)).toHaveLength(1);

    client.disconnect();
  });
});
