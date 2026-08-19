/**
 * live 全局状态（M5-4，文档 §4.1）。
 *
 * - channels：大厅列表（乐观标记，真实在播以 /status/ 为准）；
 * - current：当前直播间（详情 + SRS 实时状态 + 弹幕列表）；
 * - 弹幕按 id 去重、定长截断（内存上限，权威历史在后端可随时再拉）；
 * - 徽章语义：srsStatus 优先；null（未查询）时用乐观 status 兜底并标注。
 */
import { create } from "zustand";
import type {
  DanmakuItem,
  LiveChannelDescriptor,
  LiveChannelStatus,
  LiveSrsStatus,
} from "../api/types";

/** 弹幕内存保留上限（超出丢弃最旧；权威历史在后端，?limit=200 可再拉） */
export const DANMAKU_MAX_ITEMS = 500;

export interface LiveRoomState {
  channel: LiveChannelDescriptor | null;
  /** SRS 实时判定（权威）；null = 尚未查询，UI 用乐观 status 兜底并标注 */
  srsStatus: LiveSrsStatus | null;
  /** 升序，按 id 去重 */
  danmaku: DanmakuItem[];
}

interface LiveState {
  channels: LiveChannelDescriptor[];
  channelsLoading: boolean;
  error: string | null;
  current: LiveRoomState;
  /** 弹幕 WS 连接状态（供 UI 展示） */
  wsConnection: "connecting" | "online" | "offline";
  lastFetched: number | null;

  setChannels: (list: LiveChannelDescriptor[]) => void;
  setChannelsLoading: (loading: boolean) => void;
  setError: (error: string | null) => void;
  upsertChannel: (channel: LiveChannelDescriptor) => void;
  updateChannelStatus: (channelId: number, status: string) => void;
  removeChannel: (channelId: number) => void;

  setCurrentChannel: (channel: LiveChannelDescriptor | null) => void;
  setSrsStatus: (status: LiveSrsStatus | null) => void;
  setWsConnection: (conn: "connecting" | "online" | "offline") => void;

  /** 追加单条弹幕（WS 回帧 / POST 之外的来源），按 id 去重、定长截断 */
  appendDanmaku: (item: DanmakuItem) => void;
  /** 合并历史弹幕（进房拉取 / 重连对账），按 id 去重后按 created_at 升序 */
  mergeDanmakuHistory: (items: DanmakuItem[]) => void;
  clearDanmaku: () => void;

  /** 退房清理：清当前直播间与弹幕，保留大厅列表 */
  clearCurrent: () => void;
  reset: () => void;
}

const initialRoom: LiveRoomState = {
  channel: null,
  srsStatus: null,
  danmaku: [],
};

/** 按 id 去重后按 created_at 升序，再按 DANMAKU_MAX_ITEMS 截断（保留最新） */
function normalizeDanmaku(list: DanmakuItem[]): DanmakuItem[] {
  const seen = new Set<string>();
  const deduped: DanmakuItem[] = [];
  for (const item of list) {
    if (seen.has(item.id)) continue;
    seen.add(item.id);
    deduped.push(item);
  }
  deduped.sort((a, b) => a.created_at.localeCompare(b.created_at));
  if (deduped.length > DANMAKU_MAX_ITEMS) {
    return deduped.slice(deduped.length - DANMAKU_MAX_ITEMS);
  }
  return deduped;
}

export const useLiveStore = create<LiveState>((set) => ({
  channels: [],
  channelsLoading: false,
  error: null,
  current: initialRoom,
  wsConnection: "offline",
  lastFetched: null,

  setChannels: (list) => set({ channels: list, channelsLoading: false, error: null, lastFetched: Date.now() }),
  setChannelsLoading: (loading) => set({ channelsLoading: loading }),
  setError: (error) => set({ error, channelsLoading: false }),

  upsertChannel: (channel) =>
    set((state) => {
      const idx = state.channels.findIndex((c) => c.id === channel.id);
      const channels =
        idx >= 0
          ? state.channels.map((c) => (c.id === channel.id ? channel : c))
          : [...state.channels, channel];
      return { channels };
    }),

  updateChannelStatus: (channelId, status) =>
    set((state) => ({
      channels: state.channels.map((c) =>
        c.id === channelId ? { ...c, status: status as LiveChannelStatus } : c
      ),
    })),

  removeChannel: (channelId) =>
    set((state) => ({
      channels: state.channels.filter((c) => c.id !== channelId),
    })),

  setCurrentChannel: (channel) =>
    set((state) => ({ current: { ...state.current, channel } })),

  setSrsStatus: (status) =>
    set((state) => ({ current: { ...state.current, srsStatus: status } })),

  setWsConnection: (conn) => set({ wsConnection: conn }),

  appendDanmaku: (item) =>
    set((state) => ({
      current: {
        ...state.current,
        danmaku: normalizeDanmaku([...state.current.danmaku, item]),
      },
    })),

  mergeDanmakuHistory: (items) =>
    set((state) => ({
      current: {
        ...state.current,
        danmaku: normalizeDanmaku([...state.current.danmaku, ...items]),
      },
    })),

  clearDanmaku: () =>
    set((state) => ({ current: { ...state.current, danmaku: [] } })),

  clearCurrent: () => set({ current: initialRoom, wsConnection: "offline" }),

  reset: () =>
    set({
      channels: [],
      channelsLoading: false,
      error: null,
      current: initialRoom,
      wsConnection: "offline",
      lastFetched: null,
    }),
}));

/** 判断 live store 数据是否过期（默认 60 秒） */
export function isLiveStale(maxAgeMs = 60_000): boolean {
  const { lastFetched } = useLiveStore.getState();
  if (!lastFetched) return true;
  return Date.now() - lastFetched > maxAgeMs;
}
