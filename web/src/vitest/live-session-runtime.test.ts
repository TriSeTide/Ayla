/**
 * liveSessionRuntime 契约测试（任务 05：直播适配手机端小窗）。
 *
 * 覆盖：
 * - enter 进房序列（详情 → 状态 → 历史 → WS 连接 → loading 收敛）；
 * - enter 幂等（同频道不重复进房；StrictMode 模拟重挂载安全）；
 * - detachView 小窗判定：窄屏 + 普通观看 + 直播中 → 小窗；宽屏/控制台/非直播 → 销毁；
 * - 小窗点回（enter 同频道）→ 退出小窗模式；
 * - leave 完整销毁（hls → WS → store → miniPlayer → video 元素）；
 * - 小窗模式下直播结束（轮询）→ 自动关闭小窗；
 * - video 元素跨容器迁移（attachVideoTo 同一元素）。
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as liveApi from "../api/live";
import { liveSessionRuntime } from "../runtime/liveSessionRuntime";
import { useLiveStore } from "../stores/live";
import { useSessionActivityStore } from "../stores/sessionActivity";
import { liveWS } from "../ws/live";
import { HlsPlayer } from "../player/hls";

vi.mock("../api/live", () => ({
  getLiveChannel: vi.fn(),
  getLiveChannelStatus: vi.fn(),
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

vi.mock("../player/hls", () => ({
  HlsPlayer: class {
    attach() {
      return "hls.js";
    }
    destroy() {}
    getMode() {
      return "hls.js";
    }
    refreshToLiveEdge() {}
  },
}));

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

beforeEach(() => {
  // 显式清 mock 调用记录（afterEach 的 clearAllMocks 在 leave 之后，双保险）
  vi.mocked(liveWS.disconnect).mockClear();
  vi.mocked(liveWS.connect).mockClear();
  // 按频道 id 返回对应频道（切频道测试依赖）
  vi.mocked(liveApi.getLiveChannel).mockImplementation(async (id: number) =>
    ({ ...channel, id, title: `直播${id}` }) as never,
  );
  vi.mocked(liveApi.getLiveChannelStatus).mockResolvedValue({ status: "live" } as never);
  vi.mocked(liveApi.listDanmaku).mockResolvedValue([] as never);
  useLiveStore.getState().reset();
  useSessionActivityStore.getState().reset();
});

afterEach(() => {
  liveSessionRuntime.leave();
  vi.clearAllMocks();
});

describe("liveSessionRuntime 进房", () => {
  it("enter 完成进房序列：详情 → 状态 → 历史 → WS 连接 → loading 收敛", async () => {
    liveSessionRuntime.enter(7, {});
    expect(useLiveStore.getState().currentLoading).toBe(true);
    await flush();
    expect(useLiveStore.getState().currentLoading).toBe(false);
    expect(useLiveStore.getState().current.channel?.id).toBe(7);
    expect(useLiveStore.getState().current.srsStatus).toBe("live");
    expect(liveWS.connect).toHaveBeenCalledWith(7);
    expect(liveWS.onFrame).toHaveBeenCalled();
  });

  it("enter 幂等：同频道重复 enter 不重复进房（StrictMode 安全）", async () => {
    liveSessionRuntime.enter(7, {});
    await flush();
    const calls = vi.mocked(liveApi.getLiveChannel).mock.calls.length;
    liveSessionRuntime.enter(7, {});
    await flush();
    expect(vi.mocked(liveApi.getLiveChannel).mock.calls.length).toBe(calls);
  });

  it("enter 切频道：先销毁旧会话再进新房（无残留）", async () => {
    liveSessionRuntime.enter(7, {});
    await flush();
    liveSessionRuntime.enter(8, {});
    await flush();
    expect(useLiveStore.getState().current.channel?.id).toBe(8);
    expect(liveWS.disconnect).toHaveBeenCalled();
  });
});

describe("liveSessionRuntime 小窗判定（detachView）", () => {
  it("窄屏 + 普通观看 + 直播中 → 进入小窗（会话保留）", async () => {
    liveSessionRuntime.enter(7, {});
    await flush();
    liveSessionRuntime.detachView({ isNarrow: true, isOwnerConsole: false });
    const mini = useLiveStore.getState().miniPlayer;
    expect(mini).not.toBeNull();
    expect(mini?.channelId).toBe(7);
    expect(mini?.sourceRoute).toBe("/live/7");
    // 会话保留：WS 未断开、store 未清
    expect(liveWS.disconnect).not.toHaveBeenCalled();
    expect(useLiveStore.getState().current.channel?.id).toBe(7);
  });

  it("宽屏 → 不进入小窗，完整销毁", async () => {
    liveSessionRuntime.enter(7, {});
    await flush();
    liveSessionRuntime.detachView({ isNarrow: false, isOwnerConsole: false });
    expect(useLiveStore.getState().miniPlayer).toBeNull();
    expect(liveWS.disconnect).toHaveBeenCalled();
    expect(useLiveStore.getState().current.channel).toBeNull();
  });

  it("主播开播控制台 → 不进入小窗（保持活动态悬浮球）", async () => {
    liveSessionRuntime.enter(7, {});
    await flush();
    liveSessionRuntime.detachView({ isNarrow: true, isOwnerConsole: true });
    expect(useLiveStore.getState().miniPlayer).toBeNull();
    expect(liveWS.disconnect).toHaveBeenCalled();
  });

  it("非直播中（idle）→ 不进入小窗，完整销毁", async () => {
    vi.mocked(liveApi.getLiveChannelStatus).mockResolvedValue({ status: "idle" } as never);
    liveSessionRuntime.enter(7, {});
    await flush();
    liveSessionRuntime.detachView({ isNarrow: true, isOwnerConsole: false });
    expect(useLiveStore.getState().miniPlayer).toBeNull();
    expect(liveWS.disconnect).toHaveBeenCalled();
  });

  it("小窗点回（enter 同频道）→ 退出小窗模式", async () => {
    liveSessionRuntime.enter(7, {});
    await flush();
    liveSessionRuntime.detachView({ isNarrow: true, isOwnerConsole: false });
    expect(useLiveStore.getState().miniPlayer).not.toBeNull();
    liveSessionRuntime.enter(7, {});
    expect(useLiveStore.getState().miniPlayer).toBeNull();
    // 会话未重建（幂等）
    expect(vi.mocked(liveApi.getLiveChannel).mock.calls.length).toBe(1);
  });
});

describe("liveSessionRuntime 销毁与资源", () => {
  it("leave 完整销毁：hls → WS → store → miniPlayer → video 元素", async () => {
    liveSessionRuntime.enter(7, {});
    await flush();
    liveSessionRuntime.attachPlayer();
    const video = liveSessionRuntime.getVideoElement();
    expect(video).not.toBeNull();
    liveSessionRuntime.detachView({ isNarrow: true, isOwnerConsole: false });
    expect(useLiveStore.getState().miniPlayer).not.toBeNull();

    liveSessionRuntime.leave();
    expect(useLiveStore.getState().miniPlayer).toBeNull();
    expect(useLiveStore.getState().current.channel).toBeNull();
    expect(useLiveStore.getState().currentLoading).toBe(false);
    expect(liveWS.disconnect).toHaveBeenCalled();
    expect(liveSessionRuntime.getVideoElement()).toBeNull();
    expect(video?.isConnected).toBe(false);
  });

  it("小窗模式下直播结束（轮询）→ 自动关闭小窗", async () => {
    vi.useFakeTimers();
    try {
      liveSessionRuntime.enter(7, {});
      await flush();
      liveSessionRuntime.detachView({ isNarrow: true, isOwnerConsole: false });
      expect(useLiveStore.getState().miniPlayer).not.toBeNull();
      // 下一次轮询返回非 live → 自动 leave
      vi.mocked(liveApi.getLiveChannelStatus).mockResolvedValue({ status: "idle" } as never);
      await vi.advanceTimersByTimeAsync(15_000);
      expect(useLiveStore.getState().miniPlayer).toBeNull();
      expect(useLiveStore.getState().current.channel).toBeNull();
    } finally {
      vi.useRealTimers();
    }
  });

  it("video 原子移动：attachVideoTo 移入容器、stashVideo 移回暂存，全程不脱离文档", async () => {
    liveSessionRuntime.enter(7, {});
    await flush();
    const video = liveSessionRuntime.getVideoElement();
    expect(video).not.toBeNull();
    // 初始在暂存容器（z-index:-1 视口内）
    expect(video?.parentElement?.className).toBe("live-video-staging");
    expect(video?.isConnected).toBe(true);
    const containerA = document.createElement("div");
    document.body.appendChild(containerA);
    liveSessionRuntime.attachVideoTo(containerA);
    expect(video?.parentElement).toBe(containerA);
    expect(video?.isConnected).toBe(true);
    // 原子移动到容器 B（源/目标都在文档中 → 不脱离）
    const containerB = document.createElement("div");
    document.body.appendChild(containerB);
    liveSessionRuntime.attachVideoTo(containerB);
    expect(video?.parentElement).toBe(containerB);
    expect(video?.isConnected).toBe(true);
    // stash 回暂存
    liveSessionRuntime.stashVideo();
    expect(video?.parentElement?.className).toBe("live-video-staging");
    expect(video?.isConnected).toBe(true);
    document.body.removeChild(containerA);
    document.body.removeChild(containerB);
  });

  it("attachPlayer 使用 runtime 持有的 video 元素并 attach HLS", async () => {
    const attachSpy = vi.spyOn(HlsPlayer.prototype, "attach");
    liveSessionRuntime.enter(7, {});
    await flush();
    const ok = liveSessionRuntime.attachPlayer();
    expect(ok).toBe(true);
    const video = liveSessionRuntime.getVideoElement();
    expect(attachSpy).toHaveBeenCalledWith(video, "http://h/7.m3u8", expect.any(Object));
    attachSpy.mockRestore();
  });
});
