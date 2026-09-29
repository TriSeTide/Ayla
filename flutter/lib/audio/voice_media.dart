/// 语音媒体层薄封装 —— web `livekit/client.ts`（251 行，`VoiceLiveKitClient`）的
/// Flutter 等价物：连接/静音/音量/远端事实归一，**只处理媒体层**。
///
/// ## 依赖倒置（同 web `client.ts:4–5`）
/// 本类只依赖两个可注入件：[AylaRelayClient]（真实实现 = WS 音频中继）与
/// [AylaAudioEngine]（采集/编解码/播放），测试注入替身即可覆盖全部分支。
///
/// ## 语义边界（M5-3 §4.3，web `client.ts:11–17` 原话）
/// - **轨道 mute 是媒体事实**；`voice.state` 的 muted/unmuted 是**应用层**成员事实 ——
///   两者不混用，本封装只处理媒体层；
/// - **远端音量是本地播放偏好**：只调本地增益，不落库、不上报；
/// - **媒体断线 ≠ 离开频道**：断线只映射为 `failed`，由用户决定重进；
/// - token 纪律：token 只作 connect 入参传递，**不打日志、不缓存**。
///
/// ## 与 web 的差异（登记）
/// - web 用 `WebAudio` 的 per-slot gain 与 `WebCodecs` 编解码；Flutter 用
///   `libopus FFI` + `miniaudio`（PoC-A 选型定论）—— 语义等价，
///   增益在**编码前 / 播放前**按样本施加（见 `audio_engine.dart` 头注）；
/// - web 的 `owner generation + AbortError` 用 Dart 的 `generation` 计数表达
///   （无 `AbortError` 类型）：连接被取代时旧调用抛 [AylaVoiceMediaCancelled]，
///   调用方按"被取代"静默处理。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'audio_engine.dart';
import 'relay_client.dart';

/// 媒体连接被新连接取代（web `AbortError` 的等价物）。
class AylaVoiceMediaCancelled implements Exception {
  const AylaVoiceMediaCancelled();

  @override
  String toString() => '语音媒体连接已被取代';
}

/// 媒体层事件（web `LiveKitEvents`）。
class AylaVoiceMediaEvents {
  /// 状态变化（idle/connecting/connected/reconnecting/failed/closed）。
  void Function(RelayState state)? onStateChange;

  /// 远端轨道静音事实（媒体层；[slot] → 由会话层映射到 user_id）。
  void Function(int slot, bool muted)? onTrackMuted;

  /// 本地麦克风实时音量 0~1（未开麦时为 0）。
  void Function(double level)? onLocalAudioLevel;

  /// 远端成员实时音量**全量快照**（user_id → 0~1，含 0）。
  void Function(Map<String, double> levels)? onRemoteAudioLevels;

  /// 诊断日志。
  void Function(String line)? onLog;
}

/// 语音媒体封装（单例语义由 [aylaVoiceMedia] 承担；测试可直接 new）。
class AylaVoiceMedia {
  AylaVoiceMedia(this._events) {
    // ⚠️ `RelayCallbacks` / `AudioEngineCallbacks` 是**字段式回调容器**
    // （PoC 形态：先建实例再挂回调），不是构造参数式。
    // ⚠️ 逐条赋值（**不要用级联 `..`**：lambda 体以 `=>` 结尾时，下一行的 `..x = y`
    // 会被解析成 lambda 体内的级联，报 use_of_void_result —— 实测踩过）。
    final RelayCallbacks relayCallbacks = RelayCallbacks();
    relayCallbacks.onStateChange = (RelayState s) => _events.onStateChange?.call(s);
    relayCallbacks.onMuted = (int slot, bool on) => _events.onTrackMuted?.call(slot, on);
    relayCallbacks.onLog = (String line) => _events.onLog?.call(line);
    _relay = AylaRelayClient(
      relayCallbacks,
      freshToken: () => _freshToken(),
    );
    relayCallbacks.onAudio = (int slot, Uint8List opus) =>
        unawaited(_engine.onRemoteAudio(slot, opus));
    final AudioEngineCallbacks engineCallbacks = AudioEngineCallbacks();
    engineCallbacks.onLocalLevel =
        (double level) => _events.onLocalAudioLevel?.call(level);
    engineCallbacks.onRemoteAudioLevels =
        (Map<String, double> levels) => _events.onRemoteAudioLevels?.call(levels);
    engineCallbacks.onLog = (String line) => _events.onLog?.call(line);
    _engine = AylaAudioEngine(_relay, engineCallbacks);
  }

  final AylaVoiceMediaEvents _events;

  late final AylaRelayClient _relay;
  late final AylaAudioEngine _engine;

  /// token 续期钩子（由 `main` 注入；默认返回 null —— **不伪造续期成功**）。
  Future<String?> Function() _freshToken = () async => null;

  int _generation = 0;
  bool _engineReady = false;

  /// 当前是否已连接（媒体面）。
  bool get connected => _relay.state == RelayState.connected;

  /// 当前状态。
  RelayState get state => _relay.state;

  /// 我的 slot（-1 = 未分配）。
  int get mySlot => _relay.mySlot;

  /// 是否开麦（媒体事实）。
  bool get microphoneEnabled => _engine.micEnabled;

  /// 诊断：引擎是否已成功初始化（**false = 设备/库不可用，不冒充成功**）。
  bool get debugEngineReady => _engineReady;
  bool get debugLibInit => _engine.debugLibInit;
  bool get debugMiniaudioReady => _engine.debugMiniaudioReady;

  /// 注入 token 续期（`main` 在 `DioClient` init 之后调用一次）。
  void setTokenRefresher(Future<String?> Function() refresher) {
    _freshToken = refresher;
  }

  /// 连接频道（web `voiceLiveKit.connect(wsUrl, token)`）。
  ///
  /// 被新连接取代时旧调用以 [AylaVoiceMediaCancelled] 结束；否则异常原样上抛
  /// （由 join 流程决定回滚 —— **媒体断线 ≠ 离开频道**）。
  Future<void> connect(String channelId, String token) async {
    final int generation = ++_generation;
    if (!_engineReady) {
      _engineReady = await _engine.init();
      if (!_engineReady) {
        await disconnect();
        throw StateError('音频引擎初始化失败（libopus / 音频设备不可用）');
      }
    }
    if (generation != _generation) throw const AylaVoiceMediaCancelled();
    try {
      await _relay.connect(channelId, token);
    } catch (error) {
      if (generation != _generation) throw const AylaVoiceMediaCancelled();
      _events.onStateChange?.call(RelayState.failed);
      rethrow;
    }
    if (generation != _generation) throw const AylaVoiceMediaCancelled();
  }

  /// 播放入口就绪（web `startAudio()` 的等价物）。
  ///
  /// Flutter 侧 miniaudio 是 push 式设备流、无浏览器 autoplay 政策 ⇒ 本方法只保证
  /// "引擎已初始化"（返回值 void），**不伪造播放成功**。
  Future<void> startAudio() async {
    if (!_engineReady) _engineReady = await _engine.init();
  }

  /// 开/关麦（web `setMicrophoneEnabled`；失败原样上抛由调用方回滚 UI）。
  Future<void> setMicrophoneEnabled(bool enabled) =>
      _engine.setMicrophoneEnabled(enabled);

  /// 远端成员本地播放增益 0~1（web `setRemoteVolume`）。
  void setRemoteVolume(String userId, double volume) =>
      _engine.setRemoteVolume(userId, volume);

  /// 本地发送增益 0~2（web `setLocalVolume`；UI 的 0~100 → `volume / 50`）。
  void setLocalVolume(double gain) => _engine.setLocalGain(gain);

  /// 断开（幂等；web `disconnect()`）。**不代表离开频道**。
  Future<void> disconnect() async {
    _generation++;
    await _relay.disconnect();
  }

  /// 释放（登出/测试收尾）：断开 + 销毁引擎。
  Future<void> dispose() async {
    _generation++;
    await _relay.disconnect();
    await _engine.dispose();
    _engineReady = false;
  }

  /// 测试注入点：直接拿引擎（断言增益/采样）。
  @visibleForTesting
  AylaAudioEngine get debugEngine => _engine;

  /// slot → identity（远端轨道静音事实映射到成员用；**公开面**，不是测试专用）。
  ///
  /// web 侧同一信息在 `wsRelayRoom.ts` 的 `slotToIdentity` 里，由 `client.ts`
  /// 的 `onTrackMuted(identity, muted)` 直接给出；Flutter 侧由会话层查这张表。
  String? identityOfSlot(int slot) {
    final String? identity = _relay.slotIdentity[slot];
    return (identity == null || identity.isEmpty) ? null : identity;
  }

  /// 测试注入点：直接拿中继客户端。
  @visibleForTesting
  AylaRelayClient get debugRelay => _relay;
}

/// 全局单例（web `client.ts` 的 `voiceLiveKit`；房间同时只有一个媒体会话）。
AylaVoiceMedia? _voiceMedia;

/// 取/建全局媒体封装（首次调用时注入 events；已存在则原样返回 —— 与 web 单例同语义）。
AylaVoiceMedia aylaVoiceMedia([AylaVoiceMediaEvents? events]) {
  final AylaVoiceMedia? existing = _voiceMedia;
  if (existing != null) return existing;
  final AylaVoiceMedia created = AylaVoiceMedia(events ?? AylaVoiceMediaEvents());
  _voiceMedia = created;
  return created;
}

/// 测试专用：替换/清空全局单例。
@visibleForTesting
void debugSetVoiceMedia(AylaVoiceMedia? media) => _voiceMedia = media;
