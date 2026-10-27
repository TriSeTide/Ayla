/// LiveKit 语音媒体后端 —— `AylaVoiceMedia` 的 **运输无关后端**之一（另一个是中继）。
///
/// ## 分层（对应 web 的两级结构）
/// ```
/// AylaLiveKitSdkRoom (livekit_room_adapter.dart)   ← SDK 胶水层：Room/轨道/电平取数
///         ↓ AylaVoiceRoomLike + AylaRoomEvent（本文件定义）
/// AylaLiveKitVoiceBackend (本文件)                 ← 状态映射 / 100ms 电平节拍 / 麦开关语义
///         ↓ AylaVoiceMediaEvents（由 AylaVoiceMedia 持有并转发）
/// AylaVoiceMedia (voice_media.dart)                ← 上层唯一入口（events getter 契约不变）
/// ```
/// 这与 web `client.ts`（传输无关薄封装）↔ `livekitRoom.ts`（真实媒体实现）同构：
/// 本文件承担 web `client.ts` 的取消/状态语义，SDK 胶水层承担 web `livekitRoom.ts` 的
/// 事件映射。**测试注入假房间**（`roomFactory`）即可覆盖全部分支，不需要真服务器。
///
/// ## 三条硬约束（逐条落实，web 侧已做到）
/// 1. **identity 用裸 user_id**：后端签发 token 时 `identity = str(user.pk)`（无 `user_` 前缀，
///    见 `voice_media_config.dart` 库注释）。本层**从不改写** `participant.identity`，
///    直接拿它做成员映射（远端静音事实 → slot → identity → 会话层成员表）；
/// 2. **关麦必须真正释放麦克风设备**：`setMicrophoneEnabled(false)` 委托
///    [AylaVoiceRoomLike.unpublishMicrophone]（实现 = `removePublishedTrack` + `track.stop()` +
///    `mediaStreamTrack.stop()`）——**不是** mute。web `wsRelayRoom.ts:802-807`
///    「关麦完全释放麦克风设备（熄灭硬件指示灯）」是同一语义；
/// 3. **绝不用 isSpeaking / activeSpeakers 门控发布**：本文件与适配层都不读它们来决定
///    「是否发布 / 是否发包」。**muted 是唯一硬门控**——
///    见 `Ayla/docs/flutter/39-语音持续播放-speaking门控设计缺陷.md`；
///    把 speaking 当媒体开关等于把已修缺陷原样搬到新栈。
///
/// ## 电平语义（与 web 一致的部分 / 有意差异）
/// - `onLocalAudioLevel` / `onRemoteAudioLevels` 由 **100ms 节拍**输出；
/// - 远端快照**必须含 0**（上层 `setRemoteAudioLevels` 按「缺失=0」覆盖，缺项会留残值）；
/// - 本地电平沿用 web 的 `max(prev * 0.6, 实测)`（`livekitRoom.ts:346`）：条子不「硬跳」；
/// - **有意差异**：web 用 `WebAudio AnalyserNode` 直接算 RMS；Flutter 没有等价物，
///   本地电平取 SDK 的 `LocalAudioTrack.getSenderStats().audioSourceStats.audioLevel`
///   （media-source 统计，200ms 刷新），远端取 `participant.audioLevel`
///   （LiveKit 服务端 speaker 电平）。**都在适配层实现**，本层只消费标量。
///
/// ## 状态映射（RelayState 六值，会话层映射函数零改动）
/// | LiveKit | RelayState |
/// |---|---|
/// | 连接起点 | `connecting` |
/// | `RoomConnectedEvent` / connect resolve | `connected` |
/// | `RoomReconnectingEvent` / `RoomResumingEvent` | `reconnecting` |
/// | `RoomReconnectedEvent` | `connected` |
/// | `RoomDisconnectedEvent`（非用户主动断开） | `failed` |
/// | 主动 `disconnect()` | `closed` |
///
/// SDK 自带重连（`ReconnectPolicy`）⇒ **不需要**中继版那 30 行指数退避。
library;

import 'dart:async';
import 'dart:math' as math;

import 'relay_client.dart' show RelayState;

/// 房间事件种类（适配层归一化后的最小集；与 [AylaVoiceMediaEvents] 逐条对应）。
enum AylaRoomEventKind {
  connected,
  reconnecting,
  reconnected,
  disconnected,
  participantJoined,
  participantLeft,
  trackMuted,
  trackUnmuted,
}

/// 归一化房间事件。
class AylaRoomEvent {
  const AylaRoomEvent(this.kind, {this.identity, this.muted});

  final AylaRoomEventKind kind;

  /// 参与者 identity（**裸 user_id**）。
  final String? identity;

  /// 静音事实（仅 `trackMuted/trackUnmuted` 有值）。
  final bool? muted;

  @override
  String toString() =>
      'AylaRoomEvent(${kind.name}, identity: $identity, muted: $muted)';
}

/// LiveKit 房间的最小面（生产实现 = `AylaLiveKitSdkRoom`，测试注入假实现）。
///
/// 刻意**只暴露后端真正需要的东西**：没有 `isSpeaking`、没有 `activeSpeakers`、
/// 没有「mute 麦克风」——因为后端的麦克风语义是「发布/释放设备」，不是 mute。
abstract class AylaVoiceRoomLike {
  /// 连接（URL + 媒体 token；token 只作入参，不缓存）。
  Future<void> connect(String url, String token);

  /// 断开（幂等；**不代表离开频道**）。
  Future<void> disconnect();

  /// 释放（断开 + 释放原生资源）。
  Future<void> dispose();

  /// 归一化事件流（广播）。
  Stream<AylaRoomEvent> get events;

  /// 采集 + 发布麦克风轨道（成功后 [microphoneEnabled] == true）。
  Future<void> publishMicrophone();

  /// **完全释放麦克风设备**：unpublish + `track.stop()`（隐私：熄灭硬件指示灯）。
  Future<void> unpublishMicrophone();

  /// 麦克风是否处于「已发布」状态（媒体事实）。
  bool get microphoneEnabled;

  /// 当前远端成员 identity 列表（顺序不保证）。
  List<String> get remoteIdentities;

  /// 本地麦克风实时电平 0`1（未开麦时 0）。
  double get localAudioLevel;

  /// 指定远端成员的实时电平 0`1（未知成员 ⇒ 0）。
  double remoteAudioLevel(String identity);

  /// 恢复远端音频播放（移动端/桌面端的音频会话解锁；幂等）。
  Future<void> startAudio();

  /// 远端成员本地播放开关（`enabled=false` = 本地禁音该成员）。
  ///
  /// ⚠️ **能力边界**：LiveKit Flutter SDK（2.13.2）没有 per-track 音量 API，
  /// 只能「订阅/不订阅」⇒ 只有 0 与非 0 两档（部分音量无法生效，见交付报告）。
  Future<void> setRemoteAudioEnabled(String identity, bool enabled);
}

/// 房间工厂（测试注入点）。
typedef AylaVoiceRoomFactory = Future<AylaVoiceRoomLike> Function();

/// LiveKit 语音媒体后端（单房间；生命周期由 `AylaVoiceMedia` 编排）。
class AylaLiveKitVoiceBackend {
  AylaLiveKitVoiceBackend({
    required void Function(RelayState state) onStateChange,
    required void Function(int slot, bool muted) onTrackMuted,
    required void Function(double level) onLocalAudioLevel,
    required void Function(Map<String, double> levels) onRemoteAudioLevels,
    required void Function(String line) onLog,
    AylaVoiceRoomFactory? roomFactory,
  })  : _onStateChange = onStateChange,
        _onTrackMuted = onTrackMuted,
        _onLocalAudioLevel = onLocalAudioLevel,
        _onRemoteAudioLevels = onRemoteAudioLevels,
        _onLog = onLog,
        _roomFactory = roomFactory ?? AylaLiveKitRoomBuilder.build;

  /// 电平节拍：与中继版一致（UI 依赖「连续回调 + 含 0 + 衰减」）。
  static const Duration levelTick = Duration(milliseconds: 100);

  /// 本地电平每拍的衰减系数（与 web `livekitRoom.ts:46 LOCAL_DECAY` 一致）。
  static const double localDecay = 0.6;

  final void Function(RelayState state) _onStateChange;
  final void Function(int slot, bool muted) _onTrackMuted;
  final void Function(double level) _onLocalAudioLevel;
  final void Function(Map<String, double> levels) _onRemoteAudioLevels;
  final void Function(String line) _onLog;
  final AylaVoiceRoomFactory _roomFactory;

  AylaVoiceRoomLike? _room;
  StreamSubscription<AylaRoomEvent>? _events;
  Timer? _tick;

  RelayState _state = RelayState.idle;
  bool _closed = true;
  bool _micEnabled = false;
  double _localPeak = 0;
  double _localGain = 1;

  /// 合成 slot 表（LiveKit 给 identity，中继协议给 slot；会话层的
  /// `bindMediaEvents` 仍以 slot 为键 ⇒ 这里是**唯一一处** identity ↔ slot 映射，
  /// 上层语义（远端静音事实 → 成员表）零改动）。
  final Map<String, int> _identitySlot = <String, int>{};
  final Map<int, String> _slotIdentity = <int, String>{};
  int _nextSlot = 1;

  /// 远端成员的目标音量（0`1；0 = 本地禁音）。只在 0 ↔ 非 0 的边界动订阅。
  final Map<String, double> _remoteVolumes = <String, double>{};

  RelayState get state => _state;

  /// LiveKit 无 slot 协议概念 —— 恒 -1（会话层不用它）。
  int get mySlot => -1;

  bool get microphoneEnabled => _micEnabled;

  /// slot → identity（会话层 `identityOfSlot` 的 LiveKit 实现）。
  String? identityOfSlot(int slot) {
    final String? identity = _slotIdentity[slot];
    return (identity == null || identity.isEmpty) ? null : identity;
  }

  /// 测试/诊断：slot 表快照。
  Map<int, String> get debugSlotIdentity =>
      Map<int, String>.unmodifiable(_slotIdentity);

  /// 诊断：本地增益目标值（SDK 无 per-track 音量 API，见 [setLocalVolume]）。
  double get debugLocalGain => _localGain;

  /* ---------------- 连接生命周期 ---------------- */

  /// 连接（真实失败**原样上抛**，由 `AylaVoiceMedia` 决定是否原地降级到中继）。
  Future<void> connect(String url, String token) async {
    _closed = false;
    _setState(RelayState.connecting);
    AylaVoiceRoomLike room;
    try {
      room = await _roomFactory();
    } catch (error) {
      _closed = true;
      _setState(RelayState.failed);
      rethrow;
    }
    _room = room;
    _events = room.events.listen(_handleEvent);
    try {
      await room.connect(url, token);
    } catch (error) {
      await _teardownRoom();
      _closed = true;
      _setState(RelayState.failed);
      rethrow;
    }
    if (_closed) {
      // 连接在途时被 disconnect/dispose 取代：收掉刚建立的那一条，报「被取代」。
      await _teardownRoom();
      throw const AylaVoiceBackendCancelled();
    }
    // Connected 事件可能先于 connect() resolve 到达 —— 这里兜底一次（幂等）。
    _markConnected();
    _startTick();
    _syncRemoteSlots();
    await _applyRemoteVolumes();
  }

  /// 断开（幂等；**不代表离开频道** —— REST `leave/` 才是成员事实）。
  Future<void> disconnect() async {
    _closed = true;
    _stopTick();
    await _teardownRoom();
    _resetSession();
    _state = RelayState.closed;
  }

  /// 释放（断开 + 丢弃）。
  Future<void> dispose() => disconnect();

  /* ---------------- 麦克风（硬约束 2） ---------------- */

  /// 开/关麦。
  ///
  /// ⚠️ 关麦走 [AylaVoiceRoomLike.unpublishMicrophone]（**释放设备**），绝不只 mute：
  /// SDK 的 `setMicrophoneEnabled(false)` 默认只 mute、设备仍被占用（系统麦克风指示灯
  /// 常亮），直接用等于把 web 侧的隐私语义回退掉。
  Future<void> setMicrophoneEnabled(bool enabled) async {
    final AylaVoiceRoomLike? room = _room;
    if (room == null) {
      throw StateError('LiveKit 未连接');
    }
    if (enabled == _micEnabled) return;
    if (enabled) {
      // 发布轨道后 SDK 会持续发包（`dtx=false`，静音段也是小包）——
      // **不按 speaking 开关 track**（硬约束 3）。
      await room.publishMicrophone();
      _micEnabled = true;
      return;
    }
    _micEnabled = false;
    _localPeak = 0;
    _onLocalAudioLevel(0);
    try {
      await room.unpublishMicrophone();
    } catch (error) {
      _onLog('[livekit] 释放麦克风失败: $error');
      rethrow;
    }
  }

  /// 本地麦克风发送音量 0`2（web `client.ts setLocalVolume`）。
  ///
  /// ⚠️ **能力边界（诚实上报，不伪造成功）**：LiveKit Flutter SDK 2.13.2 **没有**
  /// per-track 增益 API（web 用 `TrackProcessor` + `GainNode`，Flutter 无等价物）
  /// ⇒ 记录目标值但不生效。
  void setLocalVolume(double gain) {
    _localGain = gain.clamp(0.0, 2.0);
    _onLog('[livekit] 本地增益 $_localGain 暂不生效'
        '（SDK 2.13.2 无 per-track 音量 API；web 用 WebAudio GainNode）');
  }

  /// 远端成员本地播放音量 0`1（0 = 本地禁音该成员）。
  ///
  /// 能力边界：SDK 没有 per-track 音量 ⇒ 只有 0（不订阅）与非 0（订阅）两档；
  /// 中间档记录但不生效（诚实日志）。
  void setRemoteVolume(String identity, double volume) {
    if (identity.isEmpty) return;
    final double clamped = volume.clamp(0.0, 1.0);
    _remoteVolumes[identity] = clamped;
    if (clamped > 0 && clamped < 1) {
      _onLog('[livekit] 远端音量 $clamped 暂不生效'
          '（SDK 无 per-track 音量；仅 0 = 本地禁音可生效）');
    }
    unawaited(_applyRemoteVolume(identity, clamped > 0));
  }

  /// 恢复远端音频播放（幂等；移动端音频会话解锁）。
  Future<void> startAudio() async {
    final AylaVoiceRoomLike? room = _room;
    if (room == null) return;
    try {
      await room.startAudio();
    } catch (error) {
      _onLog('[livekit] startAudio 失败: $error');
    }
  }

  /* ---------------- 内部：事件 / 电平 / slot ---------------- */

  void _setState(RelayState state) {
    if (_state == state) return;
    _state = state;
    _onStateChange(state);
  }

  void _markConnected() {
    if (_closed) return;
    _setState(RelayState.connected);
  }

  void _handleEvent(AylaRoomEvent event) {
    if (_closed) return;
    switch (event.kind) {
      case AylaRoomEventKind.connected:
      case AylaRoomEventKind.reconnected:
        _markConnected();
      case AylaRoomEventKind.reconnecting:
        _setState(RelayState.reconnecting);
      case AylaRoomEventKind.disconnected:
        // 非用户主动断开（_closed == true 时不会走到这里）⇒ 交给用户决定重进。
        _stopTick();
        _micEnabled = false;
        _setState(RelayState.failed);
      case AylaRoomEventKind.participantJoined:
        final String? identity = event.identity;
        if (identity != null && identity.isNotEmpty) {
          _slotFor(identity);
          _onLog('[livekit] 成员加入 identity=$identity');
        }
      case AylaRoomEventKind.participantLeft:
        _onLog('[livekit] 成员离开 identity=${event.identity ?? '-'}');
      case AylaRoomEventKind.trackMuted:
        _emitTrackMuted(event.identity, true);
      case AylaRoomEventKind.trackUnmuted:
        _emitTrackMuted(event.identity, false);
    }
  }

  void _emitTrackMuted(String? identity, bool muted) {
    if (identity == null || identity.isEmpty) return;
    _onTrackMuted(_slotFor(identity), muted);
  }

  /// identity → 合成 slot（稳定、单调分配；LiveKit 会话内不变）。
  int _slotFor(String identity) {
    final int? existing = _identitySlot[identity];
    if (existing != null) return existing;
    final int slot = _nextSlot++;
    _identitySlot[identity] = slot;
    _slotIdentity[slot] = identity;
    return slot;
  }

  void _startTick() {
    _tick?.cancel();
    _tick = Timer.periodic(levelTick, (_) => _emitLevels());
  }

  void _stopTick() {
    _tick?.cancel();
    _tick = null;
  }

  /// 单拍电平上报（契约：远端**全量快照含 0**；未开麦本地恒回调 0）。
  void _emitLevels() {
    final AylaVoiceRoomLike? room = _room;
    if (room == null || _closed) return;

    double level = 0;
    if (_micEnabled) {
      final double raw = room.localAudioLevel;
      final double measured = raw.isFinite ? raw.clamp(0.0, 1.0) : 0;
      _localPeak = math.max(_localPeak * localDecay, measured);
      level = _localPeak;
    } else {
      _localPeak = 0;
    }
    _onLocalAudioLevel(level.clamp(0.0, 1.0));

    final Map<String, double> levels = <String, double>{};
    for (final String identity in room.remoteIdentities) {
      _slotFor(identity);
      levels[identity] = _remoteLevel(identity);
    }
    _onRemoteAudioLevels(levels);
  }

  double _remoteLevel(String identity) {
    final double raw = _room?.remoteAudioLevel(identity) ?? 0;
    if (!raw.isFinite) return 0;
    return raw.clamp(0.0, 1.0);
  }

  void _syncRemoteSlots() {
    final AylaVoiceRoomLike? room = _room;
    if (room == null) return;
    for (final String identity in room.remoteIdentities) {
      _slotFor(identity);
    }
  }

  Future<void> _applyRemoteVolumes() async {
    _syncRemoteSlots();
    for (final MapEntry<String, double> entry in _remoteVolumes.entries) {
      await _applyRemoteVolume(entry.key, entry.value > 0);
    }
  }

  Future<void> _applyRemoteVolume(String identity, bool enabled) async {
    final AylaVoiceRoomLike? room = _room;
    if (room == null || _closed) return;
    try {
      await room.setRemoteAudioEnabled(identity, enabled);
    } catch (error) {
      _onLog('[livekit] 远端音量应用失败 identity=$identity: $error');
    }
  }

  Future<void> _teardownRoom() async {
    _stopTick();
    final StreamSubscription<AylaRoomEvent>? events = _events;
    _events = null;
    await events?.cancel();
    final AylaVoiceRoomLike? room = _room;
    _room = null;
    _micEnabled = false;
    if (room != null) {
      try {
        await room.disconnect();
      } catch (error) {
        _onLog('[livekit] 断开失败: $error');
      }
      try {
        await room.dispose();
      } catch (error) {
        _onLog('[livekit] 释放失败: $error');
      }
    }
  }

  void _resetSession() {
    _micEnabled = false;
    _localPeak = 0;
    _identitySlot.clear();
    _slotIdentity.clear();
    _nextSlot = 1;
  }
}

/// 连接在途时被取代（等价于 web `client.ts` 的 `AbortError`）。
///
/// ⚠️ **不是**降级场景：被取代必须原样上抛，绝不能触发「降级到中继」。
class AylaVoiceBackendCancelled implements Exception {
  const AylaVoiceBackendCancelled();

  @override
  String toString() => 'LiveKit 连接已被取代';
}

/// 生产房间构造入口（在适配层注册；本文件不 import SDK，保证后端可纯单测）。
abstract final class AylaLiveKitRoomBuilder {
  static Future<AylaVoiceRoomLike> Function()? _builder;

  /// 由 `livekit_room_adapter.dart` 在库加载时调用。
  static void install(Future<AylaVoiceRoomLike> Function() builder) {
    _builder = builder;
  }

  /// 是否已注册（诊断；单测注入假工厂时不需要注册）。
  static bool get registered => _builder != null;

  static Future<AylaVoiceRoomLike> build() {
    final Future<AylaVoiceRoomLike> Function()? builder = _builder;
    if (builder == null) {
      throw StateError('LiveKit 房间构造器未注册（适配层未加载）');
    }
    return builder();
  }
}
