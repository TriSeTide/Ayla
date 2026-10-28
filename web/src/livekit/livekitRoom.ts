/**
 * LiveKit Room —— \`LiveKitRoomLike\` 的真实媒体实现（livekit-client 2.23）。
 *
 * 与 \`wsRelayRoom.ts\` 的关系：两者是同一接口的两个传输实现，前者是回滚路径（不动），
 * 本文件是 LiveKit 单 UDP 端口媒体面（信令 wss://…/livekit）。上层
 * \`client.ts\` 的 \`VoiceLiveKitClient\` 完全不感知具体传输。
 *
 * 为什么本文件只有 ~400 行而中继实现 849 行：中继版维护 7 张表
 * （slotToIdentity / speakingSlots / mutedSlots / decoders / playHead / slotGains /
 * slotLevels），那**全部是 ws 协议没有 participant 对象的补偿**。LiveKit 直接给出
 * participant / track 对象，这些表一个都不需要。
 *
 * 契约（与 client.ts 的 LiveKitRoomLike/LiveKitEvents 逐条对应）：
 * - identity = 应用 user_id（后端签发 token 用裸 str(user.pk)，无 user_ 前缀）；
 * - **关麦完全释放麦克风设备**（隐私：熄灭硬件指示灯）：unpublishTrack + track.stop()。
 *   livekit-client 的 setMicrophoneEnabled(false) 默认只 mute 不释放设备，
 *   直接用等于隐私语义回退——本实现显式 unpublish + stop；
 * - **绝不用 isSpeaking / activeSpeakers 门控发布**：speaking 只是 UI 事实，
 *   muted 是唯一硬门控（Ayla/docs/flutter/39-语音持续播放-speaking门控设计缺陷.md）；
 *   本文件把 track 一直发布，静音帧照发（Opus VBR 下 ~25 字节）；
 * - onLocalAudioLevel / onRemoteAudioLevels 由 100ms tick 输出，快照含 0（上层直接覆盖），
 *   本地 0.6 衰减保持与中继版一致的"波动感"；
 * - 媒体断线自动重连由 SDK 的 ReconnectPolicy 负责（不需要手写指数退避）：
 *   reconnecting → connected；SDK 放弃后 disconnected → failed（用户决定重进，
 *   媒体断线 ≠ 离开频道）；
 * - token 纪律：token 只作 connect 入参，不打日志、不缓存、不落 store。
 */
import {
  createLocalAudioTrack,
  Room,
  RoomEvent,
  Track,
  type AudioCaptureOptions,
  type LocalAudioTrack,
  type Participant,
  type RemoteParticipant,
  type RemoteTrack,
  type RemoteTrackPublication,
  type TrackPublication,
} from "livekit-client";
import type { LiveKitEvents, LiveKitRoomLike, RemoteAudioTrackLike, RemoteParticipantLike } from "./client";

/** 音量/电平节拍（与 wsRelayRoom.ts 的 LEVEL_TICK_MS 一致：UI 依赖"连续回调 + 含 0 + 衰减"） */
const LEVEL_TICK_MS = 100;
/** 本地电平每拍的衰减系数（与中继版一致；波形不"硬跳") */
const LOCAL_DECAY = 0.6;

/** 本地麦克风采集参数：与中继版 getUserMedia 参数逐项一致（回声消除/降噪/自动增益） */
const MIC_CAPTURE_OPTIONS: AudioCaptureOptions = {
  channelCount: 1,
  echoCancellation: true,
  noiseSuppression: true,
  autoGainControl: true,
};

/**
 * 本地麦克风音量处理器（Web Audio 增益链，0~2，1 = 原始音量）。
 *
 * livekit-client 只有 RemoteAudioTrack.setVolume()，LocalAudioTrack 没有；
 * 「调节自己说话的响度」（别人听到的响度）只能走官方 TrackProcessor 扩展点：
 * 采集轨 → MediaStreamSource → GainNode → MediaStreamDestination，
 * 用输出的 processedTrack 发布。gain=1 时不挂（无处理链、音质零损耗）。
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
  let source: MediaStreamAudioSourceNode | null = null;
  let gainNode: GainNode | null = null;
  let dest: MediaStreamAudioDestinationNode | null = null;
  let gain = 1;

  const processor: LocalGainProcessor = {
    name: "ayla-local-mic-volume",
    processedTrack: undefined,
    setGain(value: number) {
      gain = Math.max(0, Math.min(2, value));
      if (gainNode) gainNode.gain.value = gain;
    },
    async init(opts) {
      source = opts.audioContext.createMediaStreamSource(new MediaStream([opts.track]));
      gainNode = opts.audioContext.createGain();
      gainNode.gain.value = gain;
      dest = opts.audioContext.createMediaStreamDestination();
      source.connect(gainNode);
      gainNode.connect(dest);
      processor.processedTrack = dest.stream.getAudioTracks()[0];
    },
    async restart(opts) {
      await processor.destroy();
      await processor.init(opts);
    },
    async destroy() {
      try {
        source?.disconnect();
        gainNode?.disconnect();
        dest?.disconnect();
      } catch {
        // 已断开
      }
      source = null;
      gainNode = null;
      dest = null;
      processor.processedTrack = undefined;
    },
  };
  return processor;
}

/**
 * 远端音频轨道是否可播放（LiveKit 不自动 attach，必须由我们 attach 到元素）。
 *
 * 事故记录（2026-08-26，见 9746c6b^ 的 client.ts 注释）：TrackSubscribed 只对
 * **连接后新订阅**的轨道触发；加入时房里已存在的成员轨道直接进 audioTrackPublications，
 * 不触发该事件。只在 TrackSubscribed 里 attach 会造成「先入房者已开麦但后进房者听不见」。
 * 因此 connect 之后必须再 attach 一遍已存在的轨道。
 */
function ensureAudioContainer(): HTMLElement {
  let container = document.getElementById("ayla-voice-audio");
  if (!container) {
    container = document.createElement("div");
    container.id = "ayla-voice-audio";
    (container as HTMLElement).hidden = true;
    document.body.appendChild(container);
  }
  return container;
}

/**
 * 远端音频轨道的最小面：livekit-client 的 `RemoteTrack<Kind.Audio>` 同时带
 * attach()/detach() 与 setVolume()（后者定义在具体子类 RemoteAudioTrack 上）。
 * 这里用结构化类型声明，避免对 SDK 泛型做脆弱的强制转换。
 */
type AttachableAudioTrack = {
  attach(element?: HTMLMediaElement): HTMLMediaElement;
  detach(element?: HTMLMediaElement): HTMLMediaElement[];
};

function attachedAudioTracks(room: Room): AttachableAudioTrack[] {
  const tracks: AttachableAudioTrack[] = [];
  for (const participant of room.remoteParticipants.values()) {
    for (const publication of participant.audioTrackPublications.values()) {
      const track = publication.track as unknown as AttachableAudioTrack | undefined;
      if (track) tracks.push(track);
    }
  }
  return tracks;
}

export async function createLiveKitRoom(events: LiveKitEvents): Promise<LiveKitRoomLike> {
  const room = new Room({
    // 纯音频场景：不订阅/不启用视频相关特性
    adaptiveStream: false,
    dynacast: false,
    // 关麦由本实现显式 unpublish + stop() 保证（见 setMicrophoneEnabled），
    // 不依赖 SDK 的 mute 语义；这里保持默认 true 作为额外兜底。
    stopLocalTrackOnUnpublish: true,
    audioCaptureDefaults: MIC_CAPTURE_OPTIONS,
    publishDefaults: {
      // 32 kbps：与 WS 中继的 Opus 编码参数逐字节一致
      // （wsRelayRoom.ts 的 encoder.configure({ codec:"opus", bitrate: 32000 })）。
      // AudioPresets.speech 只有 24 kbps，故显式给 maxBitrate。
      audioPreset: { maxBitrate: 32000 },
      // ⚠️ DTX 必须关闭：DTX 会在安静段**完全停发**，听感正是 doc39 的
      // 「有声音才连上去，声音小了就跟断了一样」。speaking 是 UI 事实，
      // 不是媒体开关 —— 静音帧在 Opus VBR 下约 25 字节，带宽代价可忽略。
      dtx: false,
      // 冗余音频（丢包恢复）：纯音频场景开销小、对移动网络收益明显
      red: true,
    },
  });

  /* ---- 状态 ---- */
  let closed = false;
  let connected = false;
  let micEnabled = false;
  /** 本地麦克风音量目标值 0~2（关麦后保留，开麦时重新应用） */
  let localVolume = 1;
  /** 当前本地发布 + 增益处理器 */
  let micTrack: LocalAudioTrack | null = null;
  let gainProcessor: LocalGainProcessor | null = null;
  /**
   * 采集设备的原始 MediaStreamTrack。
   *
   * 为什么单独持有：挂上增益处理器后 `micTrack.mediaStreamTrack` 会变成
   * 处理链的 MediaStreamDestination 轨（虚拟），**不是**麦克风设备轨；
   * 只停它不会熄灭硬件指示灯。这里在采集那一刻抓一份原始轨引用，
   * 关麦时显式 stop() —— 隐私语义必须由确定性动作保证，不能赌实现细节。
   */
  let micDeviceTrack: MediaStreamTrack | null = null;
  /** 本拍本地电平（麦克风分析器写入，tick 读取后衰减） */
  let localPeak = 0;

  /* ---- 电平分析器 ---- */
  let localAnalyserCleanup: (() => Promise<void>) | null = null;
  let localAnalyser: { getLevel(): number } | null = null;
  const remoteAnalysers = new Map<string, { getLevel(): number; cleanup(): Promise<void> }>();

  /**
   * 远端成员本地播放音量（identity -> 0~1）。
   *
   * 为什么要自己记：LiveKit 只有轨道级 setVolume（RemoteAudioTrack.setVolume），
   * 而对方"重新开麦"在我们的关麦语义里是 unpublish 后重新 publish => 新轨道，
   * 音量回到默认 1，本地静音就被静默绕过（用户实报 2026-10-28：
   * 「收音方明明关掉了放音方的声音，放音方重新开麦又能听见了」）。
   * 记住值 + 在 TrackSubscribed 里重新施加，才能让"本地禁音"是成员级事实。
   */
  const remoteVolumes = new Map<string, number>();

  let levelTimer: number | null = null;

  /* ---- 本地麦克风音量（发送响度） ---- */

  const applyLocalVolume = async () => {
    if (!micTrack) return;
    if (localVolume === 1) {
      if (gainProcessor) {
        try {
          await micTrack.stopProcessor();
        } catch {
          // stopProcessor 失败不阻断（保持链路可用）
        }
        gainProcessor = null;
      }
      return;
    }
    if (!gainProcessor) {
      const processor = createGainProcessor();
      processor.setGain(localVolume);
      try {
        await micTrack.setProcessor(processor);
        gainProcessor = processor;
      } catch {
        // 增益链挂载失败 → 保持原始音量（可重试），不伪造成功
        gainProcessor = null;
      }
    } else {
      gainProcessor.setGain(localVolume);
    }
  };

  /* ---- 电平（100ms tick） ---- */

  /**
   * 麦克风/远端轨道电平分析器。
   *
   * 为什么自己建 AnalyserNode 而不是读 participant.audioLevel：
   * audioLevel 由 **服务端 speaker update** 驱动（~1.5s 级、且只在"说话排行"变化时下发），
   * 直接用它会让音量条迟钝且"没声了还亮着"。中继版也是本地 Web Audio 算 peak。
   * 这里用同一手法：MediaStreamSource → AnalyserNode，100ms 取 RMS。
   *
   * 注意：AudioContext 在 autoplay 政策下默认 suspended → 必须 resume，
   * 否则 getByteFrequencyData 恒 0（历史上"音量跳动静默失效"就是这个坑）。
   */
  const createAnalyser = (track: MediaStreamTrack | null) => {
    if (!track) return null;
    try {
      const AudioCtx: typeof AudioContext | undefined =
        (globalThis as unknown as { AudioContext?: typeof AudioContext }).AudioContext;
      if (!AudioCtx) return null;
      const ctx = new AudioCtx();
      if (ctx.state === "suspended") void ctx.resume().catch(() => {});
      const source = ctx.createMediaStreamSource(new MediaStream([track]));
      const analyser = ctx.createAnalyser();
      analyser.fftSize = 512;
      // 默认 0.8 → 停声后音量衰减滞后 ~1s（条子"没声了还亮着"）；调到 0.15 实时起落
      analyser.smoothingTimeConstant = 0.15;
      source.connect(analyser);
      const data = new Uint8Array(analyser.frequencyBinCount);
      return {
        // 与 wsRelayRoom.ts 的 peak 语义一致：取时域峰值 0~1
        getLevel: () => {
          analyser.getByteTimeDomainData(data);
          let peak = 0;
          for (const sample of data) {
            const level = Math.abs(sample - 128) / 128;
            if (level > peak) peak = level;
          }
          return Math.max(0, Math.min(1, peak));
        },
        cleanup: async () => {
          try {
            source.disconnect();
            analyser.disconnect();
            await ctx.close();
          } catch {
            // 已关闭
          }
        },
      };
    } catch {
      return null;
    }
  };

  const stopLocalAnalyser = () => {
    if (localAnalyserCleanup) void localAnalyserCleanup().catch(() => {});
    localAnalyserCleanup = null;
    localAnalyser = null;
  };

  const stopRemoteAnalysers = () => {
    for (const analyser of remoteAnalysers.values()) {
      void analyser.cleanup().catch(() => {});
    }
    remoteAnalysers.clear();
  };

  const ensureLocalAnalyser = () => {
    if (localAnalyser || !micTrack) return;
    const created = createAnalyser(micTrack.mediaStreamTrack);
    if (!created) return;
    localAnalyser = created;
    localAnalyserCleanup = created.cleanup;
  };

  const ensureRemoteAnalyser = (identity: string, publication: RemoteTrackPublication) => {
    if (remoteAnalysers.has(identity)) return;
    const track = publication.track as RemoteTrack | undefined;
    if (!track) return;
    const created = createAnalyser(track.mediaStreamTrack);
    if (!created) return;
    remoteAnalysers.set(identity, created);
  };

  const aliveRemoteIdentities = () => new Set([...room.remoteParticipants.keys()]);

  const pruneRemoteAnalysers = () => {
    const alive = aliveRemoteIdentities();
    for (const [identity, analyser] of remoteAnalysers) {
      if (alive.has(identity)) continue;
      void analyser.cleanup().catch(() => {});
      remoteAnalysers.delete(identity);
    }
  };

  /**
   * 单拍电平上报。
   *
   * 契约（上层直接覆盖，不做合并）：
   * - onRemoteAudioLevels 必须是**含 0 的全量快照**——store 的 setRemoteAudioLevels
   *   把快照里没有的成员归 0，缺项会留下残值；
   * - onLocalAudioLevel 未开麦恒回调 0（连续回调，UI 条子才不会卡在高位）。
   */
  const tick = () => {
    if (closed) return;

    if (events.onLocalAudioLevel) {
      let level = 0;
      if (micEnabled && localAnalyser) {
        localPeak = Math.max(localPeak * LOCAL_DECAY, localAnalyser.getLevel());
        level = localPeak;
      } else {
        localPeak = 0;
      }
      events.onLocalAudioLevel(Math.max(0, Math.min(1, level)));
    }

    if (events.onRemoteAudioLevels) {
      const levels: Record<string, number> = {};
      for (const participant of room.remoteParticipants.values()) {
        const analyser = remoteAnalysers.get(participant.identity);
        levels[participant.identity] = analyser
          ? Math.max(0, Math.min(1, analyser.getLevel()))
          : 0;
      }
      pruneRemoteAnalysers();
      events.onRemoteAudioLevels(levels);
    }
  };

  const startLevelTimer = () => {
    if (levelTimer !== null) return;
    levelTimer = window.setInterval(tick, LEVEL_TICK_MS);
  };

  const stopLevelTimer = () => {
    if (levelTimer === null) return;
    clearInterval(levelTimer);
    levelTimer = null;
  };

  /* ---- 本地麦克风采集/发布 ---- */

  /**
   * 开麦：采集 + 发布。
   *
   * ⚠️ 这里**绝不**按 isSpeaking / activeSpeakers 门控发布：speaking 是 UI 事实，
   * muted 是唯一硬门控（doc 39）。轨道一旦发布就持续发包（静音段 ~25 字节/帧）。
   */
  const startMicrophone = async (): Promise<void> => {
    if (micTrack) return;
    const track = await createLocalAudioTrack(MIC_CAPTURE_OPTIONS);
    if (closed) {
      track.stop();
      throw new Error("LiveKit 已断开");
    }
    try {
      // publishDefaults.dtx=false：安静段仍然发小包，避免"没声就断"的听感
      await room.localParticipant.publishTrack(track, { dtx: false, red: true, source: Track.Source.Microphone });
    } catch (error) {
      track.stop();
      throw error;
    }
    micTrack = track;
    // 抓采集设备原始轨：挂处理器后 track.mediaStreamTrack 会变成虚拟轨
    micDeviceTrack = track.mediaStreamTrack;
    if (localVolume !== 1) await applyLocalVolume();
    ensureLocalAnalyser();
    micEnabled = true;
  };

  /**
   * 关麦：**完全释放麦克风设备**（隐私：熄灭硬件指示灯）。
   *
   * livekit-client 的 setMicrophoneEnabled(false) 只 mute（track 仍占用采集设备，
   * 系统麦克风指示灯常亮）——直接用它等于把中继版
   * 「setMicrophoneEnabled(false) 完全释放设备」的语义回退掉。
   * 因此这里显式 unpublishTrack(..., stopOnUnpublish=true) + track.stop() 双保险。
   * 对齐 wsRelayRoom.ts:802-807（先发媒体事实、再释放设备）。
   */
  const stopMicrophone = async (): Promise<void> => {
    micEnabled = false;
    localPeak = 0;
    stopLocalAnalyser();
    const track = micTrack;
    const deviceTrack = micDeviceTrack;
    micTrack = null;
    micDeviceTrack = null;
    gainProcessor = null;
    try {
      if (track) await room.localParticipant.unpublishTrack(track, true);
    } catch {
      // unpublish 失败（已断开等）不阻断释放设备
    }
    try {
      if (track) track.stop();
    } catch {
      // 已停止
    }
    try {
      // **确定性动作**：停采集设备原始轨 = 熄灭系统麦克风指示灯。
      // 不依赖 unpublish 的 stopOnUnpublish 实现细节，也不受增益链替换影响。
      deviceTrack?.stop();
    } catch {
      // 已停止
    }
  };

  /* ---- 事件映射（7 回调） ---- */

  const participantIdentity = (p: Participant): string => p.identity;

  const onConnected = () => {
    connected = true;
    // 补齐连接时已存在的远端音频轨道（TrackSubscribed 不覆盖这些）
    for (const participant of room.remoteParticipants.values()) {
      for (const publication of participant.audioTrackPublications.values()) {
        const track = publication.track as unknown as AttachableAudioTrack | undefined;
        if (!track) continue;
        try {
          ensureAudioContainer().appendChild(track.attach());
        } catch {
          // 重复 attach / 元素竞态 → 忽略
        }
        ensureRemoteAnalyser(participant.identity, publication);
      }
    }
    startLevelTimer();
    events.onStateChange?.("connected");
  };

  const onReconnecting = () => {
    events.onStateChange?.("reconnecting");
  };

  const onReconnected = () => {
    // 重连后远端轨道可能是新的 MediaStreamTrack（旧 analyser 失效）→ 全部重建
    stopRemoteAnalysers();
    for (const participant of room.remoteParticipants.values()) {
      for (const publication of participant.audioTrackPublications.values()) {
        ensureRemoteAnalyser(participant.identity, publication);
      }
    }
    events.onStateChange?.("connected");
  };

  const onDisconnected = () => {
    if (closed) return; // 用户主动 disconnect：不再上报状态（client.ts 已撤销所有权）
    connected = false;
    stopLevelTimer();
    stopRemoteAnalysers();
    events.onStateChange?.("failed");
  };

  const onParticipantConnected = (participant: RemoteParticipant) => {
    events.onParticipantJoined?.(participantIdentity(participant));
  };

  const onParticipantDisconnected = (participant: RemoteParticipant) => {
    const identity = participantIdentity(participant);
    const analyser = remoteAnalysers.get(identity);
    if (analyser) {
      void analyser.cleanup().catch(() => {});
      remoteAnalysers.delete(identity);
    }
    events.onParticipantLeft?.(identity);
  };

  const isAudioPublication = (publication: TrackPublication): boolean =>
    publication.kind === Track.Kind.Audio && publication.source !== Track.Source.ScreenShareAudio;

  const onTrackMuted = (publication: TrackPublication, participant: Participant) => {
    if (!isAudioPublication(publication)) return;
    // 本地静音由本实现的 micEnabled 表达（上层只关心远端成员行）；
    // 但中继版对本地不报（identityFor 会过滤 mySlot），这里保持同一语义。
    if (participant.isLocal) return;
    events.onTrackMuted?.(participantIdentity(participant), true);
  };

  const onTrackUnmuted = (publication: TrackPublication, participant: Participant) => {
    if (!isAudioPublication(publication)) return;
    if (participant.isLocal) return;
    events.onTrackMuted?.(participantIdentity(participant), false);
  };

  const onActiveSpeakersChanged = (speakers: Participant[]) => {
    // 仅 UI 提示用途；**不做任何发布门控**（doc 39 硬约束）
    events.onActiveSpeakers?.(speakers.filter((s) => !s.isLocal).map(participantIdentity));
  };

  const onTrackSubscribed = (
    track: RemoteTrack,
    publication: RemoteTrackPublication,
    participant: RemoteParticipant,
  ) => {
    if (track.kind !== Track.Kind.Audio) return;
    if (publication.source === Track.Source.ScreenShareAudio) return;
    try {
      ensureAudioContainer().appendChild((track as unknown as AttachableAudioTrack).attach());
    } catch {
      // 元素竞态 → 忽略
    }
    ensureRemoteAnalyser(participant.identity, publication);
    // 成员级本地音量（含 0 = 本地禁音）：新轨道必须继承，否则重新开麦会绕过静音。
    const storedVolume = remoteVolumes.get(participant.identity);
    if (storedVolume !== undefined) {
      try {
        (track as unknown as RemoteAudioTrackLike).setVolume(storedVolume);
      } catch {
        // 轨道已销毁 -> 忽略
      }
    }
  };

  const onTrackUnsubscribed = (
    track: RemoteTrack,
    _publication: RemoteTrackPublication,
    participant: RemoteParticipant,
  ) => {
    if (track.kind !== Track.Kind.Audio) return;
    try {
      (track as unknown as AttachableAudioTrack).detach();
    } catch {
      // 已 detach
    }
    const analyser = remoteAnalysers.get(participant.identity);
    if (analyser) {
      void analyser.cleanup().catch(() => {});
      remoteAnalysers.delete(participant.identity);
    }
  };

  const onTrackUnpublished = (
    _publication: RemoteTrackPublication,
    participant: RemoteParticipant,
  ) => {
    const analyser = remoteAnalysers.get(participant.identity);
    if (analyser) {
      void analyser.cleanup().catch(() => {});
      remoteAnalysers.delete(participant.identity);
    }
  };

  room
    .on(RoomEvent.Connected, onConnected)
    .on(RoomEvent.Reconnecting, onReconnecting)
    .on(RoomEvent.Reconnected, onReconnected)
    .on(RoomEvent.Disconnected, onDisconnected)
    .on(RoomEvent.ParticipantConnected, onParticipantConnected)
    .on(RoomEvent.ParticipantDisconnected, onParticipantDisconnected)
    .on(RoomEvent.TrackMuted, onTrackMuted)
    .on(RoomEvent.TrackUnmuted, onTrackUnmuted)
    .on(RoomEvent.ActiveSpeakersChanged, onActiveSpeakersChanged)
    .on(RoomEvent.TrackSubscribed, onTrackSubscribed)
    .on(RoomEvent.TrackUnsubscribed, onTrackUnsubscribed)
    .on(RoomEvent.TrackUnpublished, onTrackUnpublished);

  /* ---- LiveKitRoomLike（8 方法） ---- */

  const roomLike: LiveKitRoomLike = {
    async connect(url, token) {
      if (!url) throw new Error("语音媒体地址无效");
      if (!token) throw new Error("登录状态失效，请重新登录");
      closed = false;
      connected = false;
      events.onStateChange?.("connecting");
      try {
        await room.connect(url, token, { autoSubscribe: true });
      } catch (error) {
        closed = true;
        events.onStateChange?.("failed");
        throw error;
      }
      // Connected 事件可能先于 connect() resolve 到达；这里兜底一次
      if (!connected && room.state === "connected") onConnected();
    },

    async disconnect() {
      closed = true;
      connected = false;
      stopLevelTimer();
      await stopMicrophone();
      stopRemoteAnalysers();
      for (const track of attachedAudioTracks(room)) {
        try {
          track.detach();
        } catch {
          // 已 detach
        }
      }
      room.removeAllListeners();
      try {
        await room.disconnect();
      } catch {
        // 已断开
      }
      const container = document.getElementById("ayla-voice-audio");
      if (container) container.replaceChildren();
    },

    async setMicrophoneEnabled(enabled) {
      if (enabled === micEnabled) return;
      if (enabled) {
        await startMicrophone();
      } else {
        await stopMicrophone();
      }
    },

    isMicrophoneEnabled() {
      return micEnabled;
    },

    remoteParticipants(): RemoteParticipantLike[] {
      return [...room.remoteParticipants.values()].map((participant) => ({
        identity: participant.identity,
        audioTracks: [...participant.audioTrackPublications.values()]
          .map((publication) => publication.track)
          .filter((track): track is NonNullable<typeof track> => track != null)
          .map((track) => ({
            setVolume(volume: number) {
              const clamped = Math.max(0, Math.min(1, volume));
              remoteVolumes.set(participant.identity, clamped);
              (track as unknown as RemoteAudioTrackLike).setVolume(clamped);
            },
          })),
      }));
    },

    /**
     * 远端成员本地播放音量（0~1）。**记在 identity 上**，
     * 等对方重新发布轨道时由 onTrackSubscribed 再施加一次。
     * 这样"本地禁音"是成员级事实，不会被对方重新开麦绕过。
     */
    setRemoteVolume(identity: string, volume: number): void {
      const clamped = Math.max(0, Math.min(1, volume));
      remoteVolumes.set(identity, clamped);
      const participant = room.remoteParticipants.get(identity);
      if (!participant) return;
      for (const publication of participant.audioTrackPublications.values()) {
        const track = publication.track;
        if (!track) continue;
        try {
          (track as unknown as RemoteAudioTrackLike).setVolume(clamped);
        } catch {
          // 轨道已销毁 -> 忽略
        }
      }
    },

    async startAudio() {
      // 浏览器 autoplay 政策：必须在用户手势链里调用才能恢复播放
      await room.startAudio();
    },

    async setLocalVolume(volume) {
      localVolume = Math.max(0, Math.min(2, volume));
      await applyLocalVolume();
    },

    getLocalVolume() {
      return localVolume;
    },
  };


  return roomLike;
}