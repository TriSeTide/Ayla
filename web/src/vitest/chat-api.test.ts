/**
 * api/chat.ts 契约测试（mock fetch，文档 §7.1）：
 * - 幂等发送：同 key 重试返回原消息不重复；409 冲突提示
 * - 撤回：仅自己+窗口内（canRecall）；越权/超时错误
 * - 已读：标已读幂等
 * - 历史分页：before_seq 游标参数正确
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as chatApi from "../api/chat";
import { canRecall } from "../components/chat/MessageBubble";
import type { ChatMessage } from "../api/types";

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function msg(id: string, seq: number, sender = "me", createdAgoSec = 10): ChatMessage {
  return {
    id,
    conversation_id: "c1",
    sender_id: sender,
    type: "text",
    content: `内容${seq}`,
    media_id: null,
    reply_to: null,
    status: "sent",
    seq,
    created_at: new Date(Date.now() - createdAgoSec * 1000).toISOString(),
  };
}

beforeEach(() => {
  vi.restoreAllMocks();
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("api/chat 幂等发送", () => {
  it("sendMessage 带 idempotency_key；同 key 重试由服务端返回原消息（不重复）", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse(msg("m1", 1), 201))
      .mockResolvedValueOnce(jsonResponse(msg("m1", 1), 200)); // 幂等返回原消息
    vi.stubGlobal("fetch", fetchMock);
    // 需要 access token（client.ts 会带 Authorization）
    const { useAuthStore } = await import("../stores/auth");
    useAuthStore.setState({ accessToken: "acc" });

    const first = await chatApi.sendMessage("c1", { content: "你好", idempotency_key: "k-1" });
    const second = await chatApi.sendMessage("c1", { content: "你好", idempotency_key: "k-1" });
    expect(first.id).toBe("m1");
    expect(second.id).toBe("m1");
    // 请求体带 idempotency_key
    const bodies = fetchMock.mock.calls.map((c) => JSON.parse(c[1].body as string));
    expect(bodies[0].idempotency_key).toBe("k-1");
    expect(bodies[1].idempotency_key).toBe("k-1");
  });

  it("409 幂等冲突：抛 ApiError（detail 可见），不静默丢弃", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        jsonResponse({ detail: "idempotency_key 冲突：内容不一致" }, 409),
      ),
    );
    const { useAuthStore } = await import("../stores/auth");
    useAuthStore.setState({ accessToken: "acc" });
    await expect(
      chatApi.sendMessage("c1", { content: "x", idempotency_key: "k-x" }),
    ).rejects.toMatchObject({
      status: 409,
      message: expect.stringContaining("冲突"),
    });
  });
});

describe("撤回窗口判断", () => {
  it("仅自己 + 窗口内可撤回", () => {
    const mine = msg("a", 1, "me", 30); // 30s 内
    expect(canRecall(mine, "me")).toBe(true);
  });

  it("别人的消息不可撤回", () => {
    expect(canRecall(msg("a", 1, "peer", 10), "me")).toBe(false);
  });

  it("超时不可撤回", () => {
    expect(canRecall(msg("a", 1, "me", 300), "me")).toBe(false);
  });

  it("已撤回不可再撤", () => {
    const m = { ...msg("a", 1, "me", 10), status: "recalled" as const };
    expect(canRecall(m, "me")).toBe(false);
  });
});

describe("api/chat 已读/历史分页", () => {
  it("markMessageRead 幂等（POST 到 read 端点）", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValue(jsonResponse({ detail: "已读" }))
      .mockResolvedValueOnce(jsonResponse({ detail: "已读" }));
    vi.stubGlobal("fetch", fetchMock);
    const { useAuthStore } = await import("../stores/auth");
    useAuthStore.setState({ accessToken: "acc" });

    await chatApi.markMessageRead("c1", "m1");
    await chatApi.markMessageRead("c1", "m1");
    expect(fetchMock).toHaveBeenCalledTimes(2);
    // 路径正确
    expect(String(fetchMock.mock.calls[0][0])).toContain("/chat/conversations/c1/messages/m1/read/");
  });

  it("listMessages 带 before_seq 游标参数", async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse([]));
    vi.stubGlobal("fetch", fetchMock);
    const { useAuthStore } = await import("../stores/auth");
    useAuthStore.setState({ accessToken: "acc" });

    await chatApi.listMessages("c1", { before_seq: 10, limit: 50 });
    const url = String(fetchMock.mock.calls[0][0]);
    expect(url).toContain("/chat/conversations/c1/messages/");
    expect(url).toContain("before_seq=10");
    expect(url).toContain("limit=50");
  });

  it("recallMessage 越权/超时错误（403/400）向上抛", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(jsonResponse({ detail: "超过撤回时限" }, 400)),
    );
    const { useAuthStore } = await import("../stores/auth");
    useAuthStore.setState({ accessToken: "acc" });
    await expect(chatApi.recallMessage("c1", "m1")).rejects.toMatchObject({ status: 400 });
  });
});

describe("api/chat 会话创建端点", () => {
  it("createGroupConversation 走后端真实路由 /chat/conversations/group/（非 /conversations/）", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      jsonResponse({
        id: "g1", type: "group", title: "新群", announcement: "",
        owner_id: "o1", members: [], my_role: "owner", member_count: 1,
        unread_count: 0, created_at: new Date().toISOString(),
      }, 201),
    );
    vi.stubGlobal("fetch", fetchMock);
    const { useAuthStore } = await import("../stores/auth");
    useAuthStore.setState({ accessToken: "acc" });

    await chatApi.createGroupConversation({ title: "新群", member_ids: [] });

    const url = String(fetchMock.mock.calls[0][0]);
    expect(url).toContain("/chat/conversations/group/");
    expect(url).not.toContain("/chat/conversations/?");
    // 请求体：title + member_ids（可为空数组）
    const init = fetchMock.mock.calls[0][1];
    expect(init.method).toBe("POST");
    expect(JSON.parse(init.body)).toEqual({ title: "新群", member_ids: [] });
  });
});
