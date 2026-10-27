/// LiveKit SDK 胶水层 —— [AylaVoiceRoomLike] 的真实实现（livekit_client 2.13.2）。
///
/// 对应 web `livekitRoom.ts` 的角色：把 SDK 的 Room / 轨道 / 事件映射成后端要的最小面。
/// 本文件**只做映射**，状态机、电平衰减、降级决策都在 `livekit_voice_backend.dart`
/// （所以那部分可以纯单测，不需要真服务器；本文件用源码级契约锁覆盖三条硬约束）。
///
/// ## 三条硬约束在本文件的落点
/// 1. **identity 裸 user_id**：直接透传 `participant.identity`，**从不加前缀/改写**
///    （后端签发 token 时 identity = `str(user.pk)`，见 `voice_media_config.dart`）；
/// 2. **关麦真正释放设备**：`unpublishMicrophone()` = `removePublishedTrack()`（SDK 在
///    `stopLocalTrackOnUnpublish: true` 下停轨）+ **显式** `track.stop()` +
///    `track.mediaStreamTrack.stop()`。三件都要有：前者是协议侧退订，后两者是
///    **确定性设备释放**（隐私：熄灭系统麦克风指示灯）——不赌 SDK 实现细节；
///    ⚠️ **不用** `setMicrophoneEnabled(false)`：它默认只 mute，设备仍被占用；
/// 3. **绝不用 isSpeaking / activeSpeakers 门控发布**：本文件不注册
///    `ActiveSpeakersChangedEvent`、不读 `isSpeaking` 决定发布/发包。
///    `publishDefaults.dtx = false` 是同一约束的一半：DTX 会在安静段**完全停发**，
///    听感正是 doc 39 的「有声音才连上去播放，声音小点了就跟断了一样」。
///
/// ## 电平（Flutter 无 WebAudio AnalyserNode 的等价物）
/// - 本地：`LocalAudioTrack.getSenderStats().audioSourceStats.audioLevel`（media-source
///   统计，200ms 刷新；失败则回退 `localParticipant.audioLevel`）；
/// - 远端：`RemoteParticipant.audioLevel`（LiveKit 服务端 speaker 电平，
///   粒度比 web 的 AnalyserNode 粗 —— 已登记为已知差异）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:livekit_client/livekit_client.dart' as lk;

import 'livekit_voice_backend.dart';

/// 注册生产房间工厂（由 `AylaVoiceMedia` 在构造时调用一次；幂等）。
void aylaInstallLiveKitRoomBuilder() {
  AylaLiveKitRoomBuilder.install(() async => AylaLiveKitSdkRoom());
}

/// LiveKit SDK 房间实现（一个实例 = 一次连接生命周期）。
class AylaLiveKitSdkRoom implements AylaVoiceRoomLike {
  AylaLiveKitSdkRoom() {
    _room = lk.Room(roomOptions: _roomOptions);
    _bindEvents();
  }

  /// 采集参数：与中继版 `getUserMedia` / 现有 RecordConfig 逐项一致
  /// （回声消除 / 降噪 / 自动增益；web `MIC_CAPTURE_OPTIONS`
  /// `livekitRoom.ts:49-54`）。
  static const lk.AudioCaptureOptions _captureOptions =
      lk.AudioCaptureOptions(
    echoCancellation: true,
    noiseSuppression: true,
    autoGainControl: true,
  );

  /// 发布参数：32 kbps（与中继版 Opus 编码参数逐字节一致）+ 关 DTX + 开 RED。
  static const lk.AudioPublishOptions _publishOptions = lk.AudioPublishOptions(
    dtx: false,
    red: true,
    encoding: lk.AudioEncoding(maxBitrate: 32000),
  );

  static const lk.RoomOptions _roomOptions = lk.RoomOptions(
    // 纯音频场景：视频相关特性一律关闭（与 web `livekitRoom.ts:158-160` 一致）。
    adaptiveStream: false,
    dynacast: false,
    // 退订即停轨（多一层保险；显式 stop 仍在 `unpublishMicrophone` 里做）。
    stopLocalTrackOnUnpublish: true,
    defaultAudioCaptureOptions: _captureOptions,
    defaultAudioPublishOptions: _publishOptions,
  );

  late final lk.Room _room;
  final StreamController<AylaRoomEvent> _events =
      StreamController<AylaRoomEvent>.broadcast();

  /// 事件取消函数（`createListener().on(...)` 的返回值；不显式命名 SDK 类型，
  /// 只用其结构签名 —— 避免依赖 SDK 的内部导出面）。
  final List<Future<void> Function()> _cancels = <Future<void> Function()>[];
  Timer? _levelTimer;
  bool _levelBusy = false;
  bool _disposed = false;

  lk.LocalAudioTrack? _micTrack;
  lk.LocalTrackPublication<lk.LocalAudioTrack>? _micPublication;

  /// 本地电平实测值（[getSenderStats] 200ms 刷新；null = 尚无实测）。
  double? _measuredLocalLevel;

  /* ---------------- AylaVoiceRoomLike ---------------- */

  @override
  Stream<AylaRoomEvent> get events => _events.stream;

  @override
  Future<void> connect(String url, String token) async {
    await _room.connect(url, token);
    _startLevelTimer();
  }

  @override
  Future<void> disconnect() async {
    if (_disposed) return;
    _stopLevelTimer();
    await _releaseMicrophone();
    await _cancelListeners();
    try {
      await _room.disconnect();
    } catch (_) {
      // 已断开：断开是幂等语义，不向上抛
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await disconnect();
    _disposed = true;
    try {
      await _room.dispose();
    } catch (_) {
      // 已释放
    }
    try {
      await _events.close();
    } catch (_) {
      // 已关闭
    }
  }

  /// 开麦：采集 + 发布。
  ///
  /// ⚠️ 发布之后 SDK 持续发包（`dtx: false`）——**不做 speaking 门控**（硬约束 3）。
  @override
  Future<void> publishMicrophone() async {
    if (_disposed) throw StateError('LiveKit 已断开');
    if (_micTrack != null) return;
    final lk.LocalParticipant? local = _room.localParticipant;
    if (local == null) throw StateError('LiveKit 未连接');

    final lk.LocalAudioTrack track =
        await lk.LocalAudioTrack.create(_captureOptions);
    try {
      final lk.LocalTrackPublication<lk.LocalAudioTrack> publication =
          await local.publishAudioTrack(track, publishOptions: _publishOptions);
      _micTrack = track;
      _micPublication = publication;
      _measuredLocalLevel = null;
      _startLevelTimer();
    } catch (error) {
      // 发布失败必须把已采集的设备放掉（不留下占用麦克风的孤儿轨）
      try {
        await track.stop();
      } catch (_) {
        // 已停止
      }
      rethrow;
    }
  }

  /// 关麦：**完全释放麦克风设备**（隐私：熄灭硬件指示灯）。
  ///
  /// 三件确定性动作（对齐 web `wsRelayRoom.ts:802-807` 的隐私注释）：
  /// 1. `removePublishedTrack` —— 协议侧退订（`stopLocalTrackOnUnpublish` 会顺带停轨）；
  /// 2. `track.stop()` —— 停 SDK 轨道（非 web 平台内部会 `mediaStreamTrack.stop()`）；
  /// 3. `track.mediaStreamTrack.stop()` —— 停**采集设备原始轨**，不赌第 1/2 步的实现细节。
  @override
  Future<void> unpublishMicrophone() async {
    final lk.LocalAudioTrack? track = _micTrack;
    final lk.LocalTrackPublication<lk.LocalAudioTrack>? publication =
        _micPublication;
    _micTrack = null;
    _micPublication = null;
    _measuredLocalLevel = null;
    _stopLevelTimer();

    final lk.LocalParticipant? local = _room.localParticipant;
    if (publication != null && local != null) {
      try {
        await local.removePublishedTrack(publication.sid);
      } catch (_) {
        // 已断开/已退订：继续走设备释放
      }
    }
    try {
      await track?.stop();
    } catch (_) {
      // 已停止
    }
    try {
      await track?.mediaStreamTrack.stop();
    } catch (_) {
      // 已停止
    }
  }

  @override
  bool get microphoneEnabled => _micTrack != null;

  @override
  List<String> get remoteIdentities =>
      _room.remoteParticipants.keys.toList(growable: false);

  @override
  double get localAudioLevel {
    if (_micTrack == null) return 0;
    final double? measured = _measuredLocalLevel;
    if (measured != null) return measured;
    final double raw = _room.localParticipant?.audioLevel ?? 0;
    return raw.isFinite ? math.max(0.0, math.min(1.0, raw)) : 0;
  }

  @override
  double remoteAudioLevel(String identity) {
    final lk.RemoteParticipant? participant =
        _room.remoteParticipants[identity];
    if (participant == null) return 0;
    final double raw = participant.audioLevel;
    return raw.isFinite ? math.max(0.0, math.min(1.0, raw)) : 0;
  }

  @override
  Future<void> startAudio() async {
    // 原生平台：远端音频由 WebRTC 音频设备自动播放；startAudio 仅解锁音频会话
    // （web 的 autoplay 政策在原生不存在，但调用是幂等的、移动端仍有意义）。
    await _room.startAudio();
  }

  /// 远端成员本地播放开关（0 与非 0 两档；SDK 无 per-track 音量，见接口注释）。
  @override
  Future<void> setRemoteAudioEnabled(String identity, bool enabled) async {
    final lk.RemoteParticipant? participant =
        _room.remoteParticipants[identity];
    if (participant == null) return;
    for (final lk.RemoteTrackPublication<lk.RemoteAudioTrack> publication
        in participant.audioTrackPublications) {
      try {
        if (enabled) {
          if (!publication.subscribed) await publication.subscribe();
        } else {
          if (publication.subscribed) await publication.unsubscribe();
        }
      } catch (_) {
        // 订阅状态竞态（刚加入/刚离开）：下一次连接事件会再对齐
      }
    }
  }

  /* ---------------- 事件映射 ---------------- */

  /// 绑定 SDK 事件 → 归一化事件。
  ///
  /// 只映射后端需要的 8 类；**刻意不注册 `ActiveSpeakersChangedEvent`**——
  /// speaking 是 UI 事实，不是媒体门控（硬约束 3）。
  void _bindEvents() {
    final listener = _room.createListener();
    _cancels
      ..add(listener.on<lk.RoomConnectedEvent>(
          (_) => _emit(AylaRoomEventKind.connected)))
      ..add(listener.on<lk.RoomReconnectingEvent>(
          (_) => _emit(AylaRoomEventKind.reconnecting)))
      ..add(listener.on<lk.RoomResumingEvent>(
          (_) => _emit(AylaRoomEventKind.reconnecting)))
      ..add(listener.on<lk.RoomReconnectedEvent>(
          (_) => _emit(AylaRoomEventKind.reconnected)))
      ..add(listener.on<lk.RoomDisconnectedEvent>(
          (_) => _emit(AylaRoomEventKind.disconnected)))
      ..add(listener.on<lk.ParticipantConnectedEvent>((event) {
        _emit(AylaRoomEventKind.participantJoined,
            identity: event.participant.identity);
      }))
      ..add(listener.on<lk.ParticipantDisconnectedEvent>((event) {
        _emit(AylaRoomEventKind.participantLeft,
            identity: event.participant.identity);
      }))
      ..add(listener.on<lk.TrackMutedEvent>((event) {
        if (_isLocalParticipant(event.participant)) return;
        if (event.publication.kind != lk.TrackType.AUDIO) return;
        _emit(AylaRoomEventKind.trackMuted,
            identity: event.participant.identity, muted: true);
      }))
      ..add(listener.on<lk.TrackUnmutedEvent>((event) {
        if (_isLocalParticipant(event.participant)) return;
        if (event.publication.kind != lk.TrackType.AUDIO) return;
        _emit(AylaRoomEventKind.trackUnmuted,
            identity: event.participant.identity, muted: false);
      }));
  }

  /// 本地参与者判定。
  ///
  /// 不用 `isLocal`：livekit_client 2.13.2 的 `Participant` 基类**没有**该 getter
  /// （只有 `LocalParticipant` / `RemoteParticipant` 子类），而事件参数是基类类型
  /// ⇒ 用 identity 比对（本地参与者 identity 就是 token 的 `sub`）。
  bool _isLocalParticipant(lk.Participant participant) {
    final lk.LocalParticipant? local = _room.localParticipant;
    if (local == null) return false;
    return participant.identity == local.identity;
  }

  /// 取消全部 SDK 事件监听（幂等）。
  Future<void> _cancelListeners() async {
    final List<Future<void> Function()> cancels =
        List<Future<void> Function()>.of(_cancels);
    _cancels.clear();
    for (final Future<void> Function() cancel in cancels) {
      try {
        await cancel();
      } catch (_) {
        // 已取消
      }
    }
  }

  void _emit(AylaRoomEventKind kind, {String? identity, bool? muted}) {
    if (_disposed || _events.isClosed) return;
    _events.add(AylaRoomEvent(kind, identity: identity, muted: muted));
  }

  /* ---------------- 本地电平取数 ---------------- */

  void _startLevelTimer() {
    if (_levelTimer != null) return;
    _levelTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      unawaited(_refreshLocalLevel());
    });
  }

  void _stopLevelTimer() {
    _levelTimer?.cancel();
    _levelTimer = null;
    _levelBusy = false;
  }

  /// 刷新本地实测电平（`getSenderStats` 有平台通道成本 ⇒ 200ms 一次、不并发）。
  ///
  /// 取 `audioSourceStats.audioLevel`（libwebrtc 的 media-source 统计）；
  /// 平台不给该字段时留 null，由 [localAudioLevel] 回退到
  /// `localParticipant.audioLevel`（服务端 speaker 电平）。
  Future<void> _refreshLocalLevel() async {
    final lk.LocalAudioTrack? track = _micTrack;
    if (track == null || _levelBusy || _disposed) {
      if (track == null) _measuredLocalLevel = null;
      return;
    }
    _levelBusy = true;
    try {
      final stats = await track.getSenderStats();
      final num? level = stats?.audioSourceStats?.audioLevel;
      if (level != null && level.isFinite) {
        _measuredLocalLevel = math.max(0.0, math.min(1.0, level.toDouble()));
      }
    } catch (_) {
      // 统计不可用不是错误路径：保留上一次实测（下一拍再试）
    } finally {
      _levelBusy = false;
    }
  }

  /* ---------------- 设备释放 ---------------- */

  /// 断开前先放设备（与 [unpublishMicrophone] 同一语义；幂等）。
  Future<void> _releaseMicrophone() => unpublishMicrophone();
}
