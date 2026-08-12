/**
 * message 全局状态：按 conversation_id 分桶，seq 有序（文档 §4.1）。
 *
 * - upsertMessage(convId, msg)：按 seq 去重（服务端补发/重连可能重复投递，重复则忽略）；
 * - 撤回/已读是"元事件"：只改对应消息 status/已读态，不新增消息；
 * - history.sync 只作为补发完成信号，不改变消息集合；
 * - 历史分页用 before_seq 前插。
 */
import { create } from "zustand";
import type { ChatMessage, MediaDescriptor } from "../api/types";

export interface MessageBucket {
  /** 按 seq 升序 */
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
  setRecalled: (convId: string, messageId: string) => void;
  markReadByMessage: (convId: string, messageId: string, userId: string) => void;
  prependHistory: (convId: string, msgs: ChatMessage[], hasMore: boolean) => void;
  openBucket: (convId: string) => void;
  setLoading: (convId: string, loading: boolean) => void;
  setLastSeq: (convId: string, lastSeq: number) => void;
  reset: () => void;
}

/** 会话内消息按 seq 升序插入（去重：同 seq 忽略） */
function insertBySeq(list: ChatMessage[], msg: ChatMessage): ChatMessage[] {
  if (list.some((m) => m.seq === msg.seq)) return list;
  const next = [...list, msg].sort((a, b) => a.seq - b.seq);
  return next;
}

export const useMessageStore = create<MessageState>((set) => ({
  buckets: {},
  readMarks: {},

  upsertMessage: (convId, msg) =>
    set((state) => {
      const bucket = state.buckets[convId] ?? {
        messages: [],
        lastSeq: 0,
        hasMore: false,
        loading: false,
      };
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
