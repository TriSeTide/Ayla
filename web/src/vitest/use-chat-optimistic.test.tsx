import { describe, expect, it, vi } from "vitest";
import * as chatApi from "../api/chat";
import * as mediaApi from "../api/media";
import { sendOptimistic, retryOptimistic, removeOptimistic, type PickedMediaItem } from "../hooks/useChat";
import { useMessageStore } from "../stores/message";
import { segmentPreview, segmentText } from "../utils/segment";

vi.mock("../api/chat", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../api/chat")>();
  return { ...actual, sendMessage: vi.fn() };
});

const send = vi.mocked(chatApi.sendMessage);

function picked(n: number): PickedMediaItem[] {
  return Array.from({ length: n }, (_, i) => ({
    id: `p${i}`,
    kind: "image" as const,
    mimeType: "image/png",
    url: `blob:fake-${i}`,
    file: new File([`${i}`], `p${i}.png`, { type: "image/png" }),
  }));
}

function serverMessage(over: Partial<import("../api/types").ChatMessage> = {}) {
  return {
    id: "m-server",
    conversation_id: "c1",
    sender_id: "u1",
    type: "mixed",
    content: "文本",
    media_id: null,
    segments: [
      { type: "text", text: "文本" },
      { type: "image", media_id: "media-1", media: { media_id: "media-1" } as never },
    ],
    reply_to: null,
    status: "sent",
    seq: 5,
    created_at: new Date().toISOString(),
    ...over,
  } as import("../api/types").ChatMessage;
}

describe("useChat 乐观发送（M7 store 级）", () => {
  beforeEach(() => {
    useMessageStore.getState().reset();
    send.mockReset();
    vi.spyOn(mediaApi, "uploadMediaFile").mockResolvedValue({ media_id: "media-1", descriptor: {} as never });
    vi.stubGlobal("URL", { ...URL, revokeObjectURL: vi.fn(), createObjectURL: () => "blob:stub" });
  });

  it("sendOptimistic 立即插入 pending 消息（seq=0 恒置底，本地预览保留）", async () => {
    send.mockResolvedValue(serverMessage());
    sendOptimistic("c1", { text: "看看", picked: picked(2) });
    const bucket = useMessageStore.getState().buckets["c1"];
    expect(bucket).toBeDefined();
    const msgs = bucket.messages;
    expect(msgs).toHaveLength(1);
    const p = msgs[0];
    expect(p.pending).toBe(true);
    expect(p.type).toBe("mixed");
    expect(p.seq).toBe(0);
    expect(p.content).toBe("看看");
    expect(p.segments).toEqual([
      { type: "text", text: "看看" },
      { type: "image", media_id: "", media: null },
      { type: "image", media_id: "", media: null },
    ]);
    expect(p.localMedia).toHaveLength(2);
    // 与已有历史消息共存时 pending 置底
    useMessageStore.getState().upsertMessage("c1", serverMessage({ id: "old", seq: 1 }));
    sendOptimistic("c1", { text: "第二", picked: [] });
    const order = useMessageStore.getState().buckets["c1"].messages.map((m) => (m.pending ? "pending" : m.seq));
    expect(order).toEqual([1, "pending", "pending"]);
  });

  it("上传+发送成功后原地替换为服务端消息（pending 消失、seq 生效）", async () => {
    send.mockResolvedValue(serverMessage());
    sendOptimistic("c1", { text: "看看", picked: picked(1) });
    await vi.waitFor(() => {
      const msgs = useMessageStore.getState().buckets["c1"].messages;
      expect(msgs).toHaveLength(1);
      expect(msgs[0].pending).not.toBe(true);
      expect(msgs[0].id).toBe("m-server");
      expect(msgs[0].seq).toBe(5);
    });
    expect(send).toHaveBeenCalledTimes(1);
    const payload = send.mock.calls[0][1] as import("../api/types").CreateMessagePayload;
    expect(payload.type).toBe("mixed");
    expect(payload.segments).toEqual([
      { type: "text", text: "看看" },
      { type: "image", media_id: "media-1" },
    ]);
  });

  it("发送失败 → 消息保留并标记 sendFailed（可重试）", async () => {
    send.mockRejectedValueOnce(new Error("网络失败"));
    sendOptimistic("c1", { text: "失败消息", picked: picked(1) });
    await vi.waitFor(() => {
      const msgs = useMessageStore.getState().buckets["c1"].messages;
      expect(msgs).toHaveLength(1);
      expect(msgs[0].sendFailed).toBe(true);
      expect(msgs[0].pending).toBe(false);
      expect(msgs[0].localMedia).toHaveLength(1); // 本地预览保留供重试
    });
  });

  it("retryOptimistic 复用同一幂等键重新上传发送", async () => {
    send.mockRejectedValueOnce(new Error("网络失败")).mockResolvedValueOnce(serverMessage());
    sendOptimistic("c1", { text: "重试", picked: picked(1) });
    await vi.waitFor(() => {
      expect(useMessageStore.getState().buckets["c1"].messages[0].sendFailed).toBe(true);
    });
    const failed = useMessageStore.getState().buckets["c1"].messages[0];
    retryOptimistic("c1", failed);
    await vi.waitFor(() => {
      const msgs = useMessageStore.getState().buckets["c1"].messages;
      expect(msgs).toHaveLength(1);
      expect(msgs[0].id).toBe("m-server");
    });
    expect(send).toHaveBeenCalledTimes(2);
    const key1 = (send.mock.calls[0][1] as { idempotency_key: string }).idempotency_key;
    const key2 = (send.mock.calls[1][1] as { idempotency_key: string }).idempotency_key;
    expect(key1).toBe(key2);
  });

  it("WS 帧先到时（服务端消息已在列表）resolvePending 收敛为一条，不重复", async () => {
    send.mockResolvedValue(serverMessage());
    sendOptimistic("c1", { text: "并发", picked: picked(1) });
    const pendingMsg = useMessageStore.getState().buckets["c1"].messages.find((m) => m.pending) as import("../api/types").ChatMessage;
    const key = pendingMsg.idempotencyKey as string;
    // 模拟 WS 先插入服务端消息（本地 pending 还在，seq=5 与 pending seq=0 并存）
    useMessageStore.getState().upsertMessage("c1", serverMessage());
    expect(useMessageStore.getState().buckets["c1"].messages).toHaveLength(2);
    // 发送完成回包 → 收敛为一条服务端消息（WS 版或回包版），pending 消失
    await vi.waitFor(() => {
      const msgs = useMessageStore.getState().buckets["c1"].messages;
      expect(msgs).toHaveLength(1);
      expect(msgs[0].pending).not.toBe(true);
      expect(msgs[0].id).toBe("m-server");
    });
    const after = useMessageStore.getState().buckets["c1"].messages[0];
    expect(after.idempotencyKey).not.toBe(key);
  });

  it("removeOptimistic 删除消息并释放本地预览 URL", async () => {
    const revoke = vi.fn();
    vi.stubGlobal("URL", { ...URL, revokeObjectURL: revoke });
    sendOptimistic("c1", { text: "删除我", picked: picked(2) });
    const p = useMessageStore.getState().buckets["c1"].messages[0];
    removeOptimistic("c1", p);
    expect(useMessageStore.getState().buckets["c1"].messages).toHaveLength(0);
    expect(revoke).toHaveBeenCalledTimes(2);
  });
});

describe("segment 预览工具", () => {
  it("混排段生成「文本文本[视频]文本[图片]」形态摘要", () => {
    expect(
      segmentPreview([
        { type: "text", text: "文本文本" },
        { type: "video", media_id: "v", media: null },
        { type: "text", text: "文本" },
        { type: "image", media_id: "i", media: null },
        { type: "text", text: "文本文本" },
        { type: "image", media_id: "i2", media: null },
      ]),
    ).toBe("文本文本[视频]文本[图片]文本文本[图片]");
    expect(segmentPreview(null)).toBeNull();
    expect(segmentPreview([])).toBeNull();
  });

  it("segmentText 只取文本段拼接", () => {
    expect(
      segmentText([
        { type: "text", text: "A" },
        { type: "image", media_id: "i", media: null },
        { type: "text", text: "B" },
      ]),
    ).toBe("AB");
  });
});
