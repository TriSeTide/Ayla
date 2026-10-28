/// Android 语音会话「媒体音量」原生通道（`ayla/audio_route`）。
///
/// ## 为什么需要
/// Android 的语音会话默认是**通话语义**（`MODE_IN_COMMUNICATION` + 通话/听筒
/// 音频属性 + `STREAM_VOICE_CALL`），此时音量键调的是「通话音量」。
/// 用户 2026-10-28 实报：手机端语音房听感/音量档是通话形态，要求改成媒体播放。
///
/// livekit_client 2.13.2 的 Android 插件虽然自建 `LKAudioSwitchManager` 并在
/// `AudioSessionOptions.mediaPlayback()` 下把会话压成 `MODE_NORMAL` + `USAGE_MEDIA`，
/// 但**真正的播放轨（WebRTC ADM 的 AudioTrack）在 WebRTC initialize 时已按默认
/// `USAGE_VOICE_COMMUNICATION` 建好**（`dumpsys audio` 的 playback 记录可见），
/// 运行期只改会话策略不会重建播放轨，于是音量键仍落在 `STREAM_VOICE_CALL` 上。
///
/// 这里调用原生通道 [`MethodChannel('ayla/audio_route')`] 的 `applyMediaMode`：
/// 1. `AudioManager.mode = MODE_NORMAL`（媒体语义，非通话）；
/// 2. 有线/蓝牙/USB 耳机检测：**有耳机不强制外放**（媒体路由自然走耳机），
///    无耳机时 `isSpeakerphoneOn = true`；
/// 3. 以 `AudioAttributes(USAGE_MEDIA, CONTENT_TYPE_SPEECH)` 申请 `AUDIOFOCUS_GAIN`；
/// 原生侧注册 `OnAudioFocusChangeListener`，`LOSS_TRANSIENT` 结束（GAIN 回来）后
/// **重施**媒体属性，防止系统/其它应用把 mode 改回通话；
/// 4. 返回 mode / 是否外放 / 当前 `STREAM_MUSIC` 音量，供 Dart 侧打印与断言。
///
/// 约定：**幂等**（可反复调用，并发调用会合流为一次原生请求）；失败返回 `false`
/// 不抛异常——语音生命周期不得因为音频路由失败而中断。
///
/// 非 Android 平台（Windows/iOS/Web）一律返回 `false`，调用方跳过即可。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 一次 `applyMediaMode` 的原生回读状态（用于日志与断言，不做业务判断）。
typedef AylaAndroidMediaRouteState = ({
  /// `MODE_NORMAL` / `MODE_IN_COMMUNICATION` 等。
  String mode,

  /// 是否接着耳机（有线/USB/蓝牙 A2DP·SCO·BLE/助听器）。
  bool headset,

  /// 耳机种类（`wired-headset` / `bluetooth-a2dp` …，无耳机为空串）。
  String headsetKind,

  /// 当前是否外放（有耳机时为 false，表示不强制外放）。
  bool speakerOn,

  /// 媒体焦点是否申请成功。
  bool focusGranted,

  /// `STREAM_MUSIC` 当前音量档（媒体音量）。
  int streamMusicVolume,

  /// `STREAM_VOICE_CALL` 当前音量档（通话音量；媒体语义下不应被音量键改动）。
  int streamVoiceCallVolume,
});

/// Android 媒体音频路由（原生 MethodChannel `ayla/audio_route`）。
class AylaAndroidAudioRoute {
  const AylaAndroidAudioRoute._();

  static const MethodChannel _channel = MethodChannel('ayla/audio_route');

  /// 平台判定注入点（单测用；默认见 [_defaultIsAndroid]）。
  ///
  /// 刻意不用 `dart:io` 的 `Platform.isAndroid`：它在 `flutter test` 里恒为
  /// false，会让「Android 才走原生通道」这条契约无法在纯 Dart 单测里锁死。
  @visibleForTesting
  static bool Function() platformIsAndroid = _defaultIsAndroid;

  static bool _defaultIsAndroid() =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 当前平台是否支持：只有 Android 有这条原生通道。
  static bool get supported => platformIsAndroid();

  /// 最近一次成功 apply 的回读状态（debug 日志/断言用；失败不变）。
  static AylaAndroidMediaRouteState? get lastState => _lastState;
  static AylaAndroidMediaRouteState? _lastState;

  /// 单测复位（清状态与平台注入；生产代码不调用）。
  @visibleForTesting
  static void resetForTesting() {
    _lastState = null;
    _inFlight = null;
    platformIsAndroid = _defaultIsAndroid;
  }

  /// 并发合流：同一时刻的多次调用只发一次原生请求（幂等的另一半）。
  static Future<bool>? _inFlight;

  /// 应用媒体音频语义（见库注释）。幂等；失败返回 false。
  static Future<bool> applyMediaMode() async {
    if (!supported) return false;
    final Future<bool>? pending = _inFlight;
    if (pending != null) return pending;
    final Future<bool> run = _apply();
    _inFlight = run;
    try {
      return await run;
    } finally {
      if (identical(_inFlight, run)) _inFlight = null;
    }
  }

  static Future<bool> _apply() async {
    try {
      final Map<Object?, Object?>? raw = await _channel
          .invokeMethod<Map<Object?, Object?>>('applyMediaMode');
      if (raw == null) {
        debugPrint('[audio-route] 原生 applyMediaMode 未返回结果');
        return false;
      }
      if (raw['ok'] != true) {
        debugPrint('[audio-route] 原生 applyMediaMode 失败: ${raw['reason']}');
        return false;
      }
      final AylaAndroidMediaRouteState state = _parseState(raw);
      _lastState = state;
      if (kDebugMode) {
        debugPrint(
          '[audio-route] mode=${state.mode} focus=${state.focusGranted} '
          'speaker=${state.speakerOn} headset=${state.headset}'
          '${state.headsetKind.isEmpty ? '' : '(${state.headsetKind})'} '
          'musicVol=${state.streamMusicVolume} '
          'voiceCallVol=${state.streamVoiceCallVolume}',
        );
      }
      return true;
    } catch (error) {
      // 原生通道不可用 / 非 Android 误调 / 系统拒绝：一律按失败返回，不向上抛。
      debugPrint('[audio-route] Android 媒体音频路由失败: $error');
      return false;
    }
  }

  /// 只读回读原生当前状态（`getMediaModeState`）；不支持或失败返回 null，不抛。
  static Future<AylaAndroidMediaRouteState?> readMediaModeState() async {
    if (!supported) return null;
    try {
      final Map<Object?, Object?>? raw = await _channel
          .invokeMethod<Map<Object?, Object?>>('getMediaModeState');
      if (raw == null || raw['ok'] == false) return null;
      return _parseState(raw);
    } catch (error) {
      debugPrint('[audio-route] 读取原生音频状态失败: $error');
      return null;
    }
  }

  /// 原生 Map → 类型化状态（缺项走安全默认，不做业务判断）。
  static AylaAndroidMediaRouteState _parseState(Map<Object?, Object?> raw) => (
        mode: (raw['mode'] ?? 'unknown').toString(),
        headset: raw['headset'] == true,
        headsetKind: (raw['headsetKind'] ?? '').toString(),
        speakerOn: raw['speakerOn'] == true,
        focusGranted: raw['focusGranted'] == true,
        streamMusicVolume: (raw['streamMusicVolume'] as num?)?.toInt() ?? -1,
        streamVoiceCallVolume:
            (raw['streamVoiceCallVolume'] as num?)?.toInt() ?? -1,
      );
}

/// 让 Android 语音会话使用**媒体音量**（幂等；非 Android 或失败返回 false，不抛）。
///
/// 调用时机由语音生命周期决定（连接后、每次 `publishMicrophone` 之后各一次），
/// 本函数自身可安全重复调用。
Future<bool> aylaApplyAndroidMediaRoute() =>
    AylaAndroidAudioRoute.applyMediaMode();
