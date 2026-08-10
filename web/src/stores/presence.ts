/**
 * presence 全局状态：在线用户集合 + 连接状态。
 * 由 ws/presence.ts 驱动更新。
 */
import { create } from "zustand";

export type PresenceStatus = "connecting" | "online" | "offline";

interface PresenceState {
  /** user_id -> status（后端 presence.update 增量） */
  users: Record<string, string>;
  connection: PresenceStatus;

  setUser: (userId: string, status: string) => void;
  removeUser: (userId: string) => void;
  replaceAll: (users: Record<string, string>) => void;
  setConnection: (s: PresenceStatus) => void;
  reset: () => void;
}

export const usePresenceStore = create<PresenceState>((set) => ({
  users: {},
  connection: "offline",

  setUser: (userId, status) =>
    set((state) => ({ users: { ...state.users, [userId]: status } })),

  removeUser: (userId) =>
    set((state) => {
      const users = { ...state.users };
      delete users[userId];
      return { users };
    }),

  replaceAll: (users) => set({ users }),

  setConnection: (connection) => set({ connection }),

  reset: () => set({ users: {}, connection: "offline" }),
}));
