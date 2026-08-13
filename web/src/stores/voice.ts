/**
 * voice 全局状态（M5-3 §4.1）：频道列表 + 当前频道 + 成员表 + 连接状态。
 *
 * - members：user_id → 成员状态（joined/left/muted/heartbeat 由 voice.state 合并）；
 * - livekit：LiveKit 媒体连接状态（idle/connecting/connected/reconnecting/failed）；
 * - wsConnection：应用层 voice WS 状态（connecting/online/offline）；
 * - 离开/切换频道：清空 members + currentChannelId（LiveKit 断开与心跳停止由 hook 负责）。
 *
 * 纪律：
 * - 成员昵称/头像不复制到本 store，渲染层用 ensureUsers 懒拉缓存（api/users）；
 * - 爱莉条目（user_id = profile.user.id）只是普通成员 + UI 中性标签，无特殊数据源；
 * - muted 标记来自应用层 voice.state（muted/unmuted 帧）；媒体层静音事实以 LiveKit
 *   TrackMuted 事件为准（两者语义不同，见 M5-3 §4.3）。
 */
import { create } from "zustand";
import type { VoiceChannelDescriptor, VoiceMemberEventState } from "../api/types";

/** 单个成员的视图状态 */
export interface VoiceMemberState {
  user_id: string;
  joined_at: string;
  last_seen_at: string;
  /** 应用层静音标记（voice.state muted/unmuted；媒体事实以 LiveKit 为准） */
  muted: boolean;
  /** 本地播放音量 0~100（本地偏好，不落库、刷新重置） */
  volume: number;
}

export type LiveKitConnectionState =
  | "idle"
  | "connecting"
  | "connected"
  | "reconnecting"
  | "failed";

export type VoiceWSConnectionState = "connecting" | "online" | "offline";

interface VoiceState {
  channels: VoiceChannelDescriptor[];
  channelsLoading: boolean;
  error: string | null;
  /** 我正在的频道 id（null = 未加入任何频道） */
  currentChannelId: string | null;
  /** 当前频道成员表：user_id → 状态 */
  members: Record<string, VoiceMemberState>;
  livekit: LiveKitConnectionState;
  wsConnection: VoiceWSConnectionState;
  /** 我自己是否开麦（本地媒体事实，来自 LiveKit 封装层回写） */
  micEnabled: boolean;

  setChannels: (list: VoiceChannelDescriptor[]) => void;
  setChannelsLoading: (loading: boolean) => void;
  setError: (err: string | null) => void;
  /** 标记列表中某频道人数/我在其中（join/leave 后局部更新） */
  patchChannel: (channelId: string, patch: Partial<VoiceChannelDescriptor>) => void;

  /** 进入频道：设置当前频道并用 members/ 对账结果铺底 */
  enterChannel: (channelId: string, members: VoiceMemberState[]) => void;
  /** 离开/被移出：清空成员与当前频道（幂等） */
  leaveChannelLocal: () => void;

  /** voice.state 帧合并（仅处理当前频道；其他频道帧忽略） */
  applyVoiceState: (
    channelId: string,
    userId: string,
    state: VoiceMemberEventState,
    ts: string,
  ) => void;
  /** 成员对账：以服务端 members/ 为权威全量替换（WS 重连后调用） */
  reconcileMembers: (
    list: { user_id: string; joined_at: string; last_seen_at: string }[],
  ) => void;
  setMemberVolume: (userId: string, volume: number) => void;

  setLivekit: (s: LiveKitConnectionState) => void;
  setWsConnection: (s: VoiceWSConnectionState) => void;
  setMicEnabled: (enabled: boolean) => void;

  reset: () => void;
}

const INITIAL = {
  channels: [] as VoiceChannelDescriptor[],
  channelsLoading: false,
  error: null as string | null,
  currentChannelId: null as string | null,
  members: {} as Record<string, VoiceMemberState>,
  livekit: "idle" as LiveKitConnectionState,
  wsConnection: "offline" as VoiceWSConnectionState,
  micEnabled: false,
};

export const useVoiceStore = create<VoiceState>((set, get) => ({
  ...INITIAL,

  setChannels: (channels) => set({ channels, channelsLoading: false, error: null }),
  setChannelsLoading: (channelsLoading) => set({ channelsLoading }),
  setError: (error) => set({ error }),
  patchChannel: (channelId, patch) =>
    set((state) => ({
      channels: state.channels.map((c) => (c.id === channelId ? { ...c, ...patch } : c)),
    })),

  enterChannel: (channelId, members) =>
    set({
      currentChannelId: channelId,
      members: Object.fromEntries(members.map((m) => [m.user_id, m])),
    }),

  leaveChannelLocal: () =>
    set({ currentChannelId: null, members: {}, livekit: "idle", micEnabled: false }),

  applyVoiceState: (channelId, userId, state, ts) => {
    const s = get();
    if (s.currentChannelId !== channelId) return;
    const members = { ...s.members };
    switch (state) {
      case "joined":
        members[userId] = {
          user_id: userId,
          joined_at: ts,
          last_seen_at: ts,
          muted: members[userId]?.muted ?? false,
          volume: members[userId]?.volume ?? 100,
        };
        break;
      case "left":
        delete members[userId];
        break;
      case "muted":
      case "unmuted": {
        const existing = members[userId];
        if (existing) {
          members[userId] = { ...existing, muted: state === "muted", last_seen_at: ts };
        }
        break;
      }
      case "heartbeat": {
        const existing = members[userId];
        if (existing) {
          members[userId] = { ...existing, last_seen_at: ts };
        }
        break;
      }
    }
    set({ members });
  },

  reconcileMembers: (list) =>
    set((state) => {
      // 以对账结果为权威，但保留本地音量偏好（音量不落库）
      const members: Record<string, VoiceMemberState> = {};
      for (const m of list) {
        const prev = state.members[m.user_id];
        members[m.user_id] = {
          user_id: m.user_id,
          joined_at: m.joined_at,
          last_seen_at: m.last_seen_at,
          muted: prev?.muted ?? false,
          volume: prev?.volume ?? 100,
        };
      }
      return { members };
    }),

  setMemberVolume: (userId, volume) =>
    set((state) => {
      const existing = state.members[userId];
      if (!existing) return state;
      return {
        members: { ...state.members, [userId]: { ...existing, volume } },
      };
    }),

  setLivekit: (livekit) => set({ livekit }),
  setWsConnection: (wsConnection) => set({ wsConnection }),
  setMicEnabled: (micEnabled) => set({ micEnabled }),

  reset: () => set({ ...INITIAL, members: {} }),
}));
