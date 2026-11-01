/**
 * player/hls.ts —— refreshToLiveEdge 贴边目标（缺陷 R1）契约测试。
 *
 * 根因：refreshToLiveEdge 的 seekable 兜底分支直接 `seek(seekable.end())`。
 * seekable.end() 是 playlist 最后一个分片的边界，不是"可安全播放的直播边缘"——
 * seek 到它等于 seek 到尚未写完的位置（卡住/黑屏）。修复为 end 减去安全分片。
 *
 * 覆盖：
 * - hls.js 分支：有 liveSyncPosition → 用它（不落在 seekable 分支）；
 * - seekable 兜底：无 liveSyncPosition → end 回退 liveSyncDurationCount × targetDuration；
 * - 取不到分片时长 → 回退 2s（end - 2）；
 * - 回退后目标非正 → 退回 end（不 seek 到负时间）；
 * - 无 seekable → reload + play 兜底，返回 false（无法证明贴边）；
 * - 返回值：贴边成功 true、未挂载/已销毁 false。
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// ---- mock hls.js（与 hls-player.test.ts 同形，但暴露 config/levels 以便断言回退量） ----
interface FakeLevel {
  details: { targetduration?: number; averagetargetduration?: number } | null;
}
interface FakeHlsInstance {
  loadSource: ReturnType<typeof vi.fn>;
  attachMedia: ReturnType<typeof vi.fn>;
  startLoad: ReturnType<typeof vi.fn>;
  recoverMediaError: ReturnType<typeof vi.fn>;
  destroy: ReturnType<typeof vi.fn>;
  liveSyncPosition: number | null;
  config: { liveSyncDurationCount: number };
  levels: FakeLevel[];
  currentLevel: number;
  handlers: Record<string, (event: string, data: unknown) => void>;
  on: (event: string, cb: (event: string, data: unknown) => void) => void;
}

let fakeInstances: FakeHlsInstance[] = [];
let mockIsSupported = true;

vi.mock("hls.js", () => {
  class FakeHls {
    static Events = { ERROR: "hlsError" };
    static ErrorTypes = {
      NETWORK_ERROR: "networkError",
      MEDIA_ERROR: "mediaError",
      OTHER_ERROR: "otherError",
    };
    static isSupported() {
      return mockIsSupported;
    }
    loadSource = vi.fn();
    attachMedia = vi.fn();
    startLoad = vi.fn();
    recoverMediaError = vi.fn();
    destroy = vi.fn();
    liveSyncPosition: number | null = null;
    config = { liveSyncDurationCount: 2 };
    levels: FakeLevel[] = [];
    currentLevel = 0;
    handlers: Record<string, (event: string, data: unknown) => void> = {};
    on(event: string, cb: (event: string, data: unknown) => void) {
      this.handlers[event] = cb;
    }
    constructor() {
      fakeInstances.push(this as unknown as FakeHlsInstance);
    }
  }
  return { default: FakeHls };
});

import { HlsPlayer } from "../player/hls";

/**
 * jsdom 的 HTMLMediaElement 不实现 seekable（默认空 TimeRanges），
 * 用 defineProperty 覆盖成给定区间，才走 seekable 兜底分支。
 */
function makeVideo(seekableRanges: Array<[number, number]> = []): HTMLVideoElement {
  const video = document.createElement("video");
  const ranges = seekableRanges.map(([start, end]) => ({ start, end }));
  Object.defineProperty(video, "seekable", {
    configurable: true,
    get: () => ({
      length: ranges.length,
      start: (i: number) => ranges[i].start,
      end: (i: number) => ranges[i].end,
      item: (i: number) => ranges[i] ?? null,
    }),
  });
  // jsdom 未实现 play()/load()
  vi.spyOn(video, "play").mockResolvedValue(undefined);
  return video;
}

beforeEach(() => {
  fakeInstances = [];
  mockIsSupported = true;
});

afterEach(() => {
  vi.clearAllMocks();
  vi.restoreAllMocks();
});

describe("refreshToLiveEdge 贴边（R1）", () => {
  it("hls.js 分支：用 liveSyncPosition 贴边，返回 true（不走 seekable 回退）", () => {
    const player = new HlsPlayer();
    const video = makeVideo([[0, 66]]);
    player.attach(video, "u");
    fakeInstances[0].liveSyncPosition = 61.5;
    expect(player.refreshToLiveEdge()).toBe(true);
    expect(video.currentTime).toBe(61.5);
    player.destroy();
  });

  it("seekable 兜底：无 liveSyncPosition → seek 到 end - (liveSyncDurationCount × 分片时长)", () => {
    const player = new HlsPlayer();
    // playlist 边缘 100s；hls 默认 liveSyncDurationCount=2，分片 2s ⇒ 回退 4s
    const video = makeVideo([[0, 100]]);
    player.attach(video, "u");
    fakeInstances[0].liveSyncPosition = null;
    fakeInstances[0].config.liveSyncDurationCount = 2;
    fakeInstances[0].levels = [{ details: { targetduration: 2 } }];
    expect(player.refreshToLiveEdge()).toBe(true);
    expect(video.currentTime).toBe(96);
    player.destroy();
  });

  it("seekable 兜底：取不到分片时长 → 退回 end - 2s", () => {
    const player = new HlsPlayer();
    const video = makeVideo([[0, 100]]);
    player.attach(video, "u");
    fakeInstances[0].liveSyncPosition = null;
    fakeInstances[0].levels = []; // 无 level ⇒ 无 targetDuration
    expect(player.refreshToLiveEdge()).toBe(true);
    expect(video.currentTime).toBe(98);
    player.destroy();
  });

  it("seekable 兜底：回退量为 averagetargetduration 时同样参与计算", () => {
    const player = new HlsPlayer();
    const video = makeVideo([[0, 60]]);
    player.attach(video, "u");
    fakeInstances[0].liveSyncPosition = null;
    fakeInstances[0].config.liveSyncDurationCount = 3;
    fakeInstances[0].levels = [{ details: { averagetargetduration: 1 } }];
    expect(player.refreshToLiveEdge()).toBe(true);
    expect(video.currentTime).toBe(57);
    player.destroy();
  });

  it("seekable 兜底：回退后目标非正 → 退回 end 自身（不 seek 到负时间）", () => {
    const player = new HlsPlayer();
    const video = makeVideo([[0, 3]]);
    player.attach(video, "u");
    fakeInstances[0].liveSyncPosition = null;
    fakeInstances[0].config.liveSyncDurationCount = 2;
    fakeInstances[0].levels = [{ details: { targetduration: 4 } }]; // 回退 8s > end 3s
    expect(player.refreshToLiveEdge()).toBe(true);
    expect(video.currentTime).toBe(3);
    player.destroy();
  });

  it("原生分支无 seekable：reload + play 兜底，返回 false（未证明贴边）", () => {
    mockIsSupported = false;
    const player = new HlsPlayer();
    const video = makeVideo([]);
    const load = vi.spyOn(video, "load").mockImplementation(() => {});
    player.attach(video, "u");
    expect(player.refreshToLiveEdge()).toBe(false);
    expect(load).toHaveBeenCalled();
    player.destroy();
  });

  it("未挂载 / 已销毁：返回 false 且不抛错", () => {
    const player = new HlsPlayer();
    expect(player.refreshToLiveEdge()).toBe(false);
    const video = makeVideo([[0, 10]]);
    player.attach(video, "u");
    player.destroy();
    expect(player.refreshToLiveEdge()).toBe(false);
  });

  it("hls.js 分支但 liveSyncPosition 为 0/非有限值 → 落入 seekable 回退而不是 seek 到 0", () => {
    const player = new HlsPlayer();
    const video = makeVideo([[0, 40]]);
    player.attach(video, "u");
    fakeInstances[0].liveSyncPosition = 0;
    fakeInstances[0].config.liveSyncDurationCount = 2;
    fakeInstances[0].levels = [{ details: { targetduration: 1 } }];
    expect(player.refreshToLiveEdge()).toBe(true);
    expect(video.currentTime).toBe(38);
    player.destroy();
  });
});
