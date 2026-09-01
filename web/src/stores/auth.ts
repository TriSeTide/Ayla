/**
 * auth 全局状态（Zustand）。
 *
 * Token 生命周期（开发文档 4.1 / M5-1 决策）：
 * - access 只存内存（XSS 面小）；refresh 持久化到 sessionStorage（关闭标签页即失效，
 *   刷新页面可从 refresh 恢复会话）。
 * - 401 由 client.ts 拦截静默续期；refresh 也失效 → logout + 跳登录。
 */
import { create } from "zustand";
import * as authApi from "../api/auth";
import type { UserPublic } from "../api/types";
import { useSessionActivityStore } from "./sessionActivity";
import { voiceSessionRuntime } from "../runtime/voiceSessionRuntime";
import { liveSessionRuntime } from "../runtime/liveSessionRuntime";

const REFRESH_KEY = "elysia.refresh_token";

interface AuthState {
  accessToken: string | null;
  refreshToken: string | null;
  currentUser: UserPublic | null;
  /** 是否已尝试从持久化 refresh 恢复会话（避免闪跳登录页） */
  initialized: boolean;

  setTokens: (access: string, refresh?: string) => void;
  setUser: (user: UserPublic) => void;
  setMediaActivity: (activity: {
    kind: "voice" | "live";
    active: boolean;
    roomId?: number | null;
  }) => void;
  login: (username: string, password: string) => Promise<void>;
  register: (
    payload: { username: string; email: string; password: string; nickname?: string },
  ) => Promise<void>;
  /** 页面启动恢复：有持久化 refresh 则续期拿 access + 拉取 me */
  restoreSession: () => Promise<void>;
  logout: () => void;
}

function readStoredRefresh(): string | null {
  try {
    return sessionStorage.getItem(REFRESH_KEY);
  } catch {
    return null;
  }
}

function writeStoredRefresh(refresh: string | null) {
  try {
    if (refresh) sessionStorage.setItem(REFRESH_KEY, refresh);
    else sessionStorage.removeItem(REFRESH_KEY);
  } catch {
    // 存储不可用时忽略（如隐私模式），会话仅限当前内存周期
  }
}

export const useAuthStore = create<AuthState>((set, get) => ({
  accessToken: null,
  refreshToken: readStoredRefresh(),
  currentUser: null,
  initialized: false,

  setTokens: (access, refresh) => {
    set((state) => {
      const nextRefresh = refresh ?? state.refreshToken;
      writeStoredRefresh(nextRefresh);
      return { accessToken: access, refreshToken: nextRefresh };
    });
  },

  setUser: (user) => set({ currentUser: user }),

  setMediaActivity: ({ kind, active, roomId = null }) =>
    set((state) => {
      if (!state.currentUser) return state;
      return {
        currentUser: {
          ...state.currentUser,
          ...(kind === "voice"
            ? { is_in_voice: active, voice_room_id: active ? roomId : null }
            : { is_live: active, live_room_id: active ? roomId : null }),
        },
      };
    }),

  login: async (username, password) => {
    const result = await authApi.login({ username, password });
    get().setTokens(result.access, result.refresh);
    const me = await authApi.fetchMe();
    set({ currentUser: me });
  },

  register: async (payload) => {
    const result = await authApi.register(payload);
    get().setTokens(result.access, result.refresh);
    set({ currentUser: result.user });
  },

  restoreSession: async () => {
    const refreshToken = get().refreshToken;
    if (!refreshToken) {
      set({ initialized: true });
      return;
    }
    try {
      const { access, refresh } = await authApi.refresh(refreshToken);
      // ROTATE_REFRESH_TOKENS=True：用返回值覆盖旧 refresh，否则下次刷新 401
      get().setTokens(access, refresh ?? refreshToken);
      const me = await authApi.fetchMe();
      set({ currentUser: me, initialized: true });
    } catch {
      get().logout();
      set({ initialized: true });
    }
  },

  logout: () => {
    // 登出先释放已迁移的语音 runtime 与活动态索引；直播会话（含手机端小窗）一并销毁
    voiceSessionRuntime.stopHeartbeat();
    liveSessionRuntime.leave();
    useSessionActivityStore.getState().reset();
    writeStoredRefresh(null);
    set({ accessToken: null, refreshToken: null, currentUser: null, initialized: true });
  },
}));
