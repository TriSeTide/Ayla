/**
 * createLiveKitRoom 契约测试（mock livekit-client 模块）：
 * - 连接后 attach 已存在的远端音频轨道（TrackSubscribed 不覆盖此场景，
 *   缺了会导致「先进房者开麦，后进房者听不到他」——F11 语音修复）；
 * - TrackSubscribed 新订阅的音频轨道同样 attach；
 * - 非音频轨道（video）不 attach；
 * - TrackUnsubscribed 时 detach；
 * - remoteParticipants / 事件 identity 剥离 `user_` 前缀（音量匹配关键）；
 * - 本地麦克风音量监测：帧驱动（rAF + 100ms 节流），有本地轨道时回调
 *   calculateVolume；无轨道时帧循环不启动（零开销），轨道事件触发启停。
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const h = vi.hoisted(() => {
  const onHandlers: Record<string, ((...args: unknown[]) => void)[]> = {};
  const allRooms: RoomMock[] = [];

  class RoomMock {
    on = vi.fn((evt: string, cb: (...a: unknown[]) => void) => {
      (onHandlers[evt] = onHandlers[evt] ?? []).push(cb);
    });
    removeAllListeners = vi.fn();
    connect = vi.fn(async () => undefined);
    disconnect = vi.fn(async () => undefined);
    startAudio = vi.fn(async () => undefined);
    localParticipant = {
      setMicrophoneEnabled: vi.fn(async () => undefined),
      isMicrophoneEnabled: false,
      audioTrackPublications: new Map(),
    };
    remoteParticipants = new Map();

    constructor() {
      allRooms.push(this);
    }
  }

  const analyserMock = {
    calculateVolume: vi.fn(() => 0),
    cleanup: vi.fn(async () => undefined),
    analyser: {
      context: {
        state: "running" as string,
        resume: vi.fn(async () => undefined),
      },
      // livekit createAudioAnalyser 默认 0.8（声音停止后衰减滞后，跳动条"没声了还亮着"）
      smoothingTimeConstant: 0.8,
    },
  };

  function emit(evt: string, ...args: unknown[]) {
    for (const cb of onHandlers[evt] ?? []) cb(...args);
  }

  function clearAll() {
    for (const k of Object.keys(onHandlers)) delete onHandlers[k];
    allRooms.length = 0;
  }

  return {
    RoomMock,
    emit,
    clearAll,
    analyserMock,
    lastRoom: () => allRooms[allRooms.length - 1] ?? null,
  };
});

vi.mock("livekit-client", () => ({
  Room: h.RoomMock,
  // 真实 createAudioAnalyser 是同步返回对象（不是 Promise）——mock 必须同步
  createAudioAnalyser: vi.fn(() => h.analyserMock),
}));

import { createLiveKitRoom } from "../livekit/client";

type RoomMockInstance = InstanceType<typeof h.RoomMock>;
type LiveKitEvents = Parameters<typeof createLiveKitRoom>[0];

function makeRemoteTrack() {
  const el = document.createElement("audio");
  return {
    track: {
      kind: "audio",
      attach: vi.fn(() => el),
      detach: vi.fn(() => [el]),
    },
    el,
  };
}

/** 本地音频轨道 mock（带 processor 方法面，供 setLocalVolume 测试） */
function makeLocalTrack() {
  return {
    kind: "audio",
    setProcessor: vi.fn<(proc: unknown) => Promise<void>>(async () => undefined),
    stopProcessor: vi.fn(async () => undefined),
    getProcessor: vi.fn(() => undefined),
  };
}

function audioContainer() {
  return document.getElementById("ayla-voice-audio") as HTMLDivElement;
}

/** 调用 createLiveKitRoom（内部 new 一个 mock Room），返回其实例 + client */
async function makeClient(events: LiveKitEvents = {}) {
  const client = await createLiveKitRoom(events);
  const room = h.lastRoom() as RoomMockInstance;
  expect(room).not.toBeNull();
  return { client, room };
}

/**
 * 手动驱动 rAF 的测试时钟（rAF 帧驱动语义）：
 * - stub requestAnimationFrame/cancelAnimationFrame（id → 回调映射，cancel 真实取消）；
 * - stub performance.now 每次调用递增 17ms（模拟帧间隔，驱动 100ms 节流）；
 * - flush(n) 执行 n 帧排队回调（回调里新排队的帧进入下一轮 flush）。
 */
function stubRafClock() {
  const rafMap = new Map<number, () => void>();
  let rafId = 0;
  let nowValue = 0;
  vi.stubGlobal("requestAnimationFrame", (cb: () => void) => {
    rafMap.set(++rafId, cb);
    return rafId;
  });
  vi.stubGlobal("cancelAnimationFrame", (id: number) => {
    rafMap.delete(id);
  });
  vi.stubGlobal("performance", { now: () => (nowValue += 17) });
  return {
    /** 逐帧执行（默认 20 帧 ≈ 340ms，至少覆盖 2~3 个节流周期） */
    flush: (n = 20) => {
      for (let i = 0; i < n; i += 1) {
        const pending = [...rafMap.entries()];
        rafMap.clear();
        for (const [, cb] of pending) cb();
      }
    },
  };
}

beforeEach(() => {
  h.clearAll();
});

afterEach(() => {
  vi.clearAllMocks();
  audioContainer()?.remove();
  h.clearAll();
  vi.unstubAllGlobals();
});

describe("createLiveKitRoom", () => {
  it("连接后 attach 已存在的远端音频轨道（TrackSubscribed 不覆盖此场景）", async () => {
    const a = makeRemoteTrack();
    const b = makeRemoteTrack();
    const { client, room } = await makeClient();
    room.remoteParticipants.set("u_old", {
      identity: "u_old",
      audioTrackPublications: new Map([
        ["0", { track: a.track }],
        ["1", { track: b.track }],
      ]),
      videoTrackPublications: new Map(),
    });

    await client.connect("ws://lk", "token");

    expect(a.track.attach).toHaveBeenCalledTimes(1);
    expect(b.track.attach).toHaveBeenCalledTimes(1);
    const container = audioContainer();
    expect(container).not.toBeNull();
    expect(container.contains(a.el)).toBe(true);
    expect(container.contains(b.el)).toBe(true);
  });

  it("TrackSubscribed 新订阅的音频轨道也 attach", async () => {
    const { track, el } = makeRemoteTrack();
    const { client } = await makeClient();
    await client.connect("ws://lk", "token");

    h.emit("trackSubscribed", track);
    const container = audioContainer();
    expect(container).not.toBeNull();
    expect(container.contains(el)).toBe(true);
  });

  it("视频轨道不 attach（只处理 audio）", async () => {
    const audio = makeRemoteTrack();
    const videoEl = document.createElement("video");
    const videoTrack = { kind: "video", attach: vi.fn(() => videoEl), detach: vi.fn(() => [videoEl]) };
    const { client, room } = await makeClient();
    room.remoteParticipants.set("u_video", {
      identity: "u_video",
      audioTrackPublications: new Map([["0", { track: audio.track }]]),
      videoTrackPublications: new Map([["0", { track: videoTrack }]]),
    });

    await client.connect("ws://lk", "token");

    expect(audio.track.attach).toHaveBeenCalledTimes(1);
    expect(videoTrack.attach).not.toHaveBeenCalled();
  });

  it("TrackUnsubscribed 时 detach 音频轨道", async () => {
    const { track } = makeRemoteTrack();
    const { client } = await makeClient();
    await client.connect("ws://lk", "token");

    h.emit("trackUnsubscribed", track);
    expect(track.detach).toHaveBeenCalledTimes(1);
  });

  it("连接失败时向上抛错（调用方负责回滚）", async () => {
    const { client, room } = await makeClient();
    room.connect.mockRejectedValueOnce(new Error("token expired"));

    await expect(client.connect("ws://lk", "bad")).rejects.toThrow("token expired");
  });

  it("remoteParticipants 返回剥离 user_ 前缀的应用 user_id（音量匹配关键）", async () => {
    const a = makeRemoteTrack();
    const { client, room } = await makeClient();
    // 真实后端 identity = user_<32hex>；上层用裸 userId 匹配，必须剥前缀
    room.remoteParticipants.set("user_abc123", {
      identity: "user_abc123",
      audioTrackPublications: new Map([["0", { track: a.track }]]),
      videoTrackPublications: new Map(),
    });

    await client.connect("ws://lk", "token");

    const parts = client.remoteParticipants();
    expect(parts[0].identity).toBe("abc123");
    expect(parts[0].audioTracks).toHaveLength(1);
  });

  it("TrackMuted 事件回调剥离 user_ 前缀（成员表匹配关键）", async () => {
    const onTrackMuted = vi.fn();
    const { client } = await makeClient({ onTrackMuted });
    await client.connect("ws://lk", "token");

    const p = { identity: "user_abc123" };
    h.emit("trackMuted", {}, p);
    expect(onTrackMuted).toHaveBeenCalledWith("abc123", true);
  });

  it("无本地开麦且无远端音频轨道：帧循环不启动（完全零开销）", async () => {
    const rafSpy = vi.fn();
    vi.stubGlobal("requestAnimationFrame", rafSpy);
    try {
      const levelCb = vi.fn();
      const { client } = await makeClient({ onLocalAudioLevel: levelCb });
      await client.connect("ws://lk", "token");
      expect(rafSpy).not.toHaveBeenCalled();
      expect(levelCb).not.toHaveBeenCalled();
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("远端音量帧驱动：本地 Web Audio 分析远端音频轨道（剥离前缀；无轨道不上报）", async () => {
    const raf = stubRafClock();
    try {
      const levelsCb = vi.fn();
      const { client, room } = await makeClient({ onRemoteAudioLevels: levelsCb });

      const a = makeRemoteTrack();
      // a1 有音频轨道 → 本地 analyser 分析；b2 无轨道 → 不上报（store 归 0）
      // 房间成员在连接前已存在（attachExistingRemoteAudio 场景：先进房者已开麦）
      room.remoteParticipants.set("user_a1", {
        identity: "user_a1",
        audioLevel: 0.9, // 即使 server 值大，也应走本地 analyser（不依赖 server）
        audioTrackPublications: new Map([["0", { track: a.track }]]),
      });
      room.remoteParticipants.set("user_b2", {
        identity: "user_b2",
        audioLevel: 0.5,
        audioTrackPublications: new Map(),
      });

      await client.connect("ws://lk", "token");

      h.analyserMock.calculateVolume.mockReturnValue(0.42);
      raf.flush();
      expect(levelsCb).toHaveBeenCalledWith({ a1: 0.42 });
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("远端参与者离开：清理其 analyser（防泄漏）", async () => {
    const raf = stubRafClock();
    try {
      const levelsCb = vi.fn();
      const { client, room } = await makeClient({ onRemoteAudioLevels: levelsCb });

      const a = makeRemoteTrack();
      room.remoteParticipants.set("user_a1", {
        identity: "user_a1",
        audioLevel: 0,
        audioTrackPublications: new Map([["0", { track: a.track }]]),
      });

      await client.connect("ws://lk", "token");
      raf.flush(); // 首帧创建 analyser
      expect(h.analyserMock.cleanup).not.toHaveBeenCalled();

      room.remoteParticipants.delete("user_a1"); // 离开
      const callsAfterDelete = levelsCb.mock.calls.length;
      raf.flush(); // 帧循环发现无轨道 → 停止 + 清理 analyser
      expect(h.analyserMock.cleanup).toHaveBeenCalled();
      // 无任何轨道后帧循环完全停止（零开销），不再回调
      expect(levelsCb.mock.calls.length).toBe(callsAfterDelete);
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("远端 analyser 创建失败：回退 server speaker update 快照（不伪造跳动）", async () => {
    const raf = stubRafClock();
    try {
      // 模拟 createAudioAnalyser 对远端轨道抛错（如 track 无 mediaStreamTrack）
      const mod = await import("livekit-client");
      vi.mocked(mod.createAudioAnalyser).mockImplementationOnce(() => {
        throw new Error("no media stream track");
      });

      const levelsCb = vi.fn();
      const { client, room } = await makeClient({ onRemoteAudioLevels: levelsCb });

      const a = makeRemoteTrack();
      room.remoteParticipants.set("user_a1", {
        identity: "user_a1",
        audioLevel: 0.33,
        audioTrackPublications: new Map([["0", { track: a.track }]]),
      });

      await client.connect("ws://lk", "token");
      raf.flush();
      expect(levelsCb).toHaveBeenCalledWith({ a1: 0.33 }); // 回退 server 值
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("本地麦克风音量监测：无轨道帧循环不启动（零开销），开麦事件后回调 calculateVolume", async () => {
    const raf = stubRafClock();
    try {
      const levelCb = vi.fn();
      const { client, room } = await makeClient({ onLocalAudioLevel: levelCb });

      await client.connect("ws://lk", "token");
      // 未开麦且无远端轨道 → 帧循环不启动（零开销），不回调
      raf.flush();
      expect(levelCb).not.toHaveBeenCalled();

      // 开麦（发布本地音频轨道）→ localTrackPublished 事件启动帧循环
      h.analyserMock.calculateVolume.mockReturnValue(0.55);
      room.localParticipant.audioTrackPublications.set("mic", {
        track: makeLocalTrack(),
      });
      h.emit("localTrackPublished");
      // 首帧立即计算：创建 analyser 并 return，下一轮才上报 level
      raf.flush();
      raf.flush();
      expect(levelCb).toHaveBeenCalledWith(0.55);
      // analyser 创建时把 smoothingTimeConstant 调小（0.8 → 0.15）：
      // 声音停止后音量快速归零，跳动条不会"没声了还亮着"
      expect(h.analyserMock.analyser.smoothingTimeConstant).toBe(0.15);
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("analyser 的 AudioContext 为 suspended 时主动 resume（autoplay 策略修复）", async () => {
    const raf = stubRafClock();
    try {
      // 模拟浏览器 autoplay 拦截：createAudioAnalyser 的 AudioContext 默认 suspended
      h.analyserMock.analyser.context.state = "suspended";
      const levelCb = vi.fn();
      const { client, room } = await makeClient({ onLocalAudioLevel: levelCb });

      await client.connect("ws://lk", "token");
      room.localParticipant.audioTrackPublications.set("mic", {
        track: makeLocalTrack(),
      });
      h.emit("localTrackPublished");
      // 首帧创建 analyser（同步），下一轮才上报
      raf.flush();
      raf.flush();
      expect(h.analyserMock.analyser.context.resume).toHaveBeenCalledTimes(1);
    } finally {
      vi.unstubAllGlobals();
      h.analyserMock.analyser.context.state = "running";
    }
  });

  it("断开连接时停止音量监测（清理帧循环与分析器）", async () => {
    const raf = stubRafClock();
    try {
      const levelCb = vi.fn();
      const { client, room } = await makeClient({ onLocalAudioLevel: levelCb });
      await client.connect("ws://lk", "token");
      room.localParticipant.audioTrackPublications.set("mic", {
        track: makeLocalTrack(),
      });
      h.emit("localTrackPublished");
      raf.flush();
      raf.flush();
      expect(h.analyserMock.calculateVolume).toHaveBeenCalled();

      await client.disconnect();
      const callsBefore = levelCb.mock.calls.length;
      raf.flush(); // 帧循环已停：不再回调
      expect(levelCb.mock.calls.length).toBe(callsBefore);
      expect(h.analyserMock.cleanup).toHaveBeenCalled();
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("setLocalVolume 懒挂载增益链：≠100% 时挂 processor，恢复 100% 时 stopProcessor", async () => {
    const { client, room } = await makeClient({ onLocalAudioLevel: vi.fn() });
    await client.connect("ws://lk", "token");
    const track = makeLocalTrack();
    room.localParticipant.audioTrackPublications.set("mic", { track });

    // 未调节（默认 1）→ 不挂 processor
    expect(track.setProcessor).not.toHaveBeenCalled();

    // 调小音量（0.5）→ 挂 processor
    await client.setLocalVolume(0.5);
    expect(track.setProcessor).toHaveBeenCalledTimes(1);
    const proc = track.setProcessor.mock.calls[0][0] as {
      name: string;
      setGain: (v: number) => void;
    };
    expect(proc.name).toBe("local-mic-volume");
    expect(client.getLocalVolume()).toBe(0.5);

    // 再次调节 → 复用 processor，只更新 gain
    await client.setLocalVolume(1.5);
    expect(track.setProcessor).toHaveBeenCalledTimes(1);
    expect(client.getLocalVolume()).toBe(1.5);

    // 恢复 1（原始）→ stopProcessor
    await client.setLocalVolume(1);
    expect(track.stopProcessor).toHaveBeenCalledTimes(1);
    expect(client.getLocalVolume()).toBe(1);
  });

  it("setLocalVolume 夹取到 0~2 边界", async () => {
    const { client } = await makeClient({ onLocalAudioLevel: vi.fn() });
    await client.connect("ws://lk", "token");
    await client.setLocalVolume(9);
    expect(client.getLocalVolume()).toBe(2);
    await client.setLocalVolume(-1);
    expect(client.getLocalVolume()).toBe(0);
  });

  it("未开麦时 setLocalVolume 只记录目标值，开麦后由监测懒挂载", async () => {
    const raf = stubRafClock();
    try {
      const { client, room } = await makeClient({ onLocalAudioLevel: vi.fn() });
      await client.connect("ws://lk", "token");
      // 未开麦（无本地轨道）
      await client.setLocalVolume(0.5);
      expect(client.getLocalVolume()).toBe(0.5);
      const track = makeLocalTrack();
      room.localParticipant.audioTrackPublications.set("mic", { track });
      h.emit("localTrackPublished");
      // 帧循环首帧发现 volume≠1 且未挂 → 懒挂载（异步，让 microtask 落地）
      raf.flush(1);
      await Promise.resolve();
      expect(track.setProcessor).toHaveBeenCalledTimes(1);
      // 已挂载后不再重复 setProcessor（后续帧只调 setGain）
      raf.flush(10);
      expect(track.setProcessor).toHaveBeenCalledTimes(1);
    } finally {
      vi.unstubAllGlobals();
    }
  });
});
