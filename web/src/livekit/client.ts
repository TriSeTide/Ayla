/**
 * 语音媒体层薄封装（M5-3 §3.4 / §4.3）：连接/静音/音量/远端轨道/事件归一。
 *
 * 依赖倒置：VoiceLiveKitClient 只依赖 LiveKitRoomLike 接口；两个真实实现
 * （createLiveKitRoom / createWsRelayRoom）由工厂按服务端下发的 transport 选择，
 * 测试注入 fake —— 本文件是**唯一**同时认识两种传输的地方，页面/组件/store 不感知。
 *
 * 传输（2026-10-27 起）：**两条并存，服务端裁决 + 客户端原地降级**
 * - `livekit`：LiveKit 单 UDP 端口媒体面（实测 1/3/5 人 ICE=connected，candidate 为
 *   udp prflx，RTP 持续流动）。信令 `wss://…/livekit`，音量/指令走 REST 与 voice.state。
 * - `ws_relay`：WS 音频中继（Opus over WebSocket over TCP），**回滚路径**，一行未改。
 *
 * join 响应同时下发两种配置 ⇒ LiveKit 连接失败可**原地降级**到 ws_relay（一次连接尝试，
 * 不等发版、不回后端），降级不触发 leave/（媒体断线 ≠ 离开频道）。
 *
 * 语义边界（M5-3 §4.3）：
 * - 轨道 mute 是媒体事实；voice.state 的 muted/unmuted 是应用层成员事实——两者不混用，
 *   本封装只处理媒体层。
 * - 远端音量是本地播放偏好：只调本地轨道/元素音量，不落库、不上报。
 * - 媒体断线 ≠ 离开频道：断线只映射为 failed，由用户决定重进。
 * - token 纪律：token 只作为 connect 入参传递，不打日志、不缓存。
 */
import type { VoiceMediaConfig } from "../api/types";
import { createLiveKitRoom } from "./livekitRoom";
import { createWsRelayRoom } from "./wsRelayRoom";


/** LiveKit 连接状态（与 voice store 对齐） */
export type LiveKitState = "idle" | "connecting" | "connected" | "reconnecting" | "failed";

export interface LiveKitEvents {
  onStateChange?: (state: LiveKitState) => void;
  /** 远端参与者进出（identity = 应用 user_id，无 user_ 前缀） */
  onParticipantJoined?: (identity: string) => void;
  onParticipantLeft?: (identity: string) => void;
  /** 远端轨道静音事实（媒体层） */
  onTrackMuted?: (identity: string, muted: boolean) => void;
  /** 说话指示（active speaker 变化；identity = 应用 user_id） */
  onActiveSpeakers?: (identities: string[]) => void;
  /** 本地麦克风实时音量 0~1（自己说话音量跳动效果；未开麦/无轨道时连续回调 0） */
  onLocalAudioLevel?: (level: number) => void;
  /**
   * 远端成员实时音量（user_id → 0~1；server speaker update 轮询，含 0 的全量快照）。
   * 用于成员行显示"谁在说话"的音量跳动。
   */
  onRemoteAudioLevels?: (levels: Record<string, number>) => void;
}

/** 远端音频轨道抽象（真实实现 = RemoteAudioTrack） */
export interface RemoteAudioTrackLike {
  setVolume(volume: number): void;
}

export interface RemoteParticipantLike {
  identity: string;
  audioTracks: RemoteAudioTrackLike[];
}

/** Room 抽象（媒体引擎 Room 的最小面） */
export interface LiveKitRoomLike {
  connect(wsUrl: string, token: string): Promise<void>;
  disconnect(): Promise<void>;
  setMicrophoneEnabled(enabled: boolean): Promise<void>;
  isMicrophoneEnabled(): boolean;
  remoteParticipants(): RemoteParticipantLike[];
  /** 恢复音频播放（浏览器 autoplay 政策被阻断时，须在用户手势中调用） */
  startAudio(): Promise<void>;
  /** 本地麦克风音量 0~2（1 = 原始音量；改变自己说话别人听到的响度） */
  setLocalVolume(volume: number): Promise<void>;
  getLocalVolume(): number;
  /**
   * 远端成员本地播放音量 0~1（0 = 本地禁音）。
   *
   * 可选实现：**由房间自己记住该值**，并在该成员重新发布轨道（重新开麦）时
   * 自动重新施加。不实现时上层只能对"当前已存在的轨道"生效——
   * 对方重新开麦会产生新轨道，静音就被静默绕过（用户实报 2026-10-28）。
   */
  setRemoteVolume?(identity: string, volume: number): void;
}

/* ================= 封装客户端 ================= */

/** 媒体传输（与后端 VOICE_MEDIA_TRANSPORT / join 的 media.transport 同字面量） */
export type VoiceTransport = "livekit" | "ws_relay";

type RoomFactory = (events: LiveKitEvents) => Promise<LiveKitRoomLike> | LiveKitRoomLike;

/**
 * 缺省 Room 工厂：按传输选择实现（**默认 ws_relay**，与后端默认值一致）。
 *
 * 这是 web 侧接 LiveKit 的全部接入点：8 方法 / 7 回调的契约不变，
 * 上层（useVoiceChannel / store / 组件）完全无感。
 */
function defaultRoomFactory(transport: VoiceTransport): RoomFactory {
  return transport === "livekit" ? createLiveKitRoom : createWsRelayRoom;
}

/**
 * 脱敏：SDK 的原始错误消息可能夹带 token / 长凭据（JWTs 形如三段 base64url）。
 * AGENTS.md §9 要求日志不得泄露凭据，因此这里把长 token 形状的片段替换掉。
 */
function redact(text: string): string {
  return text
    .replace(/[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g, "<redacted-jwt>")
    .replace(/([?&](?:access_token|token|key|secret)=)[^&\s]+/gi, "$1<redacted>")
    .slice(0, 200);
}

/** 降级日志（结构化、便于判断"是否真的切成功了"；不含 token） */
function logTransportFallback(reason: unknown): void {
  const detail = redact(reason instanceof Error ? reason.message : String(reason));
  // 只记一句，不打印栈：降级是预期路径，不是崩溃
  console.warn(`[voice] transport_fallback from=livekit to=ws_relay reason=${detail}`);
}

interface RoomOwner {
  generation: number;
  room: LiveKitRoomLike | null;
  closing: Promise<void> | null;
  cancel: () => void;
}

function cancelledConnection(): DOMException {
  return new DOMException("LiveKit 连接已取消", "AbortError");
}

export class VoiceLiveKitClient {
  private owner: RoomOwner | null = null;
  private generation = 0;
  private events: LiveKitEvents = {};
  private roomFactory: RoomFactory | null = null;
  /** 本次连接实际使用的传输（降级后为 ws_relay；供排障与续签判断） */
  private transport: VoiceTransport = "ws_relay";
  /** 最近一次 connect 的媒体配置（livekit 失败时据此原地降级到 ws_relay） */
  private media: VoiceMediaConfig | null = null;

  /** 测试/替换用：注入 Room 工厂；缺省按 transport 选 createLiveKitRoom/createWsRelayRoom */
  setRoomFactory(factory: RoomFactory | null) {
    this.roomFactory = factory;
  }

  /** 本次连接实际使用的传输（降级后读回 ws_relay） */
  getTransport(): VoiceTransport {
    return this.transport;
  }

  /**
   * 按服务端下发的媒体配置连接。
   *
   * - `transport === "livekit"` 且配置完整 → 走 LiveKit；**连接失败原地降级**到
   *   `media.ws_relay.url`（服务端双下发，无需二次请求）；
   * - 其它情况 → 走 WS 中继（与旧行为逐字节一致）。
   * - 降级**不触发 leave/**：媒体断线 ≠ 离开频道（client.ts 既有契约）。
   */
  async connectWithMedia(
    media: VoiceMediaConfig | null | undefined,
    accessToken: string,
    /** 老后端不返回 media 时的回滚地址（= voiceDirectWsUrl(channelId)） */
    fallbackRelayUrl?: string,
  ): Promise<void> {
    const token = accessToken;
    if (!token) throw new Error("登录状态失效，请重新登录");
    const relayUrl = media?.ws_relay?.url ?? fallbackRelayUrl ?? "";
    const livekit = media?.livekit ?? null;
    const wantLiveKit = media?.transport === "livekit" && !!livekit?.url && !!livekit?.token;

    if (!wantLiveKit) {
      if (!relayUrl) throw new Error("语音媒体配置缺失");
      this.media = media ?? null;
      this.transport = "ws_relay";
      await this.connect(relayUrl, token);
      return;
    }

    this.media = media ?? null;
    this.transport = "livekit";
    try {
      await this.connect(livekit!.url, livekit!.token);
    } catch (error) {
      // 取消（用户切频道/离开）不是降级场景：原样向上抛，由调用方识别 AbortError
      if (error instanceof DOMException && error.name === "AbortError") throw error;
      if (!relayUrl) throw error; // 没有回滚路径：保持原错误（上层 show failed）
      logTransportFallback(error);
      this.transport = "ws_relay";
      await this.connect(relayUrl, token);
    }
  }

  /**
   * 长时通话续签：媒体 token 临期时重新取一份（TTL 由后端 LIVEKIT_TOKEN_TTL_SECONDS 决定）。
   * 仅 livekit 传输需要；ws_relay 由中继自己在重连前刷新 access token。
   */
  setMedia(media: VoiceMediaConfig | null | undefined) {
    this.media = media ?? null;
  }

  /** 最近一次连接的媒体配置（续签判断用；不含副作用） */
  getMedia(): VoiceMediaConfig | null {
    return this.media;
  }

  setEvents(events: LiveKitEvents) {
    this.events = events;
  }

  /** 新连接取代旧 owner；被取代或断开的请求以 AbortError 结束。 */
  async connect(wsUrl: string, token: string): Promise<void> {
    const previous = this.owner;
    let cancel!: () => void;
    const cancelled = new Promise<never>((_resolve, reject) => {
      cancel = () => reject(cancelledConnection());
    });
    const owner: RoomOwner = {
      generation: ++this.generation,
      room: null,
      closing: null,
      cancel,
    };
    this.owner = owner;
    previous?.cancel();
    const factory = this.roomFactory ?? defaultRoomFactory(this.transport);
    const events = this.guardedEvents(owner, this.events);
    const connectOwned = async () => {
      try {
        if (previous) await this.closeOwner(previous);
        this.assertCurrent(owner);
        const room = await factory(events);
        owner.room = room;
        this.assertCurrent(owner);
        await room.connect(wsUrl, token);
        this.assertCurrent(owner);
      } catch (error) {
        const stale = !this.isCurrent(owner);
        if (!stale) this.owner = null;
        // A non-cooperative connect may finish after the first disconnect.
        // Close that captured room again; never look up the current room here.
        await this.closeOwner(owner);
        owner.room = null;
        throw stale ? cancelledConnection() : error;
      }
    };
    // Cancellation must not wait for a pending factory or an SDK that ignores abort.
    await Promise.race([connectOwned(), cancelled]);
  }

  private isCurrent(owner: RoomOwner): boolean {
    return this.owner === owner && this.generation === owner.generation;
  }

  private assertCurrent(owner: RoomOwner): void {
    if (!this.isCurrent(owner)) throw cancelledConnection();
  }

  private guardedEvents(owner: RoomOwner, events: LiveKitEvents): LiveKitEvents {
    const guard = <T extends unknown[]>(callback: ((...args: T) => void) | undefined) =>
      callback ? (...args: T) => { if (this.isCurrent(owner)) callback(...args); } : undefined;
    return {
      onStateChange: guard(events.onStateChange),
      onParticipantJoined: guard(events.onParticipantJoined),
      onParticipantLeft: guard(events.onParticipantLeft),
      onTrackMuted: guard(events.onTrackMuted),
      onActiveSpeakers: guard(events.onActiveSpeakers),
      onLocalAudioLevel: guard(events.onLocalAudioLevel),
      onRemoteAudioLevels: guard(events.onRemoteAudioLevels),
    };
  }

  /** Deduplicate concurrent closes, but allow cleanup after a late connect settles. */
  private async closeOwner(owner: RoomOwner): Promise<void> {
    const room = owner.room;
    if (!room) return;
    if (owner.closing) return owner.closing;
    const closing = Promise.resolve().then(() => room.disconnect()).catch(() => {
      // Preserve the existing disconnect contract: local ownership is already revoked.
    });
    owner.closing = closing;
    await closing;
    if (owner.closing === closing) owner.closing = null;
  }

  private async onOwnedRoom(owner: RoomOwner, action: (room: LiveKitRoomLike) => Promise<void>): Promise<void> {
    const room = owner.room;
    if (!room) throw new Error("LiveKit 未连接");
    try {
      this.assertCurrent(owner);
      await action(room);
      this.assertCurrent(owner);
    } catch (error) {
      this.assertCurrent(owner);
      throw error;
    }
  }

  /** 静音切换（媒体层）；SDK 抛错向上抛，调用方回滚 UI */
  async setMicrophoneEnabled(enabled: boolean): Promise<void> {
    const owner = this.owner;
    if (!owner?.room) throw new Error("LiveKit 未连接");
    await this.onOwnedRoom(owner, (room) => room.setMicrophoneEnabled(enabled));
  }

  isMicrophoneEnabled(): boolean {
    return this.owner?.room?.isMicrophoneEnabled() ?? false;
  }

  /** 恢复远端音频播放（autoplay 被浏览器阻断时，在用户手势中调用） */
  async startAudio(): Promise<void> {
    const owner = this.owner;
    if (!owner?.room) return;
    await this.onOwnedRoom(owner, (room) => room.startAudio());
  }

  /** 设置远端成员本地播放音量（0~1）；只影响本地，不落库 */
  setRemoteVolume(identity: string, volume: number): void {
    const owner = this.owner;
    const room = owner?.room;
    if (!owner || !room) return;
    const clamped = Math.max(0, Math.min(1, volume));
    // 优先交给房间：它把该值记在 identity 上，等对方重新开麦（新轨道）时再施加一次。
    if (typeof room.setRemoteVolume === "function") {
      room.setRemoteVolume(identity, clamped);
      return;
    }
    for (const p of room.remoteParticipants()) {
      if (p.identity !== identity) continue;
      for (const track of p.audioTracks) {
        if (!this.isCurrent(owner)) return;
        track.setVolume(clamped);
      }
    }
  }

  /** 设置本地麦克风音量（0~2，1 = 原始）；改变自己说话别人听到的响度；未开麦时记录目标值 */
  async setLocalVolume(volume: number): Promise<void> {
    const owner = this.owner;
    if (!owner?.room) return;
    await this.onOwnedRoom(owner, (room) => room.setLocalVolume(volume));
  }

  /** 当前本地麦克风音量（0~2，1 = 原始） */
  getLocalVolume(): number {
    return this.owner?.room?.getLocalVolume() ?? 1;
  }

  /** 远端参与者 identity 列表 */
  remoteIdentities(): string[] {
    return this.owner?.room?.remoteParticipants().map((p) => p.identity) ?? [];
  }

  /** 断开（离开频道/组件卸载；幂等） */
  async disconnect(): Promise<void> {
    const owner = this.owner;
    this.owner = null;
    ++this.generation;
    if (!owner) return;
    owner.cancel();
    await this.closeOwner(owner);
  }
}

/** 单例 */
export const voiceLiveKit = new VoiceLiveKitClient();
