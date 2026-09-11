/**
 * WS 音频中继 Room —— `LiveKitRoomLike` 的中继实现（替代 livekit-client）。
 *
 * 背景（2026-09-11）：媒体经 frp 穿透时 UDP 源地址被改写，WebRTC/TURN 不可用；
 * 改走 ws/voice/audio/ 纯转发通道（复用 CF Tunnel 的 TCP 443），协议见
 * backend/apps/voice/audio_consumer.py 模块注释：
 *   C→S binary : 20ms Opus 包（仅 speaking 时发送）
 *   S→C binary : [1B slot][Opus 包]
 *   text       : joined / member_joined / member_left / speaking / muted / pong / error
 *
 * 契约（与 client.ts 的 LiveKitRoomLike/LiveKitEvents 逐条对应）：
 * - identity = 应用 user_id（后端 audio_relay 以 str(user.pk) 入房，无前缀）
 * - setMicrophoneEnabled(false) 完全释放麦克风设备（隐私：熄灭硬件指示灯），
 *   并向服务端发 mute on —— 对端经 onTrackMuted 看到静音事实
 * - setLocalVolume 0~2 改发送响度（增益链位于采集与编码之间）
 * - setRemoteVolume / remoteParticipants().audioTracks 按 user_id 生效（每 slot 增益）
 * - onLocalAudioLevel / onRemoteAudioLevels 由 100ms tick 输出，快照含 0（上层直接覆盖）
 * - 媒体断线自动重连（指数退避至 30s）：reconnecting → connected；
 *   连续失败先尝试刷新 access token，仍失败 → failed（用户决定重进，媒体断线 ≠ 离开频道）
 * - token 纪律：token 不打日志；重连前从 auth store 取最新值，临期先续期
 */
import { refreshAccessToken } from "../api/client";
import { useAuthStore } from "../stores/auth";
import type { LiveKitEvents, LiveKitRoomLike, RemoteAudioTrackLike, RemoteParticipantLike } from "./client";

/* ================= 传输选择（回滚开关） ================= */

export type VoiceMediaTransport = "ws" | "livekit";

/** 语音媒体传输方式：默认 WS 中继；VITE_VOICE_TRANSPORT=livekit 可回滚旧引擎 */
export function voiceMediaTransport(): VoiceMediaTransport {
  const raw = String((import.meta.env?.VITE_VOICE_TRANSPORT as string | undefined) ?? "ws").toLowerCase();
  return raw === "livekit" ? "livekit" : "ws";
}

/** 复制 ws/presence.ts 的取值逻辑而非导入它：避免 stores↔ws 的模块环在初始化期放大 */
const WS_BASE = ((import.meta.env as Record<string, string | undefined>)?.VITE_WS_BASE_URL) ?? "";

/** 中继 WS 端点（token 由 connect 入参另行携带，不预拼进 URL） */
export function relayWsUrl(channelId: string): string {
  return `${WS_BASE}/ws/voice/audio/?channel=${encodeURIComponent(channelId)}`;
}

/* ================= WebCodecs 最小类型（TS 5.6 lib.dom 未含 WebCodecs） ================= */

interface WsEncodedAudioChunk {
  byteLength: number;
  copyTo(dest: Uint8Array): void;
}
interface WsAudioData {
  numberOfFrames: number;
  sampleRate: number;
  copyTo(dest: Float32Array, options: { planeIndex: number; format: string }): void;
  close(): void;
}
interface WsAudioEncoder {
  configure(config: { codec: string; sampleRate: number; numberOfChannels: number; bitrate: number }): void;
  encode(data: WsAudioData): void;
  close(): void;
  readonly state: string;
}
interface WsAudioDecoder {
  configure(config: { codec: string; sampleRate: number; numberOfChannels: number }): void;
  decode(chunk: WsEncodedAudioChunk): void;
  close(): void;
}

type WsAudioEncoderCtor = new (init: {
  output: (chunk: WsEncodedAudioChunk, meta: unknown) => void;
  error: (error: unknown) => void;
}) => WsAudioEncoder;
type WsAudioDecoderCtor = new (init: {
  output: (audioData: WsAudioData) => void;
  error: (error: unknown) => void;
}) => WsAudioDecoder;
type WsAudioDataCtor = new (init: {
  format: string;
  sampleRate: number;
  numberOfFrames: number;
  numberOfChannels: number;
  timestamp: number;
  data: Float32Array;
}) => WsAudioData;
type WsEncodedAudioChunkCtor = new (init: {
  type: "key";
  timestamp: number;
  data: Uint8Array;
}) => WsEncodedAudioChunk;

/** 从 window 取构造器（避免全局类型声明与未来 TS lib 冲突） */
function webCodecs(): {
  AudioEncoder: WsAudioEncoderCtor;
  AudioDecoder: WsAudioDecoderCtor;
  AudioData: WsAudioDataCtor;
  EncodedAudioChunk: WsEncodedAudioChunkCtor;
} {
  const w = window as unknown as {
    AudioEncoder?: WsAudioEncoderCtor;
    AudioDecoder?: WsAudioDecoderCtor;
    AudioData?: WsAudioDataCtor;
    EncodedAudioChunk?: WsEncodedAudioChunkCtor;
  };
  if (!w.AudioEncoder || !w.AudioDecoder || !w.AudioData || !w.EncodedAudioChunk) {
    throw new Error("当前浏览器不支持 WebCodecs 音频（需 Chrome/Edge 94+），无法进行语音通话");
  }
  return { AudioEncoder: w.AudioEncoder, AudioDecoder: w.AudioDecoder, AudioData: w.AudioData, EncodedAudioChunk: w.EncodedAudioChunk };
}

/* ================= 常量 ================= */

const SAMPLE_RATE = 48000;
const FRAME_MS = 20;
const FRAME_SAMPLES = (SAMPLE_RATE * FRAME_MS) / 1000; // 960
const LEVEL_TICK_MS = 100;
// 说话判定用迟滞阈值：开 0.02 / 关 0.012。单一阈值会导致音量在阈值附近时
// speaking 每几百 ms 翻转一次（服务端日志实测），接收方听到断续的"颤音"
const SPEAKING_ON = 0.02;
const SPEAKING_OFF = 0.012;
const HANDSHAKE_TIMEOUT_MS = 10_000;
const RECONNECT_BASE_MS = 1_000;
const RECONNECT_MAX_MS = 30_000;
const RECONNECT_REFRESH_AFTER = 3; // 连续失败次数达到后尝试续期 token
const RECONNECT_GIVE_UP_AFTER = 6; // 连续失败达到后放弃（failed，由用户重进）
const PING_INTERVAL_MS = 25_000;

/** 采集 worklet：切 20ms 帧 + 峰值，源码内联（blob URL 加载，免打包配置） */
const CAPTURE_WORKLET = `
class RelayCapture extends AudioWorkletProcessor {
  constructor() {
    super();
    this.buf = new Float32Array(${FRAME_SAMPLES});
    this.n = 0;
    this.peak = 0;
  }
  process(inputs) {
    const ch = inputs[0] && inputs[0][0];
    if (!ch) return true;
    for (let i = 0; i < ch.length; i++) {
      const v = ch[i];
      this.buf[this.n++] = v;
      const a = Math.abs(v);
      if (a > this.peak) this.peak = a;
      if (this.n === ${FRAME_SAMPLES}) {
        this.port.postMessage({ pcm: this.buf.slice(), peak: this.peak });
        this.n = 0;
        this.peak = 0;
      }
    }
    return true;
  }
}
registerProcessor("relay-capture", RelayCapture);
`;

/* ================= 工具 ================= */

/** JWT payload 的 exp 剩余秒数（解析失败返回 0，视为已过期走续期） */
function jwtSecondsLeft(token: string): number {
  try {
    const part = token.split(".")[1];
    if (!part) return 0;
    let b64 = part.replace(/-/g, "+").replace(/_/g, "/");
    while (b64.length % 4) b64 += "=";
    const payload = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)))) as { exp?: number };
    return typeof payload.exp === "number" ? payload.exp - Date.now() / 1000 : 0;
  } catch {
    return 0;
  }
}

function wsClearTimeout(handle: number | null) {
  if (handle !== null) clearTimeout(handle);
}

/* ================= 实现 ================= */

/** 服务端控制帧（与 audio_consumer.py 的 send_json 载荷一致） */
type RelayServerFrame =
  | { type: "joined"; slot: number; members: Array<{ slot: number; identity: string; speaking?: boolean; muted?: boolean }> }
  | { type: "member_joined"; slot: number; identity: string }
  | { type: "member_left"; slot: number }
  | { type: "speaking"; slot: number; on: boolean }
  | { type: "muted"; slot: number; on: boolean }
  | { type: "pong"; ts: number }
  | { type: "error"; detail: string };

export async function createWsRelayRoom(events: LiveKitEvents): Promise<LiveKitRoomLike> {
  const codecs = webCodecs(); // 能力不满足 → factory 抛错，join 流程给出明确错误

  /* ---- 连接状态 ---- */
  let ws: WebSocket | null = null;
  let closed = true; // 用户已 disconnect：之后所有异步回调都不再动作
  let handshaken = false; // 当前连接是否收到过 joined
  let channelId = "";
  let reconnectTimer: number | null = null;
  let reconnectAttempts = 0;
  let consecutiveFailures = 0;
  let mySlot: number | null = null;

  /* ---- 诊断计数（window.__voiceDebug 暴露；F12 即可查看卡点） ---- */
  const debug = {
    binary: 0, // 收到的二进制帧总数
    decoded: 0, // 解码输出回调次数
    decodeError: 0, // 解码/播放异常次数
    suspended: 0, // AudioContext 非 running 的次数（autoplay 受阻信号）
    selfFrames: 0, // 收到自己帧的次数（N-1 失效信号）
    noDecoder: 0, // 解码器创建失败的次数
    lastError: "",
  };
  if (typeof window !== "undefined") {
    (window as unknown as { __voiceDebug: unknown }).__voiceDebug = {
      get snapshot() {
        return {
          ...debug,
          mySlot,
          members: [...slotToIdentity.entries()],
          decoders: decoders.size,
          outCtxState: outCtx?.state ?? "未创建",
          micEnabled,
          speakingSent,
          wsState: ws?.readyState ?? null,
        };
      },
    };
  }

  /* ---- 成员表（slot ↔ user_id）与说话/静音事实 ---- */
  const slotToIdentity = new Map<number, string>();
  const speakingSlots = new Set<number>();
  const mutedSlots = new Set<number>();

  /* ---- 音频（采集/播放/音量） ---- */
  let micEnabled = false;
  let micStream: MediaStream | null = null;
  let micCtx: AudioContext | null = null;
  let micSource: MediaStreamAudioSourceNode | null = null;
  let micGain: GainNode | null = null;
  let micWorklet: AudioWorkletNode | null = null;
  let micSink: GainNode | null = null;
  let encoder: WsAudioEncoder | null = null;
  let localVolume = 1;
  let speakingSent = false;
  let localPeak = 0;

  let outCtx: AudioContext | null = null;
  const decoders = new Map<number, WsAudioDecoder>();
  const playHead = new Map<number, number>();
  const slotGains = new Map<number, GainNode>();
  const slotLevels = new Map<number, number>();
  const remoteVolumes = new Map<string, number>(); // user_id → 0~1（跨重连保留）

  /* ---- 定时器 ---- */
  let levelTimer: number | null = null;
  let pingTimer: number | null = null;

  /* ---- token ---- */

  /** 取当前可用的 access token：临期先续期（静默），失败回退现值 */
  const freshToken = async (): Promise<string> => {
    let token = useAuthStore.getState().accessToken ?? "";
    if (!token) throw new Error("登录状态失效，请重新登录");
    if (jwtSecondsLeft(token) < 60) {
      const ok = await refreshAccessToken().catch(() => false);
      if (ok) token = useAuthStore.getState().accessToken ?? token;
    }
    return token;
  };

  /* ---- 下行：播放 + 音量 + 电平 ---- */

  const ensureOutCtx = (): AudioContext => {
    if (!outCtx) outCtx = new AudioContext({ sampleRate: SAMPLE_RATE });
    return outCtx;
  };

  const ensureSlotGain = (slot: number, identity: string): GainNode => {
    const ctx = ensureOutCtx();
    let gain = slotGains.get(slot);
    if (!gain) {
      gain = ctx.createGain();
      gain.gain.value = remoteVolumes.get(identity) ?? 1;
      gain.connect(ctx.destination);
      slotGains.set(slot, gain);
    }
    return gain;
  };

  const ensureDecoder = (slot: number): WsAudioDecoder | null => {
    const existing = decoders.get(slot);
    if (existing) return existing;
    let dec: WsAudioDecoder;
    try {
      dec = new codecs.AudioDecoder({
        output: (audioData) => {
          try {
            const ctx = ensureOutCtx();
            if (ctx.state !== "running") {
              debug.suspended += 1;
              void ctx.resume().catch(() => {});
            }
            debug.decoded += 1;
            const buf = ctx.createBuffer(1, audioData.numberOfFrames, audioData.sampleRate);
            const dst = buf.getChannelData(0);
            audioData.copyTo(dst, { planeIndex: 0, format: "f32-planar" });
            let peak = 0;
            for (let i = 0; i < dst.length; i++) {
              const a = Math.abs(dst[i]);
              if (a > peak) peak = a;
            }
            slotLevels.set(slot, peak);
            const src = ctx.createBufferSource();
            src.buffer = buf;
            src.connect(ensureSlotGain(slot, slotToIdentity.get(slot) ?? ""));
            const now = ctx.currentTime;
            let at = playHead.get(slot) ?? 0;
            // 抖动缓冲：落后 20ms 内顺延播放；积压超 400ms 视为断流，重置追赶
            if (at < now + 0.02 || at > now + 0.4) at = now + 0.02;
            src.start(at);
            playHead.set(slot, at + buf.duration);
          } catch (e) {
            debug.decodeError += 1;
            debug.lastError = `decode output: ${String(e)}`;
            throw e;
          } finally {
            audioData.close();
          }
        },
        error: () => {
          slotLevels.set(slot, 0);
        },
      });
    } catch {
      return null; // 解码器创建失败：丢帧不崩溃（levels 归 0）
    }
    dec.configure({ codec: "opus", sampleRate: SAMPLE_RATE, numberOfChannels: 1 });
    decoders.set(slot, dec);
    return dec;
  };

  const dropSlot = (slot: number) => {
    const dec = decoders.get(slot);
    if (dec) {
      try {
        dec.close();
      } catch {
        // 已关闭
      }
      decoders.delete(slot);
    }
    const gain = slotGains.get(slot);
    if (gain) {
      try {
        gain.disconnect();
      } catch {
        // 已断开
      }
      slotGains.delete(slot);
    }
    playHead.delete(slot);
    slotLevels.delete(slot);
    speakingSlots.delete(slot);
    mutedSlots.delete(slot);
  };

  /* ---- 事件映射 ---- */

  const identityFor = (slot: number): string | null => {
    if (slot === mySlot) return null;
    return slotToIdentity.get(slot) ?? null;
  };

  const emitActiveSpeakers = () => {
    const ids = [...speakingSlots]
      .map((slot) => identityFor(slot))
      .filter((id): id is string => id != null);
    events.onActiveSpeakers?.(ids);
  };

  const handleControl = (frame: RelayServerFrame) => {
    switch (frame.type) {
      case "joined": {
        mySlot = frame.slot;
        slotToIdentity.clear();
        for (const m of frame.members ?? []) slotToIdentity.set(m.slot, m.identity);
        handshaken = true;
        consecutiveFailures = 0;
        reconnectAttempts = 0;
        events.onStateChange?.("connected");
        break;
      }
      case "member_joined": {
        slotToIdentity.set(frame.slot, frame.identity);
        events.onParticipantJoined?.(frame.identity);
        break;
      }
      case "member_left": {
        const identity = slotToIdentity.get(frame.slot);
        dropSlot(frame.slot);
        if (identity) events.onParticipantLeft?.(identity);
        break;
      }
      case "speaking": {
        if (frame.slot === mySlot) break;
        if (frame.on) speakingSlots.add(frame.slot);
        else speakingSlots.delete(frame.slot);
        emitActiveSpeakers();
        break;
      }
      case "muted": {
        const identity = identityFor(frame.slot);
        if (frame.on) mutedSlots.add(frame.slot);
        else mutedSlots.delete(frame.slot);
        if (identity && !frame.on) speakingSlots.delete(frame.slot);
        if (identity) events.onTrackMuted?.(identity, frame.on);
        if (!frame.on) emitActiveSpeakers();
        break;
      }
      case "error":
        // 服务端拒绝某类控制消息；不中断媒体，仅暴露给上层日志渠道
        break;
      case "pong":
        break;
    }
  };

  const handleBinary = (buf: ArrayBuffer) => {
    const bytes = new Uint8Array(buf);
    if (bytes.length < 2) return;
    debug.binary += 1;
    const slot = bytes[0];
    if (slot === mySlot) {
      debug.selfFrames += 1; // 不应发生（服务端已做 N-1）；仅计数
      return;
    }
    // 不再要求 slot 已登记（对齐 lab 行为）：成员事件偶发丢失不应导致整段无声。
    // identity 未知时增益取默认 1，member 事件到达后自动归位。
    const dec = ensureDecoder(slot);
    if (!dec) {
      debug.noDecoder += 1;
      return;
    }
    try {
      // AudioDecoder.decode 做品牌检查：必须传入真正的 EncodedAudioChunk 实例，
      // 普通对象字面量会被 Chrome 以 "parameter 1 is not of type 'EncodedAudioChunk'" 拒绝
      const chunk = new codecs.EncodedAudioChunk({
        type: "key",
        timestamp: performance.now() * 1000,
        data: bytes.subarray(1),
      });
      dec.decode(chunk);
    } catch (e) {
      debug.decodeError += 1;
      debug.lastError = `decode: ${String(e)}`;
      slotLevels.set(slot, 0);
    }
  };

  /* ---- 100ms tick：本地/远端音量快照 ---- */

  const tick = () => {
    if (closed) return;
    // 本地电平：未开麦恒 0（契约：未开麦连续回调 0）；开麦用最近峰值并衰减
    if (events.onLocalAudioLevel) {
      const level = micEnabled ? localPeak : 0;
      events.onLocalAudioLevel(Math.max(0, Math.min(1, level)));
      localPeak *= 0.6;
    }
    if (events.onRemoteAudioLevels) {
      const levels: Record<string, number> = {};
      for (const [slot, identity] of slotToIdentity) {
        if (slot === mySlot) continue;
        levels[identity] = Math.max(0, Math.min(1, slotLevels.get(slot) ?? 0));
        slotLevels.set(slot, (slotLevels.get(slot) ?? 0) * 0.6);
      }
      events.onRemoteAudioLevels(levels);
    }
  };

  const startTimers = () => {
    if (levelTimer === null) levelTimer = window.setInterval(tick, LEVEL_TICK_MS);
    if (pingTimer === null) {
      pingTimer = window.setInterval(() => {
        sendControl({ type: "ping", ts: Date.now() });
      }, PING_INTERVAL_MS);
    }
  };

  /* ---- 上行：采集 + 编码 + speaking 检测 ---- */

  const sendControl = (msg: { type: string; on?: boolean; ts?: number }) => {
    if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg));
  };

  const startCapture = async () => {
    if (micCtx) return;
    micStream = await navigator.mediaDevices.getUserMedia({
      audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    });
    micCtx = new AudioContext({ sampleRate: SAMPLE_RATE });
    if (micCtx.state === "suspended") await micCtx.resume().catch(() => {});
    const url = URL.createObjectURL(new Blob([CAPTURE_WORKLET], { type: "application/javascript" }));
    try {
      await micCtx.audioWorklet.addModule(url);
    } finally {
      URL.revokeObjectURL(url);
    }
    encoder = new codecs.AudioEncoder({
      output: (chunk) => {
        // 断线重连窗口（ws 非 OPEN）直接丢弃：语音是实时流，补发无意义
        if (!ws || ws.readyState !== WebSocket.OPEN || !micEnabled) return;
        const out = new Uint8Array(chunk.byteLength);
        chunk.copyTo(out);
        ws.send(out);
      },
      error: () => {
        // 编码器异常：停止发送（本地电平归 0），不拖垮连接
        void stopCapture();
      },
    });
    encoder.configure({ codec: "opus", sampleRate: SAMPLE_RATE, numberOfChannels: 1, bitrate: 32000 });

    micSource = micCtx.createMediaStreamSource(micStream);
    micGain = micCtx.createGain(); // 本地音量 0~2：改变自己说话别人听到的响度
    micGain.gain.value = localVolume;
    micWorklet = new AudioWorkletNode(micCtx, "relay-capture");
    micWorklet.port.onmessage = ({ data }: MessageEvent<{ pcm: Float32Array; peak: number }>) => {
      if (!micEnabled || !encoder || encoder.state !== "configured") return;
      localPeak = data.peak;
      const speaking = speakingSent ? data.peak > SPEAKING_OFF : data.peak > SPEAKING_ON;
      if (speaking !== speakingSent) {
        speakingSent = speaking;
        sendControl({ type: "speaking", on: speaking });
      }
      if (!speaking) return; // 静音不发帧：带宽由客户端先兜一层
      const ad = new codecs.AudioData({
        format: "f32-planar",
        sampleRate: SAMPLE_RATE,
        numberOfFrames: FRAME_SAMPLES,
        numberOfChannels: 1,
        timestamp: performance.now() * 1000,
        data: data.pcm,
      });
      encoder.encode(ad);
      ad.close();
    };
    micSource.connect(micGain);
    micGain.connect(micWorklet);
    // AudioWorklet 需有下游才被驱动；静音 gain 收尾
    micSink = micCtx.createGain();
    micSink.gain.value = 0;
    micWorklet.connect(micSink);
    micSink.connect(micCtx.destination);
  };

  const stopCapture = async () => {
    try {
      if (encoder) encoder.close();
    } catch {
      // 已关闭
    }
    encoder = null;
    try {
      micSource?.disconnect();
      micGain?.disconnect();
      micWorklet?.disconnect();
      micSink?.disconnect();
    } catch {
      // 已断开
    }
    micSource = null;
    micGain = null;
    micWorklet = null;
    micSink = null;
    try {
      micStream?.getTracks().forEach((t) => t.stop());
    } catch {
      // 已停止
    }
    micStream = null;
    try {
      await micCtx?.close();
    } catch {
      // 已关闭
    }
    micCtx = null;
    localPeak = 0;
    if (speakingSent) {
      speakingSent = false;
      sendControl({ type: "speaking", on: false });
    }
  };

  /* ---- 连接与重连 ---- */

  const clearSocket = (socket: WebSocket) => {
    socket.onopen = null;
    socket.onmessage = null;
    socket.onclose = null;
    socket.onerror = null;
  };

  const handleSocketClose = () => {
    if (closed) return;
    if (!handshaken) return; // 握手期失败由 openOnce 的 reject 处理
    // 已建立的连接异常断开 → 指数退避重连（媒体断线 ≠ 离开频道）
    events.onStateChange?.("reconnecting");
    speakingSent = false;
    mySlot = null;
    for (const slot of [...decoders.keys()]) dropSlot(slot); // 拷贝后再删：边遍历边删会跳项
    scheduleReconnect();
  };

  const openOnce = (token: string): Promise<void> =>
    new Promise<void>((resolve, reject) => {
      let settled = false;
      const socket = new WebSocket(`${relayWsUrl(channelId)}&token=${encodeURIComponent(token)}`);
      socket.binaryType = "arraybuffer";
      const timeout = window.setTimeout(() => {
        if (settled) return;
        settled = true;
        clearSocket(socket);
        try {
          socket.close();
        } catch {
          // 未 open
        }
        reject(new Error("语音通道连接超时"));
      }, HANDSHAKE_TIMEOUT_MS);

      socket.onmessage = (ev: MessageEvent) => {
        if (typeof ev.data !== "string") {
          // 二进制 = [1B slot][Opus]；握手期不该出现，忽略
          if (settled) handleBinary(ev.data as ArrayBuffer);
          return;
        }
        let frame: RelayServerFrame;
        try {
          frame = JSON.parse(ev.data) as RelayServerFrame;
        } catch {
          return;
        }
        if (frame.type === "joined" && !settled) {
          settled = true;
          wsClearTimeout(timeout);
          ws = socket;
          handshaken = true;
          handleControl(frame);
          startTimers();
          resolve();
          return;
        }
        handleControl(frame);
      };
      socket.onclose = () => {
        if (ws === socket) ws = null;
        if (!settled) {
          // 握手期失败：reject 给调用方（首次 connect 抛错 / 重连安排下一次退避）
          settled = true;
          wsClearTimeout(timeout);
          clearSocket(socket);
          reject(new Error("语音通道握手被拒（未认证、非频道成员或服务不可用）"));
          return;
        }
        handleSocketClose();
      };
      socket.onerror = () => {
        if (settled) return;
        settled = true;
        wsClearTimeout(timeout);
        clearSocket(socket);
        reject(new Error("语音通道连接失败"));
      };
    });

  const scheduleReconnect = () => {
    if (closed || reconnectTimer !== null) return;
    const delay = Math.min(RECONNECT_MAX_MS, RECONNECT_BASE_MS * 2 ** reconnectAttempts);
    reconnectAttempts += 1;
    reconnectTimer = window.setTimeout(() => {
      reconnectTimer = null;
      void attemptReconnect();
    }, delay);
  };

  const attemptReconnect = async () => {
    if (closed) return;
    consecutiveFailures += 1;
    if (consecutiveFailures > RECONNECT_GIVE_UP_AFTER) {
      events.onStateChange?.("failed");
      return; // 用户决定重进（join 幂等路径）
    }
    if (consecutiveFailures >= RECONNECT_REFRESH_AFTER) {
      await refreshAccessToken().catch(() => false); // token 过期是断连最常见的持久原因
    }
    try {
      const token = await freshToken();
      await openOnce(token);
      // 重连成功：向新房间同步媒体事实（服务端房间表是按连接重建的）
      sendControl({ type: "mute", on: !micEnabled });
    } catch {
      scheduleReconnect();
    }
  };

  /* ---- LiveKitRoomLike ---- */

  const room: LiveKitRoomLike = {
    async connect(url, token) {
      let parsed: URL;
      try {
        parsed = new URL(url, window.location.href);
      } catch {
        throw new Error("语音通道地址无效");
      }
      const id = parsed.searchParams.get("channel");
      if (!id) throw new Error("语音通道缺少 channel 参数");
      if (!token) throw new Error("登录状态失效，请重新登录");
      channelId = id;
      closed = false;
      handshaken = false;
      consecutiveFailures = 0;
      reconnectAttempts = 0;
      events.onStateChange?.("connecting");
      try {
        await openOnce(token);
      } catch (error) {
        closed = true;
        events.onStateChange?.("failed");
        throw error;
      }
      // 播放上下文提前创建并 resume：不等第一帧解码（autoplay 策略下，
      // 越早出现在用户手势链里越可靠），与 startAudio() 双保险
      const ctx = ensureOutCtx();
      if (ctx.state === "suspended") void ctx.resume().catch(() => {});
      // 新入房：默认静音事实同步给服务端（join 流程随后按选项开麦）
      sendControl({ type: "mute", on: !micEnabled });
    },

    async disconnect() {
      closed = true;
      wsClearTimeout(reconnectTimer);
      reconnectTimer = null;
      if (levelTimer !== null) {
        clearInterval(levelTimer);
        levelTimer = null;
      }
      if (pingTimer !== null) {
        clearInterval(pingTimer);
        pingTimer = null;
      }
      await stopCapture();
      const socket = ws;
      ws = null;
      if (socket) {
        clearSocket(socket);
        try {
          socket.close(1000, "leave");
        } catch {
          // 已关闭
        }
      }
      for (const slot of [...decoders.keys()]) dropSlot(slot); // 拷贝后再删：边遍历边删会跳项
      slotToIdentity.clear();
      slotGains.clear();
      remoteVolumes.clear();
      mySlot = null;
      handshaken = false;
      try {
        await outCtx?.close();
      } catch {
        // 已关闭
      }
      outCtx = null;
    },

    async setMicrophoneEnabled(enabled) {
      if (enabled === micEnabled) return;
      if (enabled) {
        await startCapture();
        micEnabled = true;
        sendControl({ type: "mute", on: false });
      } else {
        micEnabled = false;
        // 先发媒体事实再释放设备：对端立刻看到静音，本机麦克风指示灯熄灭
        sendControl({ type: "mute", on: true });
        await stopCapture();
      }
    },

    isMicrophoneEnabled() {
      return micEnabled;
    },

    startAudio: async () => {
      const ctx = ensureOutCtx();
      if (ctx.state === "suspended") await ctx.resume().catch(() => {});
    },

    async setLocalVolume(volume) {
      localVolume = Math.max(0, Math.min(2, volume));
      if (micGain) micGain.gain.value = localVolume;
    },

    getLocalVolume() {
      return localVolume;
    },

    remoteParticipants(): RemoteParticipantLike[] {
      return [...slotToIdentity.entries()]
        .filter(([slot]) => slot !== mySlot)
        .map(([slot, identity]) => ({
          identity,
          audioTracks: [
            {
              // LiveKit 的 RemoteAudioTrack.setVolume 语义：0~1 本地播放音量
              setVolume(volume: number) {
                const clamped = Math.max(0, Math.min(1, volume));
                remoteVolumes.set(identity, clamped);
                const gain = slotGains.get(slot);
                if (gain) gain.gain.value = clamped;
              },
            } satisfies RemoteAudioTrackLike,
          ],
        }));
    },
  };

  return room;
}
