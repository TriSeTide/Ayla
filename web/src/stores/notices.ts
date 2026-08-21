import { create } from "zustand";

export type RealtimeNoticeKind = "group.request.new" | "group.request.resolved" | "group.invite.new" | "group.member.left" | "friend.request.new" | "friend.request.resolved";

export interface RealtimeNotice {
  id: string;
  kind: RealtimeNoticeKind;
  title: string;
  detail: string;
  createdAt: number;
}

interface NoticeState {
  notices: RealtimeNotice[];
  push: (notice: Omit<RealtimeNotice, "id" | "createdAt">) => void;
  dismiss: (id: string) => void;
  clear: () => void;
}

let sequence = 0;

export const useNoticeStore = create<NoticeState>((set) => ({
  notices: [],
  push: (notice) => set((state) => ({
    notices: [...state.notices, { ...notice, id: `notice-${Date.now()}-${sequence++}`, createdAt: Date.now() }].slice(-4),
  })),
  dismiss: (id) => set((state) => ({ notices: state.notices.filter((item) => item.id !== id) })),
  clear: () => set({ notices: [] }),
}));
