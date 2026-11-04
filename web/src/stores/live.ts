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
  LiveViewerItem,
} from "../api/types";
import { sortLiveChannels } from "../utils/sortChannels";

/** 实时弹幕队列上限；完整历史由 useCursorHistory 通过 cursor/before_id 独立续读。 */
export const DANMAKU_MAX_ITEMS = 500;

/**
 * 观众端（看别人的直播）静音偏好存储键：值 "1" = 静音；无记录 = 有声音（缺省）。
 * 键名保持 68a4e93 的现状，已存用户偏好继续生效，不做迁移。
 */
export const LIVE_MUTED_STORAGE_KEY = "ayla.live.muted";

/**
 * 开播控制台（自己的直播间，showOwnerPanel / is_owner）静音偏好存储键。
 * 与观众端分开存：主播在自己控制台静音只是"控制台不要出声"，不能把他去别人直播间
 * 的观看偏好也改成静音。值 "1" = 用户显式静音；无记录 = 缺省（静音）。
 */
export const LIVE_OWNER_MUTED_STORAGE_KEY = "ayla.live.owner.muted";

/**
 * 各端静音偏好的缺省值：观众端缺省有声（用户来看直播就是要听声音），
 * 开播端缺省静音（自己的控制台主要用来盯画面/调试，声音是额外打扰）。
 */
export function defaultLiveMuted(owner: boolean): boolean {
  return owner;
}

/**
 * 读取静音偏好（owner=true 读开播端，缺省静音；否则读观众端，缺省有声）。
 * 存储不可用（隐私模式/被禁用/无 localStorage）时回退到**该端自己的**缺省值：
 * 静音必须是用户的显式选择，不能因为读不到偏好就替观众关掉声音。
 */
export function readLiveMuted(owner = false): boolean {
  try {
    if (owner) {
      // 开播端缺省静音：没有记录 = 静音（产品要求"开播界面默认把声音关掉"）。
      // 取消静音会删键回到缺省（见 writeLiveMuted），所以"开声"只对当场生效，
      // 下次打开控制台依旧安静——这是刻意的产品语义，不是漏掉持久化。
      // 仍兼容读取 "0"，将来若要支持"记住开声"只需改写侧、不必动读侧契约。
      const raw = localStorage.getItem(LIVE_OWNER_MUTED_STORAGE_KEY);
      return raw === null ? defaultLiveMuted(true) : raw !== "0";
    }
    return localStorage.getItem(LIVE_MUTED_STORAGE_KEY) === "1";
  } catch {
    return defaultLiveMuted(owner);
  }
}

/**
 * 写入静音偏好（owner 语义同 readLiveMuted）。
 * 取消静音时删除键，不存 "0"——避免"从没静音过"与"曾取消静音"变成两种需要迁移的状态。
 * 开播端由此得到一个明确的产品语义：**取消静音只对当前这场生效**，下次打开控制台
 * 仍回到缺省的静音（用户要的是"开播界面默认不吵"，不是记住某次临时开声）。
 * 存储不可用/写满时静默：偏好只在本会话内存生效，不阻断播放。
 */
export function writeLiveMuted(muted: boolean, owner = false): void {
  try {
    const key = owner ? LIVE_OWNER_MUTED_STORAGE_KEY : LIVE_MUTED_STORAGE_KEY;
    if (muted) localStorage.setItem(key, "1");
    else localStorage.removeItem(key);
  } catch {
    // 存储不可用：静默降级，播放不受影响
  }
}

export interface LiveRoomState {
  channel: LiveChannelDescriptor | null;
  /** SRS 实时判定（权威）；null = 尚未查询，UI 用乐观 status 兜底并标注 */
  srsStatus: LiveSrsStatus | null;
  /** 升序，按 id 去重 */
  danmaku: DanmakuItem[];
  /** 当前在看人数（弹幕 WS 连接数）；null = 未知（presence 存储不可用 / 尚未读到） */
  viewerCount: number | null;
  /** 在看观众预览（后端上限 12 位，最近活跃优先）；完整名单走 REST */
  viewers: LiveViewerItem[];
}

/** 手机端 App 内浮动小窗（任务 05）：离开直播间页面后继续播放的迷你播放器状态。
 *  会话资源（HLS/video/SRS 状态/WS）由 liveSessionRuntime 持有，这里只放 UI 投影。 */
export interface MiniPlayerState {
  channelId: number;
  channel: LiveChannelDescriptor | null;
  /** 点回直播间时导航的目标路由（一级直播默认 /live/:id，群内直播为群场景路由） */
  sourceRoute: string;
}

interface LiveState {
  channels: LiveChannelDescriptor[];
  channelsLoading: boolean;
  error: string | null;
  current: LiveRoomState;
  /** 弹幕 WS 连接状态（供 UI 展示） */
  wsConnection: "connecting" | "online" | "offline";
  /** 当前直播间进房加载中（liveSessionRuntime 写入） */
  currentLoading: boolean;
  /** 当前直播间进房失败文案（liveSessionRuntime 写入） */
  currentError: string | null;
  /** 当前直播间播放器 fatal 错误（liveSessionRuntime 写入） */
  currentPlayerError: string | null;
  /** 手机端浮动小窗状态；null = 无小窗（唯一 owner，同一时间至多一个） */
  miniPlayer: MiniPlayerState | null;
  /**
   * 直播静音状态（喇叭按钮与 video.muted 的 UI 投影，权威偏好在 localStorage）。
   * 跨直播间保留：换台不清空（用户选的是"这场直播要不要出声"，不是某个频道的属性）。
   * 具体读写哪一套偏好由 mutedOwner 决定。
   */
  muted: boolean;
  /**
   * 当前会话是否开播控制台语义（决定 muted 对应哪套偏好：开播端 `ayla.live.owner.muted`
   * 缺省静音 / 观众端 `ayla.live.muted` 缺省有声）。
   * 由 runtime.enter 按 isOwnerConsole 写入；**只有 runtime 会改它**，UI 只读。
   */
  mutedOwner: boolean;
  lastFetched: number | null;
  /** 最近一次列表请求是否携带 only_live=1；null 表示尚未按筛选条件请求。 */
  channelsOnlyLive: boolean | null;

  setChannels: (list: LiveChannelDescriptor[], onlyLive?: boolean) => void;
  setChannelsLoading: (loading: boolean) => void;
  setError: (error: string | null) => void;
  upsertChannel: (channel: LiveChannelDescriptor) => void;
  updateChannelStatus: (channelId: number, status: string) => void;
  removeChannel: (channelId: number) => void;

  setCurrentChannel: (channel: LiveChannelDescriptor | null) => void;
  setSrsStatus: (status: LiveSrsStatus | null) => void;
  setWsConnection: (conn: "connecting" | "online" | "offline") => void;
  setCurrentLoading: (loading: boolean) => void;
  setCurrentError: (error: string | null) => void;
  setCurrentPlayerError: (error: string | null) => void;
  setMiniPlayer: (mini: MiniPlayerState | null) => void;
  /**
   * 更新静音 UI 投影（不写存储）。偏好写入只由 runtime.setMuted()（用户手势）负责，
   * video 元素的 muted 也由 runtime 应用——store 只是投影。
   */
  setMuted: (muted: boolean) => void;
  /** 切换当前会话的端语义（开播控制台 ↔ 观众端）；同样只镜像，不写存储。 */
  setMutedOwner: (owner: boolean) => void;

  /** 房内在看人数/预览（弹幕 WS `viewers` 帧或 REST 快照）；仅对当前直播间生效 */
  setViewers: (channelId: number, count: number, viewers: LiveViewerItem[]) => void;
  /**
   * 按频道 id patch 在看人数（chat WS `live.viewers.changed`）：更新大厅/群内列表项
   * 与当前直播间。人数是瞬态投影，**不参与排序**——重排由 useDirectoryPage 的
   * sortIdentity 决定（只含 status/时间），这里只替换描述符。
   */
  patchViewerCount: (channelId: number, count: number) => void;
  /** 在看人数未知（presence 不可用）：清空人数而不写 0，UI 隐藏人数展示 */
  clearViewers: () => void;

  /** 追加单条弹幕（WS 回帧 / POST 之外的来源），按 id 去重、定长截断 */
  appendDanmaku: (item: DanmakuItem) => void;
  /** 旧消费者兼容；当前可见历史页不写回此实时队列，避免重播 overlay。 */
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
  viewerCount: null,
  viewers: [],
};

const initialState = {
  channels: [],
  channelsLoading: false,
  error: null,
  current: initialRoom,
  wsConnection: "offline" as const,
  currentLoading: false,
  currentError: null,
  currentPlayerError: null,
  miniPlayer: null,
  muted: false,
  mutedOwner: false,
  lastFetched: null,
  channelsOnlyLive: null,
};

/** 按频道 id 替换列表项的在看人数；未加载的频道原样返回（不凭空插入条目）。 */
function patchChannels(
  channels: LiveChannelDescriptor[],
  channelId: number,
  count: number,
): LiveChannelDescriptor[] {
  if (!channels.some((c) => c.id === channelId && c.viewer_count !== count)) return channels;
  return channels.map((c) => (c.id === channelId ? { ...c, viewer_count: count } : c));
}

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
  ...initialState,
  // 冷启动按已保存的偏好初始化（刷新后仍保持用户上次的选择）。
  // 读在 create 回调里而不是模块顶层：测试/SSR 下 localStorage 可能晚于模块存在。
  muted: readLiveMuted(),
  mutedOwner: false,

  setChannels: (list, onlyLive = false) =>
    set({
      channels: sortLiveChannels(list),
      channelsLoading: false,
      error: null,
      lastFetched: Date.now(),
      channelsOnlyLive: onlyLive,
    }),
  setChannelsLoading: (loading) => set({ channelsLoading: loading }),
  setError: (error) => set({ error, channelsLoading: false }),

  upsertChannel: (channel) =>
    set((state) => {
      const idx = state.channels.findIndex((c) => c.id === channel.id);
      const merged =
        idx >= 0
          ? state.channels.map((c) => (c.id === channel.id ? channel : c))
          : [...state.channels, channel];
      const channels = sortLiveChannels(merged);
      const current = state.current.channel?.id === channel.id
        ? { ...state.current, channel }
        : state.current;
      return { channels, current };
    }),

  updateChannelStatus: (channelId, status) =>
    set((state) => ({
      channels: sortLiveChannels(
        state.channels.map((c) =>
          c.id === channelId ? { ...c, status: status as LiveChannelStatus } : c
        ),
      ),
      current: state.current.channel?.id === channelId
        ? { ...state.current, channel: { ...state.current.channel, status: status as LiveChannelStatus } }
        : state.current,
    })),


  removeChannel: (channelId) =>
    set((state) => ({
      channels: state.channels.filter((c) => c.id !== channelId),
      current: state.current.channel?.id === channelId ? initialRoom : state.current,
    })),

  setCurrentChannel: (channel) =>
    set((state) => ({ current: { ...state.current, channel } })),

  setSrsStatus: (status) =>
    set((state) => ({ current: { ...state.current, srsStatus: status } })),

  setWsConnection: (conn) => set({ wsConnection: conn }),

  setCurrentLoading: (loading) => set({ currentLoading: loading }),

  setCurrentError: (error) => set({ currentError: error }),

  setCurrentPlayerError: (error) => set({ currentPlayerError: error }),

  setMiniPlayer: (mini) => set({ miniPlayer: mini }),

  /**
   * 只镜像 UI 投影，**不写 localStorage**。
   * 写偏好是「用户手势」的语义，唯一入口是 runtime.setMuted()（音量键点击）；
   * ensureVideo()/retrySound() 的失败分支这些**非手势**路径也会调本 action，
   * 若在这里写存储，就会把用户偏好改写成"静音"——比如用户明明偏好有声，
   * 只是还没等到 playing 事件，或者浏览器拒绝自动出声，偏好就被永久写脏了。
   */
  setMuted: (muted) => set({ muted }),

  setMutedOwner: (owner) => set({ mutedOwner: owner }),

  setViewers: (channelId, count, viewers) =>
    set((state) => {
      const current = state.current.channel?.id === channelId
        ? { ...state.current, viewerCount: count, viewers }
        : state.current;
      return { current, channels: patchChannels(state.channels, channelId, count) };
    }),

  patchViewerCount: (channelId, count) =>
    set((state) => {
      const current = state.current.channel?.id === channelId
        ? { ...state.current, viewerCount: count }
        : state.current;
      return { current, channels: patchChannels(state.channels, channelId, count) };
    }),

  clearViewers: () =>
    set((state) => ({
      current: { ...state.current, viewerCount: null, viewers: [] },
    })),

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

  /**
   * 退房清理：清当前直播间、弹幕与会话 UI 状态，保留大厅列表（miniPlayer 由 runtime 显式管理）。
   * **不动 muted**：静音是用户偏好，跨直播间/跨场次保留，换台不该让声音突然炸出来。
   */
  clearCurrent: () =>
    set({
      current: initialRoom,
      wsConnection: "offline",
      currentLoading: false,
      currentError: null,
      currentPlayerError: null,
    }),

  /**
   * 全量重置（退出登录/测试基线）：muted 回到**观众端**已持久化的偏好，而不是硬编码默认值
   * （reset 之后没有会话，端语义回到缺省的观众端）。
   */
  reset: () =>
    set({
      ...initialState,
      muted: readLiveMuted(),
      mutedOwner: false,
    }),
}));

/** 判断 live store 数据是否过期（默认 60 秒） */
export function isLiveStale(maxAgeMs = 60_000): boolean {
  const { lastFetched } = useLiveStore.getState();
  if (!lastFetched) return true;
  return Date.now() - lastFetched > maxAgeMs;
}
