import { describe, expect, it, vi } from "vitest";
import * as chatApi from "../api/chat";
import * as mediaApi from "../api/media";
import { sendOptimistic, retryOptimistic, removeOptimistic, cancelOptimistic, type PickedMediaItem } from "../hooks/useChat";
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

/** 纯文本 → blocks（M8 后 sendOptimistic 改收 blocks） */
function blocksOf(text: string): { type: "text"; text: string }[] {
  return text ? [{ type: "text", text }] : [];
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
    vi.spyOn(mediaApi, "uploadMediaFile").mockResolvedValue({ media_id: "media-1", descriptor: {} as never, upload_id: "u-1" });
    vi.stubGlobal("URL", { ...URL, revokeObjectURL: vi.fn(), createObjectURL: () => "blob:stub" });
  });

  it("sendOptimistic 立即插入 pending 消息（seq=0 恒置底，本地预览保留）", async () => {
    send.mockResolvedValue(serverMessage());
    sendOptimistic("c1", { blocks: blocksOf("看看"), picked: picked(2) });
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
    sendOptimistic("c1", { blocks: blocksOf("第二"), picked: [] });
    const order = useMessageStore.getState().buckets["c1"].messages.map((m) => (m.pending ? "pending" : m.seq));
    expect(order).toEqual([1, "pending", "pending"]);
  });

  it("上传+发送成功后原地替换为服务端消息（pending 消失、seq 生效）", async () => {
    send.mockResolvedValue(serverMessage());
    sendOptimistic("c1", { blocks: blocksOf("看看"), picked: picked(1) });
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
    sendOptimistic("c1", { blocks: blocksOf("失败消息"), picked: picked(1) });
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
    sendOptimistic("c1", { blocks: blocksOf("重试"), picked: picked(1) });
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
    sendOptimistic("c1", { blocks: blocksOf("并发"), picked: picked(1) });
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
    sendOptimistic("c1", { blocks: blocksOf("删除我"), picked: picked(2) });
    const p = useMessageStore.getState().buckets["c1"].messages[0];
    removeOptimistic("c1", p);
    expect(useMessageStore.getState().buckets["c1"].messages).toHaveLength(0);
    expect(revoke).toHaveBeenCalledTimes(2);
  });

  it("上传进度经 onProgress 聚合写入 store（uploadProgress 百分比）", async () => {
    let capture: ((p: { loaded: number; total: number }) => void) | undefined;
    vi.spyOn(mediaApi, "uploadMediaFile").mockImplementation((_f, _k, opts) => {
      capture = opts?.onProgress;
      return new Promise(() => {}); // 挂起，保持 pending
    });
    send.mockReturnValue(new Promise(() => {}));
    sendOptimistic("c1", { blocks: [], picked: picked(2) });
    await vi.waitFor(() => expect(capture).toBeTruthy());
    // 每个 File 真实大小 1 字节；第一个文件完成 → 聚合 1/2 = 50%
    capture!({ loaded: 1, total: 1 });
    const msgs = useMessageStore.getState().buckets["c1"].messages;
    expect(msgs[0].pending).toBe(true);
    expect(msgs[0].uploadProgress).toBe(50);
  });

  it("cancelOptimistic 中止上传（signal aborted）并删除气泡", async () => {
    const signalRef: { current?: AbortSignal } = {};
    vi.spyOn(mediaApi, "uploadMediaFile").mockImplementation((_f, _k, opts) => {
      signalRef.current = opts?.signal;
      return new Promise(() => {}); // 模拟传输中永不完成
    });
    const revoke = vi.fn();
    vi.stubGlobal("URL", { ...URL, createObjectURL: () => "blob:stub", revokeObjectURL: revoke });
    sendOptimistic("c1", { blocks: [], picked: picked(1) });
    const p = useMessageStore.getState().buckets["c1"].messages[0];
    cancelOptimistic("c1", p);
    expect(signalRef.current?.aborted).toBe(true);
    expect(useMessageStore.getState().buckets["c1"].messages).toHaveLength(0);
    expect(revoke).toHaveBeenCalledWith("blob:fake-0");
  });

  it("纯文本 + @（无媒体）→ mixed 契约：mention 段不进 content，payload 只带 user_id", async () => {
    send.mockResolvedValue(serverMessage({ type: "mixed" }));
    sendOptimistic("c1", {
      blocks: [
        { type: "text", text: "hi " },
        { type: "mention", user_id: "u2", name: "张三" },
        { type: "text", text: "看这个" },
      ],
      picked: [],
    });
    const p = useMessageStore.getState().buckets["c1"].messages[0];
    expect(p.type).toBe("mixed");
    expect(p.content).toBe("hi 看这个"); // mention 不进 content
    expect(p.segments).toEqual([
      { type: "text", text: "hi " },
      { type: "mention", user_id: "u2", name: "张三" }, // 乐观本地带 name 供渲染
      { type: "text", text: "看这个" },
    ]);
    await vi.waitFor(() => expect(send).toHaveBeenCalledTimes(1));
    const payload = send.mock.calls[0][1] as import("../api/types").CreateMessagePayload;
    expect(payload.type).toBe("mixed");
    expect(payload.segments).toEqual([
      { type: "text", text: "hi " },
      { type: "mention", user_id: "u2" }, // 发送 payload 只带 user_id（后端展开 user）
      { type: "text", text: "看这个" },
    ]);
  });

  it("@ + 媒体 → mixed：text/mention 段在前、媒体段追加尾部", async () => {
    send.mockResolvedValue(serverMessage());
    sendOptimistic("c1", {
      blocks: [
        { type: "text", text: "hi " },
        { type: "mention", user_id: "u2", name: "张三" },
      ],
      picked: picked(1),
    });
    await vi.waitFor(() => expect(send).toHaveBeenCalledTimes(1));
    const payload = send.mock.calls[0][1] as import("../api/types").CreateMessagePayload;
    expect(payload.segments).toEqual([
      { type: "text", text: "hi " },
      { type: "mention", user_id: "u2" },
      { type: "image", media_id: "media-1" },
    ]);
  });

  it("重试含 @ 的失败消息保留 mention 段", async () => {
    send.mockRejectedValueOnce(new Error("网络失败")).mockResolvedValueOnce(serverMessage());
    sendOptimistic("c1", {
      blocks: [
        { type: "text", text: "hi " },
        { type: "mention", user_id: "u2", name: "张三" },
      ],
      picked: [],
    });
    await vi.waitFor(() => {
      expect(useMessageStore.getState().buckets["c1"].messages[0].sendFailed).toBe(true);
    });
    const failed = useMessageStore.getState().buckets["c1"].messages[0];
    retryOptimistic("c1", failed);
    await vi.waitFor(() => {
      expect(useMessageStore.getState().buckets["c1"].messages[0].id).toBe("m-server");
    });
    const payload = send.mock.calls[1][1] as import("../api/types").CreateMessagePayload;
    expect(payload.segments).toEqual([
      { type: "text", text: "hi " },
      { type: "mention", user_id: "u2" },
    ]);
  });

  it("文件消息走 type=file 契约：content=文件名、上传后带 media_id、不构造 segments", async () => {
    send.mockResolvedValue(serverMessage({ type: "file", content: "报告.pdf" }));
    const fileItem: PickedMediaItem = {
      id: "f0",
      kind: "file",
      mimeType: "application/pdf",
      url: "",
      file: new File(["pdf"], "报告.pdf", { type: "application/pdf" }),
    };
    sendOptimistic("c1", { blocks: blocksOf(""), picked: [fileItem] });
    const p = useMessageStore.getState().buckets["c1"].messages[0];
    expect(p.type).toBe("file");
    expect(p.content).toBe("报告.pdf");
    expect(p.segments).toBeNull();
    expect(p.localMedia).toHaveLength(1);
    expect(p.localMedia![0].kind).toBe("file");

    await vi.waitFor(() => expect(send).toHaveBeenCalledTimes(1));
    const payload = send.mock.calls[0][1] as import("../api/types").CreateMessagePayload;
    expect(payload.type).toBe("file");
    expect(payload.content).toBe("报告.pdf");
    expect(payload.media_id).toBe("media-1");
    expect(payload.segments).toBeUndefined();
  });

  it("文件消息发送失败后 retryOptimistic 复用幂等键走 file 契约", async () => {
    send.mockRejectedValueOnce(new Error("fail")).mockResolvedValueOnce(serverMessage({ type: "file", content: "报告.pdf" }));
    const fileItem: PickedMediaItem = {
      id: "f0",
      kind: "file",
      mimeType: "application/pdf",
      url: "",
      file: new File(["pdf"], "报告.pdf", { type: "application/pdf" }),
    };
    sendOptimistic("c1", { blocks: blocksOf(""), picked: [fileItem] });
    await vi.waitFor(() => {
      expect(useMessageStore.getState().buckets["c1"].messages[0].sendFailed).toBe(true);
    });
    const failed = useMessageStore.getState().buckets["c1"].messages[0];
    retryOptimistic("c1", failed);
    await vi.waitFor(() => {
      expect(useMessageStore.getState().buckets["c1"].messages[0].id).toBe("m-server");
    });
    expect(send).toHaveBeenCalledTimes(2);
    const payload = send.mock.calls[1][1] as import("../api/types").CreateMessagePayload;
    expect(payload.type).toBe("file");
    expect(payload.content).toBe("报告.pdf");
    expect(payload.media_id).toBe("media-1");
    const k1 = (send.mock.calls[0][1] as { idempotency_key: string }).idempotency_key;
    const k2 = (send.mock.calls[1][1] as { idempotency_key: string }).idempotency_key;
    expect(k1).toBe(k2);
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

  it("segmentPreview 对 mention 段生成 @昵称 摘要（无 user 回退 name/未知用户）", () => {
    expect(
      segmentPreview([
        { type: "text", text: "hi " },
        { type: "mention", user_id: "u2", user: { nickname: "张三" } as never },
      ]),
    ).toBe("hi @张三");
    expect(
      segmentPreview([{ type: "mention", user_id: "u2", name: "李四" }]),
    ).toBe("@李四");
    expect(
      segmentPreview([{ type: "mention", user_id: "u2" }]),
    ).toBe("@未知用户");
  });
});
