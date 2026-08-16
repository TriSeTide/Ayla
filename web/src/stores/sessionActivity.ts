/**
 * 跨页面活动态：媒体连接的导航投影（规划 P0-1）。
 *
 * 这里只保存可恢复的会话身份与连接状态，不复制成员、消息或媒体凭据；
 * 具体媒体资源仍由 voice/live 各自的 owner 管理。
 */
import { create } from "zustand";

export type ActivityStatus = "idle" | "connecting" | "connected" | "reconnecting" | "leaving" | "ended" | "failed";
export type ActivityKind = "voice" | "live";

export interface ActivitySession {
  kind: ActivityKind;
  sessionId: string;
  sourceRoute: string;
  owner: string | null;
  title: string;
  status: ActivityStatus;
  lastError: string | null;
  updatedAt: string;
}

interface SessionActivityState {
  voiceSession: ActivitySession | null;
  liveSession: ActivitySession | null;
  upsert: (session: Omit<ActivitySession, "updatedAt"> & { updatedAt?: string }) => void;
  setStatus: (kind: ActivityKind, status: ActivityStatus, lastError?: string | null) => void;
  clear: (kind: ActivityKind, status?: "ended" | "idle") => void;
  reset: () => void;
}

const initialState = { voiceSession: null, liveSession: null };

export const useSessionActivityStore = create<SessionActivityState>((set) => ({
  ...initialState,
  upsert: (session) =>
    set(() => ({
      [session.kind === "voice" ? "voiceSession" : "liveSession"]: {
        ...session,
        updatedAt: session.updatedAt ?? new Date().toISOString(),
      },
    })),
  setStatus: (kind, status, lastError = null) =>
    set((state) => {
      const key = kind === "voice" ? "voiceSession" : "liveSession";
      const current = state[key];
      if (!current) return state;
      return { [key]: { ...current, status, lastError, updatedAt: new Date().toISOString() } };
    }),
  clear: (kind, status = "ended") =>
    set((state) => {
      const key = kind === "voice" ? "voiceSession" : "liveSession";
      const current = state[key];
      if (!current) return state;
      return {
        [key]: status === "idle" ? null : { ...current, status, updatedAt: new Date().toISOString() },
      };
    }),
  reset: () => set(initialState),
}));
