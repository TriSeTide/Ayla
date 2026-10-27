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

  /// 本实例的事件容器（中继/引擎的回调**构造时已接进这一份**）。
  ///
  /// ⚠️ **会话层必须绑这一份**（2026-10-26 用户实报「听得见声音但音量条恒 0」的根因）：
  /// 构造体把 [RelayCallbacks] / [AudioEngineCallbacks] 逐条转发到 [_events]，而
  /// 引擎每 100ms 就调一次 `_events.onRemoteAudioLevels?.call(snapshot)`。
  /// 若调用方另建一个 [AylaVoiceMediaEvents] 去 `bindMediaEvents`，那个对象
  /// **永远不会被任何东西调用** ⇒ 音频电平/静音/状态事实全部丢失，只有声音照旧
  /// （媒体链路本身是好的）⇒ 条子恒 0。
  AylaVoiceMediaEvents get events => _events;

  late final AylaRelayClient _relay;
  late final AylaAudioEngine _engine;

  /// token 续期钩子（默认继承模块级 `_voiceMediaTokenRefresher`，见 [setTokenRefresher]）。
  /// 未注入时返回 null —— **不伪造续期成功**。
  Future<String?> Function() _freshToken =
      _voiceMediaTokenRefresher ?? () async => null;

  /// 见 [debugHasTokenRefresher]（构造时若模块级已有注入则视为已注入）。
  bool _hasTokenRefresher = _voiceMediaTokenRefresher != null;

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
  ///
  /// ⚠️ 同时写进**模块级** `_voiceMediaTokenRefresher`：登出会
  /// [aylaVoiceMediaTeardown] 把单例置空，下次 [aylaVoiceMedia] 新建的实例必须
  /// 继承同一个续期实现 —— 否则「登出再登录」之后中继又退回「恒返回 null」，
  /// 且再没有人会去补注入（`main` 每个进程只跑一次）。
  void setTokenRefresher(Future<String?> Function() refresher) {
    _freshToken = refresher;
    _voiceMediaTokenRefresher = refresher;
    _hasTokenRefresher = true;
  }

  /// 诊断：是否已注入 token 续期实现。
  ///
  /// `false` = 中继连续失败达阈值后**只能沿用旧 token**（token 过期就永远续不上）。
  /// 生产由 `main` 注入一次；本 getter 是接线回归锁的可观测面。
  bool get debugHasTokenRefresher => _hasTokenRefresher;

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

/// 进程级 token 续期实现（由 `main` 注入一次；**跨单例重建存活**，见
/// [AylaVoiceMedia.setTokenRefresher]）。null = 尚未注入（不伪造续期成功）。
Future<String?> Function()? _voiceMediaTokenRefresher;

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

/// 登出 / 401 过期时的**语音媒体收尾**（幂等）。
///
/// 对应 web `stores/auth.ts:136` 的 `void voiceLiveKit.disconnect()`：登出必须断开语音
/// 媒体（WebAudio 设备、中继 WS、编解码器），否则下一位登录者会继承上一位的音频会话。
///
/// 与 [AylaVoiceMedia.disconnect] 的差别（有意）：
/// - `disconnect()` 是**房间级**语义（"离开当前频道、仍可复用实例"，web 同名）；
/// - 本函数是**账号级**收尾：连单例一起放掉（`_voiceMedia = null`），下一次
///   [aylaVoiceMedia] 会新建一份干净实例 —— 与 web 登出后 `voiceLiveKit` 重新 `connect`
///   的观感一致，且能保证事件回调不泄漏到已登出的会话。
///
/// **不阻塞调用方**：登出路径不等待音频设备释放（web 也是 `void` 调用）。
void aylaVoiceMediaTeardown() {
  final AylaVoiceMedia? media = _voiceMedia;
  _voiceMedia = null;
  if (media == null) return;
  // 不 await：登出是同步路径；dispose 内部幂等且自带错误吞并（见其实现）。
  unawaited(media.dispose());
}
