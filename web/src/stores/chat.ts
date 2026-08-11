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

  setConversations: (list: ConversationSummary[]) => void;
  upsertConversation: (conv: ConversationSummary | ConversationDetail) => void;
  setLoading: (loading: boolean) => void;
  setError: (err: string | null) => void;
  openConversation: (id: string) => void;
  closeConversation: () => void;
  /** 收到未打开会话的 message.new → 未读数 +1（打开则置 0） */
  bumpUnread: (convId: string) => void;
  clearUnread: (convId: string) => void;
  reset: () => void;
}

export const useChatStore = create<ChatState>((set) => ({
  conversations: [],
  loading: false,
  error: null,
  activeConversationId: null,

  setConversations: (conversations) => set({ conversations, loading: false, error: null }),
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
    set((state) => ({
      activeConversationId: id,
      // 打开即清未读
      conversations: state.conversations.map((c) =>
        c.id === id ? { ...c, unread_count: 0 } : c,
      ),
    }));
  },
  closeConversation: () => set({ activeConversationId: null }),

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
    set({ conversations: [], loading: false, error: null, activeConversationId: null }),
}));
