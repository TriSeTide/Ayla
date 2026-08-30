/**
 * createLiveKitRoom 契约测试（mock livekit-client 模块）：
 * - 连接后 attach 已存在的远端音频轨道（TrackSubscribed 不覆盖此场景，
 *   缺了会导致「先进房者开麦，后进房者听不到他」——F11 语音修复）；
 * - TrackSubscribed 新订阅的音频轨道同样 attach；
 * - 非音频轨道（video）不 attach；
 * - TrackUnsubscribed 时 detach；
 * - remoteParticipants / 事件 identity 剥离 `user_` 前缀（音量匹配关键）；
 * - 本地麦克风音量监测：有本地轨道时轮询 getLevel 回调，无轨道回调 0。
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

beforeEach(() => {
  h.clearAll();
});

afterEach(() => {
  vi.clearAllMocks();
  audioContainer()?.remove();
  h.clearAll();
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

  it("远端音量轮询：本地 Web Audio 分析远端音频轨道（剥离前缀；无轨道不上报）", async () => {
    vi.useFakeTimers();
    try {
      const levelsCb = vi.fn();
      const { client, room } = await makeClient({ onRemoteAudioLevels: levelsCb });

      await client.connect("ws://lk", "token");
      const a = makeRemoteTrack();
      // a1 有音频轨道 → 本地 analyser 分析；b2 无轨道 → 不上报（store 归 0）
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

      h.analyserMock.calculateVolume.mockReturnValue(0.42);
      await vi.advanceTimersByTimeAsync(110);
      expect(levelsCb).toHaveBeenCalledWith({ a1: 0.42 });
    } finally {
      vi.useRealTimers();
    }
  });

  it("远端参与者离开：清理其 analyser（防泄漏）", async () => {
    vi.useFakeTimers();
    try {
      const levelsCb = vi.fn();
      const { client, room } = await makeClient({ onRemoteAudioLevels: levelsCb });

      await client.connect("ws://lk", "token");
      const a = makeRemoteTrack();
      room.remoteParticipants.set("user_a1", {
        identity: "user_a1",
        audioLevel: 0,
        audioTrackPublications: new Map([["0", { track: a.track }]]),
      });

      await vi.advanceTimersByTimeAsync(110); // 创建 analyser
      expect(h.analyserMock.cleanup).not.toHaveBeenCalled();

      room.remoteParticipants.delete("user_a1"); // 离开
      await vi.advanceTimersByTimeAsync(110); // 轮询清理
      expect(h.analyserMock.cleanup).toHaveBeenCalled();
      expect(levelsCb).toHaveBeenLastCalledWith({});
    } finally {
      vi.useRealTimers();
    }
  });

  it("远端 analyser 创建失败：回退 server speaker update 快照（不伪造跳动）", async () => {
    vi.useFakeTimers();
    try {
      // 模拟 createAudioAnalyser 对远端轨道抛错（如 track 无 mediaStreamTrack）
      const mod = await import("livekit-client");
      vi.mocked(mod.createAudioAnalyser).mockImplementationOnce(() => {
        throw new Error("no media stream track");
      });

      const levelsCb = vi.fn();
      const { client, room } = await makeClient({ onRemoteAudioLevels: levelsCb });

      await client.connect("ws://lk", "token");
      const a = makeRemoteTrack();
      room.remoteParticipants.set("user_a1", {
        identity: "user_a1",
        audioLevel: 0.33,
        audioTrackPublications: new Map([["0", { track: a.track }]]),
      });

      await vi.advanceTimersByTimeAsync(110);
      expect(levelsCb).toHaveBeenCalledWith({ a1: 0.33 }); // 回退 server 值
    } finally {
      vi.useRealTimers();
    }
  });

  it("本地麦克风音量监测：无本地轨道回调 0，有轨道时回调 calculateVolume", async () => {
    vi.useFakeTimers();
    try {
      const levelCb = vi.fn();
      const { client, room } = await makeClient({ onLocalAudioLevel: levelCb });

      await client.connect("ws://lk", "token");
      // 未开麦（无本地轨道）→ 连续回调 0
      await vi.advanceTimersByTimeAsync(210);
      expect(levelCb).toHaveBeenCalledWith(0);

      // 开麦（发布本地音频轨道）→ 创建 analyser（同步）并回调 calculateVolume
      h.analyserMock.calculateVolume.mockReturnValue(0.55);
      room.localParticipant.audioTrackPublications.set("mic", {
        track: makeLocalTrack(),
      });
      // 第一轮创建 analyser 并 return，第二轮才上报 level
      await vi.advanceTimersByTimeAsync(110);
      await vi.advanceTimersByTimeAsync(110);
      expect(levelCb).toHaveBeenCalledWith(0.55);
      // analyser 创建时把 smoothingTimeConstant 调小（0.8 → 0.15）：
      // 声音停止后音量快速归零，跳动条不会"没声了还亮着"
      expect(h.analyserMock.analyser.smoothingTimeConstant).toBe(0.15);
    } finally {
      vi.useRealTimers();
    }
  });

  it("analyser 的 AudioContext 为 suspended 时主动 resume（autoplay 策略修复）", async () => {
    vi.useFakeTimers();
    try {
      // 模拟浏览器 autoplay 拦截：createAudioAnalyser 的 AudioContext 默认 suspended
      h.analyserMock.analyser.context.state = "suspended";
      const levelCb = vi.fn();
      const { client, room } = await makeClient({ onLocalAudioLevel: levelCb });

      await client.connect("ws://lk", "token");
      room.localParticipant.audioTrackPublications.set("mic", {
        track: makeLocalTrack(),
      });
      // 第一轮创建 analyser（同步），第二轮才上报
      await vi.advanceTimersByTimeAsync(110);
      await vi.advanceTimersByTimeAsync(110);
      expect(h.analyserMock.analyser.context.resume).toHaveBeenCalledTimes(1);
    } finally {
      vi.useRealTimers();
      h.analyserMock.analyser.context.state = "running";
    }
  });

  it("断开连接时停止音量监测（清理定时器与分析器）", async () => {
    vi.useFakeTimers();
    try {
      const levelCb = vi.fn();
      const { client, room } = await makeClient({ onLocalAudioLevel: levelCb });
      await client.connect("ws://lk", "token");
      room.localParticipant.audioTrackPublications.set("mic", {
        track: makeLocalTrack(),
      });
      await vi.advanceTimersByTimeAsync(110);
      await vi.advanceTimersByTimeAsync(110);
      expect(h.analyserMock.calculateVolume).toHaveBeenCalled();

      await client.disconnect();
      const callsBefore = levelCb.mock.calls.length;
      await vi.advanceTimersByTimeAsync(300);
      expect(levelCb.mock.calls.length).toBe(callsBefore); // 定时器已清
      expect(h.analyserMock.cleanup).toHaveBeenCalled();
    } finally {
      vi.useRealTimers();
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
    vi.useFakeTimers();
    try {
      const { client, room } = await makeClient({ onLocalAudioLevel: vi.fn() });
      await client.connect("ws://lk", "token");
      // 未开麦（无本地轨道）
      await client.setLocalVolume(0.5);
      expect(client.getLocalVolume()).toBe(0.5);
      const track = makeLocalTrack();
      room.localParticipant.audioTrackPublications.set("mic", { track });
      // 下一轮监测发现 volume≠1 且未挂 → 懒挂载
      await vi.advanceTimersByTimeAsync(110);
      expect(track.setProcessor).toHaveBeenCalledTimes(1);
    } finally {
      vi.useRealTimers();
    }
  });
});
