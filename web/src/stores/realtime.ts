/** 跨通道实时连接事实：只记录连接状态，不把失败伪装成空数据。 */
import { create } from "zustand";

export type RealtimeChannel = "chat" | "presence" | "voice" | "live";
export type RealtimeConnection = "connecting" | "online" | "offline" | "failed";

export interface RealtimeStatus {
  connection: RealtimeConnection;
  lastError: string | null;
  updatedAt: string;
}

interface RealtimeState {
  statuses: Record<RealtimeChannel, RealtimeStatus>;
  setStatus: (channel: RealtimeChannel, connection: RealtimeConnection, error?: string | null) => void;
  reset: () => void;
}

const now = () => new Date().toISOString();
const initial: Record<RealtimeChannel, RealtimeStatus> = {
  chat: { connection: "offline", lastError: null, updatedAt: now() },
  presence: { connection: "offline", lastError: null, updatedAt: now() },
  voice: { connection: "offline", lastError: null, updatedAt: now() },
  live: { connection: "offline", lastError: null, updatedAt: now() },
};

export const useRealtimeStore = create<RealtimeState>((set) => ({
  statuses: initial,
  setStatus: (channel, connection, lastError = null) =>
    set((state) => ({
      statuses: {
        ...state.statuses,
        [channel]: { connection, lastError, updatedAt: now() },
      },
    })),
  reset: () => set({ statuses: initial }),
}));
