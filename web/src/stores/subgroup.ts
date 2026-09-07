/**
 * subgroup 全局状态：群聊子群列表 + 当前选中子群 + 子群独立未读。
 *
 * - byGroup：conversation_id -> 子群列表（后端顺序，默认组在前）；
 * - activeByGroup：conversation_id -> 当前选中子群 id（null = 未加载，默认组兜底）；
 * - lastMessageSeqByKey：消息最大序号，保留列表加载前收到的消息，避免迟到 REST 回退活跃度；
 * - unreadByKey / unreadSeqsByKey：`${convId}:${subgroupId}` -> 本人未读投影。
 *   列表加载时以服务端 unread_count/unread_seqs 为准；WS message.new 实时增量；
 *   实际看到消息后按服务端确认序号移除（subgroup.read 同步其他端）。
 */
import { create } from "zustand";
import type { SubGroup } from "../api/types";

export function subgroupKey(convId: string, subgroupId: string | null | undefined): string {
  return `${convId}:${subgroupId ?? ""}`;
}

/** 宽屏侧栏投影：默认组固定第一，其余按最近消息降序，并列保持列表原序。 */
export function sortSubgroupsByActivity(list: SubGroup[]): SubGroup[] {
  return [...list].sort((a, b) =>
    Number(b.is_default) - Number(a.is_default)
    || (b.last_message_seq ?? 0) - (a.last_message_seq ?? 0));
}

interface SubGroupState {
  byGroup: Record<string, SubGroup[]>;
  activeByGroup: Record<string, string | null>;
  unreadByKey: Record<string, number>;
  unreadSeqsByKey: Record<string, number[]>;
  lastMessageSeqByKey: Record<string, number>;
  /** 当前账号已确认序号，避免迟到列表/补发恢复已读；账号切换时重置。 */
  confirmedReadSeqsByKey: Record<string, number[]>;

  setSubgroups: (convId: string, list: SubGroup[]) => void;
  upsertSubgroup: (convId: string, sg: SubGroup) => void;
  removeSubgroup: (convId: string, subgroupId: string) => void;
  setActiveSubgroup: (convId: string, subgroupId: string | null) => void;
  /** 已落库消息推进活跃度；与未读、发送者、当前查看位置无关。 */
  recordMessageActivity: (convId: string, subgroupId: string | null | undefined, seq: number) => void;
  /** WS message.new：消息先进入未读，待可视区精确确认（带 seq 去重）。 */
  bumpSubgroupUnread: (convId: string, subgroupId: string, seq?: number) => void;
  /** 仅移除本次确认序号，返回实际移除的本地未读数；重复确认幂等。 */
  markSubgroupReadSeqs: (convId: string, subgroupId: string, seqs: number[]) => number;
  /** 显式清理投影；查看/切换子群与已读回执不得调用。 */
  clearSubgroupUnread: (convId: string, subgroupId: string) => void;
  reset: () => void;
}

/** REST 列表与单组编辑响应共用快照边界：保留之后的新消息，排除已确认序号。 */
function mergeUnreadSnapshot(state: SubGroupState, convId: string, sg: SubGroup) {
  const key = subgroupKey(convId, sg.id);
  const confirmed = new Set(state.confirmedReadSeqsByKey[key] ?? []);
  const incoming = sg.unread_seqs ?? state.unreadSeqsByKey[key] ?? [];
  const later = (state.unreadSeqsByKey[key] ?? [])
    .filter((seq) => sg.last_message_seq == null || seq > sg.last_message_seq);
  const seqs = [...new Set([...incoming, ...later])]
    .filter((seq) => !confirmed.has(seq)).sort((a, b) => a - b);
  const count = sg.unread_seqs != null ? seqs.length
    : Math.max(sg.unread_count ?? state.unreadByKey[key] ?? 0, seqs.length);
  return { seqs, count };
}

export const useSubGroupStore = create<SubGroupState>((set) => ({
  byGroup: {},
  activeByGroup: {},
  unreadByKey: {},
  unreadSeqsByKey: {},
  lastMessageSeqByKey: {},
  confirmedReadSeqsByKey: {},

  setSubgroups: (convId, list) =>
    set((state) => {
      const unreadByKey = { ...state.unreadByKey };
      const unreadSeqsByKey = { ...state.unreadSeqsByKey };
      const lastMessageSeqByKey = { ...state.lastMessageSeqByKey };
      const next = list.map((sg) => {
        const key = subgroupKey(convId, sg.id);
        const unread = mergeUnreadSnapshot(state, convId, sg);
        unreadByKey[key] = unread.count;
        unreadSeqsByKey[key] = unread.seqs;
        const seq = Math.max(sg.last_message_seq ?? 0, lastMessageSeqByKey[key] ?? 0);
        lastMessageSeqByKey[key] = seq;
        return { ...sg, last_message_seq: seq, unread_count: unread.count, unread_seqs: unread.seqs };
      });
      return {
        byGroup: { ...state.byGroup, [convId]: next },
        unreadByKey,
        unreadSeqsByKey,
        lastMessageSeqByKey,
      };
    }),

  upsertSubgroup: (convId, sg) =>
    set((state) => {
      const list = state.byGroup[convId] ?? [];
      const key = subgroupKey(convId, sg.id);
      const seq = Math.max(sg.last_message_seq ?? 0, state.lastMessageSeqByKey[key] ?? 0);
      const unread = mergeUnreadSnapshot(state, convId, sg);
      const updated = { ...sg, last_message_seq: seq, unread_count: unread.count, unread_seqs: unread.seqs };
      const exists = list.some((item) => item.id === sg.id);
      const next = exists
        ? list.map((item) => (item.id === sg.id ? { ...item, ...updated } : item))
        : [...list, updated];
      // WS 帧（created/updated）不带未读：保留本地已有未读投影，避免被 undefined 覆盖
      return {
        byGroup: { ...state.byGroup, [convId]: next },
        lastMessageSeqByKey: { ...state.lastMessageSeqByKey, [key]: seq },
        unreadByKey: {
          ...state.unreadByKey,
          [key]: unread.count,
        },
        unreadSeqsByKey: {
          ...state.unreadSeqsByKey,
          [key]: unread.seqs,
        },
      };
    }),

  removeSubgroup: (convId, subgroupId) =>
    set((state) => {
      const list = state.byGroup[convId] ?? [];
      const next = list.filter((item) => item.id !== subgroupId);
      const unreadByKey = { ...state.unreadByKey };
      const unreadSeqsByKey = { ...state.unreadSeqsByKey };
      const lastMessageSeqByKey = { ...state.lastMessageSeqByKey };
      const confirmedReadSeqsByKey = { ...state.confirmedReadSeqsByKey };
      delete unreadByKey[subgroupKey(convId, subgroupId)];
      delete unreadSeqsByKey[subgroupKey(convId, subgroupId)];
      delete lastMessageSeqByKey[subgroupKey(convId, subgroupId)];
      delete confirmedReadSeqsByKey[subgroupKey(convId, subgroupId)];
      return {
        byGroup: { ...state.byGroup, [convId]: next },
        unreadByKey,
        unreadSeqsByKey,
        lastMessageSeqByKey,
        confirmedReadSeqsByKey,
      };
    }),

  setActiveSubgroup: (convId, subgroupId) =>
    set((state) => ({
      activeByGroup: { ...state.activeByGroup, [convId]: subgroupId },
    })),

  recordMessageActivity: (convId, subgroupId, seq) =>
    set((state) => {
      // 无子群归属的旧消息属于固定首位的默认组；本地 pending 不参与排序。
      if (subgroupId == null || !Number.isSafeInteger(seq) || seq <= 0) return state;
      const key = subgroupKey(convId, subgroupId);
      if (seq <= (state.lastMessageSeqByKey[key] ?? 0)) return state;
      const list = state.byGroup[convId];
      return {
        lastMessageSeqByKey: { ...state.lastMessageSeqByKey, [key]: seq },
        ...(list && {
          byGroup: {
            ...state.byGroup,
            [convId]: list.map((sg) => sg.id === subgroupId ? { ...sg, last_message_seq: seq } : sg),
          },
        }),
      };
    }),

  bumpSubgroupUnread: (convId, subgroupId, seq) =>
    set((state) => {
      const key = subgroupKey(convId, subgroupId);
      const seqs = state.unreadSeqsByKey[key] ?? [];
      if (seq != null && (seqs.includes(seq) || state.confirmedReadSeqsByKey[key]?.includes(seq))) return state;
      return {
        unreadByKey: { ...state.unreadByKey, [key]: (state.unreadByKey[key] ?? 0) + 1 },
        unreadSeqsByKey: {
          ...state.unreadSeqsByKey,
          [key]: seq != null ? [...seqs, seq].sort((a, b) => a - b) : seqs,
        },
      };
    }),

  markSubgroupReadSeqs: (convId, subgroupId, seqs) => {
    let removed = 0;
    set((state) => {
      const read = seqs.filter((seq) => Number.isSafeInteger(seq) && seq > 0);
      if (read.length === 0) return state;
      const key = subgroupKey(convId, subgroupId);
      const confirmed = [...new Set([...(state.confirmedReadSeqsByKey[key] ?? []), ...read])];
      const incoming = new Set(read);
      const previous = state.unreadSeqsByKey[key] ?? [];
      const unread = previous.filter((seq) => !incoming.has(seq));
      removed = previous.length - unread.length;
      const count = Math.max(0, (state.unreadByKey[key] ?? previous.length) - removed);
      return {
        confirmedReadSeqsByKey: { ...state.confirmedReadSeqsByKey, [key]: confirmed },
        unreadByKey: { ...state.unreadByKey, [key]: count },
        unreadSeqsByKey: { ...state.unreadSeqsByKey, [key]: unread },
        byGroup: {
          ...state.byGroup,
          [convId]: (state.byGroup[convId] ?? []).map((sg) => sg.id === subgroupId
            ? { ...sg, unread_count: count, unread_seqs: unread } : sg),
        },
      };
    });
    return removed;
  },

  clearSubgroupUnread: (convId, subgroupId) =>
    set((state) => {
      const key = subgroupKey(convId, subgroupId);
      return {
        unreadByKey: { ...state.unreadByKey, [key]: 0 },
        unreadSeqsByKey: { ...state.unreadSeqsByKey, [key]: [] },
      };
    }),

  reset: () =>
    set({ byGroup: {}, activeByGroup: {}, unreadByKey: {}, unreadSeqsByKey: {}, lastMessageSeqByKey: {}, confirmedReadSeqsByKey: {} }),
}));

/** 会话内 seq 唯一；默认组描述未加载时仍可识别已确认的 legacy null 消息。 */
export function isSubgroupMessageConfirmedRead(convId: string, seq: number): boolean {
  return Object.entries(useSubGroupStore.getState().confirmedReadSeqsByKey)
    .some(([key, confirmed]) => key.startsWith(`${convId}:`) && confirmed.includes(seq));
}
