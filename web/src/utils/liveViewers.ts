/**
 * 直播列表项的在看人数投影（群内 / 群外列表共用）。
 *
 * - 只在**确实在播**（乐观 status=live）时展示：人数是"正在观看直播"的语义，
 *   未开播的房间里驻留的人不是"在看直播"；
 * - `viewer_count` 为 `null`（presence 存储不可用）时返回 `null` → 不渲染——
 *   读不到 ≠ 0 人在看，不用 0 冒充（AGENTS.md §8）；
 * - `0` 是真实读数，照常展示。
 */
import type { LiveChannelStatus } from "../api/types";

/** 列表卡面（LiveCardData 为 Partial 投影）只保证这两个字段可能缺失 */
type ViewerBadgeSource = {
  status?: LiveChannelStatus | null;
  viewer_count?: number | null;
};

export function liveViewerBadge(channel: ViewerBadgeSource): number | null {
  if (channel.status !== "live") return null;
  return typeof channel.viewer_count === "number" ? channel.viewer_count : null;
}

/** 人数文本：≥1000 用 1.2k 紧凑写法（列表徽标位置很窄，不换行、不截断数字语义） */
export function formatViewerCount(count: number): string {
  if (count < 1000) return String(count);
  return `${(count / 1000).toFixed(count < 10_000 ? 1 : 0)}k`;
}
