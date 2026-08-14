/**
 * 群状态角标 —— 纯函数（需求 R-H5）。
 *
 * 优先级：未读 > 直播 > 语音 > 桌游（design.md §12.6 / 布局文档 §4）；
 * 一屏最多展示 3 个角标；未读为圆底白字数字徽标（99+ 截断），
 * 其余为 16px 线性图标底圆（直播 --glow-500 / 语音 --ice-500 / 桌游 --sakura-300）。
 *
 * 数据源：未读来自会话列表 unread_count（真实落地）；
 * live/voice/game 状态来自对应列表接口（live status=live、voice member_count>0、
 * game status=playing），F2 阶段仅定义契约 + 预留字段，数据由 F4/F5/F7 填充。
 */
import type { SVGProps } from "react";
import { IconGame, IconMic, IconVideo } from "../icons";

export type BadgeKind = "unread" | "live" | "voice" | "game";

/** 群状态输入（可选字段缺省视为无该状态） */
export interface GroupStatus {
  unread?: number;
  live?: boolean;
  voice?: boolean;
  game?: boolean;
}

export interface GroupBadge {
  kind: BadgeKind;
  /** 未读时是格式化后的数字文本（"99+"），其余为 null（图标徽标） */
  label: string | null;
  /** 无障碍描述 */
  ariaLabel: string;
}

/** 未读 > 直播 > 语音 > 桌游（需求 §3.1 R-H5、design.md §12.6） */
const BADGE_ORDER: BadgeKind[] = ["unread", "live", "voice", "game"];

/** 一屏最多展示角标数（design.md §12.6 角标列纵向叠放，最多 3 个） */
export const MAX_BADGES = 3;

const BADGE_ARIA: Record<BadgeKind, string> = {
  unread: "有未读消息",
  live: "群内有直播",
  voice: "群内有语音房",
  game: "群内有桌游",
};

/** 图标徽标映射（未读是数字，无图标） */
export function badgeIcon(kind: BadgeKind): ((p: SVGProps<SVGSVGElement>) => JSX.Element) | null {
  switch (kind) {
    case "live":
      return IconVideo;
    case "voice":
      return IconMic;
    case "game":
      return IconGame;
    default:
      return null;
  }
}

function formatUnread(count: number): string {
  return count > 99 ? "99+" : String(count);
}

/**
 * 由群状态解析角标列表：按优先级排序、去重（status 里 false/0/undefined 视为无）、
 * 最多 MAX_BADGES 个。
 */
export function resolveBadges(status: GroupStatus): GroupBadge[] {
  const badges: GroupBadge[] = [];
  if (status.unread != null && status.unread > 0) {
    badges.push({
      kind: "unread",
      label: formatUnread(status.unread),
      ariaLabel: `${BADGE_ARIA.unread}（${status.unread} 条）`,
    });
  }
  if (status.live) {
    badges.push({ kind: "live", label: null, ariaLabel: BADGE_ARIA.live });
  }
  if (status.voice) {
    badges.push({ kind: "voice", label: null, ariaLabel: BADGE_ARIA.voice });
  }
  if (status.game) {
    badges.push({ kind: "game", label: null, ariaLabel: BADGE_ARIA.game });
  }
  // 已按 BADGE_ORDER 顺序 push，稳定性天然满足；理论上 status 对象无顺序语义，这里显式再排一次
  badges.sort((a, b) => BADGE_ORDER.indexOf(a.kind) - BADGE_ORDER.indexOf(b.kind));
  return badges.slice(0, MAX_BADGES);
}
