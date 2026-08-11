/**
 * useAuth：组合式封装认证逻辑。
 */
import { useCallback } from "react";
import { useNavigate } from "react-router-dom";
import { useAuthStore } from "../stores/auth";
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
    },
    [],
  );

  const register = useCallback(
    async (payload: { username: string; email: string; password: string; nickname?: string }) => {
      await useAuthStore.getState().register(payload);
      presenceClient.connect();
      chatWS.connect();
    },
    [],
  );

  const logout = useCallback(() => {
    presenceClient.disconnect();
    chatWS.disconnect();
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
