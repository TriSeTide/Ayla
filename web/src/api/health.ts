/**
 * 健康检查 API。
 * /api/v1/health/live/：存活探针（进程活着即 ok）
 * /api/v1/health/：只读、快速，区分预期禁用与真实故障
 */
import { apiRequestRaw } from "./client";

export interface LiveStatus {
  status: string;
}

export interface HealthStatus {
  status: "ok" | "degraded";
  checks: Record<string, string>;
  degraded: string[];
}

/** GET /health/live/ */
export async function checkLive(): Promise<LiveStatus | null> {
  try {
    const res = await apiRequestRaw("/health/live/");
    if (!res.ok) return null;
    return (await res.json()) as LiveStatus;
  } catch {
    return null;
  }
}

/** GET /health/ */
export async function checkHealth(): Promise<HealthStatus | null> {
  try {
    const res = await apiRequestRaw("/health/");
    if (!res.ok) return null;
    return (await res.json()) as HealthStatus;
  } catch {
    return null;
  }
}
