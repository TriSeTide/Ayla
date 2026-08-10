/**
 * API 客户端：fetch 封装。
 *
 * 职责：
 * - baseURL 前缀（VITE_API_BASE_URL，默认走同源 Vite proxy `/api/v1`）
 * - JSON 序列化 / 解析
 * - 自动携带 Authorization: Bearer <access>
 * - 非 2xx 归一为 ApiError { status, detail }
 * - 401（非 refresh 端点）静默刷新并重放一次原请求；并发 401 只触发一次刷新
 * - 刷新失败 → 清空 auth 并跳登录
 */
import { useAuthStore } from "../stores/auth";
import type { ApiErrorBody } from "./types";

export const API_BASE_URL = (import.meta.env.VITE_API_BASE_URL as string | undefined) ?? "";

/** 前端统一 API 根路径（后端挂载在 /api/v1/） */
export const API_PREFIX = "/api/v1";

export class ApiError extends Error {
  status: number;
  /** 后端返回的原始结构（detail 或字段错误） */
  body: ApiErrorBody | null;

  constructor(status: number, detail: string, body: ApiErrorBody | null = null) {
    super(detail);
    this.name = "ApiError";
    this.status = status;
    this.body = body;
  }
}

export interface ApiRequestOptions {
  method?: "GET" | "POST" | "PUT" | "PATCH" | "DELETE";
  /** 请求体；非 FormData 时自动 JSON.stringify */
  body?: unknown;
  /** 是否携带 Authorization（默认 true） */
  auth?: boolean;
  /** 标记该请求为 refresh 端点（401 不触发刷新，直接失败） */
  isRefresh?: boolean;
  /** 认证端点（login/register 等）：401 不触发刷新重放，原样归一给调用方展示 */
  noRetry401?: boolean;
  /** 额外请求头 */
  headers?: Record<string, string>;
}

/** 归一化后端错误：{detail} / {field: [msg]} / {field: msg} → 可读文案 */
export function normalizeErrorBody(body: ApiErrorBody | null, fallback: string): string {
  if (!body) return fallback;
  if (typeof body.detail === "string" && body.detail) return body.detail;
  if (typeof body.detail === "object" && body.detail !== null) {
    return String(body.detail);
  }
  // 字段错误：取第一个字段的第一条消息
  const first = Object.entries(body).find(([, v]) => v != null);
  if (first) {
    const [, v] = first;
    if (Array.isArray(v)) return v.length ? String(v[0]) : fallback;
    return String(v);
  }
  return fallback;
}

async function parseBody(response: Response): Promise<ApiErrorBody | null> {
  const text = await response.text();
  if (!text) return null;
  try {
    return JSON.parse(text) as ApiErrorBody;
  } catch {
    return null;
  }
}

/** 触发登出：清 store、断开 presence，返回登录页（保留当前路径用于回跳） */
function handleSessionExpired() {
  const { logout } = useAuthStore.getState();
  logout();
  const current = window.location.pathname + window.location.search;
  if (!window.location.pathname.startsWith("/login")) {
    window.location.assign(`/login?next=${encodeURIComponent(current)}`);
  }
}

/** 刷新并重放：互斥锁避免并发 401 触发多次 refresh */
let refreshPromise: Promise<boolean> | null = null;

async function doRefresh(): Promise<boolean> {
  const current = refreshPromise;
  if (current) return current; // 已有刷新进行中，复用同一 promise

  const p = (async () => {
    const { refreshToken } = useAuthStore.getState();
    if (!refreshToken) return false;
    try {
      const res = await fetch(`${API_BASE_URL}${API_PREFIX}/auth/refresh/`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ refresh: refreshToken }),
      });
      if (!res.ok) return false;
      const data = (await res.json()) as { access: string; refresh?: string };
      useAuthStore.getState().setTokens(data.access, data.refresh ?? refreshToken);
      return true;
    } catch {
      return false;
    }
  })();
  refreshPromise = p;
  try {
    return await p;
  } finally {
    // 仅当仍是本次刷新时清理，避免并发调用各自清掉共享锁
    if (refreshPromise === p) refreshPromise = null;
  }
}

async function rawRequest(path: string, options: ApiRequestOptions): Promise<Response> {
  const headers: Record<string, string> = { ...(options.headers ?? {}) };
  const { accessToken } = useAuthStore.getState();
  if (options.auth !== false && accessToken) {
    headers.Authorization = `Bearer ${accessToken}`;
  }
  let body: BodyInit | undefined;
  if (options.body !== undefined && !(options.body instanceof FormData)) {
    headers["Content-Type"] = "application/json";
    body = JSON.stringify(options.body);
  } else if (options.body instanceof FormData) {
    body = options.body;
  }
  return fetch(`${API_BASE_URL}${API_PREFIX}${path}`, {
    method: options.method ?? "GET",
    headers,
    body,
  });
}

export async function apiRequest<T>(
  path: string,
  options: ApiRequestOptions = {},
): Promise<T> {
  let response = await rawRequest(path, options);

  // 401 且非 refresh / 非认证端点：静默刷新后重放一次
  if (response.status === 401 && options.isRefresh !== true && options.noRetry401 !== true) {
    const ok = await doRefresh();
    if (ok) {
      response = await rawRequest(path, options);
    } else {
      handleSessionExpired();
      throw new ApiError(401, "登录已过期，请重新登录");
    }
  }

  if (!response.ok) {
    const body = await parseBody(response);
    const detail = normalizeErrorBody(body, `请求失败（${response.status}）`);
    throw new ApiError(response.status, detail, body);
  }

  // 204 No Content
  if (response.status === 204) {
    return undefined as T;
  }
  const data = await parseBody(response);
  return (data ?? null) as T;
}

/** 无鉴权裸请求（健康检查等，不做 JSON 归一） */
export async function apiRequestRaw(path: string): Promise<Response> {
  return fetch(`${API_BASE_URL}${API_PREFIX}${path}`);
}
