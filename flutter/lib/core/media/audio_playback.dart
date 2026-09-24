/// 语音消息播放（web `MediaContent.tsx` 的 `VoiceMedia` + `utils/mediaPlayback.ts`）。
///
/// ## 事实源
///
/// | 本文件 | web |
/// |---|---|
/// | [AylaAudioClaims] | `utils/mediaPlayback.ts` `claimAudioPlayback` / `releaseAudioPlayback`（**全局同时只播一条**：新语音抢占时先 `stop()` 上一条） |
/// | [AylaAudioEngine] | `new Audio(objectURL)` + `loadedmetadata` / `timeupdate` / `ended` / `error` |
/// | [mediaContentUrl] + [aylaMediaAuthHeaders] | `apiRequestBlob(mediaContentUrl(id))`（web 先下载 blob 再播放；Flutter 侧把 Authorization 交给播放内核直接拉流，语义等价且省一次全量下载） |
///
/// ## 生命周期约定
/// 每个语音气泡持有自己的引擎实例（等价 web 每个 `VoiceMedia` 持有一个 `<audio>`），
/// 卸载时 `dispose()` + `release` 播放位（web 的 `URL.revokeObjectURL` 等价动作）。
library;

import 'dart:async';

import 'package:media_kit/media_kit.dart';

import '../net/dio_client.dart';
import '../../widgets/resource_image.dart' show mediaContentUrl;

/// 播放状态（web `VoiceMedia` 的 `playing` / `loadingAudio` / `audioError` /
/// `duration` / `current` 五态投影）。
class AylaAudioPlaybackState {
  const AylaAudioPlaybackState({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.playing = false,
    this.buffering = false,
    this.error,
  });

  final Duration position;
  final Duration duration;
  final bool playing;
  final bool buffering;

  /// 出错文案（null = 正常）。
  final String? error;

  AylaAudioPlaybackState copyWith({
    Duration? position,
    Duration? duration,
    bool? playing,
    bool? buffering,
    String? error,
  }) =>
      AylaAudioPlaybackState(
        position: position ?? this.position,
        duration: duration ?? this.duration,
        playing: playing ?? this.playing,
        buffering: buffering ?? this.buffering,
        error: error ?? this.error,
      );
}

/// 全局播放位（`utils/mediaPlayback.ts`）：
/// **全应用同时只有一条语音在播** —— 新播放先停旧播放。
abstract final class AylaAudioClaims {
  static void Function()? _current;

  /// 抢占播放位（先停掉当前持有者）。
  static void claim(void Function() stop) {
    final void Function()? current = _current;
    if (current != null && !identical(current, stop)) current();
    _current = stop;
  }

  /// 释放播放位（仅当自己仍是持有者时）。
  static void release(void Function() stop) {
    if (identical(_current, stop)) _current = null;
  }

  /// 测试隔离：清空持有者。
  static void reset() => _current = null;
}

/// 音频播放内核接口（平台实现见 [createAylaAudioEngine]；测试注入替身）。
abstract class AylaAudioEngine {
  void Function(AylaAudioPlaybackState state)? onStateChange;

  /// 打开媒体（不自动播放）。
  Future<void> open(String url, {Map<String, String>? headers});

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> dispose();
}

/// 创建音频引擎（Web/桌面/移动统一用 media_kit 的音频通道）。
AylaAudioEngine createAylaAudioEngine() => _MediaKitAudioEngine();

/// 内部媒体读取鉴权头（web `apiRequestBlob` 走 dio 拦截器；播放内核不经拦截器
/// ⇒ 必须显式带上同一个 Bearer）。
Map<String, String> aylaMediaAuthHeaders() {
  final String? token = DioClient.instance.accessToken;
  if (token == null || token.isEmpty) return const <String, String>{};
  return <String, String>{'Authorization': 'Bearer $token'};
}

/// 语音播放源（媒体 id → 内容 URL + 鉴权头）。
class AylaAudioSource {
  const AylaAudioSource({required this.url, this.headers = const <String, String>{}});

  /// 媒体内容 URL（`/api/v1/media/{id}/content`）。
  factory AylaAudioSource.media(String mediaId) => AylaAudioSource(
        url: mediaContentUrl(mediaId),
        headers: aylaMediaAuthHeaders(),
      );

  final String url;
  final Map<String, String> headers;
}

/// media_kit 实现（音频不需要 VideoController）。
class _MediaKitAudioEngine implements AylaAudioEngine {
  @override
  void Function(AylaAudioPlaybackState state)? onStateChange;

  Player? _player;
  final List<StreamSubscription<dynamic>> _subs = <StreamSubscription<dynamic>>[];
  AylaAudioPlaybackState _state = const AylaAudioPlaybackState();
  bool _initialized = false;

  void _emit(AylaAudioPlaybackState next) {
    _state = next;
    onStateChange?.call(next);
  }

  @override
  Future<void> open(String url, {Map<String, String>? headers}) async {
    if (!_initialized) {
      MediaKit.ensureInitialized(); // 幂等
      _initialized = true;
    }
    final Player player = Player();
    _player = player;
    _subs.add(player.stream.position.listen(
      (Duration p) => _emit(_state.copyWith(position: p)),
    ));
    _subs.add(player.stream.duration.listen(
      (Duration d) => _emit(_state.copyWith(duration: d)),
    ));
    _subs.add(player.stream.playing.listen(
      (bool v) => _emit(_state.copyWith(playing: v)),
    ));
    _subs.add(player.stream.buffering.listen(
      (bool v) => _emit(_state.copyWith(buffering: v)),
    ));
    _subs.add(player.stream.error.listen(
      (String e) => _emit(_state.copyWith(error: e)),
    ));
    await player.setVolume(100);
    await player.open(
      Media(url, httpHeaders: headers == null || headers.isEmpty ? null : headers),
      play: false,
    );
  }

  @override
  Future<void> play() async => _player?.play();

  @override
  Future<void> pause() async => _player?.pause();

  @override
  Future<void> seek(Duration position) async {
    final Player? player = _player;
    if (player == null) return;
    await player.seek(position);
    _emit(_state.copyWith(position: position));
  }

  @override
  Future<void> dispose() async {
    for (final StreamSubscription<dynamic> sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    await _player?.dispose();
    _player = null;
  }
}
