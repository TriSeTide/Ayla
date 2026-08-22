/**
 * message 全局状态：按 conversation_id 分桶，seq 有序（文档 §4.1）。
 *
 * - upsertMessage(convId, msg)：按 seq 去重（服务端补发/重连可能重复投递，重复则忽略）；
 * - 撤回/已读是"元事件"：只改对应消息 status/已读态，不新增消息；
 * - history.sync 只作为补发完成信号，不改变消息集合；
 * - 历史分页用 before_seq 前插。
 *
 * 乐观发送（M7）：addPendingMessage 插入 pending 消息（seq=0，排序恒置底、
 * 不参与 seq 去重），发送成功后 resolvePendingMessage 原地替换为服务端消息；
 * WS 帧先到时按幂等键清理本地 pending，避免同一消息出现两次。
 */
import { create } from "zustand";
import type { ChatMessage, MediaDescriptor } from "../api/types";

export interface MessageBucket {
  /** 按 seq 升序（pending 乐观消息恒置底） */
  messages: ChatMessage[];
  /** 已收到的最新 seq */
  lastSeq: number;
  /** 还有更早历史（返回条数 < limit 置 false） */
  hasMore: boolean;
  loading: boolean;
}

interface MessageState {
  /** conversation_id -> bucket */
  buckets: Record<string, MessageBucket>;
  /** 已读标记：conversation_id -> 已读到的 message_id（对端已读状态用） */
  readMarks: Record<string, Record<string, string[]>>;

  upsertMessage: (convId: string, msg: ChatMessage) => void;
  /** M5-2.1：WS 消息只带 media_id 时，异步补拉 descriptor 后合并进消息 */
  mergeMedia: (convId: string, messageId: string, media: MediaDescriptor) => void;
  /** 乐观发送：插入本地 pending 消息（seq=0 恒置底；按 id/幂等键去重） */
  addPendingMessage: (convId: string, msg: ChatMessage) => void;
  /** 乐观发送成功：localId 存在则原地替换为服务端消息；否则按幂等键清掉本地 pending */
  resolvePendingMessage: (
    convId: string,
    localId: string,
    idempotencyKey: string,
    serverMsg: ChatMessage,
  ) => void;
  /** 乐观发送失败：消息保留，标记失败态（气泡左上角可重试/删除） */
  markMessageFailed: (convId: string, messageId: string) => void;
  /** 删除消息（乐观失败丢弃/本地清理） */
  removeMessage: (convId: string, messageId: string) => void;
  setRecalled: (convId: string, messageId: string) => void;
  markReadByMessage: (convId: string, messageId: string, userId: string) => void;
  prependHistory: (convId: string, msgs: ChatMessage[], hasMore: boolean) => void;
  openBucket: (convId: string) => void;
  setLoading: (convId: string, loading: boolean) => void;
  setLastSeq: (convId: string, lastSeq: number) => void;
  reset: () => void;
}

function defaultBucket(): MessageBucket {
  return { messages: [], lastSeq: 0, hasMore: false, loading: false };
}

/** 排序：非 pending 按 seq 升序；pending 恒置底（彼此保持插入序，sort 稳定） */
function sortMessages(list: ChatMessage[]): ChatMessage[] {
  return [...list].sort((a, b) => {
    if (a.pending !== b.pending) return a.pending ? 1 : -1;
    return a.seq - b.seq;
  });
}

/** 会话内消息按 seq 升序插入（去重：同 seq 忽略；pending 消息不参与去重） */
function insertBySeq(list: ChatMessage[], msg: ChatMessage): ChatMessage[] {
  if (!msg.pending && list.some((m) => m.seq === msg.seq)) return list;
  return sortMessages([...list, msg]);
}

export const useMessageStore = create<MessageState>((set) => ({
  buckets: {},
  readMarks: {},

  upsertMessage: (convId, msg) =>
    set((state) => {
      const bucket = state.buckets[convId] ?? defaultBucket();
      return {
        buckets: {
          ...state.buckets,
          [convId]: {
            ...bucket,
            messages: insertBySeq(bucket.messages, msg),
            lastSeq: Math.max(bucket.lastSeq, msg.seq),
          },
        },
      };
    }),

  addPendingMessage: (convId, msg) =>
    set((state) => {
      const bucket = state.buckets[convId] ?? defaultBucket();
      // 幂等：同 id 或同幂等键的 pending 已存在则忽略（防连点/重入）
      const exists = bucket.messages.some(
        (m) =>
          (m.pending && m.id === msg.id) ||
          (m.pending && msg.idempotencyKey != null && m.idempotencyKey === msg.idempotencyKey),
      );
      if (exists) return state;
      return {
        buckets: {
          ...state.buckets,
          [convId]: {
            ...bucket,
            messages: sortMessages([...bucket.messages, msg]),
          },
        },
      };
    }),

  resolvePendingMessage: (convId, localId, idempotencyKey, serverMsg) =>
    set((state) => {
      const bucket = state.buckets[convId];
      if (!bucket) return state;
      const local = bucket.messages.find((m) => m.pending && m.id === localId);
      // 收敛到一条服务端消息：
      // - 同 seq 的 WS 版（message.new 广播已插入）删除；
      // - 同幂等键的本地 pending 删除（含本次乐观消息）；
      // 之后 local 存在则补入服务端回包（原地替换），否则 WS 版已代表该消息。
      const filtered = bucket.messages.filter((m) => {
        if (!m.pending && m.seq === serverMsg.seq) return false;
        if (m.pending && m.idempotencyKey === idempotencyKey) return false;
        return true;
      });
      return {
        buckets: {
          ...state.buckets,
          [convId]: {
            ...bucket,
            messages: local
              ? sortMessages([...filtered, serverMsg])
              : sortMessages(filtered),
            lastSeq: Math.max(bucket.lastSeq, serverMsg.seq),
          },
        },
      };
    }),

  markMessageFailed: (convId, messageId) =>
    set((state) => {
      const bucket = state.buckets[convId];
      if (!bucket) return state;
      return {
        buckets: {
          ...state.buckets,
          [convId]: {
            ...bucket,
            messages: bucket.messages.map((m) =>
              m.id === messageId ? { ...m, pending: false, sendFailed: true } : m,
            ),
          },
        },
      };
    }),

  removeMessage: (convId, messageId) =>
    set((state) => {
      const bucket = state.buckets[convId];
      if (!bucket) return state;
      return {
        buckets: {
          ...state.buckets,
          [convId]: { ...bucket, messages: bucket.messages.filter((m) => m.id !== messageId) },
        },
      };
    }),

  mergeMedia: (convId, messageId, media) =>
    set((state) => {
      const bucket = state.buckets[convId];
      if (!bucket) return state;
      return {
        buckets: {
          ...state.buckets,
          [convId]: {
            ...bucket,
            messages: bucket.messages.map((m) =>
              m.id === messageId ? { ...m, media } : m,
            ),
          },
        },
      };
    }),

  setRecalled: (convId, messageId) =>
    set((state) => {
      const bucket = state.buckets[convId];
      if (!bucket) return state;
      return {
        buckets: {
          ...state.buckets,
          [convId]: {
            ...bucket,
            messages: bucket.messages.map((m) =>
              m.id === messageId ? { ...m, status: "recalled" as const } : m,
            ),
          },
        },
      };
    }),

  markReadByMessage: (convId, messageId, userId) =>
    set((state) => {
      const convMarks = state.readMarks[convId] ?? {};
      const users = convMarks[messageId] ?? [];
      if (users.includes(userId)) return state;
      return {
        readMarks: {
          ...state.readMarks,
          [convId]: { ...convMarks, [messageId]: [...users, userId] },
        },
      };
    }),

  prependHistory: (convId, msgs, hasMore) =>
    set((state) => {
      const bucket = state.buckets[convId] ?? {
        messages: [],
        lastSeq: 0,
        hasMore: false,
        loading: false,
      };
      let merged = bucket.messages;
      for (const m of msgs) merged = insertBySeq(merged, m);
      return {
        buckets: {
          ...state.buckets,
          [convId]: {
            ...bucket,
            messages: merged,
            hasMore,
            lastSeq: Math.max(bucket.lastSeq, ...msgs.map((m) => m.seq), 0),
          },
        },
      };
    }),

  openBucket: (convId) =>
    set((state) => {
      if (state.buckets[convId]) return state;
      return {
        buckets: {
          ...state.buckets,
          [convId]: {
            messages: [],
            lastSeq: 0,
            hasMore: true,
            loading: false,
          },
        },
      };
    }),

  setLoading: (convId, loading) =>
    set((state) => {
      const bucket = state.buckets[convId];
      if (!bucket) return state;
      return {
        buckets: {
          ...state.buckets,
          [convId]: { ...bucket, loading },
        },
      };
    }),

  setLastSeq: (convId, lastSeq) =>
    set((state) => {
      const bucket = state.buckets[convId];
      if (!bucket) return state;
      return {
        buckets: {
          ...state.buckets,
          [convId]: { ...bucket, lastSeq: Math.max(bucket.lastSeq, lastSeq) },
        },
      };
    }),

  reset: () => set({ buckets: {}, readMarks: {} }),
}));
