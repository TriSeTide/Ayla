/**
 * 爱莉 profile REST：与 backend/apps/elysia_bridge/views.py 真实契约对齐。
 * 路径挂 /api/v1/elysia/。
 *
 * M5-2 只做读取 + 入口跳转（文档 §3.3）：
 * - GET /profile/ 登录可读；POST/PATCH 需管理员（本期前端只读，不触发）。
 */
import { apiRequest } from "./client";
import type { ElysiaProfile } from "./types";

/** GET /elysia/profile/ —— 读取爱莉 profile（应用级单例；未初始化返回 404） */
export function getElysiaProfile() {
  return apiRequest<ElysiaProfile>("/elysia/profile/");
}
