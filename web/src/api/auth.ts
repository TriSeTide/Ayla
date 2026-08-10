/**
 * 认证 API：与 backend/apps/accounts/urls.py 对齐。
 */
import { apiRequest } from "./client";
import type {
  LoginPayload,
  LoginResult,
  ProfileUpdatePayload,
  RegisterPayload,
  RegisterResult,
  UserPublic,
} from "./types";

/** POST /auth/register/ */
export function register(payload: RegisterPayload) {
  return apiRequest<RegisterResult>("/auth/register/", {
    method: "POST",
    body: payload,
    // 注册/登录的 401/400 是业务错误，原样展示，不触发 401 刷新重放
    noRetry401: true,
  });
}

/** POST /auth/login/（SimpleJWT TokenObtainPairView） */
export function login(payload: LoginPayload) {
  return apiRequest<LoginResult>("/auth/login/", {
    method: "POST",
    body: payload,
    noRetry401: true,
  });
}

/** POST /auth/refresh/（TokenRefreshView，ROTATE_REFRESH_TOKENS=True 会返回新 refresh） */
export function refresh(refreshToken: string) {
  return apiRequest<{ access: string; refresh?: string }>("/auth/refresh/", {
    method: "POST",
    body: { refresh: refreshToken },
    isRefresh: true,
  });
}

/** GET /me/ */
export function fetchMe() {
  return apiRequest<UserPublic>("/me/");
}

/** PATCH /me/profile/ */
export function updateProfile(payload: ProfileUpdatePayload) {
  return apiRequest<UserPublic>("/me/profile/", {
    method: "PATCH",
    body: payload,
  });
}
