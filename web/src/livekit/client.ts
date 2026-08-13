/**
 * LiveKit 薄封装（M5-3 §3.4 / §4.3）：连接/静音/音量/远端轨道/事件归一。
 *
 * 依赖倒置：VoiceLiveKitClient 只依赖 LiveKitRoomLike 接口；真实实现由
 * createLiveKitRoom()（livekit-client 动态导入）给出，测试注入 fake。
 *
 * 语义边界（M5-3 §4.3）：
 * - 轨道 mute 是媒体事实（LiveKit 层）；voice.state 的 muted/unmuted 是应用层
 *   成员事实——两者不混用，本封装只处理媒体层。
 * - 远端音量是本地播放偏好：只调本地轨道/元素音量，不落库、不上报。
 * - 媒体断线 ≠ 离开频道：Disconnected 只映射为 livekit="failed"，由用户决定重进。
 * - token 纪律：token 只作为 connect 入参传递，不打日志、不缓存。
 */

/** LiveKit 连接状态（与 voice store 对齐） */
export type LiveKitState = "idle" | "connecting" | "connected" | "reconnecting" | "failed";

export interface LiveKitEvents {
  onStateChange?: (state: LiveKitState) => void;
  /** 远端参与者进出（user identity = 应用 user_id） */
  onParticipantJoined?: (identity: string) => void;
  onParticipantLeft?: (identity: string) => void;
  /** 远端轨道静音事实（媒体层） */
  onTrackMuted?: (identity: string, muted: boolean) => void;
  /** 说话指示（active speaker 变化） */
  onActiveSpeakers?: (identities: string[]) => void;
}

/** 远端音频轨道抽象（真实实现 = RemoteAudioTrack） */
export interface RemoteAudioTrackLike {
  setVolume(volume: number): void;
}

export interface RemoteParticipantLike {
  identity: string;
  audioTracks: RemoteAudioTrackLike[];
}

/** Room 抽象（livekit-client Room 的最小面） */
export interface LiveKitRoomLike {
  connect(wsUrl: string, token: string): Promise<void>;
  disconnect(): Promise<void>;
  setMicrophoneEnabled(enabled: boolean): Promise<void>;
  isMicrophoneEnabled(): boolean;
  remoteParticipants(): RemoteParticipantLike[];
}

/* ================= 真实实现（livekit-client 动态导入） ================= */

type RoomEventName =
  | "Disconnected"
  | "Reconnecting"
  | "Reconnected"
  | "ParticipantConnected"
  | "ParticipantDisconnected"
  | "TrackMuted"
  | "TrackUnmuted"
  | "ActiveSpeakersChanged";

interface LiveKitRoomInternal {
  on(event: RoomEventName, cb: (...args: unknown[]) => void): void;
  removeAllListeners(): void;
  connect(url: string, token: string): Promise<void>;
  disconnect(): Promise<void>;
  localParticipant: {
    setMicrophoneEnabled(enabled: boolean): Promise<unknown>;
    isMicrophoneEnabled: boolean;
  };
  remoteParticipants: Map<string, LiveKitRemoteParticipantInternal>;
}

interface LiveKitRemoteParticipantInternal {
  identity: string;
  audioTrackPublications: Map<string, { track: { setVolume(v: number): void } | null }>;
}

/**
 * 创建真实 Room（动态导入 livekit-client，未安装/加载失败时抛出明确错误）。
 * 音量实现：遍历 participant.audioTrackPublications 取 RemoteAudioTrack.setVolume()。
 */
export async function createLiveKitRoom(events: LiveKitEvents): Promise<LiveKitRoomLike> {
  const mod = (await import("livekit-client")) as unknown as {
    Room: new () => LiveKitRoomInternal;
  };
  const room = new mod.Room();

  const emitRemoteIdentities = () =>
    [...room.remoteParticipants.values()].map((p) => p.identity);

  room.on("Reconnecting", () => events.onStateChange?.("reconnecting"));
  room.on("Reconnected", () => events.onStateChange?.("connected"));
  room.on("Disconnected", () => events.onStateChange?.("failed"));
  room.on("ParticipantConnected", (p) => {
    events.onParticipantJoined?.((p as LiveKitRemoteParticipantInternal).identity);
  });
  room.on("ParticipantDisconnected", (p) => {
    events.onParticipantLeft?.((p as LiveKitRemoteParticipantInternal).identity);
  });
  room.on("TrackMuted", (_pub, participant) => {
    events.onTrackMuted?.((participant as LiveKitRemoteParticipantInternal).identity, true);
  });
  room.on("TrackUnmuted", (_pub, participant) => {
    events.onTrackMuted?.((participant as LiveKitRemoteParticipantInternal).identity, false);
  });
  room.on("ActiveSpeakersChanged", (speakers) => {
    events.onActiveSpeakers?.(
      (speakers as LiveKitRemoteParticipantInternal[]).map((s) => s.identity),
    );
  });

  return {
    async connect(wsUrl, token) {
      await room.connect(wsUrl, token);
      events.onStateChange?.("connected");
    },
    async disconnect() {
      room.removeAllListeners();
      await room.disconnect();
    },
    async setMicrophoneEnabled(enabled) {
      await room.localParticipant.setMicrophoneEnabled(enabled);
    },
    isMicrophoneEnabled() {
      return room.localParticipant.isMicrophoneEnabled;
    },
    remoteParticipants() {
      void emitRemoteIdentities;
      return [...room.remoteParticipants.values()].map((p) => ({
        identity: p.identity,
        audioTracks: [...p.audioTrackPublications.values()]
          .map((pub) => pub.track)
          .filter((t): t is { setVolume(v: number): void } => t != null),
      }));
    },
  };
}

/* ================= 封装客户端 ================= */

type RoomFactory = (events: LiveKitEvents) => Promise<LiveKitRoomLike> | LiveKitRoomLike;

export class VoiceLiveKitClient {
  private room: LiveKitRoomLike | null = null;
  private events: LiveKitEvents = {};
  private roomFactory: RoomFactory | null = null;

  /** 测试/替换用：注入 Room 工厂；缺省用真实 createLiveKitRoom */
  setRoomFactory(factory: RoomFactory | null) {
    this.roomFactory = factory;
  }

  setEvents(events: LiveKitEvents) {
    this.events = events;
  }

  /** 连接房间（token 不打日志）；失败抛错由调用方回滚 */
  async connect(wsUrl: string, token: string): Promise<void> {
    await this.disconnect();
    const factory = this.roomFactory ?? createLiveKitRoom;
    this.room = await factory(this.events);
    await this.room.connect(wsUrl, token);
  }

  /** 静音切换（媒体层）；SDK 抛错向上抛，调用方回滚 UI */
  async setMicrophoneEnabled(enabled: boolean): Promise<void> {
    if (!this.room) throw new Error("LiveKit 未连接");
    await this.room.setMicrophoneEnabled(enabled);
  }

  isMicrophoneEnabled(): boolean {
    return this.room?.isMicrophoneEnabled() ?? false;
  }

  /** 设置远端成员本地播放音量（0~1）；只影响本地，不落库 */
  setRemoteVolume(identity: string, volume: number): void {
    if (!this.room) return;
    const clamped = Math.max(0, Math.min(1, volume));
    for (const p of this.room.remoteParticipants()) {
      if (p.identity !== identity) continue;
      for (const track of p.audioTracks) track.setVolume(clamped);
    }
  }

  /** 远端参与者 identity 列表 */
  remoteIdentities(): string[] {
    return this.room?.remoteParticipants().map((p) => p.identity) ?? [];
  }

  /** 断开（离开频道/组件卸载；幂等） */
  async disconnect(): Promise<void> {
    const room = this.room;
    this.room = null;
    if (room) {
      try {
        await room.disconnect();
      } catch {
        // 断开失败不阻塞本地状态重置
      }
    }
  }
}

/** 单例 */
export const voiceLiveKit = new VoiceLiveKitClient();
