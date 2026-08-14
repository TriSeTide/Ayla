/**
 * badges 全局状态（F8，B9 全站未读聚合）。
 *
 * - badges：GET /me/badges/ 五维计数；
 * - 消息入口聚合红点（R-M4）= 私信未读 + 好友申请 + 群邀请 + 待审批入群申请
 *   （群未读不进"消息中心"红点——群未读属群卡片/ServerRail 角标，R-H5）。
 */
import { create } from "zustand";
import * as accountsApi from "../api/accounts";
import type { Badges } from "../api/types";

interface BadgesState {
  badges: Badges | null;
  fetch: () => Promise<void>;
  /** 消息中心入口聚合红点数（MessageFAB / TopNav 消息项） */
  messageBadge: () => number;
  reset: () => void;
}

const EMPTY: Badges = {
  private_unread: 0,
  group_unread: 0,
  friend_requests: 0,
  group_invites: 0,
  join_requests_pending: 0,
};

export const useBadgesStore = create<BadgesState>((set, get) => ({
  badges: null,

  fetch: async () => {
    try {
      const badges = await accountsApi.getBadges();
      set({ badges });
    } catch {
      // 拉取失败保持上一版计数（下次再试），不伪造清零
    }
  },

  messageBadge: () => {
    const b = get().badges ?? EMPTY;
    return b.private_unread + b.friend_requests + b.group_invites + b.join_requests_pending;
  },

  reset: () => set({ badges: null }),
}));
