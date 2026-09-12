/**
 * 语音媒体层薄封装（M5-3 §3.4 / §4.3）：连接/静音/音量/远端轨道/事件归一。
 *
 * 依赖倒置：VoiceLiveKitClient 只依赖 LiveKitRoomLike 接口；真实实现由
 * createWsRelayRoom()（WS 音频中继，见 wsRelayRoom.ts）给出，测试注入 fake。
 *
 * 传输（2026-09-12 起）：**只有 WS 音频中继**。frp 穿透下 UDP 源地址被改写，
 * WebRTC/TURN 媒体面不可用；LiveKit 已整体退役（服务端 + livekit-client 依赖 +
 * VITE_VOICE_TRANSPORT 回滚开关全部移除）。
 *
 * 语义边界（M5-3 §4.3）：
 * - 轨道 mute 是媒体事实；voice.state 的 muted/unmuted 是应用层成员事实——两者不混用，
 *   本封装只处理媒体层。
 * - 远端音量是本地播放偏好：只调本地轨道/元素音量，不落库、不上报。
 * - 媒体断线 ≠ 离开频道：断线只映射为 failed，由用户决定重进。
 * - token 纪律：token 只作为 connect 入参传递，不打日志、不缓存。
 */
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
}

/* ================= 封装客户端 ================= */

type RoomFactory = (events: LiveKitEvents) => Promise<LiveKitRoomLike> | LiveKitRoomLike;

/** 缺省 Room 工厂：WS 音频中继（LiveKit 已退役，无回滚分支） */
function defaultRoomFactory(): RoomFactory {
  return createWsRelayRoom;
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

  /** 测试/替换用：注入 Room 工厂；缺省用真实 createWsRelayRoom */
  setRoomFactory(factory: RoomFactory | null) {
    this.roomFactory = factory;
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
    const factory = this.roomFactory ?? defaultRoomFactory();
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
