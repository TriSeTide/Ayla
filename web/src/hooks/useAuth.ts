/**
 * useAuth：组合式封装认证逻辑。
 */
import { useCallback } from "react";
import { useNavigate } from "react-router-dom";
import { useAuthStore } from "../stores/auth";
import { appInit } from "../appInit";
import { chatWS } from "../ws/chat";
import { presenceClient } from "../ws/presence";

export function useAuth() {
  const navigate = useNavigate();
  const currentUser = useAuthStore((s) => s.currentUser);
  const accessToken = useAuthStore((s) => s.accessToken);
  const initialized = useAuthStore((s) => s.initialized);

  const login = useCallback(
    async (username: string, password: string) => {
      await useAuthStore.getState().login(username, password);
      presenceClient.connect();
      chatWS.connect();
      // 全屏预加载门：核心数据加载完成前 App 渲染 FullScreenLoader，不进入页面
      void appInit.run();
    },
    [],
  );

  const register = useCallback(
    async (payload: { username: string; email: string; password: string; nickname?: string }) => {
      await useAuthStore.getState().register(payload);
      presenceClient.connect();
      chatWS.connect();
      void appInit.run();
    },
    [],
  );

  const logout = useCallback(() => {
    presenceClient.disconnect();
    chatWS.disconnect();
    // appInit 已订阅 auth store：token 清空时自动 reset（含 TopNav/NarrowTopBar 直接调 store.logout 的入口）
    useAuthStore.getState().logout();
    navigate("/login", { replace: true });
  }, [navigate]);

  return {
    currentUser,
    accessToken,
    initialized,
    isAuthenticated: Boolean(accessToken),
    login,
    register,
    logout,
  };
}
