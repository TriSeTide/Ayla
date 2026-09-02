/**
 * subgroup 全局状态：群聊子群列表 + 当前选中子群 + 子群独立未读。
 *
 * - byGroup：conversation_id -> 子群列表（后端顺序，默认组在前）；
 * - activeByGroup：conversation_id -> 当前选中子群 id（null = 未加载，默认组兜底）；
 * - unreadByKey / unreadSeqsByKey：`${convId}:${subgroupId}` -> 本人未读投影。
 *   列表加载时以服务端 unread_count/unread_seqs 为准；WS message.new 实时增量；
 *   切换子群标已读后本地清零（subgroup.read 事件同步其他端）。
 */
import { create } from "zustand";
import type { SubGroup } from "../api/types";

export function subgroupKey(convId: string, subgroupId: string | null | undefined): string {
  return `${convId}:${subgroupId ?? ""}`;
}

interface SubGroupState {
  byGroup: Record<string, SubGroup[]>;
  activeByGroup: Record<string, string | null>;
  unreadByKey: Record<string, number>;
  unreadSeqsByKey: Record<string, number[]>;

  setSubgroups: (convId: string, list: SubGroup[]) => void;
  upsertSubgroup: (convId: string, sg: SubGroup) => void;
  removeSubgroup: (convId: string, subgroupId: string) => void;
  setActiveSubgroup: (convId: string, subgroupId: string | null) => void;
  /** WS message.new：非当前活跃子群的消息未读 +1（带 seq 去重） */
  bumpSubgroupUnread: (convId: string, subgroupId: string, seq?: number) => void;
  /** 切换子群标已读 / subgroup.read 事件：清零该子群未读 */
  clearSubgroupUnread: (convId: string, subgroupId: string) => void;
  reset: () => void;
}

export const useSubGroupStore = create<SubGroupState>((set) => ({
  byGroup: {},
  activeByGroup: {},
  unreadByKey: {},
  unreadSeqsByKey: {},

  setSubgroups: (convId, list) =>
    set((state) => {
      const unreadByKey = { ...state.unreadByKey };
      const unreadSeqsByKey = { ...state.unreadSeqsByKey };
      for (const sg of list) {
        const key = subgroupKey(convId, sg.id);
        unreadByKey[key] = sg.unread_count;
        unreadSeqsByKey[key] = sg.unread_seqs ?? [];
      }
      return {
        byGroup: { ...state.byGroup, [convId]: list },
        unreadByKey,
        unreadSeqsByKey,
      };
    }),

  upsertSubgroup: (convId, sg) =>
    set((state) => {
      const list = state.byGroup[convId] ?? [];
      const exists = list.some((item) => item.id === sg.id);
      const next = exists
        ? list.map((item) => (item.id === sg.id ? { ...item, ...sg } : item))
        : [...list, sg];
      const key = subgroupKey(convId, sg.id);
      // WS 帧（created/updated）不带未读：保留本地已有未读投影，避免被 undefined 覆盖
      return {
        byGroup: { ...state.byGroup, [convId]: next },
        unreadByKey: {
          ...state.unreadByKey,
          [key]: sg.unread_count ?? state.unreadByKey[key] ?? 0,
        },
        unreadSeqsByKey: {
          ...state.unreadSeqsByKey,
          [key]: sg.unread_seqs ?? state.unreadSeqsByKey[key] ?? [],
        },
      };
    }),

  removeSubgroup: (convId, subgroupId) =>
    set((state) => {
      const list = state.byGroup[convId] ?? [];
      const next = list.filter((item) => item.id !== subgroupId);
      const unreadByKey = { ...state.unreadByKey };
      const unreadSeqsByKey = { ...state.unreadSeqsByKey };
      delete unreadByKey[subgroupKey(convId, subgroupId)];
      delete unreadSeqsByKey[subgroupKey(convId, subgroupId)];
      return {
        byGroup: { ...state.byGroup, [convId]: next },
        unreadByKey,
        unreadSeqsByKey,
      };
    }),

  setActiveSubgroup: (convId, subgroupId) =>
    set((state) => ({
      activeByGroup: { ...state.activeByGroup, [convId]: subgroupId },
    })),

  bumpSubgroupUnread: (convId, subgroupId, seq) =>
    set((state) => {
      const key = subgroupKey(convId, subgroupId);
      const seqs = state.unreadSeqsByKey[key] ?? [];
      if (seq != null && seqs.includes(seq)) return state;
      return {
        unreadByKey: { ...state.unreadByKey, [key]: (state.unreadByKey[key] ?? 0) + 1 },
        unreadSeqsByKey: {
          ...state.unreadSeqsByKey,
          [key]: seq != null ? [...seqs, seq].sort((a, b) => a - b) : seqs,
        },
      };
    }),

  clearSubgroupUnread: (convId, subgroupId) =>
    set((state) => {
      const key = subgroupKey(convId, subgroupId);
      return {
        unreadByKey: { ...state.unreadByKey, [key]: 0 },
        unreadSeqsByKey: { ...state.unreadSeqsByKey, [key]: [] },
      };
    }),

  reset: () =>
    set({ byGroup: {}, activeByGroup: {}, unreadByKey: {}, unreadSeqsByKey: {} }),
}));
