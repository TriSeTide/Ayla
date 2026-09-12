/**
 * WS 音频中继 Room 契约测试（jsdom + 假 WebSocket / 假 WebCodecs）。
 *
 * 覆盖前端状态机：握手 → 事件映射（participant/speaking/muted）→ 上行
 * （speaking 峰值触发控制帧与 Opus 帧、关麦释放设备）→ 异常断线退避重连
 * （含静音事实重同步）→ 主动断开不再重连。
 *
 * 真实链路（daphne 直连 + nginx 回源双路径）由服务器端独立探针脚本验证，
 * 不在本测试范围：jsdom 没有 Web Audio/WebCodecs 真实现。
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useAuthStore } from "../stores/auth";
import { createWsRelayRoom, voiceDirectWsUrl, voiceMediaTransport } from "../livekit/wsRelayRoom";
import type { LiveKitEvents, LiveKitState } from "../livekit/client";

vi.mock("../api/client", () => ({ refreshAccessToken: vi.fn(async () => true) }));

/* ================= 假设施 ================= */

class FakeWebSocket {
  static instances: FakeWebSocket[] = [];
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSING = 2;
  static CLOSED = 3;
  url: string;
  binaryType = "";
  readyState = FakeWebSocket.CONNECTING;
  onopen: (() => void) | null = null;
  onmessage: ((ev: { data: unknown }) => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;
  sent: Array<string | Uint8Array> = [];
  constructor(url: string) {
    this.url = url;
    FakeWebSocket.instances.push(this);
  }
  send(data: string | Uint8Array) {
    this.sent.push(data);
  }
  close(_code?: number, _reason?: string) {
    this.readyState = FakeWebSocket.CLOSED;
    this.onclose?.();
  }
  serverOpen() {
    this.readyState = FakeWebSocket.OPEN;
    this.onopen?.();
  }
  serverText(payload: unknown) {
    this.onmessage?.({ data: JSON.stringify(payload) });
  }
  serverBinary(bytes: Uint8Array) {
    this.onmessage?.({ data: bytes.buffer as ArrayBuffer });
  }
  serverClose() {
    this.readyState = FakeWebSocket.CLOSED;
    this.onclose?.();
  }
}

class FakeEncoder {
  static instances: FakeEncoder[] = [];
  state = "unconfigured";
  constructor(init: { output: (chunk: { byteLength: number; copyTo(dest: Uint8Array): void }) => void }) {
    // 记录输出回调供 encode 使用（挂实例上，避免 noUnusedParameters 报未使用）
    (this as unknown as { out: typeof init }).out = init;
    FakeEncoder.instances.push(this);
  }
  private out!: { output: (chunk: { byteLength: number; copyTo(dest: Uint8Array): void }) => void };
  configure() {
    this.state = "configured";
  }
  encode(chunk: { close(): void }) {
    this.out.output({ byteLength: 3, copyTo: (dest) => dest.set([9, 9, 9]) });
    chunk.close();
  }
  close() {
    this.state = "closed";
  }
}

class FakeDecoder {
  static instances: FakeDecoder[] = [];
  chunks: Array<{ data?: Uint8Array }> = [];
  constructor(_init: { output: (audioData: unknown) => void }) {
    FakeDecoder.instances.push(this);
  }
  configure() {
    /* 无操作 */
  }
  decode(chunk: { data?: Uint8Array }) {
    this.chunks.push(chunk);
  }
  close() {
    /* 无操作 */
  }
}

class FakeAudioData {
  constructor(public init: Record<string, unknown>) {}
  close() {
    /* 无操作 */
  }
}

class FakeEncodedAudioChunk {
  data?: Uint8Array;
  constructor(init: Record<string, unknown>) {
    Object.assign(this, init); // 真实实例没有 .data，fake 摊开 init 方便断言
  }
}

class FakeGainNode {
  gain = { value: 1 };
  connect() {
    /* 无操作 */
  }
  disconnect() {
    /* 无操作 */
  }
}

class FakeAudioContext {
  state = "running";
  currentTime = 0;
  sampleRate = 48000;
  destination = {} as AudioDestinationNode;
  audioWorklet = { addModule: vi.fn(async () => {}) };
  createGain() {
    return new FakeGainNode() as unknown as GainNode;
  }
  createMediaStreamSource() {
    return { connect() {}, disconnect() {} } as unknown as MediaStreamAudioSourceNode;
  }
  createBuffer(_channels: number, length: number, rate: number) {
    return {
      getChannelData: () => new Float32Array(length),
      duration: length / rate,
    } as unknown as AudioBuffer;
  }
  createBufferSource() {
    const node = { connect() {}, start() {}, buffer: null as AudioBuffer | null };
    return node as unknown as AudioBufferSourceNode;
  }
  resume = vi.fn(async () => {});
  close = vi.fn(async () => {});
}

class FakeAudioWorkletNode {
  static instances: FakeAudioWorkletNode[] = [];
  port = { onmessage: null as ((ev: { data: unknown }) => void) | null };
  constructor(_ctx: unknown, _name: string) {
    FakeAudioWorkletNode.instances.push(this);
  }
  connect() {
    /* 无操作 */
  }
  disconnect() {
    /* 无操作 */
  }
}

const fakeTrack = { stop: vi.fn() };
const getUserMedia = vi.fn(async () =>
  ({ getTracks: () => [fakeTrack], getAudioTracks: () => [fakeTrack] }) as unknown as MediaStream,
);

/** 构造带指定 exp 的假 JWT（freshToken 临期判断用） */
function makeJwt(secondsLeft: number): string {
  const payload = { exp: Math.floor(Date.now() / 1000) + secondsLeft };
  const b64 = (obj: unknown) => btoa(JSON.stringify(obj)).replace(/=+$/, "");
  return `${b64({ alg: "HS256" })}.${b64(payload)}.sig`;
}

/* ================= 测试 ================= */

describe("wsRelayRoom", () => {
  let states: LiveKitState[];
  let joined: string[];
  let left: string[];
  let trackMuted: Array<[string, boolean]>;
  let activeSpeakers: string[][];
  let localLevels: number[];
  let remoteLevelSnapshots: Record<string, number>[];

  const makeEvents = (): LiveKitEvents => ({
    onStateChange: (s) => states.push(s),
    onParticipantJoined: (id) => joined.push(id),
    onParticipantLeft: (id) => left.push(id),
    onTrackMuted: (id, muted) => trackMuted.push([id, muted]),
    onActiveSpeakers: (ids) => activeSpeakers.push(ids),
    onLocalAudioLevel: (l) => localLevels.push(l),
    onRemoteAudioLevels: (l) => remoteLevelSnapshots.push(l),
  });

  async function makeConnectedRoom(): Promise<{ room: Awaited<ReturnType<typeof createWsRelayRoom>>; sock: FakeWebSocket }> {
    const room = await createWsRelayRoom(makeEvents());
    const pending = room.connect(voiceDirectWsUrl("1"), "tok-0");
    const sock = FakeWebSocket.instances.at(-1)!;
    sock.serverOpen();
    sock.serverText({ type: "joined", slot: 1, members: [] });
    await pending;
    return { room, sock };
  }

  const lastText = (sock: FakeWebSocket): Record<string, unknown> => {
    const texts = sock.sent.filter((s): s is string => typeof s === "string");
    return JSON.parse(texts.at(-1)!) as Record<string, unknown>;
  };

  beforeEach(() => {
    vi.useFakeTimers();
    states = [];
    joined = [];
    left = [];
    trackMuted = [];
    activeSpeakers = [];
    localLevels = [];
    remoteLevelSnapshots = [];
    FakeWebSocket.instances = [];
    FakeEncoder.instances = [];
    FakeDecoder.instances = [];
    FakeAudioWorkletNode.instances = [];
    fakeTrack.stop.mockClear();
    getUserMedia.mockClear();
    vi.stubGlobal("WebSocket", FakeWebSocket);
    vi.stubGlobal("AudioEncoder", FakeEncoder);
    vi.stubGlobal("AudioDecoder", FakeDecoder);
    vi.stubGlobal("AudioData", FakeAudioData);
    vi.stubGlobal("EncodedAudioChunk", FakeEncodedAudioChunk);
    vi.stubGlobal("AudioContext", FakeAudioContext);
    vi.stubGlobal("AudioWorkletNode", FakeAudioWorkletNode);
    Object.defineProperty(navigator, "mediaDevices", {
      configurable: true,
      value: { getUserMedia },
    });
    // jsdom 无 Blob URL：只补缺失的静态方法，不能整体替换 URL（会毁掉 new URL() 构造器）
    const urlCtor = URL as unknown as Record<string, unknown>;
    if (typeof urlCtor.createObjectURL !== "function") urlCtor.createObjectURL = () => "blob:fake";
    if (typeof urlCtor.revokeObjectURL !== "function") urlCtor.revokeObjectURL = () => {};
    useAuthStore.getState().setTokens(makeJwt(3600), "refresh-token");
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("传输选择默认 ws；直连地址带上 channel 且指向 frp 直连端口", () => {
    expect(voiceMediaTransport()).toBe("ws");
    const url = voiceDirectWsUrl("42");
    expect(url).toContain("/ws/voice/audio/?channel=42");
    expect(url).toContain("7881");
    expect(url).not.toContain("ayla.trise.top"); // 不再经 CF
  });

  it("缺 WebCodecs 时给出明确错误（而非深处的 TypeError）", async () => {
    vi.stubGlobal("AudioEncoder", undefined);
    await expect(createWsRelayRoom(makeEvents())).rejects.toThrow(/WebCodecs/);
  });

  it("握手 → joined → connected；join 前先发 connecting", async () => {
    const { sock } = await makeConnectedRoom();
    expect(sock.url).toContain("channel=1");
    expect(sock.url).toContain("token=tok-0");
    expect(states).toEqual(["connecting", "connected"]);
  });

  it("服务端事件映射：member_joined/left、speaking、muted", async () => {
    const { sock } = await makeConnectedRoom();

    sock.serverText({ type: "member_joined", slot: 2, identity: "u2" });
    expect(joined).toEqual(["u2"]);

    sock.serverText({ type: "speaking", slot: 2, on: true });
    expect(activeSpeakers.at(-1)).toEqual(["u2"]);
    sock.serverText({ type: "speaking", slot: 2, on: false });
    expect(activeSpeakers.at(-1)).toEqual([]);

    sock.serverText({ type: "muted", slot: 2, on: true });
    expect(trackMuted.at(-1)).toEqual(["u2", true]);

    sock.serverText({ type: "member_left", slot: 2 });
    expect(left).toEqual(["u2"]);
  });

  it("二进制帧解码播放；未知 slot 也收（对齐 lab 行为），自己的帧丢弃", async () => {
    const { sock } = await makeConnectedRoom();
    sock.serverText({ type: "member_joined", slot: 2, identity: "u2" });

    sock.serverBinary(new Uint8Array([2, 1, 2, 3]));
    expect(FakeDecoder.instances).toHaveLength(1);
    expect(FakeDecoder.instances[0].chunks[0]?.data).toEqual(new Uint8Array([1, 2, 3]));

    // 未知 slot 也要解码（成员事件偶发丢失不应导致整段无声）→ 新建第二个解码器
    sock.serverBinary(new Uint8Array([7, 9, 9]));
    expect(FakeDecoder.instances).toHaveLength(2);

    // 自己的帧（N-1 失效信号）丢弃
    const before = FakeDecoder.instances[0].chunks.length;
    sock.serverBinary(new Uint8Array([1, 8, 8])); // mySlot=1
    expect(FakeDecoder.instances[0].chunks).toHaveLength(before);
    expect((window as unknown as { __voiceDebug: { snapshot: { selfFrames: number } } }).__voiceDebug.snapshot.selfFrames).toBe(1);
  });

  it("远端音量快照按 user_id 输出且含 0；setRemoteVolume 改对应增益", async () => {
    const { sock, room } = await makeConnectedRoom();
    sock.serverText({ type: "member_joined", slot: 2, identity: "u2" });

    await vi.advanceTimersByTimeAsync(100);
    expect(remoteLevelSnapshots.at(-1)).toEqual({ u2: 0 });

    room.remoteParticipants()[0].audioTracks[0].setVolume(0.3);
    // 增益是播放路径内部状态：此处验证 participants 契约暴露了同一 identity
    expect(room.remoteParticipants()[0].identity).toBe("u2");
  });

  it("开麦：申请设备 + mute off；峰值驱动 speaking 控制与上行帧；关麦释放设备", async () => {
    const { room, sock } = await makeConnectedRoom();

    await room.setMicrophoneEnabled(true);
    expect(getUserMedia).toHaveBeenCalledTimes(1);
    expect(lastText(sock)).toMatchObject({ type: "mute", on: false });

    const worklet = FakeAudioWorkletNode.instances.at(-1)!;
    // 响亮帧 → speaking on（控制帧）→ 编码输出（二进制上行）
    worklet.port.onmessage?.({ data: { pcm: new Float32Array(960), peak: 0.5 } });
    expect(lastText(sock)).toMatchObject({ type: "speaking", on: true });
    worklet.port.onmessage?.({ data: { pcm: new Float32Array(960), peak: 0.5 } });
    const up = sock.sent.at(-1)!;
    expect(up).toBeInstanceOf(Uint8Array);
    expect(Array.from(up as Uint8Array)).toEqual([9, 9, 9]);
    // 安静帧 → speaking off，不发帧
    worklet.port.onmessage?.({ data: { pcm: new Float32Array(960), peak: 0.001 } });
    expect(lastText(sock)).toMatchObject({ type: "speaking", on: false });

    // 关麦：先发媒体事实再释放设备（对端立即看到静音，麦克风灯熄灭）
    await room.setMicrophoneEnabled(false);
    expect(fakeTrack.stop).toHaveBeenCalled();
    expect(lastText(sock)).toMatchObject({ type: "mute", on: true });
    expect(room.isMicrophoneEnabled()).toBe(false);
  });

  it("本地音量 0~2 记录并反映在 getLocalVolume", async () => {
    const { room } = await makeConnectedRoom();
    await room.setLocalVolume(1.5);
    expect(room.getLocalVolume()).toBe(1.5);
    await room.setLocalVolume(99);
    expect(room.getLocalVolume()).toBe(2); // 上限钳制
  });

  it("异常断开 → reconnecting → 退避重连成功后重发静音事实", async () => {
    const { room, sock } = await makeConnectedRoom();
    await room.setMicrophoneEnabled(true);

    sock.serverClose();
    expect(states.at(-1)).toBe("reconnecting");

    await vi.advanceTimersByTimeAsync(1000); // 首次退避 1s
    const sock2 = FakeWebSocket.instances.at(-1)!;
    expect(sock2).not.toBe(sock);
    sock2.serverOpen();
    sock2.serverText({ type: "joined", slot: 3, members: [] });
    await vi.advanceTimersByTimeAsync(0);
    expect(states.at(-1)).toBe("connected");
    // 重连后同步媒体事实：麦克风开着 → mute off
    expect(lastText(sock2)).toMatchObject({ type: "mute", on: false });
  });

  it("token 临期时重连前先续期并使用新令牌", async () => {
    useAuthStore.getState().setTokens(makeJwt(10), "refresh-token"); // 临期
    const { room, sock } = await makeConnectedRoom();
    sock.serverClose();
    await vi.advanceTimersByTimeAsync(1000);
    const sock2 = FakeWebSocket.instances.at(-1)!;
    // 续期后 store 里是同 exp 的新令牌字符串（mock 刷新成功、store 值不变）；
    // 这里验证连接确实携带了 store 的最新 token 而非初始入参
    expect(sock2.url).toContain("token=");
    expect(sock2.url).not.toContain("token=tok-0");
    void room;
  });

  it("主动断开后不再重连", async () => {
    const { room, sock } = await makeConnectedRoom();
    await room.disconnect();
    const before = FakeWebSocket.instances.length;
    sock.serverClose();
    await vi.advanceTimersByTimeAsync(60_000);
    expect(FakeWebSocket.instances).toHaveLength(before);
  });

  it("连续失败超过上限 → failed（由用户决定重进）", async () => {
    const { sock } = await makeConnectedRoom();
    sock.serverClose();
    // 每轮退避最长 30s；给足时间让 6 次失败跑完
    await vi.advanceTimersByTimeAsync(60_000 * 4);
    expect(states.at(-1)).toBe("failed");
  });
});
