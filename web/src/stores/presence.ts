/**
 * presence 全局状态：在线用户集合（连接状态）+ 状态模式映射 + 连接状态。
 * 由 ws/presence.ts 驱动更新：
 * - presence.update（online/offline）→ users（连接状态）；
 * - presence.status（auto/dnd/away/invisible）→ statuses（用户选择的模式，实时）。
 */
import { create } from "zustand";

export type PresenceStatus = "connecting" | "online" | "offline";

interface PresenceState {
  /** user_id -> 连接状态（presence.update 增量：online/offline） */
  users: Record<string, string>;
  /** user_id -> 状态模式（presence.status 增量：auto/dnd/away/invisible） */
  statuses: Record<string, string>;
  connection: PresenceStatus;

  setUser: (userId: string, status: string) => void;
  setUserStatus: (userId: string, status: string) => void;
  removeUser: (userId: string) => void;
  replaceAll: (users: Record<string, string>) => void;
  setConnection: (s: PresenceStatus) => void;
  reset: () => void;
}

export const usePresenceStore = create<PresenceState>((set) => ({
  users: {},
  statuses: {},
  connection: "offline",

  setUser: (userId, status) =>
    set((state) => ({ users: { ...state.users, [userId]: status } })),

  setUserStatus: (userId, status) =>
    set((state) => ({ statuses: { ...state.statuses, [userId]: status } })),

  removeUser: (userId) =>
    set((state) => {
      const users = { ...state.users };
      delete users[userId];
      return { users };
    }),

  replaceAll: (users) => set({ users }),

  setConnection: (connection) => set({ connection }),

  reset: () => set({ users: {}, statuses: {}, connection: "offline" }),
}));
