/**
 * chat 全局状态：会话列表 + 未读数 + 当前会话（文档 §2 stores/chat.ts）。
 *
 * - conversations：会话列表（来自 GET /chat/conversations/）；
 * - activeConversationId：当前打开的会话；
 * - 未读数：来自会话列表 unread_count + 实时 message.new 增量（未打开会话 +1）；
 * - 打开会话时清空该会话未读。
 */
import { create } from "zustand";
import type { ConversationDetail, ConversationSummary } from "../api/types";

/** 归一：ConversationDetail（无 peer）→ ConversationSummary（peer 补 null） */
function toSummary(conv: ConversationSummary | ConversationDetail): ConversationSummary {
  return { ...conv, peer: (conv as ConversationSummary).peer ?? null };
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
  /** 从会话列表中移除（解散群/退出群/被移除时），若为当前会话一并置空 */
  removeConversation: (id: string) => void;
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
    // 并发预加载/页面加载拿到相同数据时不触发无意义重渲染；数据真的变化仍要替换，
    // 否则侧栏会永久保留旧群列表、未读数和头像。
    const same = current.length === conversations.length && current.every((item, index) => {
      const next = conversations[index];
      return item.id === next.id
        && item.title === next.title
        && item.avatar === next.avatar
        && item.unread_count === next.unread_count
        && item.member_count === next.member_count;
    });
    if (same && current.length > 0) {
      set({ loading: false, error: null, lastFetched: Date.now() });
      return;
    }
    set({ conversations, loading: false, error: null, lastFetched: Date.now() });
  },
  upsertConversation: (conv) =>
    set((state) => {
      const normalized = toSummary(conv);
      const exists = state.conversations.some((c) => c.id === normalized.id);
      const conversations = exists
        ? state.conversations.map((c) => (c.id === normalized.id ? normalized : c))
        : [normalized, ...state.conversations];
      return { conversations };
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
