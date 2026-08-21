/**
 * chat 全局状态：会话列表 + 未读数 + 当前会话（文档 §2 stores/chat.ts）。
 *
 * - conversations：会话列表（来自 GET /chat/conversations/）；
 * - activeConversationId：当前打开的会话；
 * - 未读数：来自会话列表 unread_count + 实时 message.new 增量（未打开会话 +1）；
 * - 打开会话时清空该会话未读。
 */
import { create } from "zustand";
import type {
  ConversationDetail,
  ConversationSummary,
  LastMessagePreview,
} from "../api/types";

/** 归一：ConversationDetail（无 peer）→ ConversationSummary（peer 补 null）
 *  并给 is_pinned/last_message 补默认值（兼容旧后端/旧缓存数据）。 */
function toSummary(conv: ConversationSummary | ConversationDetail): ConversationSummary {
  return {
    ...conv,
    peer: (conv as ConversationSummary).peer ?? null,
    is_pinned: (conv as ConversationSummary).is_pinned ?? false,
    last_message: (conv as ConversationSummary).last_message ?? null,
  };
}

/** 会话排序：置顶优先，置顶组/非置顶组内保持传入顺序（稳定）。 */
function sortConversations(list: ConversationSummary[]): ConversationSummary[] {
  const pinned = list.filter((c) => c.is_pinned);
  const unpinned = list.filter((c) => !c.is_pinned);
  return [...pinned, ...unpinned];
}

interface ChatState {
  conversations: ConversationSummary[];
  loading: boolean;
  error: string | null;
  activeConversationId: string | null;
  lastFetched: number | null;

  setConversations: (list: ConversationSummary[]) => void;
  upsertConversation: (conv: ConversationSummary | ConversationDetail) => void;
  setLoading: (loading: boolean) => void;
  setError: (err: string | null) => void;
  openConversation: (id: string) => void;
  closeConversation: () => void;
  /** 从会话列表中移除（解散群/退出群/被移除/隐藏删除时），若为当前会话一并置空 */
  removeConversation: (id: string) => void;
  /** 置顶/取消置顶（本人视图），置顶会话排到列表最前 */
  setPin: (convId: string, pinned: boolean) => void;
  /** 更新会话最新一条消息预览（WS message.new 到达时）表达式 */
  setLastMessage: (convId: string, preview: LastMessagePreview) => void;
  /** 收到未打开会话的 message.new → 未读数 +1（打开则置 0） */
  bumpUnread: (convId: string) => void;
  clearUnread: (convId: string) => void;
  reset: () => void;
}

export const useChatStore = create<ChatState>((set, get) => ({
  conversations: [],
  loading: false,
  error: null,
  activeConversationId: null,
  lastFetched: null,

  setConversations: (conversations) => {
    const { conversations: current } = get();
    const sorted = sortConversations(conversations);
    // 并发预加载/页面加载拿到相同数据时不触发无意义重渲染；数据真的变化仍要替换，
    // 否则侧栏会永久保留旧群列表、未读数和头像。
    const same = current.length === sorted.length && current.every((item, index) => {
      const next = sorted[index];
      return item.id === next.id
        && item.title === next.title
        && item.avatar === next.avatar
        && item.unread_count === next.unread_count
        && item.member_count === next.member_count
        && item.is_pinned === next.is_pinned
        && (item.last_message?.seq ?? null) === (next.last_message?.seq ?? null)
        && (item.last_message?.content ?? null) === (next.last_message?.content ?? null);
    });
    if (same && current.length > 0) {
      set({ loading: false, error: null, lastFetched: Date.now() });
      return;
    }
    set({ conversations: sorted, loading: false, error: null, lastFetched: Date.now() });
  },
  upsertConversation: (conv) =>
    set((state) => {
      const normalized = toSummary(conv);
      const exists = state.conversations.some((c) => c.id === normalized.id);
      const conversations = exists
        ? state.conversations.map((c) => (c.id === normalized.id ? { ...c, ...normalized } : c))
        : [normalized, ...state.conversations];
      return { conversations: sortConversations(conversations) };
    }),
  setLoading: (loading) => set({ loading }),
  setError: (error) => set({ error }),

  openConversation: (id) => {
    // 仅记录当前会话；未读必须在服务端已读确认成功后由 clearUnread 清除。
    set({ activeConversationId: id });
  },
  closeConversation: () => set({ activeConversationId: null }),
  removeConversation: (id) =>
    set((state) => ({
      conversations: state.conversations.filter((c) => c.id !== id),
      activeConversationId: state.activeConversationId === id ? null : state.activeConversationId,
    })),

  setPin: (convId, pinned) =>
    set((state) => ({
      conversations: sortConversations(
        state.conversations.map((c) =>
          c.id === convId ? { ...c, is_pinned: pinned } : c,
        ),
      ),
    })),

  setLastMessage: (convId, preview) =>
    set((state) => ({
      conversations: state.conversations.map((c) =>
        c.id === convId ? { ...c, last_message: preview } : c,
      ),
    })),

  bumpUnread: (convId) =>
    set((state) => {
      if (state.activeConversationId === convId) return state;
      return {
        conversations: state.conversations.map((c) =>
          c.id === convId ? { ...c, unread_count: c.unread_count + 1 } : c,
        ),
      };
    }),

  clearUnread: (convId) =>
    set((state) => ({
      conversations: state.conversations.map((c) =>
        c.id === convId ? { ...c, unread_count: 0 } : c,
      ),
    })),

  reset: () =>
    set({ conversations: [], loading: false, error: null, activeConversationId: null, lastFetched: null }),
}));

/** 判断 chat store 数据是否过期（默认 60 秒） */
export function isChatStale(maxAgeMs = 60_000): boolean {
  const { lastFetched } = useChatStore.getState();
  if (!lastFetched) return true;
  return Date.now() - lastFetched > maxAgeMs;
}
