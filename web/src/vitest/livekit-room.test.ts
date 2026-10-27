/**
 * LiveKit Room 契约测试（jsdom + mock livekit-client）。
 *
 * 覆盖必须成立的语义（与 wsRelayRoom.ts 的契约逐条对齐）：
 * 1. 连接：URL/token 原样交给 SDK；状态 connecting → connected；
 * 2. **关麦真正释放麦克风设备**：unpublishTrack(stopOnUnpublish) + MediaStreamTrack.stop()
 *    —— 隐私语义（熄灭硬件指示灯），不能只剩 mute；
 * 3. **绝不用 isSpeaking / activeSpeakers 门控发布**（doc 39 硬约束）：
 *    行为上「activeSpeakers 清空后轨道仍保持发布」，结构上不得出现 .isSpeaking 属性访问；
 * 4. 电平：100ms 拍、远端快照含 0（上层直接覆盖）、本地关麦恒 0；
 * 5. 远端参与者/音量契约（identity = 裸 user_id，无前缀）；
 * 6. 断线语义：主动 disconnect 不再上报 failed；SDK 放弃重连 → failed（不自动 leave）；
 * 7. client.ts 的传输分支：transport=livekit 走 LiveKit，失败**原地降级**到 ws_relay，
 *    降级不触发 leave/（取消 AbortError 不降级）。
 *
 * 真实链路（ICE/DTLS/UDP candidate）由 task-1 的 webrtc harness 与真机验收覆盖，
 * 不在本测试范围：jsdom 没有 WebRTC/WebAudio 真实现。
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

/* ================= mock livekit-client ================= */

const lk = vi.hoisted(() => {
  const RoomEvent = {
    Connected: "connected",
    Reconnecting: "reconnecting",
    SignalReconnecting: "signalReconnecting",
    Reconnected: "reconnected",
    Disconnected: "disconnected",
    ConnectionStateChanged: "connectionStateChanged",
    ParticipantConnected: "participantConnected",
    ParticipantDisconnected: "participantDisconnected",
    TrackSubscribed: "trackSubscribed",
    TrackUnsubscribed: "trackUnsubscribed",
    TrackUnpublished: "trackUnpublished",
    TrackMuted: "trackMuted",
    TrackUnmuted: "trackUnmuted",
    ActiveSpeakersChanged: "activeSpeakersChanged",
  } as const;
  const Track = {
    Kind: { Audio: "audio", Video: "video", Unknown: "unknown" },
    Source: {
      Camera: "camera",
      Microphone: "microphone",
      ScreenShare: "screen_share",
      ScreenShareAudio: "screen_share_audio",
      Unknown: "unknown",
    },
  } as const;

  class FakeLocalTrack {
    kind = "audio";
    /** 底层设备轨：stop() = 熄灭硬件指示灯（关麦必须调它） */
    mediaStreamTrack = { kind: "audio", stop: vi.fn() };
    /** 采集设备原始轨引用（供断言：挂处理器后 mediaStreamTrack 会被换掉） */
    deviceTrack = this.mediaStreamTrack;
    stopped = false;
    processor: unknown = null;
    stop = vi.fn(() => {
      this.stopped = true;
    });
    /** 模拟 SDK 真实行为：挂上 TrackProcessor 后 mediaStreamTrack 变成处理链的虚拟轨 */
    setProcessor = vi.fn(async (p: unknown) => {
      this.processor = p;
      this.mediaStreamTrack = { kind: "audio", stop: vi.fn() };
    });
    stopProcessor = vi.fn(async () => {
      this.processor = null;
    });
  }

  class FakeRoom {
    static instances: FakeRoom[] = [];
    state = "disconnected";
    remoteParticipants = new Map<string, unknown>();
    handlers = new Map<string, Array<(...args: unknown[]) => void>>();
    options: Record<string, unknown>;
    connect = vi.fn(async (url: string, token: string) => {
      void url;
      void token;
      this.state = "connected";
      this.emit("connected");
    });
    disconnect = vi.fn(async () => {
      this.state = "disconnected";
    });
    startAudio = vi.fn(async () => {});
    removeAllListeners = vi.fn(() => {
      this.handlers.clear();
    });
    localParticipant = {
      identity: "me",
      sid: "PA_me",
      isLocal: true,
      publishTrack: vi.fn(async () => ({ trackSid: "TR_mic" })),
      unpublishTrack: vi.fn(async () => undefined),
      audioTrackPublications: new Map<string, unknown>(),
    };
    constructor(options: Record<string, unknown> = {}) {
      this.options = options;
      FakeRoom.instances.push(this);
    }
    on(event: string, cb: (...args: unknown[]) => void) {
      const list = this.handlers.get(event) ?? [];
      list.push(cb);
      this.handlers.set(event, list);
      return this;
    }
    emit(event: string, ...args: unknown[]) {
      for (const cb of this.handlers.get(event) ?? []) cb(...args);
    }
  }

  const createLocalAudioTrack = vi.fn(async () => new FakeLocalTrack());

  return { RoomEvent, Track, FakeRoom, FakeLocalTrack, createLocalAudioTrack };
});

vi.mock("livekit-client", () => ({
  Room: lk.FakeRoom,
  RoomEvent: lk.RoomEvent,
  Track: lk.Track,
  AudioPresets: { telephone: { maxBitrate: 12000 }, speech: { maxBitrate: 24000 }, music: { maxBitrate: 48000 } },
  createLocalAudioTrack: lk.createLocalAudioTrack,
}));

import { createLiveKitRoom } from "../livekit/livekitRoom";
import { VoiceLiveKitClient, type LiveKitEvents, type LiveKitRoomLike, type LiveKitState } from "../livekit/client";

/* ================= 夹具 ================= */

type RemoteParticipantStub = {
  identity: string;
  isLocal: false;
  audioTrackPublications: Map<string, unknown>;
};

function remoteParticipant(identity: string, opts: { muted?: boolean; trackSid?: string } = {}) {
  const setVolume = vi.fn();
  const detach = vi.fn(() => []);
  const attach = vi.fn(() => document.createElement("audio"));
  const track = { kind: "audio", mediaStreamTrack: { kind: "audio" }, setVolume, attach, detach };
  const publication = {
    kind: "audio",
    source: "microphone",
    track,
    isMuted: opts.muted ?? false,
  };
  const stub: RemoteParticipantStub = {
    identity,
    isLocal: false,
    audioTrackPublications: new Map([[opts.trackSid ?? "TR_" + identity, publication]]),
  };
  return { stub, publication, track, setVolume, attach, detach };
}

function makeEvents() {
  const states: LiveKitState[] = [];
  const joined: string[] = [];
  const left: string[] = [];
  const trackMuted: Array<[string, boolean]> = [];
  const activeSpeakers: string[][] = [];
  const localLevels: number[] = [];
  const remoteLevelSnapshots: Array<Record<string, number>> = [];
  const events: LiveKitEvents = {
    onStateChange: (s) => states.push(s),
    onParticipantJoined: (id) => joined.push(id),
    onParticipantLeft: (id) => left.push(id),
    onTrackMuted: (id, m) => trackMuted.push([id, m]),
    onActiveSpeakers: (ids) => activeSpeakers.push(ids),
    onLocalAudioLevel: (l) => localLevels.push(l),
    onRemoteAudioLevels: (l) => remoteLevelSnapshots.push(l),
  };
  return { events, states, joined, left, trackMuted, activeSpeakers, localLevels, remoteLevelSnapshots };
}

const ROOM_URL = "wss://frp-one.com:26211/livekit";

async function connectedRoom() {
  const harness = makeEvents();
  const room = await createLiveKitRoom(harness.events);
  await room.connect(ROOM_URL, "tok-livekit");
  const fake = lk.FakeRoom.instances.at(-1)!;
  return { ...harness, room, fake };
}

beforeEach(() => {
  vi.useFakeTimers();
  lk.FakeRoom.instances.length = 0;
  lk.createLocalAudioTrack.mockClear();
});

afterEach(() => {
  vi.useRealTimers();
  vi.clearAllMocks();
});

/* ================= createLiveKitRoom ================= */

describe("createLiveKitRoom", () => {
  it("connect 把 url/token 原样交给 SDK，状态 connecting → connected", async () => {
    const { states, fake, room } = await connectedRoom();
    expect(fake.connect).toHaveBeenCalledWith(ROOM_URL, "tok-livekit", { autoSubscribe: true });
    expect(states).toEqual(["connecting", "connected"]);
    expect(room.isMicrophoneEnabled()).toBe(false);
  });

  it("connect 失败 → failed 并向上抛（调用方回滚 leave/）", async () => {
    const { events, states } = makeEvents();
    const room = await createLiveKitRoom(events);
    lk.FakeRoom.instances.at(-1)!.connect.mockRejectedValueOnce(new Error("token expired"));
    await expect(room.connect(ROOM_URL, "bad")).rejects.toThrow("token expired");
    expect(states).toEqual(["connecting", "failed"]);
  });

  it("缺 token/地址时给明确错误，不静默连接", async () => {
    const room = await createLiveKitRoom(makeEvents().events);
    await expect(room.connect(ROOM_URL, "")).rejects.toThrow(/登录状态失效/);
    await expect(room.connect("", "tok")).rejects.toThrow(/媒体地址无效/);
  });

  it("⚠️关麦必须真正释放设备：unpublishTrack(stopOnUnpublish) + MediaStreamTrack.stop()", async () => {
    const { room, fake } = await connectedRoom();
    await room.setMicrophoneEnabled(true);
    expect(lk.createLocalAudioTrack).toHaveBeenCalledTimes(1);
    expect(fake.localParticipant.publishTrack).toHaveBeenCalledTimes(1);
    expect(room.isMicrophoneEnabled()).toBe(true);

    const track = await lk.createLocalAudioTrack.mock.results[0]!.value as InstanceType<
      typeof lk.FakeLocalTrack
    >;
    await room.setMicrophoneEnabled(false);

    // 1) 从发布中移除（对端立刻看到 muted 事实）
    expect(fake.localParticipant.unpublishTrack).toHaveBeenCalledWith(track, true);
    // 2) 停**采集设备原始轨** —— 这才是"熄灭硬件指示灯"，只 mute 不算。
    // 注意：挂增益处理器后 track.mediaStreamTrack 会变成虚拟轨，
    // 所以实现里单独持有采集时抓到的 deviceTrack 引用；这里断言那次 stop 被调用。
    expect(track.mediaStreamTrack.stop).toHaveBeenCalled();
    expect(track.stop).toHaveBeenCalled();
    expect(room.isMicrophoneEnabled()).toBe(false);
  });

  it("⚠️绝不用 isSpeaking/activeSpeakers 门控发布（doc 39）：说话状态清空后轨道仍发布", async () => {
    const { room, fake } = await connectedRoom();
    await room.setMicrophoneEnabled(true);
    const published = fake.localParticipant.publishTrack.mock.calls.length;

    // 服务端主动说话列表清空（安静）→ 不得影响发布：不重复 publish、也不 unpublish
    fake.emit(lk.RoomEvent.ActiveSpeakersChanged, []);
    fake.emit(lk.RoomEvent.ActiveSpeakersChanged, [{ identity: "me", sid: "PA_me", isLocal: true }]);
    await Promise.resolve();

    expect(fake.localParticipant.publishTrack.mock.calls.length).toBe(published);
    expect(fake.localParticipant.unpublishTrack).not.toHaveBeenCalled();
    expect(room.isMicrophoneEnabled()).toBe(true);
  });

  it("结构防线：源码里不得出现 .isSpeaking / room.activeSpeakers 之类门控属性访问", () => {
    const src = readFileSync(resolve(process.cwd(), "src/livekit/livekitRoom.ts"), "utf8");
    expect(src).not.toMatch(/\.isSpeaking\b/);
    expect(src).not.toMatch(/\.activeSpeakers\b/);
  });

  it("远端参与者/音量：identity 用裸 user_id，setVolume 透传到轨道并 clamp 0~1", async () => {
    const { room, fake } = await connectedRoom();
    const u2 = remoteParticipant("u2");
    fake.remoteParticipants.set("u2", u2.stub);

    const participants = room.remoteParticipants();
    expect(participants).toHaveLength(1);
    expect(participants[0].identity).toBe("u2"); // 无 user_ 前缀
    participants[0].audioTracks[0].setVolume(0.42);
    expect(u2.setVolume).toHaveBeenCalledWith(0.42);

    room.remoteParticipants()[0].audioTracks[0].setVolume(150);
    expect(u2.setVolume).toHaveBeenLastCalledWith(1);
  });

  it("音量≠100% 会挂增益处理器（发送响度），关麦时设备原始轨仍被 stop（隐私不受处理器影响）", async () => {
    const { room } = await connectedRoom();
    await room.setMicrophoneEnabled(true);
    const track = (await lk.createLocalAudioTrack.mock.results[0]!.value) as InstanceType<
      typeof lk.FakeLocalTrack
    >;
    const deviceTrack = track.deviceTrack;

    await room.setLocalVolume(0.5); // 50% → 挂增益链
    expect(track.setProcessor).toHaveBeenCalled();

    await room.setMicrophoneEnabled(false);
    // 关键：处理器换掉了 track.mediaStreamTrack，但**采集设备原始轨**必须被停，
    // 否则系统麦克风指示灯不灭（隐私语义回退）。
    expect(deviceTrack.stop).toHaveBeenCalled();
  });

  it("本集音量 0~2 记录并 clamp（1 = 原始）", async () => {
    const { room } = await connectedRoom();
    await room.setLocalVolume(1.5);
    expect(room.getLocalVolume()).toBe(1.5);
    await room.setLocalVolume(99);
    expect(room.getLocalVolume()).toBe(2);
    await room.setLocalVolume(-3);
    expect(room.getLocalVolume()).toBe(0);
  });

  it("电平 100ms 拍：远端快照**含 0**，本地关麦恒 0", async () => {
    const { fake, localLevels, remoteLevelSnapshots } = await connectedRoom();
    const u2 = remoteParticipant("u2");
    fake.remoteParticipants.set("u2", u2.stub);

    await vi.advanceTimersByTimeAsync(100);
    expect(remoteLevelSnapshots.at(-1)).toEqual({ u2: 0 }); // 含 0 的全量快照（上层直接覆盖）
    expect(localLevels.at(-1)).toBe(0); // 未开麦：连续回调 0

    await vi.advanceTimersByTimeAsync(300);
    expect(remoteLevelSnapshots.length).toBeGreaterThanOrEqual(4); // 持续回调，不是一次性
  });

  it("participant 进出 / 轨道静音映射到回调；本地自身静音不上报（与中继版同语义）", async () => {
    const { room, fake, joined, left, trackMuted } = await connectedRoom();
    const u2 = remoteParticipant("u2");
    fake.emit(lk.RoomEvent.ParticipantConnected, u2.stub);
    expect(joined).toEqual(["u2"]);

    fake.emit(lk.RoomEvent.TrackMuted, u2.publication, u2.stub);
    expect(trackMuted.at(-1)).toEqual(["u2", true]);
    fake.emit(lk.RoomEvent.TrackUnmuted, u2.publication, u2.stub);
    expect(trackMuted.at(-1)).toEqual(["u2", false]);

    // 本地自己的静音：成员行只关心远端，不上报
    const before = trackMuted.length;
    fake.emit(lk.RoomEvent.TrackMuted, { kind: "audio", source: "microphone" }, fake.localParticipant);
    expect(trackMuted).toHaveLength(before);

    fake.emit(lk.RoomEvent.ParticipantDisconnected, u2.stub);
    expect(left).toEqual(["u2"]);
    void room;
  });

  it("TrackSubscribed 时 attach 远端音频（SDK 不自动 attach，漏了就是「听不见对方」）", async () => {
    const { room, fake } = await connectedRoom();
    const u2 = remoteParticipant("u2");
    fake.remoteParticipants.set("u2", u2.stub);
    const remoteTrack = { kind: "audio", mediaStreamTrack: { kind: "audio" }, attach: vi.fn(() => document.createElement("audio")), detach: vi.fn(), setVolume: vi.fn() };
    fake.emit(lk.RoomEvent.TrackSubscribed, remoteTrack, u2.publication, u2.stub);
    expect(remoteTrack.attach).toHaveBeenCalled();

    const container = document.getElementById("ayla-voice-audio");
    expect(container).not.toBeNull();
    expect(container!.childElementCount).toBeGreaterThan(0);
    void room;
  });

  it("connect 后补齐**已存在**的远端音频（TrackSubscribed 不覆盖此场景）", async () => {
    const harness = makeEvents();
    const room = await createLiveKitRoom(harness.events);
    const fake = lk.FakeRoom.instances.at(-1)!;
    // 先有成员轨道，再 connect（= 加入时房里已有人开麦）
    const early = { kind: "audio", mediaStreamTrack: { kind: "audio" }, attach: vi.fn(() => document.createElement("audio")), detach: vi.fn(), setVolume: vi.fn() };
    fake.remoteParticipants.set("early", {
      identity: "early",
      isLocal: false,
      audioTrackPublications: new Map([["TR_early", { kind: "audio", source: "microphone", track: early }]]),
    } as unknown as RemoteParticipantStub);
    await room.connect(ROOM_URL, "tok");
    expect(early.attach).toHaveBeenCalled();
  });

  it("SDK 重连：reconnecting → connected；放弃后 disconnected → failed", async () => {
    const { fake, states, room } = await connectedRoom();
    fake.emit(lk.RoomEvent.Reconnecting);
    expect(states.at(-1)).toBe("reconnecting");
    fake.emit(lk.RoomEvent.Reconnected);
    expect(states.at(-1)).toBe("connected");
    fake.emit(lk.RoomEvent.Disconnected);
    expect(states.at(-1)).toBe("failed");
    void room;
  });

  it("主动 disconnect 后不再上报 failed（所有权已被 client.ts 撤销）", async () => {
    const { room, fake, states } = await connectedRoom();
    await room.disconnect();
    const snapshot = states.length;
    fake.emit(lk.RoomEvent.Disconnected);
    expect(states).toHaveLength(snapshot);
    expect(states).not.toContain("failed");
  });

  it("disconnect 幂等：重复调用不报错，设备与定时器都被回收", async () => {
    const { room, fake } = await connectedRoom();
    await room.setMicrophoneEnabled(true);
    await room.disconnect();
    await room.disconnect();
    expect(fake.disconnect).toHaveBeenCalled();
    expect(fake.removeAllListeners).toHaveBeenCalled();
    const track = await lk.createLocalAudioTrack.mock.results[0]!.value as InstanceType<typeof lk.FakeLocalTrack>;
    expect(track.mediaStreamTrack.stop).toHaveBeenCalled();
  });

  it("断开后 100ms 拍停止（不再回调电平）", async () => {
    const { room, localLevels } = await connectedRoom();
    await vi.advanceTimersByTimeAsync(100);
    const before = localLevels.length;
    expect(before).toBeGreaterThan(0);
    await room.disconnect();
    await vi.advanceTimersByTimeAsync(500);
    expect(localLevels).toHaveLength(before);
  });
});

/* ================= client.ts 传输分支 ================= */

function fakeRoom(overrides: Partial<LiveKitRoomLike> = {}): LiveKitRoomLike & {
  connect: ReturnType<typeof vi.fn>;
  disconnect: ReturnType<typeof vi.fn>;
} {
  const base = {
    connect: vi.fn().mockResolvedValue(undefined),
    disconnect: vi.fn().mockResolvedValue(undefined),
    setMicrophoneEnabled: vi.fn().mockResolvedValue(undefined),
    isMicrophoneEnabled: vi.fn().mockReturnValue(false),
    remoteParticipants: vi.fn().mockReturnValue([]),
    startAudio: vi.fn().mockResolvedValue(undefined),
    setLocalVolume: vi.fn().mockResolvedValue(undefined),
    getLocalVolume: vi.fn().mockReturnValue(1),
  };
  return Object.assign(base, overrides) as unknown as ReturnType<typeof fakeRoom>;
}

const LIVEKIT_MEDIA = {
  transport: "livekit" as const,
  livekit: { url: "wss://lk/livekit", token: "lk-token", ttl: 600 },
  ws_relay: { url: "wss://relay/ws/voice/audio/?channel=1" },
};

describe("VoiceLiveKitClient.connectWithMedia", () => {
  it("transport=ws_relay → 直接用中继地址（与旧行为一致）", async () => {
    const client = new VoiceLiveKitClient();
    const room = fakeRoom();
    const factory = vi.fn().mockResolvedValue(room);
    client.setRoomFactory(factory);
    await client.connectWithMedia(
      { transport: "ws_relay", livekit: null, ws_relay: { url: "wss://relay/a" } },
      "access",
      "wss://relay/fallback",
    );
    expect(room.connect).toHaveBeenCalledWith("wss://relay/a", "access");
    expect(client.getTransport()).toBe("ws_relay");
  });

  it("transport=livekit → 用 livekit 的 url/token", async () => {
    const client = new VoiceLiveKitClient();
    const room = fakeRoom();
    client.setRoomFactory(() => room);
    await client.connectWithMedia(LIVEKIT_MEDIA, "access");
    expect(room.connect).toHaveBeenCalledWith("wss://lk/livekit", "lk-token");
    expect(client.getTransport()).toBe("livekit");
  });

  it("⚠️livekit 连接失败 → **原地降级**到 ws_relay（不 throw、不回后端）", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const client = new VoiceLiveKitClient();
    const livekitRoom = fakeRoom({ connect: vi.fn().mockRejectedValue(new Error("ice failed")) });
    const relayRoom = fakeRoom();
    const factory = vi.fn().mockResolvedValueOnce(livekitRoom).mockResolvedValueOnce(relayRoom);
    client.setRoomFactory(factory);

    await expect(client.connectWithMedia(LIVEKIT_MEDIA, "access")).resolves.toBeUndefined();
    expect(relayRoom.connect).toHaveBeenCalledWith("wss://relay/ws/voice/audio/?channel=1", "access");
    expect(client.getTransport()).toBe("ws_relay");
    // 失败的房间必须被清理，不能留着占设备
    expect(livekitRoom.disconnect).toHaveBeenCalled();
    // 结构化日志，便于判断"是否真的切成功了"（不含 token）
    expect(warn).toHaveBeenCalledWith(expect.stringContaining("transport_fallback"));
    expect(String(warn.mock.calls[0][0])).not.toContain("lk-token");
    warn.mockRestore();
  });

  it("降级日志脱敏：token/凭据不得进日志", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const client = new VoiceLiveKitClient();
    const jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.c2lnbmF0dXJlLXZhbHVl";
    const err = new Error(`connect failed token=${jwt} &secret=abcdef123456`);
    const livekitRoom = fakeRoom({ connect: vi.fn().mockRejectedValue(err) });
    // 降级目标必须是一个能连上的房间：否则第二次 connect 会再次抛出 token 错误，
    // 测到的就不是"脱敏"而是"未捕获异常"（原用例的 factory 恒返回失败房间，属用例缺陷）。
    const relayRoom = fakeRoom();
    let call = 0;
    client.setRoomFactory(() => {
      call += 1;
      return call === 1 ? livekitRoom : relayRoom;
    });
    await client.connectWithMedia(
      { transport: "livekit", livekit: { url: "wss://lk", token: "t" }, ws_relay: { url: "wss://relay/x" } },
      "a",
    );
    const logged = String(warn.mock.calls[0]?.[0] ?? "");
    expect(logged).toContain("transport_fallback");
    expect(logged).not.toContain(jwt);
    expect(logged).not.toContain("abcdef123456");
    warn.mockRestore();
  });

  it("livekit 失败且没有 ws_relay 回滚地址 → 原样抛错（交由上层 failed）", async () => {
    const client = new VoiceLiveKitClient();
    const livekitRoom = fakeRoom({ connect: vi.fn().mockRejectedValue(new Error("ice failed")) });
    client.setRoomFactory(() => livekitRoom);
    await expect(
      client.connectWithMedia({ transport: "livekit", livekit: { url: "wss://lk", token: "t" }, ws_relay: null }, "a"),
    ).rejects.toThrow("ice failed");
  });

  it("取消（AbortError）不触发降级：切频道/离开不是传输故障", async () => {
    const client = new VoiceLiveKitClient();
    const abort = new DOMException("cancelled", "AbortError");
    const livekitRoom = fakeRoom({ connect: vi.fn().mockRejectedValue(abort) });
    const relayFactory = vi.fn().mockResolvedValue(fakeRoom());
    let call = 0;
    client.setRoomFactory(() => {
      call += 1;
      return call === 1 ? livekitRoom : relayFactory();
    });
    await expect(client.connectWithMedia(LIVEKIT_MEDIA, "a")).rejects.toThrow(/cancelled/);
    expect(relayFactory).not.toHaveBeenCalled();
  });

  it("老后端不返回 media → 用调用方给的 fallback 中继地址（向后兼容）", async () => {
    const client = new VoiceLiveKitClient();
    const room = fakeRoom();
    client.setRoomFactory(() => room);
    await client.connectWithMedia(null, "access", "wss://relay/legacy?channel=9");
    expect(room.connect).toHaveBeenCalledWith("wss://relay/legacy?channel=9", "access");
  });

  it("transport=livekit 但配置不完整（livekit=null）→ 走中继，不发半套配置", async () => {
    const client = new VoiceLiveKitClient();
    const room = fakeRoom();
    client.setRoomFactory(() => room);
    await client.connectWithMedia(
      { transport: "livekit", livekit: null, ws_relay: { url: "wss://relay/x" } },
      "access",
    );
    expect(room.connect).toHaveBeenCalledWith("wss://relay/x", "access");
  });

  it("缺 token 时直接抛（不发起任何连接）", async () => {
    const client = new VoiceLiveKitClient();
    const factory = vi.fn();
    client.setRoomFactory(factory);
    await expect(client.connectWithMedia(LIVEKIT_MEDIA, "")).rejects.toThrow(/登录状态失效/);
    expect(factory).not.toHaveBeenCalled();
  });

  it("媒体配置缺失且无回滚地址 → 明确报错", async () => {
    const client = new VoiceLiveKitClient();
    await expect(client.connectWithMedia(null, "access")).rejects.toThrow(/媒体配置缺失/);
  });
});
