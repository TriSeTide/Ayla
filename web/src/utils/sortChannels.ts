/**
 * sortChannels —— 语音房/直播间统一排序（2026-09-05 定，全界面同序）。
 *
 * 排序事实源 = 后端持久字段（语音 last_occupied_at/last_vacant_at、直播
 * started_at/ended_at），随 WS 帧广播；这里只按字段排序，无任何前端计数器/
 * 本地时间戳 bump —— 刷新不丢、多端一致。
 *
 * 语音房（有人区/无人区，只升不降不回落初始位）：
 * - 有人区（member_count > 0）整体置顶，内部按 last_occupied_at 新→旧
 *   （最近有人进入的最前）；
 * - 无人区：曾有人进入（last_occupied_at/last_vacant_at 任一非空）按
 *   last_vacant_at 新→旧（最近变空的最前、压住从未进入的房——变空不回
 *   初始位）；从未进入按 created_at 降序。
 * - 「曾进入」用两字段兜底：部署前有历史的房间 last_occupied_at 可能为
 *   null，但变空后必有 last_vacant_at——避免老房间被误判为「从未进入」。
 *
 * 直播间（在播/曾播/从未，同语音模型）：
 * - 在播（status=live）置顶，按「最近开播」新→旧（started_at 降序）；
 * - 曾开播（started_at 非空）但现在未播 → 按「最近下播」新→旧（ended_at
 *   降序），压住从未开播的——下播不回初始位；
 * - 从未开播按 created_at 降序。
 */
import type { LiveChannelDescriptor, VoiceChannelDescriptor } from "../api/types";

/** ISO 时间字符串 → ms（排序投影字段比较；null/非法 → 0） */
export function toMs(value: string | null | undefined): number {
  if (!value) return 0;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : 0;
}

export function sortVoiceChannels(list: VoiceChannelDescriptor[]): VoiceChannelDescriptor[] {
  return [...list].sort((a, b) => {
    const aOccupied = Number(a.member_count) > 0;
    const bOccupied = Number(b.member_count) > 0;
    if (aOccupied !== bOccupied) return aOccupied ? -1 : 1;
    if (aOccupied) {
      return toMs(b.last_occupied_at) - toMs(a.last_occupied_at);
    }
    const everA = a.last_occupied_at != null || a.last_vacant_at != null;
    const everB = b.last_occupied_at != null || b.last_vacant_at != null;
    if (everA !== everB) return everA ? -1 : 1;
    if (everA) return toMs(b.last_vacant_at) - toMs(a.last_vacant_at);
    return b.created_at.localeCompare(a.created_at);
  });
}

export function sortLiveChannels(list: LiveChannelDescriptor[]): LiveChannelDescriptor[] {
  return [...list].sort((a, b) => {
    const aLive = a.status === "live";
    const bLive = b.status === "live";
    if (aLive !== bLive) return aLive ? -1 : 1;
    if (aLive) {
      return (b.started_at || "").localeCompare(a.started_at || "");
    }
    const everA = a.started_at != null;
    const everB = b.started_at != null;
    if (everA !== everB) return everA ? -1 : 1;
    if (everA) return (b.ended_at || "").localeCompare(a.ended_at || "");
    return b.created_at.localeCompare(a.created_at);
  });
}
