import { create } from "zustand";

interface ChatDraftState {
  drafts: Record<string, string>;
  getDraft: (conversationId: string) => string;
  setDraft: (conversationId: string, content: string) => void;
  clearDraft: (conversationId: string) => void;
  reset: () => void;
}

export const useChatDraftsStore = create<ChatDraftState>((set, get) => ({
  drafts: {},
  getDraft: (conversationId) => get().drafts[conversationId] ?? "",
  setDraft: (conversationId, content) =>
    set((state) => ({ drafts: { ...state.drafts, [conversationId]: content } })),
  clearDraft: (conversationId) =>
    set((state) => {
      if (!(conversationId in state.drafts)) return state;
      const drafts = { ...state.drafts };
      delete drafts[conversationId];
      return { drafts };
    }),
  reset: () => set({ drafts: {} }),
}));
