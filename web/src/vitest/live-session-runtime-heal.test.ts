/**
 * liveSessionRuntime 自愈/幂等/画面槽位契约测试（缺陷 B2 / B3 / B6）。
 *
 * B2 自愈封顶后永久放弃：连续失败无时间窗重置，也没有封顶后的延迟重试。
 *    → REBUILD_COUNT_RESET_WINDOW_MS 时间窗归零 + 封顶后 60s 有界重试。
 * B3 attach 幂等只比 URL：实例已死但 URL 未变 ⇒ 永久黑屏。
 *    → 幂等判定加 video 健康（readyState / ended / error），不健康则销毁重建。
 * B6 状态补拉无条件重挂：小窗态下 attach 会把 video 抢回大窗。
 *    → 画面槽位守卫：小窗态不重挂、不动 video 元素、不销毁小窗在用的实例。
 *
 * 时间统一用 vi.useFakeTimers + setSystemTime(0) 控制（冷却 4s / 时间窗 60s）。
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as liveApi from "../api/live";
import { useLiveStore } from "../stores/live";
import { useSessionActivityStore } from "../stores/sessionActivity";
import { liveWS } from "../ws/live";

/** 假 HlsPlayer 实例记录（vi.hoisted：mock 工厂在模块求值前执行，不能引用普通 const） */
const h = vi.hoisted(() => ({
  instances: [] as Array<{
    video: HTMLVideoElement | null;
    url: string | null;
    fatal: ((detail: string) => void) | null;
    playlist: ((mediaSequence: number) => void) | null;
    destroyed: number;
  }>,
}));

vi.mock("../player/hls", () => ({
  HlsPlayer: class {
    inst = {
      video: null as HTMLVideoElement | null,
      url: null as string | null,
      fatal: null as ((detail: string) => void) | null,
      playlist: null as ((mediaSequence: number) => void) | null,
      destroyed: 0,
    };
    constructor() {
      h.instances.push(this.inst);
    }
    attach(
      video: HTMLVideoElement,
      url: string,
      callbacks: {
        onFatalError?: (detail: string) => void;
        onPlaylistLevelUpdated?: (mediaSequence: number) => void;
      } = {},
    ) {
      this.inst.video = video;
      this.inst.url = url;
      this.inst.fatal = callbacks.onFatalError ?? null;
      this.inst.playlist = callbacks.onPlaylistLevelUpdated ?? null;
      return "hls.js";
    }
    destroy() {
      this.inst.destroyed += 1;
    }
    getMode() {
      return "hls.js";
    }
    refreshToLiveEdge() {
      return true;
    }
  },
}));

vi.mock("../api/live", () => ({
  getLiveChannel: vi.fn(),
  getLiveChannelStatus: vi.fn(),
  getLiveChannelViewers: vi.fn(),
  listDanmaku: vi.fn(),
}));

vi.mock("../ws/live", () => ({
  liveWS: {
    onFrame: vi.fn(() => () => {}),
    onConnectionChange: null,
    onClosedByServer: null,
    onReconnected: null,
    connect: vi.fn(),
    disconnect: vi.fn(),
  },
}));

vi.mock("../ws/chat", () => ({
  chatWS: { onFrame: vi.fn(() => () => {}) },
}));

import {
  liveSessionRuntime,
  REBUILD_COOLDOWN_MS,
  STALL_TIMEOUT_MS,
  UPSTREAM_STALL_WINDOW_MS,
} from "../runtime/liveSessionRuntime";

/** 越过重建冷却所需的推进量（+1s 余量，避免边界相等） */
const PAST_COOLDOWN = REBUILD_COOLDOWN_MS + 1_000;

const channel = {
  id: 7,
  title: "测试直播间",
  status: "live",
  owner_id: "o1",
  owner_nickname: "主播",
  is_owner: false,
  visibility: "public",
  group: null,
  group_name: null,
  stream_key: null,
  rtmp_url: null,
  hls_url: "http://h/7.m3u8",
  flv_url: "http://h/7.flv",
  started_at: null,
  ended_at: null,
  created_at: "2026-01-01T00:00:00Z",
};

/** 推进微任务队列，让 enterAsync 的 await 链落地 */
async function flush(): Promise<void> {
  for (let i = 0; i < 8; i += 1) {
    await Promise.resolve();
  }
}

/**
 * jsdom 的 HTMLMediaElement 没有真实解码状态：用可写探针覆盖 readyState/ended/error，
 * 让"实例健康 / 实例已死"两个分支都可被驱动。
 */
function probeVideo(video: HTMLVideoElement) {
  const probe = {
    readyState: 0,
    ended: false,
    error: null as MediaError | null,
  };
  Object.defineProperty(video, "readyState", { configurable: true, get: () => probe.readyState });
  Object.defineProperty(video, "ended", { configurable: true, get: () => probe.ended });
  Object.defineProperty(video, "error", { configurable: true, get: () => probe.error });
  vi.spyOn(video, "play").mockResolvedValue(undefined);
  return probe;
}

/** 进房 + 等异步落地，返回可驱动状态的 video 探针 */
async function enterAndProbe(channelId = 7) {
  liveSessionRuntime.enter(channelId, {});
  await flush();
  const video = liveSessionRuntime.getVideoElement();
  if (!video) throw new Error("video 元素未创建");
  return { video, probe: probeVideo(video) };
}

/** 当前实例的 fatal 回调（HlsPlayer.attach 传入的 onFatalError） */
function fireFatal(detail = "fatal"): void {
  const inst = h.instances[h.instances.length - 1];
  if (!inst?.fatal) throw new Error("当前实例没有 fatal 回调");
  inst.fatal(detail);
}

/** 模拟 hls.js 上报 playlist 序号（LEVEL_UPDATED） */
function firePlaylist(mediaSequence: number): void {
  const inst = h.instances[h.instances.length - 1];
  if (!inst?.playlist) throw new Error("当前实例没有 playlist 回调");
  inst.playlist(mediaSequence);
}

beforeEach(() => {
  h.instances.length = 0;
  vi.useFakeTimers();
  vi.setSystemTime(0);
  vi.mocked(liveWS.disconnect).mockClear();
  vi.mocked(liveWS.connect).mockClear();
  vi.mocked(liveApi.getLiveChannel).mockImplementation(async (id: number) =>
    ({ ...channel, id, title: `直播${id}` }) as never,
  );
  vi.mocked(liveApi.getLiveChannelStatus).mockResolvedValue({ status: "live" } as never);
  vi.mocked(liveApi.getLiveChannelViewers).mockResolvedValue({
    channel_id: 7,
    count: 0,
    has_more: false,
    viewers: [],
  } as never);
  vi.mocked(liveApi.listDanmaku).mockResolvedValue([] as never);
  useLiveStore.getState().reset();
  useSessionActivityStore.getState().reset();
});

afterEach(() => {
  liveSessionRuntime.leave();
  vi.clearAllMocks();
  vi.restoreAllMocks();
  vi.useRealTimers();
});

describe("B3 幂等判定：URL + 实例健康", () => {
  it("实例健康 + 同 URL → 幂等命中，不重建", async () => {
    const { probe } = await enterAndProbe();
    expect(liveSessionRuntime.attachPlayer()).toBe(true);
    expect(h.instances).toHaveLength(1);
    probe.readyState = HTMLMediaElement.HAVE_CURRENT_DATA;
    expect(liveSessionRuntime.attachPlayer()).toBe(true);
    expect(h.instances).toHaveLength(1); // 未重建
    expect(h.instances[0].destroyed).toBe(0);
  });

  it("刚建实例尚在出帧宽限内 → 自动挂载不判死、不反复重建（防抖）", async () => {
    const { probe } = await enterAndProbe();
    expect(liveSessionRuntime.attachPlayer()).toBe(true);
    expect(h.instances).toHaveLength(1);
    // 新实例还没出帧（readyState=0），但仍在 4s 宽限内：页面 effect 反复调用不得重建
    probe.readyState = HTMLMediaElement.HAVE_NOTHING;
    expect(liveSessionRuntime.attachPlayer()).toBe(true);
    expect(liveSessionRuntime.attachPlayer()).toBe(true);
    expect(h.instances).toHaveLength(1);
    // 过了宽限仍是死的 ⇒ 真正判死并重建
    vi.advanceTimersByTime(PAST_COOLDOWN);
    expect(liveSessionRuntime.attachPlayer()).toBe(true);
    expect(h.instances).toHaveLength(2);
  });

  it("显式重试（retryPlayer）强制重建，不受出帧宽限限制", async () => {
    const { probe } = await enterAndProbe();
    expect(liveSessionRuntime.attachPlayer()).toBe(true);
    probe.readyState = HTMLMediaElement.HAVE_NOTHING;
    liveSessionRuntime.retryPlayer();
    expect(h.instances).toHaveLength(2);
    expect(h.instances[0].destroyed).toBe(1);
  });

  it("实例已死（readyState 不足）但 URL 未变 → 幂等命中被否决，销毁后重建", async () => {
    const { probe } = await enterAndProbe();
    liveSessionRuntime.attachPlayer();
    expect(h.instances).toHaveLength(1);
    probe.readyState = HTMLMediaElement.HAVE_NOTHING; // 实例已死但 URL 相同
    vi.advanceTimersByTime(PAST_COOLDOWN); // 越过出帧宽限
    expect(liveSessionRuntime.attachPlayer()).toBe(true);
    expect(h.instances).toHaveLength(2);
    expect(h.instances[0].destroyed).toBe(1);
    expect(h.instances[1].url).toBe("http://h/7.m3u8");
  });

  it("video.error 非空 → 视为实例已死，强制重建", async () => {
    const { probe } = await enterAndProbe();
    liveSessionRuntime.attachPlayer();
    probe.readyState = HTMLMediaElement.HAVE_ENOUGH_DATA;
    probe.error = { code: 3, message: "decode" } as MediaError;
    vi.advanceTimersByTime(PAST_COOLDOWN); // 越过出帧宽限
    liveSessionRuntime.attachPlayer();
    expect(h.instances).toHaveLength(2);
    expect(h.instances[0].destroyed).toBe(1);
  });

  it("video.ended（直播被判结束）→ 视为实例已死，强制重建", async () => {
    const { probe } = await enterAndProbe();
    liveSessionRuntime.attachPlayer();
    probe.readyState = HTMLMediaElement.HAVE_ENOUGH_DATA;
    probe.ended = true;
    vi.advanceTimersByTime(PAST_COOLDOWN); // 越过出帧宽限
    liveSessionRuntime.attachPlayer();
    expect(h.instances).toHaveLength(2);
  });
});

describe("B2 自愈：时间窗重置与封顶后的有界重试", () => {
  it("连续失败达上限 → 报播放失败，但 60s 后自动重建（不永久放弃）", async () => {
    const { probe } = await enterAndProbe();
    liveSessionRuntime.attachPlayer();
    expect(h.instances).toHaveLength(1);

    // 每次 fatal 间隔 5s（> 重建冷却 4s）⇒ 逐次重建：build 2/3/4
    for (let i = 0; i < 3; i += 1) {
      vi.advanceTimersByTime(PAST_COOLDOWN);
      fireFatal("boom");
    }
    expect(h.instances).toHaveLength(4);
    expect(useLiveStore.getState().currentPlayerError).toBeNull();

    // 第 4 次失败：计数已封顶（3）⇒ 报错 + 安排 60s 后重试
    vi.advanceTimersByTime(PAST_COOLDOWN);
    fireFatal("boom");
    expect(h.instances).toHaveLength(4);
    expect(useLiveStore.getState().currentPlayerError).toBe("boom");

    // 时间窗到 → 计数归零并重建一次（不再永久放弃）
    probe.readyState = HTMLMediaElement.HAVE_NOTHING;
    vi.advanceTimersByTime(60_000);
    expect(h.instances).toHaveLength(5);
    expect(useLiveStore.getState().currentPlayerError).toBeNull();
  });

  it("时间窗重置：距上次失败超过 60s 后计数归零，后续失败仍能重建", async () => {
    const { probe } = await enterAndProbe();
    liveSessionRuntime.attachPlayer();

    // 三次失败把连续计数推到上限（3），但每次都真实重建（未触发封顶报错）
    for (let i = 0; i < 3; i += 1) {
      vi.advanceTimersByTime(PAST_COOLDOWN);
      fireFatal("boom");
    }
    expect(h.instances).toHaveLength(4);
    expect(useLiveStore.getState().currentPlayerError).toBeNull();

    // 静默 61s（超过重置窗口）后再次失败 ⇒ 计数归零，重新允许重建
    vi.advanceTimersByTime(61_000);
    probe.readyState = HTMLMediaElement.HAVE_NOTHING;
    fireFatal("boom");
    expect(h.instances).toHaveLength(5);
    expect(useLiveStore.getState().currentPlayerError).toBeNull();
  });

  it("冷却期内连续 fatal 不立即重建，但不丢工作：延迟重试仍在排队", async () => {
    await enterAndProbe();
    liveSessionRuntime.attachPlayer();
    fireFatal("boom"); // 冷却期内（刚 attach）
    expect(h.instances).toHaveLength(1);
    expect(useLiveStore.getState().currentPlayerError).toBe("boom");
    // 时间窗到 → 仍然会重试一次
    vi.advanceTimersByTime(60_000);
    expect(h.instances).toHaveLength(2);
  });

  it("封顶后的延迟重试有界：画面已自行恢复则不重建（不制造多余重建）", async () => {
    const { probe } = await enterAndProbe();
    liveSessionRuntime.attachPlayer();
    for (let i = 0; i < 4; i += 1) {
      vi.advanceTimersByTime(PAST_COOLDOWN);
      fireFatal("boom");
    }
    expect(h.instances).toHaveLength(4);
    probe.readyState = HTMLMediaElement.HAVE_ENOUGH_DATA; // 自行恢复
    vi.advanceTimersByTime(60_000);
    expect(h.instances).toHaveLength(4);
  });

  it("leave 清掉延迟重试定时器：不残留重建（生命周期幂等）", async () => {
    await enterAndProbe();
    liveSessionRuntime.attachPlayer();
    for (let i = 0; i < 4; i += 1) {
      vi.advanceTimersByTime(PAST_COOLDOWN);
      fireFatal("boom");
    }
    expect(useLiveStore.getState().currentPlayerError).toBe("boom");
    liveSessionRuntime.leave();
    const before = h.instances.length;
    vi.advanceTimersByTime(120_000);
    expect(h.instances).toHaveLength(before);
  });

  it("出帧（playing）视为自愈成功：连续失败计数归零", async () => {
    const { video, probe } = await enterAndProbe();
    liveSessionRuntime.attachPlayer();
    vi.advanceTimersByTime(PAST_COOLDOWN);
    fireFatal("boom"); // 计数 1

    probe.readyState = HTMLMediaElement.HAVE_ENOUGH_DATA;
    video.dispatchEvent(new Event("playing")); // 出帧 ⇒ 计数归零
    await flush();

    // 再失败三次仍可重建（若计数未归零，第 3 次就会封顶）
    for (let i = 0; i < 3; i += 1) {
      vi.advanceTimersByTime(PAST_COOLDOWN);
      fireFatal("boom");
      expect(useLiveStore.getState().currentPlayerError).toBeNull();
    }
  });
});

describe("B6 画面槽位守卫：小窗态不抢流", () => {
  it("小窗态 attachPlayer 不重建、不动 video 元素（画面归小窗）", async () => {
    const { video, probe } = await enterAndProbe();
    probe.readyState = HTMLMediaElement.HAVE_ENOUGH_DATA;
    liveSessionRuntime.attachPlayer();
    expect(h.instances).toHaveLength(1);

    // 进入小窗：video 由 attachVideoTo 原子迁移到小窗容器
    liveSessionRuntime.detachView({ isNarrow: true, isOwnerConsole: false });
    expect(useLiveStore.getState().miniPlayer).not.toBeNull();
    const miniContainer = document.createElement("div");
    miniContainer.className = "live-mini-player";
    document.body.appendChild(miniContainer);
    liveSessionRuntime.attachVideoTo(miniContainer);
    expect(video.parentElement).toBe(miniContainer);

    // 小窗期间状态补拉/页面侧 attach → 必须不抢流
    expect(liveSessionRuntime.attachPlayer()).toBe(false);
    expect(h.instances).toHaveLength(1);
    expect(h.instances[0].destroyed).toBe(0);
    expect(video.parentElement).toBe(miniContainer);
    miniContainer.remove();
  });

  it("小窗态 refreshPlayer 不重建（刷新键交回页面侧处理）", async () => {
    const { probe } = await enterAndProbe();
    probe.readyState = HTMLMediaElement.HAVE_ENOUGH_DATA;
    liveSessionRuntime.attachPlayer();
    liveSessionRuntime.detachView({ isNarrow: true, isOwnerConsole: false });
    expect(liveSessionRuntime.refreshPlayer()).toBe(false);
    expect(h.instances).toHaveLength(1);
  });

  it("出帧一次后 watchdog 仍然有效：后续卡死仍会自愈重建", async () => {
    // 回归锁（2026-11-05）：旧实现 clearStallTimer() 顺带拆掉 5 个监听器，
    // 而 onResume（playing/canplay 出帧）会调用它 ⇒ 播放器出过一次画面后
    // 永久失去卡死检测，之后的定格再也不会被自愈。服务端日志曾印证：
    // 上游停摆 151s 期间客户端重建 0 次、fatal 0 次。
    const { video, probe } = await enterAndProbe();
    liveSessionRuntime.attachPlayer();
    expect(h.instances).toHaveLength(1);

    // 1) 先出帧（模拟正常播放起来）—— 这一步旧实现会把 watchdog 拆掉
    probe.readyState = HTMLMediaElement.HAVE_ENOUGH_DATA;
    video.dispatchEvent(new Event("playing"));
    await flush();

    // 2) 越过重建冷却后制造一次真正的卡死
    vi.advanceTimersByTime(PAST_COOLDOWN);
    probe.readyState = HTMLMediaElement.HAVE_NOTHING;
    video.dispatchEvent(new Event("waiting"));
    vi.advanceTimersByTime(STALL_TIMEOUT_MS);

    // 3) 仍然必须被检出并重建
    expect(h.instances).toHaveLength(2);
    expect(h.instances[0].destroyed).toBe(1);
  });

  it("上游停摆：playlist 序号停滞超过窗口 → 上报中断提示", async () => {
    await enterAndProbe();
    liveSessionRuntime.attachPlayer();
    expect(useLiveStore.getState().currentPlayerError).toBeNull();

    // 序号推进：不报错
    firePlaylist(100);
    vi.advanceTimersByTime(UPSTREAM_STALL_WINDOW_MS - 1_000);
    firePlaylist(101);
    vi.advanceTimersByTime(UPSTREAM_STALL_WINDOW_MS - 1_000);
    expect(useLiveStore.getState().currentPlayerError).toBeNull();

    // 序号不再前进 ⇒ 越过窗口后必须报错
    vi.advanceTimersByTime(UPSTREAM_STALL_WINDOW_MS + 1_000);
    expect(useLiveStore.getState().currentPlayerError).toContain("直播流已中断");

    // 恢复产片 ⇒ 提示自动清除
    firePlaylist(102);
    expect(useLiveStore.getState().currentPlayerError).toBeNull();
  });

  it("上游停摆不触发重建（重建也拉不到数据）", async () => {
    await enterAndProbe();
    liveSessionRuntime.attachPlayer();
    expect(h.instances).toHaveLength(1);
    firePlaylist(200);
    vi.advanceTimersByTime(UPSTREAM_STALL_WINDOW_MS * 3);
    expect(h.instances).toHaveLength(1);
    expect(h.instances[0].destroyed).toBe(0);
  });

  it("小窗态 watchdog 卡死不自愈重建（避免与大窗抢流）", async () => {
    const { video, probe } = await enterAndProbe();
    probe.readyState = HTMLMediaElement.HAVE_ENOUGH_DATA;
    liveSessionRuntime.attachPlayer();
    liveSessionRuntime.detachView({ isNarrow: true, isOwnerConsole: false });
    vi.advanceTimersByTime(PAST_COOLDOWN); // 越过重建冷却
    probe.readyState = HTMLMediaElement.HAVE_NOTHING;
    video.dispatchEvent(new Event("waiting"));
    vi.advanceTimersByTime(STALL_TIMEOUT_MS);
    expect(h.instances).toHaveLength(1);
  });

  it("退出小窗（enter 同频道）后 attachPlayer 恢复可用", async () => {
    const { video, probe } = await enterAndProbe();
    probe.readyState = HTMLMediaElement.HAVE_ENOUGH_DATA;
    liveSessionRuntime.attachPlayer();
    liveSessionRuntime.detachView({ isNarrow: true, isOwnerConsole: false });
    expect(useLiveStore.getState().miniPlayer).not.toBeNull();
    const miniContainer = document.createElement("div");
    document.body.appendChild(miniContainer);
    liveSessionRuntime.attachVideoTo(miniContainer);

    liveSessionRuntime.enter(7, {}); // 小窗点回
    expect(useLiveStore.getState().miniPlayer).toBeNull();
    const bigHost = document.createElement("div");
    document.body.appendChild(bigHost);
    liveSessionRuntime.attachVideoTo(bigHost, { big: true });
    expect(video.parentElement).toBe(bigHost);
    // 大窗接管后实例已死才重建（幂等仍生效）
    probe.readyState = HTMLMediaElement.HAVE_NOTHING;
    vi.advanceTimersByTime(PAST_COOLDOWN); // 越过出帧宽限
    expect(liveSessionRuntime.attachPlayer()).toBe(true);
    expect(h.instances).toHaveLength(2);
    miniContainer.remove();
    bigHost.remove();
  });
});
