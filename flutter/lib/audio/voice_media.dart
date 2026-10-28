/// 语音媒体封装 —— **LiveKit 单一实现**（会话层唯一入口）。
///
/// ## 分层
/// ```
/// AylaLiveKitSdkRoom (livekit_room_adapter.dart)      ← SDK 胶水层：Room/轨道/电平取数
///         ↓ AylaVoiceRoomLike + AylaRoomEvent
/// AylaLiveKitVoiceBackend (livekit_voice_backend.dart) ← 状态映射 / 100ms 电平 / 麦开关语义
///         ↓ AylaVoiceMediaEvents（由 [AylaVoiceMedia] 持有并转发）
/// AylaVoiceMedia (本文件)                              ← 上层唯一入口
/// ```
///
/// ## 历史（2026-10-28 定稿）
/// 本封装曾同时持有 ws_relay（Opus over WebSocket over TCP + miniaudio）实现，
/// 按后端下发的 `media.transport` 二选一，并在 LiveKit 连接失败时**原地降级**到中继。
/// 用户明确要求：**只保留 LiveKit，中继与其回退路径一并删除**（中继在真机上
/// 断断续续、且 TCP 队头阻塞正是这次迁移要解决的问题）。现在：
/// - `connectWithMedia` 只接受 `media.livekit`，缺失即显式失败（不静默降级）；
/// - 本文件不再引用任何 Opus/miniaudio/中继代码。
///
/// ## 语义边界（沿用既有契约）
/// - **轨道 mute 是媒体事实**；`voice.state` 的 muted/unmuted 是应用层成员事实 —— 不混用；
/// - **远端音量是本地播放偏好**：只影响本地播放，不落库、不上报；
/// - **媒体断线 ≠ 离开频道**：断线只映射为 `failed`，由用户决定重进；
/// - token 纪律：token 只作 connect 入参传递，**不打日志、不缓存**。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'livekit_room_adapter.dart' show aylaInstallLiveKitRoomBuilder;
import 'livekit_voice_backend.dart';
import 'voice_media_config.dart';
import 'voice_state.dart';

export 'voice_media_config.dart';
export 'voice_state.dart' show RelayState;

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

  /// 远端成员静音事实（LiveKit `trackMuted/trackUnmuted`；slot 为合成 slot）。
  void Function(int slot, bool muted)? onTrackMuted;

  /// 本地麦克风电平 0~1。
  void Function(double level)? onLocalAudioLevel;

  /// 远端成员电平快照（**含 0**，上层直接覆盖）。
  void Function(Map<String, double> levels)? onRemoteAudioLevels;

  /// 诊断日志（不含 token）。
  void Function(String line)? onLog;
}

/// 语音媒体封装（单例语义由 [aylaVoiceMedia] 承担；测试可直接 new）。
class AylaVoiceMedia {
  AylaVoiceMedia(this._events) {
    // 生产房间构造器注册（幂等）：只在真正 connect 时才构造原生 Room ——
    // 单测注入假工厂时完全不碰 SDK / 原生插件。
    aylaInstallLiveKitRoomBuilder();

    // 回调**逐条转发到同一份 [_events]**：会话层只绑这一份（历史事故根因，
    // 见 [events] 注释），绝不另建孤儿事件对象。
    _livekit = AylaLiveKitVoiceBackend(
      onStateChange: (RelayState state) => _events.onStateChange?.call(state),
      onTrackMuted: (int slot, bool muted) =>
          _events.onTrackMuted?.call(slot, muted),
      onLocalAudioLevel: (double level) => _events.onLocalAudioLevel?.call(level),
      onRemoteAudioLevels: (Map<String, double> levels) =>
          _events.onRemoteAudioLevels?.call(levels),
      onLog: (String line) => _events.onLog?.call(line),
      roomFactory: _createLiveKitRoom,
    );
  }

  final AylaVoiceMediaEvents _events;

  /// 本实例的事件容器（会话层**必须**绑这一份）。
  AylaVoiceMediaEvents get events => _events;

  late final AylaLiveKitVoiceBackend _livekit;

  int _generation = 0;

  /// 当前状态。
  RelayState get state => _livekit.state;

  /// 当前是否已连接（媒体面）。
  bool get connected => state == RelayState.connected;

  /// 我的 slot（LiveKit 无 slot 概念，恒 -1；保留给会话层兼容）。
  int get mySlot => -1;

  /// 是否开麦（媒体事实）。
  bool get microphoneEnabled => _livekit.microphoneEnabled;

  /// 连接媒体（只接受 LiveKit 配置；缺失即显式失败，不降级）。
  ///
  /// - [accessToken]：API 访问令牌（LiveKit 用不到它，仅用于续期语义占位）；
  /// - [media]：后端 `join` 下发的 `media`；
  /// - [selfUserId]：当前用户 id，用于 identity 纪律自检。
  Future<void> connectWithMedia(
    String channelId,
    String accessToken,
    AylaVoiceMediaConfig? media, {
    String? selfUserId,
  }) async {
    final int generation = ++_generation;
    final AylaVoiceLiveKitConfig? livekit = media?.livekit;
    _logIdentityCheck(livekit, selfUserId);
    if (livekit == null) {
      throw StateError('媒体配置缺失：后端未下发 media.livekit');
    }
    try {
      await _livekit.connect(livekit.url, livekit.token);
    } on AylaVoiceBackendCancelled {
      throw const AylaVoiceMediaCancelled();
    } catch (error) {
      if (generation != _generation) throw const AylaVoiceMediaCancelled();
      _events.onLog?.call('[voice] livekit_connect_failed reason=${_redact(error)}');
      rethrow;
    }
    if (generation != _generation) {
      await _livekit.disconnect();
      throw const AylaVoiceMediaCancelled();
    }
  }

  /// 断开（幂等；**不代表离开频道** —— REST `leave/` 才是成员事实）。
  Future<void> disconnect() async {
    ++_generation;
    await _livekit.disconnect();
  }

  /// 释放（断开 + 丢弃）。
  Future<void> dispose() async {
    ++_generation;
    await _livekit.dispose();
  }

  /// 播放入口就绪（原生平台远端音频由 WebRTC 自动播放，调用幂等）。
  Future<void> startAudio() => _livekit.startAudio();

  /// 开/关麦（关麦 = **释放麦克风设备**，不是 mute）。
  Future<void> setMicrophoneEnabled(bool enabled) =>
      _livekit.setMicrophoneEnabled(enabled);

  /// 远端成员本地播放音量 0~1（0 = 本地禁音该成员）。
  void setRemoteVolume(String identity, double volume) =>
      _livekit.setRemoteVolume(identity, volume);

  /// 本地麦克风发送音量 0~2。
  ///
  /// ⚠️ 能力边界（诚实上报）：LiveKit Flutter SDK 2.13.2 没有 per-track 增益 API
  /// （web 用 `TrackProcessor` + `GainNode`）⇒ 记录目标值但不生效。
  void setLocalVolume(double gain) {
    _livekit.setLocalVolume(gain);
  }

  /// slot → identity（远端轨道静音事实映射到成员用；**公开面**）。
  String? identityOfSlot(int slot) => _livekit.identityOfSlot(slot);

  /* ---------------- 测试注入点 ---------------- */

  /// 测试注入点：替换 LiveKit 房间工厂（避免单测触网/碰原生插件）。
  @visibleForTesting
  static AylaVoiceRoomFactory? debugLiveKitRoomFactory;

  /// 测试注入点：直接拿 LiveKit 后端（断言状态/电平/slot 表）。
  @visibleForTesting
  AylaLiveKitVoiceBackend get debugLiveKit => _livekit;

  Future<AylaVoiceRoomLike> _createLiveKitRoom() {
    final AylaVoiceRoomFactory? override = debugLiveKitRoomFactory;
    if (override != null) return override();
    return AylaLiveKitRoomBuilder.build();
  }

  /// identity 纪律诊断（后端 token.identity 必须是裸 `str(user.pk)`）。
  void _logIdentityCheck(AylaVoiceLiveKitConfig? livekit, String? selfUserId) {
    final String? identity = livekit?.identity;
    if (identity == null || identity.isEmpty) return;
    if (selfUserId == null || selfUserId.isEmpty) return;
    if (identity == selfUserId) return;
    _events.onLog?.call(
      '[voice] identity_mismatch token.identity=$identity self=$selfUserId'
      ' —— 后端 media.livekit.identity 必须是裸 str(user.pk)',
    );
  }

  /// 脱敏：SDK 原始错误可能夹带 token（JWT 形如三段 base64url），日志不得泄露凭据。
  static String _redact(Object error) {
    // LiveKit 自带的 `WebSocketException` 没有覆写 toString ⇒ 只打出来是
    // 「Instance of 'WebSocketException'」，排查时等于没有信息。这里补上类型。
    final String text =
        '${error.runtimeType}: ${error.toString()}'.replaceAllMapped(
      RegExp(r'[A-Za-z0-9_-]{20,}.[A-Za-z0-9_-]{10,}.[A-Za-z0-9_-]{10,}'),
      (Match match) => '<redacted-jwt>',
    ).replaceAllMapped(
      RegExp(
        r'([?&](?:access_token|token|key|secret)=)[^&s]+',
        caseSensitive: false,
      ),
      (Match match) => '${match[1]}<redacted>',
    );
    return text.length > 200 ? text.substring(0, 200) : text;
  }
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

/// 登出 / 401 过期时的**语音媒体收尾**（幂等）。
///
/// 对应 web `stores/auth.ts` 的 `void voiceLiveKit.disconnect()`：登出必须断开语音
/// 媒体（房间 + 麦克风设备），否则下一位登录者会继承上一位的音频会话。
///
/// 与 [AylaVoiceMedia.disconnect] 的差别（有意）：
/// - `disconnect()` 是**房间级**语义（"离开当前频道、仍可复用实例"）；
/// - 本函数是**账号级**收尾：连单例一起放掉，下一次 [aylaVoiceMedia] 会新建干净实例。
///
/// **不阻塞调用方**：登出是同步路径。
void aylaVoiceMediaTeardown() {
  final AylaVoiceMedia? media = _voiceMedia;
  _voiceMedia = null;
  if (media == null) return;
  unawaited(media.dispose());
}
