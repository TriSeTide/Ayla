/**
 * U16 历史分页参数契约：初始 20 条、继续上拉 50 条。
 * - 断言 loadHistory 首批请求 limit=20；
 * - 断言 loadMoreHistory 以全量缓存最小 seq 为 before_seq、limit=50。
 * 后端 before_seq 游标契约不变，仅前端页大小收敛到 20/50 常量。
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import * as chatApi from "../api/chat";
import type { ChatMessage } from "../api/types";
import { loadHistory, loadMoreHistory } from "../hooks/useChat";
import { useMessageStore } from "../stores/message";

vi.mock("../api/chat", () => ({
  listMessages: vi.fn(),
}));

const listMessages = vi.mocked(chatApi.listMessages);

function message(id: string, seq: number, content = `m${seq}`): ChatMessage {
  return {
    id,
    conversation_id: "c1",
    sender_id: "me",
    type: "text",
    content,
    media_id: null,
    reply_to: null,
    status: "sent",
    seq,
    created_at: new Date().toISOString(),
  };
}

beforeEach(() => {
  useMessageStore.getState().reset();
  listMessages.mockReset();
});

describe("useChat 历史分页（U16）", () => {
  it("loadHistory 首批请求 limit=INITIAL_HISTORY_LIMIT(20)", async () => {
    const latest = Array.from({ length: 20 }, (_, i) => message(`m${i + 481}`, i + 481));
    listMessages.mockResolvedValue(latest);

    await loadHistory("c1", undefined, true);

    expect(listMessages).toHaveBeenCalledWith("c1", { before_seq: undefined, limit: 20 });
    const bucket = useMessageStore.getState().buckets["c1"];
    expect(bucket.messages).toHaveLength(20);
    expect(bucket.hasMore).toBe(true); // 满 20 条 → 还有更早
  });

  it("首批恰好不足一页时 hasMore=false（不假报还有更早）", async () => {
    const small = Array.from({ length: 3 }, (_, i) => message(`m${i + 1}`, i + 1));
    listMessages.mockResolvedValue(small);

    await loadHistory("c1", undefined, true);

    const bucket = useMessageStore.getState().buckets["c1"];
    expect(bucket.messages).toHaveLength(3);
    expect(bucket.hasMore).toBe(false);
  });

  it("loadMoreHistory 以缓存最小 seq 为 before_seq、limit=HISTORY_PAGE_LIMIT(50)", async () => {
    // 先载入 20 条最新历史（481..500）
    const latest = Array.from({ length: 20 }, (_, i) => message(`m${i + 481}`, i + 481));
    listMessages.mockResolvedValue(latest);
    await loadHistory("c1", undefined, true);
    listMessages.mockClear();

    // 上拉一页 50 条更早（431..480）
    const earlier = Array.from({ length: 50 }, (_, i) => message(`e${i + 431}`, i + 431));
    listMessages.mockResolvedValue(earlier);

    await loadMoreHistory("c1");

    expect(listMessages).toHaveBeenCalledWith("c1", { before_seq: 481, limit: 50 });
    const bucket = useMessageStore.getState().buckets["c1"];
    expect(bucket.messages).toHaveLength(70);
    expect(bucket.messages[0].seq).toBe(431);
    expect(bucket.hasMore).toBe(true); // 满 50 → 还有更早
  });
});