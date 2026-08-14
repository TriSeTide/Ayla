/**
 * accounts REST 封装（F8，对齐 backend/apps/accounts/views.py）。
 *
 * - GET /me/badges/ —— 全站未读与待处理聚合（B9）。
 */
import { apiRequest } from "./client";
import type { Badges } from "./types";

/** GET /me/badges/ —— 五维聚合计数（私信未读/群未读/好友申请/群邀请/待审批入群申请） */
export function getBadges() {
  return apiRequest<Badges>("/me/badges/");
}
