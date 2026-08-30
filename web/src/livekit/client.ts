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

/** Room 抽象（livekit-client Room 的最小面） */
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

/* ================= 真实实现（livekit-client 动态导入） ================= */

/**
 * livekit-client RoomEvent 枚举的**实际字符串值**（camelCase）。
 *
 * 事故（2026-08-26 语音连麦「先入房者听不到后入房开麦者」）：这里曾误写成
 * PascalCase（"TrackSubscribed" 等），而 RoomEvent 是 camelCase（"trackSubscribed"），
 * 导致所有 room.on() 监听器静默失效——尤其 TrackSubscribed 不触发，后进房者开麦的
 * 音频轨不会被 attach，先入房者听不见；重进时靠 attachExistingRemoteAudio 补齐才听见。
 * 测试没拦住是因为 mock 也用了同样的 PascalCase（已同步修正）。
 * 事件名必须与 livekit-client `RoomEvent` 枚举值逐字一致，改前先核对 events.ts。
 */
type RoomEventName =
  | "disconnected"
  | "reconnecting"
  | "reconnected"
  | "participantConnected"
  | "participantDisconnected"
  | "trackSubscribed"
  | "trackUnsubscribed"
  | "trackMuted"
  | "trackUnmuted"
  | "activeSpeakersChanged";

interface LiveKitRoomInternal {
  on(event: RoomEventName, cb: (...args: unknown[]) => void): void;
  removeAllListeners(): void;
  connect(url: string, token: string): Promise<void>;
  disconnect(): Promise<void>;
  startAudio(): Promise<void>;
  localParticipant: {
    setMicrophoneEnabled(enabled: boolean): Promise<unknown>;
    isMicrophoneEnabled: boolean;
    audioTrackPublications: Map<
      string,
      {
        track:
          | {
              kind: string;
              setProcessor(processor: unknown): Promise<void>;
              stopProcessor(): Promise<void>;
              getProcessor(): unknown;
            }
          | null;
      }
    >;
  };
  remoteParticipants: Map<string, LiveKitRemoteParticipantInternal>;
}

/** createAudioAnalyser 返回的最小面（calculateVolume 0~1 + cleanup） */
interface AudioAnalyserLike {
  calculateVolume(): number;
  cleanup(): Promise<void>;
  /** analyser 节点（context 用于 resume——autoplay 策略下 AudioContext 默认 suspended；
   *  smoothingTimeConstant 默认 0.8 → 声音停止后音量衰减滞后约 1s，跳动条"没声了还亮着"，须调小） */
  analyser: { context: { state: string }; smoothingTimeConstant?: number };
}

interface LiveKitRemoteParticipantInternal {
  identity: string;
  /** server speaker update 写入的实时音量 0~1（说话时更新；安静时接近 0） */
  audioLevel: number;
  audioTrackPublications: Map<string, { track: { setVolume(v: number): void } | null }>;
}

interface LiveKitRemoteTrackInternal {
  kind: string;
  attach(): HTMLMediaElement;
  detach(): HTMLMediaElement[];
}

/** 远端音频轨道 attach 到隐藏容器（audio 元素 autoplay，livekit 自动播放） */
function ensureAudioContainer(): HTMLDivElement {
  let container = document.getElementById("ayla-voice-audio") as HTMLDivElement | null;
  if (!container) {
    container = document.createElement("div");
    container.id = "ayla-voice-audio";
    container.hidden = true;
    document.body.appendChild(container);
  }
  return container;
}

/**
 * LiveKit participant identity → 应用 user_id。
 *
 * 后端 token 签发 identity = `user_<user.id>`（后端 apps/voice/livekit.py with_identity），
 * 而应用层 user_id（voice.state / members 表 / store key）是不带前缀的裸 id。
 * 所有对外暴露的 identity 统一剥掉 `user_` 前缀，否则上层用 user_id 匹配
 * （setRemoteVolume / onTrackMuted 查 members）永远失配 → 音量调节无效。
 */
function toAppUserId(lkIdentity: string): string {
  return lkIdentity.startsWith("user_") ? lkIdentity.slice("user_".length) : lkIdentity;
}

/**
 * 本地麦克风音量处理器（Web Audio 增益链，0~2，1 = 原始音量）。
 *
 * 背景：livekit-client 2.21 的 LocalAudioTrack 没有 setVolume()（只有 RemoteAudioTrack
 * 有），要「调节自己说话的音量」（别人听到的响度）只能走官方 TrackProcessor 扩展点：
 * 用 AudioContext 把本地麦克风轨接 MediaStreamSource → GainNode → MediaStreamDestination，
 * 把输出的 processedTrack 交给 LiveKit 发布；setGain 实时改 GainNode.gain。
 *
 * 默认不挂（gain 1 时无处理链、音质零损耗）；仅当用户把音量拉到 ≠100% 时才懒挂载。
 */
interface LocalGainProcessor {
  name: string;
  processedTrack?: MediaStreamTrack;
  init(opts: { audioContext: AudioContext; track: MediaStreamTrack }): Promise<void>;
  restart(opts: { audioContext: AudioContext; track: MediaStreamTrack }): Promise<void>;
  destroy(): Promise<void>;
  setGain(value: number): void;
}

function createGainProcessor(): LocalGainProcessor {
  let ctx: AudioContext | null = null;
  let source: MediaStreamAudioSourceNode | null = null;
  let gainNode: GainNode | null = null;
  let dest: MediaStreamAudioDestinationNode | null = null;
  let gain = 1;

  const p: LocalGainProcessor = {
    name: "local-mic-volume",
    processedTrack: undefined,
    setGain(value) {
      gain = Math.max(0, Math.min(2, value));
      if (gainNode) gainNode.gain.value = gain;
    },
    async init(opts) {
      ctx = opts.audioContext;
      source = ctx.createMediaStreamSource(new MediaStream([opts.track]));
      gainNode = ctx.createGain();
      gainNode.gain.value = gain;
      dest = ctx.createMediaStreamDestination();
      source.connect(gainNode);
      gainNode.connect(dest);
      p.processedTrack = dest.stream.getAudioTracks()[0];
    },
    async restart(opts) {
      await p.destroy();
      await p.init(opts);
    },
    async destroy() {
      if (source) source.disconnect();
      if (gainNode) gainNode.disconnect();
      if (dest) dest.disconnect();
      source = null;
      gainNode = null;
      dest = null;
      ctx = null;
      p.processedTrack = undefined;
    },
  };
  return p;
}

/**
 * 创建真实 Room（动态导入 livekit-client，未安装/加载失败时抛出明确错误）。
 * 音量实现：遍历 participant.audioTrackPublications 取 RemoteAudioTrack.setVolume()。
 * 播放实现：TrackSubscribed 时对音频轨道 attach() 到隐藏容器（livekit-client
 * 不自动 attach，漏掉会导致「听不见对方声音」）。
 */
export async function createLiveKitRoom(events: LiveKitEvents): Promise<LiveKitRoomLike> {
  const mod = (await import("livekit-client")) as unknown as {
    Room: new () => LiveKitRoomInternal;
    createAudioAnalyser: (
      track: { kind: string },
      options?: { fftSize?: number; smoothingTimeConstant?: number },
    ) => AudioAnalyserLike;
  };
  const room = new mod.Room();

  const emitRemoteIdentities = () =>
    [...room.remoteParticipants.values()].map((p) => p.identity);

  // ---- 本地麦克风音量监测（自己说话音量跳动） ----
  // 用 livekit 官方 createAudioAnalyser 对本地音频轨道做 Web Audio 分析，
  // 轮询 calculateVolume()（0~1）回调给上层。无轨道/未开麦时回调 0。
  // 注：createAudioAnalyser 返回的是 calculateVolume/cleanup（2.21 API），
  // 不是 getLevel/destroy——用错会导致开麦后 TypeError，跳动永远不生效。
  let levelTimer: ReturnType<typeof setInterval> | null = null;
  let localAnalyser: AudioAnalyserLike | null = null;
  /** 防止 analyser 创建中时每轮轮询重复 new AudioContext（泄漏） */
  let analyserCreating = false;
  /** 本地麦克风音量 0~2（1 = 原始）；≠1 时经 Web Audio 增益链（懒挂载） */
  let localVolume = 1;
  let gainProc: LocalGainProcessor | null = null;

  // ---- 远端成员音量监测（"谁在说话"的跳动） ----
  // 每个有音频轨道的远端参与者一个 analyser（key = 应用 user_id）。本地 Web Audio
  // 分析远端轨道 → 100ms 轮询即算即报，响应速度与本地一样快、对声音更灵敏；
  // 不依赖 livekit 服务器的低频 speaker update（~1.5s 级，会显得响应慢/迟钝）。
  // server 的 participant.audioLevel 仅作 analyser 创建失败时的回退。
  const remoteAnalysers = new Map<string, AudioAnalyserLike>();

  /** 创建远端轨道分析器（同步；AudioContext 需 resume，autoplay 策略默认 suspended） */
  const createRemoteAnalyser = (track: unknown): AudioAnalyserLike | null => {
    try {
      const a = mod.createAudioAnalyser(track as never);
      // livekit 默认 smoothingTimeConstant 0.8：声音停止后音量衰减滞后 ~1s，
      // 跳动条"没声了还亮着"——调小让跳动实时起落（0.15：2~3 轮内归零）
      if (a.analyser.smoothingTimeConstant !== undefined) {
        a.analyser.smoothingTimeConstant = 0.15;
      }
      const ctx = a.analyser.context as AudioContext | undefined;
      if (ctx && ctx.state === "suspended") {
        void ctx.resume().catch(() => {
          // resume 失败（如仍被策略拦截）→ 保持 0，不伪造
        });
      }
      return a;
    } catch {
      return null;
    }
  };

  const stopAnalyser = () => {
    if (localAnalyser) {
      try {
        void localAnalyser.cleanup();
      } catch {
        // 分析器清理失败不影响主流程
      }
      localAnalyser = null;
    }
  };

  const stopRemoteAnalysers = () => {
    for (const ana of remoteAnalysers.values()) {
      try {
        void ana.cleanup();
      } catch {
        // 分析器清理失败不影响主流程
      }
    }
    remoteAnalysers.clear();
  };

  const stopLevelMonitor = () => {
    if (levelTimer) {
      clearInterval(levelTimer);
      levelTimer = null;
    }
    stopAnalyser();
    stopRemoteAnalysers();
  };

  /** 找已发布的本地音频轨道（开麦才有；关麦则轨道被移除） */
  const findLocalAudioTrack = () => {
    for (const pub of room.localParticipant.audioTrackPublications.values()) {
      if (pub.track && pub.track.kind === "audio") return pub.track;
    }
    return null;
  };

  /** 应用/恢复本地麦克风音量（挂增益链或停止它），失败静默保留原始音量 */
  const applyLocalVolume = async () => {
    const track = findLocalAudioTrack();
    if (!track) return;
    if (localVolume === 1) {
      if (gainProc) {
        try {
          await track.stopProcessor();
        } catch {
          // stopProcessor 失败不阻断
        }
        gainProc = null;
      }
    } else {
      if (!gainProc) {
        const proc = createGainProcessor();
        proc.setGain(localVolume);
        try {
          await track.setProcessor(proc as never);
          gainProc = proc;
        } catch {
          // 增益链挂载失败 → 保持原始音量（可重试），不伪造成功
          gainProc = null;
        }
      } else {
        gainProc.setGain(localVolume);
      }
    }
    // 轨道可能被 processor 替换（mediaStreamTrack 变了），重建 analyser 反映处理后音量
    stopAnalyser();
  };

  const startLevelMonitor = () => {
    stopLevelMonitor();
    if (!events.onLocalAudioLevel && !events.onRemoteAudioLevels) return;
    levelTimer = setInterval(() => {
      if (!events.onLocalAudioLevel && !events.onRemoteAudioLevels) return;
      // 远端成员实时音量：**本地 Web Audio 分析远端音频轨道**（100ms 即算即报，
      // 响应快、灵敏）——不依赖服务器低频 speaker update；分析器创建失败时回退
      // server 快照 participant.audioLevel。levels 全量快照含 0，调用方直接覆盖。
      if (events.onRemoteAudioLevels) {
        const levels: Record<string, number> = {};
        const alive = new Set<string>();
        for (const p of room.remoteParticipants.values()) {
          const appId = toAppUserId(p.identity);
          alive.add(appId);
          // audioTrackPublications 只含音频发布：有 track 就是可分析的音频轨道
          const audioTrack = [...p.audioTrackPublications.values()]
            .map((pub) => pub.track)
            .find((t) => t != null);
          if (!audioTrack) continue; // 未开麦/无轨道：不上报（store 归 0）
          let ana: AudioAnalyserLike | null = remoteAnalysers.get(appId) ?? null;
          if (!ana) {
            ana = createRemoteAnalyser(audioTrack);
            if (ana) remoteAnalysers.set(appId, ana);
          }
          if (ana) {
            levels[appId] = Math.max(0, Math.min(1, ana.calculateVolume()));
          } else {
            // 分析器创建失败 → 回退 server speaker update 快照（不伪造跳动）
            const lvl = p.audioLevel ?? 0;
            if (lvl > 0.005) levels[appId] = Math.max(0, Math.min(1, lvl));
          }
        }
        // 清理已离开参与者的分析器（不再被遍历到，防泄漏）
        for (const [appId, ana] of remoteAnalysers) {
          if (!alive.has(appId)) {
            try {
              void ana.cleanup();
            } catch {
              // 忽略清理失败
            }
            remoteAnalysers.delete(appId);
          }
        }
        events.onRemoteAudioLevels(levels);
      }
      const track = findLocalAudioTrack();
      if (!track) {
        events.onLocalAudioLevel?.(0);
        return;
      }
      // 开麦后若需调节音量且增益链未挂 → 懒挂载（异步，本轮先返回 0）
      if (localVolume !== 1 && !gainProc) {
        void applyLocalVolume();
        return;
      }
      if (!localAnalyser && !analyserCreating) {
        analyserCreating = true;
        try {
          // 注意：livekit 的 createAudioAnalyser 是**同步**返回对象（不是 Promise），
          // 当异步 .then 调用会 TypeError → analyser 永远建不起来 → 跳动永不生效。
          const a = mod.createAudioAnalyser(track);
          // 关键：createAudioAnalyser 内部 new 的 AudioContext 在浏览器 autoplay
          // 策略下默认 suspended（我们不在用户手势同步上下文里创建）→ 音频图不
          // 处理，getByteFrequencyData 恒 0 → calculateVolume 恒 0，跳动永不生效。
          // 必须主动 resume，否则音量跳动效果"静默失效"。
          // livekit 默认 smoothingTimeConstant 0.8：声音停止后音量衰减滞后 ~1s，
          // 跳动条"没声了还亮着"——调小让跳动实时起落（0.15：2~3 轮内归零）。
          if (a.analyser.smoothingTimeConstant !== undefined) {
            a.analyser.smoothingTimeConstant = 0.15;
          }
          const ctx = a.analyser.context as AudioContext | undefined;
          if (ctx && ctx.state === "suspended") {
            void ctx.resume().catch(() => {
              // resume 失败（如仍被策略拦截）→ 保持 0，下一轮不重试（不伪造）
            });
          }
          localAnalyser = a;
        } catch {
          localAnalyser = null;
        } finally {
          analyserCreating = false;
        }
        return; // 本次先返回 0，下一轮有 analyser 再上报
      }
      if (localAnalyser) {
        events.onLocalAudioLevel?.(localAnalyser.calculateVolume());
      } else {
        events.onLocalAudioLevel?.(0);
      }
    }, 100);
  };

  // 注意：事件名必须是 livekit-client RoomEvent 的 camelCase 字面值（见 RoomEventName
  // 类型注释的事故记录）——PascalCase 会导致监听器静默失效。
  room.on("reconnecting", () => events.onStateChange?.("reconnecting"));
  room.on("reconnected", () => events.onStateChange?.("connected"));
  room.on("disconnected", () => events.onStateChange?.("failed"));
  room.on("participantConnected", (p) => {
    events.onParticipantJoined?.(toAppUserId((p as LiveKitRemoteParticipantInternal).identity));
  });
  room.on("participantDisconnected", (p) => {
    events.onParticipantLeft?.(toAppUserId((p as LiveKitRemoteParticipantInternal).identity));
  });
  room.on("trackMuted", (_pub, participant) => {
    events.onTrackMuted?.(toAppUserId((participant as LiveKitRemoteParticipantInternal).identity), true);
  });
  room.on("trackUnmuted", (_pub, participant) => {
    events.onTrackMuted?.(toAppUserId((participant as LiveKitRemoteParticipantInternal).identity), false);
  });
  room.on("activeSpeakersChanged", (speakers) => {
    events.onActiveSpeakers?.(
      (speakers as LiveKitRemoteParticipantInternal[]).map((s) => toAppUserId(s.identity)),
    );
  });
  // 远端音频订阅后必须 attach 才会出声（livekit-client 不自动 attach）
  room.on("trackSubscribed", (track) => {
    const t = track as LiveKitRemoteTrackInternal;
    if (t.kind !== "audio") return;
    ensureAudioContainer().appendChild(t.attach());
  });
  // 退订/移除时 detach，避免残留播放
  room.on("trackUnsubscribed", (track) => {
    const t = track as LiveKitRemoteTrackInternal;
    if (t.kind !== "audio") return;
    try {
      t.detach();
    } catch {
      // 元素已移除等竞态，忽略
    }
  });
  /**
   * attach 所有已存在的远端音频轨道。
   *
   * 关键：livekit-client 的 `TrackSubscribed` 只对**连接后新订阅**的轨道触发；
   * 我加入时房间里已存在的成员轨道会被直接放进 `audioTrackPublications`，
   * **不触发 TrackSubscribed**。只在 TrackSubscribed 里 attach 会导致
   * 「先进房者已开麦，但后进房者听不到他」——必须连接后主动遍历补齐。
   */
  const attachExistingRemoteAudio = () => {
    for (const p of room.remoteParticipants.values()) {
      for (const pub of p.audioTrackPublications.values()) {
        const t = pub.track as LiveKitRemoteTrackInternal | null;
        if (!t || t.kind !== "audio") continue;
        ensureAudioContainer().appendChild(t.attach());
      }
    }
  };

  return {
    async connect(wsUrl, token) {
      await room.connect(wsUrl, token);
      // 补齐连接时已存在的远端音频轨道（TrackSubscribed 不覆盖此场景）
      attachExistingRemoteAudio();
      startLevelMonitor();
      events.onStateChange?.("connected");
    },
    async disconnect() {
      stopLevelMonitor();
      if (gainProc) {
        try {
          await gainProc.destroy();
        } catch {
          // 增益链清理失败不阻塞断开
        }
        gainProc = null;
      }
      room.removeAllListeners();
      await room.disconnect();
    },
    async setMicrophoneEnabled(enabled) {
      await room.localParticipant.setMicrophoneEnabled(enabled);
    },
    isMicrophoneEnabled() {
      return room.localParticipant.isMicrophoneEnabled;
    },
    /** 本地麦克风音量 0~2（1 = 原始）：拖滑块实时改发送响度 */
    async setLocalVolume(volume) {
      localVolume = Math.max(0, Math.min(2, volume));
      if (findLocalAudioTrack()) {
        await applyLocalVolume().catch(() => {});
      }
      // 未开麦时只记录目标值，开麦后由 startLevelMonitor 懒挂载
    },
    getLocalVolume() {
      return localVolume;
    },
    startAudio() {
      return room.startAudio();
    },
    remoteParticipants() {
      void emitRemoteIdentities;
      return [...room.remoteParticipants.values()].map((p) => ({
        identity: toAppUserId(p.identity),
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

  /** 恢复远端音频播放（autoplay 被浏览器阻断时，在用户手势中调用） */
  async startAudio(): Promise<void> {
    if (!this.room) return;
    await this.room.startAudio();
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

  /** 设置本地麦克风音量（0~2，1 = 原始）；改变自己说话别人听到的响度；未开麦时记录目标值 */
  async setLocalVolume(volume: number): Promise<void> {
    if (!this.room) return;
    await this.room.setLocalVolume(volume);
  }

  /** 当前本地麦克风音量（0~2，1 = 原始） */
  getLocalVolume(): number {
    return this.room?.getLocalVolume() ?? 1;
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
