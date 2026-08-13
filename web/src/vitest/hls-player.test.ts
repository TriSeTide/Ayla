/**
 * player/hls.ts 单测（M5-4 文档 §7.1，mock hls.js）：
 * - Hls.isSupported() true → hls.js 分支：loadSource + attachMedia
 * - false → 原生 HLS 分支：video.src 直挂
 * - fatal networkError → startLoad() 重试；fatal mediaError → recoverMediaError()
 * - 其他 fatal → onFatalError 回调（UI 重试按钮）
 * - 非 fatal 错误不触发恢复动作
 * - destroy 幂等：重复调用不抛错
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// ---- mock hls.js（vi.mock 提升，工厂内自建 fake） ----
interface FakeHlsInstance {
  loadSource: ReturnType<typeof vi.fn>;
  attachMedia: ReturnType<typeof vi.fn>;
  startLoad: ReturnType<typeof vi.fn>;
  recoverMediaError: ReturnType<typeof vi.fn>;
  destroy: ReturnType<typeof vi.fn>;
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

function makeVideo(): HTMLVideoElement {
  return document.createElement("video");
}

beforeEach(() => {
  fakeInstances = [];
  mockIsSupported = true;
});

afterEach(() => {
  vi.clearAllMocks();
});

describe("HlsPlayer", () => {
  it("hls.js 分支：loadSource + attachMedia，返回 hls.js 模式", () => {
    const player = new HlsPlayer();
    const video = makeVideo();
    const mode = player.attach(video, "http://h/live/k.m3u8");
    expect(mode).toBe("hls.js");
    expect(player.getMode()).toBe("hls.js");
    const fake = fakeInstances[0];
    expect(fake.loadSource).toHaveBeenCalledWith("http://h/live/k.m3u8");
    expect(fake.attachMedia).toHaveBeenCalledWith(video);
    player.destroy();
  });

  it("原生 HLS 分支（Safari）：video.src 直挂，返回 native 模式", () => {
    mockIsSupported = false;
    const player = new HlsPlayer();
    const video = makeVideo();
    const mode = player.attach(video, "http://h/live/k.m3u8");
    expect(mode).toBe("native");
    expect(fakeInstances).toHaveLength(0);
    expect(video.src).toBe("http://h/live/k.m3u8");
    player.destroy();
  });

  it("fatal networkError → startLoad() 重试，不上报 fatal", () => {
    const player = new HlsPlayer();
    const onFatal = vi.fn();
    player.attach(makeVideo(), "u", { onFatalError: onFatal });
    const fake = fakeInstances[0];
    fake.handlers["hlsError"]("hlsError", {
      fatal: true,
      type: "networkError",
      details: "manifestLoadError",
    });
    expect(fake.startLoad).toHaveBeenCalledTimes(1);
    expect(onFatal).not.toHaveBeenCalled();
    player.destroy();
  });

  it("fatal mediaError → recoverMediaError()，不上报 fatal", () => {
    const player = new HlsPlayer();
    const onFatal = vi.fn();
    player.attach(makeVideo(), "u", { onFatalError: onFatal });
    const fake = fakeInstances[0];
    fake.handlers["hlsError"]("hlsError", {
      fatal: true,
      type: "mediaError",
      details: "bufferStalledError",
    });
    expect(fake.recoverMediaError).toHaveBeenCalledTimes(1);
    expect(onFatal).not.toHaveBeenCalled();
    player.destroy();
  });

  it("不可恢复 fatal → onFatalError 回调（UI 显示重试）", () => {
    const player = new HlsPlayer();
    const onFatal = vi.fn();
    player.attach(makeVideo(), "u", { onFatalError: onFatal });
    fakeInstances[0].handlers["hlsError"]("hlsError", {
      fatal: true,
      type: "otherError",
      details: "internalException",
    });
    expect(onFatal).toHaveBeenCalledWith("internalException");
    player.destroy();
  });

  it("非 fatal 错误不触发任何恢复动作", () => {
    const player = new HlsPlayer();
    const onFatal = vi.fn();
    player.attach(makeVideo(), "u", { onFatalError: onFatal });
    const fake = fakeInstances[0];
    fake.handlers["hlsError"]("hlsError", {
      fatal: false,
      type: "networkError",
      details: "fragLoadError",
    });
    expect(fake.startLoad).not.toHaveBeenCalled();
    expect(fake.recoverMediaError).not.toHaveBeenCalled();
    expect(onFatal).not.toHaveBeenCalled();
    player.destroy();
  });

  it("destroy 幂等：重复调用不抛错；销毁后错误事件不再回调", () => {
    const player = new HlsPlayer();
    const onFatal = vi.fn();
    player.attach(makeVideo(), "u", { onFatalError: onFatal });
    const fake = fakeInstances[0];
    player.destroy();
    expect(() => player.destroy()).not.toThrow();
    expect(fake.destroy).toHaveBeenCalledTimes(1);
    // destroy 后事件不再触发回调
    fake.handlers["hlsError"]("hlsError", {
      fatal: true,
      type: "otherError",
      details: "late",
    });
    expect(onFatal).not.toHaveBeenCalled();
    expect(player.getMode()).toBeNull();
  });

  it("重复 attach 先销毁旧实例", () => {
    const player = new HlsPlayer();
    player.attach(makeVideo(), "u1");
    player.attach(makeVideo(), "u2");
    expect(fakeInstances).toHaveLength(2);
    expect(fakeInstances[0].destroy).toHaveBeenCalledTimes(1);
    expect(fakeInstances[1].loadSource).toHaveBeenCalledWith("u2");
    player.destroy();
  });
});
