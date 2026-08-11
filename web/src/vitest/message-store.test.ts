/**
 * stores/message.ts 测试：
 * - 同 seq 重复投递去重（补发场景）
 * - 按 conversation_id 分桶互不污染
 * - 撤回/已读元事件
 * - 历史分页 before_seq 前插 + hasMore
 */
import { beforeEach, describe, expect, it } from "vitest";
import type { ChatMessage } from "../api/types";
import { useMessageStore } from "../stores/message";

function msg(
  id: string,
  seq: number,
  sender = "me",
  convId = "c1",
  content = `m${seq}`,
): ChatMessage {
  return {
    id,
    conversation_id: convId,
    sender_id: sender,
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
});

describe("message store", () => {
  it("同 seq 重复投递去重（补发场景）", () => {
    const s = useMessageStore.getState();
    s.upsertMessage("c1", msg("a", 1));
    s.upsertMessage("c1", msg("b", 2));
    // 补发重复投递 seq=2 的同一消息（同 seq 不同 id 也去重）
    s.upsertMessage("c1", msg("b2", 2));
    const b = useMessageStore.getState().buckets["c1"];
    expect(b.messages).toHaveLength(2);
    expect(b.messages.map((m) => m.seq)).toEqual([1, 2]);
  });

  it("按 conversation_id 分桶互不污染", () => {
    const s = useMessageStore.getState();
    s.upsertMessage("c1", msg("a", 1, "me", "c1"));
    s.upsertMessage("c2", msg("x", 5, "me", "c2"));
    s.upsertMessage("c1", msg("b", 2, "me", "c1"));
    const st = useMessageStore.getState();
    expect(st.buckets["c1"].messages.map((m) => m.seq)).toEqual([1, 2]);
    expect(st.buckets["c2"].messages.map((m) => m.seq)).toEqual([5]);
  });

  it("消息按 seq 升序排列（乱序插入也正确）", () => {
    const s = useMessageStore.getState();
    s.upsertMessage("c1", msg("a", 3));
    s.upsertMessage("c1", msg("b", 1));
    s.upsertMessage("c1", msg("c", 2));
    expect(useMessageStore.getState().buckets["c1"].messages.map((m) => m.seq)).toEqual([
      1, 2, 3,
    ]);
  });

  it("撤回：元事件只改状态，不新增消息", () => {
    const s = useMessageStore.getState();
    s.upsertMessage("c1", msg("a", 1));
    s.upsertMessage("c1", msg("b", 2));
    s.setRecalled("c1", "a");
    const b = useMessageStore.getState().buckets["c1"];
    expect(b.messages).toHaveLength(2);
    expect(b.messages.find((m) => m.id === "a")?.status).toBe("recalled");
  });

  it("已读：message.read 帧更新对端已读态（按消息 + 用户）", () => {
    const s = useMessageStore.getState();
    s.markReadByMessage("c1", "b", "peer1");
    expect(useMessageStore.getState().readMarks["c1"]?.["b"]).toEqual(["peer1"]);
    // 同一用户重复已读幂等
    s.markReadByMessage("c1", "b", "peer1");
    expect(useMessageStore.getState().readMarks["c1"]?.["b"]).toEqual(["peer1"]);
    // 不同用户各自记录
    s.markReadByMessage("c1", "b", "peer2");
    expect(useMessageStore.getState().readMarks["c1"]?.["b"]).toEqual(["peer1", "peer2"]);
  });

  it("历史分页：before_seq 前插 + hasMore", () => {
    const s = useMessageStore.getState();
    // 首次加载最新 50 条（假设 seq 51..100）
    const latest = Array.from({ length: 50 }, (_, i) => msg(`m${i + 51}`, i + 51));
    s.prependHistory("c1", latest, true); // 满 50 → 还有更早
    let b = useMessageStore.getState().buckets["c1"];
    expect(b.messages).toHaveLength(50);
    expect(b.hasMore).toBe(true);

    // 上拉加载 seq 1..50
    const earlier = Array.from({ length: 50 }, (_, i) => msg(`e${i + 1}`, i + 1));
    s.prependHistory("c1", earlier, false); // < limit → 到底
    b = useMessageStore.getState().buckets["c1"];
    expect(b.messages).toHaveLength(100);
    expect(b.messages[0].seq).toBe(1);
    expect(b.hasMore).toBe(false);
  });

  it("lastSeq 只增不减（补发基线）", () => {
    const s = useMessageStore.getState();
    s.upsertMessage("c1", msg("a", 3));
    s.upsertMessage("c1", msg("b", 1));
    s.setLastSeq("c1", 2); // 旧的 sync 不应把 lastSeq 拉低
    expect(useMessageStore.getState().buckets["c1"].lastSeq).toBe(3);
    s.setLastSeq("c1", 7);
    expect(useMessageStore.getState().buckets["c1"].lastSeq).toBe(7);
  });

  it("reset 清空所有桶", () => {
    const s = useMessageStore.getState();
    s.upsertMessage("c1", msg("a", 1));
    s.markReadByMessage("c1", "a", "p");
    s.reset();
    expect(useMessageStore.getState().buckets).toEqual({});
    expect(useMessageStore.getState().readMarks).toEqual({});
  });
});
