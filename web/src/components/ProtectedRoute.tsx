/**
 * 受保护路由守卫：无 access → 重定向 /login；登录后统一进主页 /group。
 */
import { Navigate } from "react-router-dom";
import { useAuthStore } from "../stores/auth";

export function ProtectedRoute({ children }: { children: React.ReactNode }) {
  const accessToken = useAuthStore((s) => s.accessToken);

  if (!accessToken) {
    return <Navigate to="/login" replace />;
  }
  return <>{children}</>;
}
