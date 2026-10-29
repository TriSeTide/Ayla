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
/// ## 播放内核按平台分派（2026-10 用户实报「手机端无法播放语音」的修复）
///
/// | 平台 | 内核 | 理由 |
/// |---|---|---|
/// | Windows / macOS / Linux | [_MediaKitAudioEngine]（media_kit / libmpv） | 现状可用，**不要动** |
/// | Android / iOS | [_JustAudioEngine]（just_audio → ExoPlayer / AVPlayer） | `pubspec.yaml` 只声明了 `media_kit_libs_windows_video`，移动端**没有 libmpv** ⇒ media_kit 的 `player.open()` 必然失败；just_audio 底层是系统原生播放器，原生支持 m4a/AAC 与 HTTP Range 流式 |
///
/// 分派判定是纯函数 [aylaAudioEngineKind]（读 `defaultTargetPlatform`，单测用
/// `debugDefaultTargetPlatformOverride` 覆盖），[createAylaAudioEngine] 只做
/// 「按判定选实现」；两者都不做初始化，可被纯 Dart 单测直接断言。
///
/// ## 生命周期约定
/// 每个语音气泡持有自己的引擎实例（等价 web 每个 `VoiceMedia` 持有一个 `<audio>`），
/// 卸载时 `dispose()` + `release` 播放位（web 的 `URL.revokeObjectURL` 等价动作）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:media_kit/media_kit.dart';

import '../net/dio_client.dart';
import '../../widgets/base/resource_image.dart' show mediaContentUrl;

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

/// 播放内核种类（[aylaAudioEngineKind] 的选择结果；单测可直接断言）。
enum AylaAudioEngineKind {
  /// media_kit（libmpv）：Windows / macOS / Linux。
  mediaKit,

  /// just_audio（ExoPlayer / AVPlayer）：Android / iOS。
  justAudio,
}

/// 当前平台该用哪个内核。
///
/// **刻意不用 `dart:io` 的 `Platform.isAndroid`**：它在 `flutter test` 里恒为宿主
/// 平台（本机 Windows），平台分派就无法在纯 Dart 单测里锁死。
/// 这里读 `defaultTargetPlatform`，单测用 `debugDefaultTargetPlatformOverride` 覆盖。
///
/// Web 端本工程不打包（pubspec 只面向 Windows/Android/iOS），保守走 mediaKit。
AylaAudioEngineKind aylaAudioEngineKind() {
  if (kIsWeb) return AylaAudioEngineKind.mediaKit;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => AylaAudioEngineKind.justAudio,
    _ => AylaAudioEngineKind.mediaKit,
  };
}

/// 创建音频引擎（按平台分派，见文件头表格）。
///
/// - Android / iOS → [_JustAudioEngine]；
/// - Windows / macOS / Linux → [_MediaKitAudioEngine]（现状可用，保持不动）。
///
/// 构造函数本身不做任何初始化（内核在 [AylaAudioEngine.open] 时才创建），
/// 因此单测可以直接调用本函数断言分派结果。
AylaAudioEngine createAylaAudioEngine() => switch (aylaAudioEngineKind()) {
      AylaAudioEngineKind.justAudio => _JustAudioEngine(),
      AylaAudioEngineKind.mediaKit => _MediaKitAudioEngine(),
    };

/// 媒体源是否「本地文件」而不是网络 URL。
///
/// 命中漫游缓存时调用方给的是**裸绝对路径**（`AylaMediaCache.lookup` 的
/// `File.path`，没有 `file:` scheme），而只有 `http`/`https` 才是需要
/// `Authorization` 头的网络源。
///
/// 口径：白名单判网络（http/https），其余一律本地 —— 含 `file:`、
/// `content:`、以及被 `Uri` 解析成单字母 scheme 的 Windows 盘符路径
/// （`E:\media\x.m4a` → scheme `e`）。
bool aylaIsLocalMediaPath(String source) {
  final Uri? uri = Uri.tryParse(source);
  if (uri == null || !uri.hasScheme) return true;
  final String scheme = uri.scheme.toLowerCase();
  return !(scheme == 'http' || scheme == 'https');
}

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

/// just_audio 实现（**Android / iOS**）。
///
/// ## 状态映射（严格对齐 media_kit 的语义）
///
/// | just_audio | [AylaAudioPlaybackState] |
/// |---|---|
/// | `positionStream` | `position` |
/// | `durationStream`（null/零值忽略，不覆盖 descriptor 时长） | `duration` |
/// | `playerStateStream.playing` | `playing` |
/// | `processingState == loading / buffering` | `buffering` |
/// | `processingState == completed` | `playing=false` + `position=Duration.zero`（= media_kit 的 ended：气泡回到「从头播」） |
/// | `errorStream` / `open()` 抛错 | `error` |
///
/// ## 鉴权头
/// 语音走 `/api/v1/media/{id}/content`，必须带 `Authorization: Bearer`。
/// `AudioSource.uri(uri, headers:)` 把 headers 交给原生内核，两条路径不同：
/// - **Android**：just_audio 在应用内起一个**本机回环代理**（`127.0.0.1` 的明文
///   HTTP）转发带头请求 ⇒ 需要 `android:usesCleartextTraffic="true"`
///   （本工程 `AndroidManifest.xml:17` 已有）；
/// - **iOS**：headers 走 `AVURLAssetHTTPHeaderFieldsKey` 直接交给 AVPlayer，
///   没有代理、不涉及明文 HTTP。
class _JustAudioEngine implements AylaAudioEngine {
  @override
  void Function(AylaAudioPlaybackState state)? onStateChange;

  ja.AudioPlayer? _player;
  final List<StreamSubscription<dynamic>> _subs = <StreamSubscription<dynamic>>[];
  AylaAudioPlaybackState _state = const AylaAudioPlaybackState();

  /// 已播完（`processingState.completed`）：
  /// 期间忽略 `positionStream` 残余位置，避免把归零的进度又推回时长末尾。
  bool _ended = false;
  bool _disposed = false;

  void _emit(AylaAudioPlaybackState next) {
    if (_disposed) return;
    _state = next;
    onStateChange?.call(next);
  }

  @override
  Future<void> open(String url, {Map<String, String>? headers}) async {
    await _teardownPlayer();
    _ended = false;
    final ja.AudioPlayer player = ja.AudioPlayer();
    _player = player;
    _bind(player);

    final Uri? uri = Uri.tryParse(url);
    final bool hasFileScheme =
        uri != null && uri.scheme.toLowerCase() == 'file';
    try {
      if (aylaIsLocalMediaPath(url)) {
        // 本地文件（漫游缓存命中）：不带 headers，直接文件源。
        await player.setFilePath(hasFileScheme ? uri.toFilePath() : url);
      } else {
        // 网络源：headers 透传给原生内核（见类注释的「鉴权头」一节）。
        await player.setAudioSource(
          ja.AudioSource.uri(
            uri!,
            headers: headers == null || headers.isEmpty ? null : headers,
          ),
        );
      }
    } catch (e) {
      // 加载失败：抛给调用方（`_VoiceMediaState._ensureEngine` 的 catch 分支
      // 负责渲染「语音播放失败 + 重试」），同时清掉半初始化的播放器。
      debugPrint('[audio] just_audio 打开失败（$url）：$e');
      await _teardownPlayer();
      rethrow;
    }
  }

  void _bind(ja.AudioPlayer player) {
    _subs.add(player.positionStream.listen((Duration p) {
      if (_ended) return; // 播完后的残余位置不覆盖已归零的进度
      _emit(_state.copyWith(position: p));
    }));
    _subs.add(player.durationStream.listen((Duration? d) {
      // null = 未知（刚换源 / 流式未就绪）⇒ 不覆盖已有时长。
      if (d == null || d <= Duration.zero) return;
      _emit(_state.copyWith(duration: d));
    }));
    _subs.add(player.playerStateStream.listen(_onPlayerState));
    _subs.add(player.errorStream.listen((ja.PlayerException e) {
      debugPrint('[audio] just_audio 播放错误：$e');
      _emit(_state.copyWith(error: e.message ?? e.toString(), buffering: false));
    }));
  }

  void _onPlayerState(ja.PlayerState s) {
    final ja.ProcessingState ps = s.processingState;
    if (ps == ja.ProcessingState.completed) {
      if (_ended) return; // pause() 引起的重复 completed 事件不再上报
      _ended = true;
      // media_kit 的 ended 语义：playing=false 且位置归零（气泡回到「从头播」）。
      _emit(
        _state.copyWith(
          playing: false,
          buffering: false,
          position: Duration.zero,
        ),
      );
      // 原生侧仍停在 completed（just_audio 的 playing 会保持 true 以便 seek 回续播）；
      // 显式 pause 让 positionStream 停摆，避免空转。
      unawaited(_player?.pause() ?? Future<void>.value());
      return;
    }
    _ended = false;
    _emit(
      _state.copyWith(
        playing: s.playing,
        buffering: ps == ja.ProcessingState.loading ||
            ps == ja.ProcessingState.buffering,
      ),
    );
  }

  @override
  Future<void> play() async {
    final ja.AudioPlayer? player = _player;
    if (player == null) return;
    if (_ended) {
      // 播完后再点播放：从头开始（等价 media_kit 的 ended 后 play 重播）。
      _ended = false;
      await player.seek(Duration.zero);
    }
    await player.play();
  }

  @override
  Future<void> pause() async {
    // 播完后 just_audio 的 playing 仍为 true，pause() 可安全调用（内部幂等）。
    await _player?.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    final ja.AudioPlayer? player = _player;
    if (player == null) return;
    _ended = false;
    await player.seek(position);
    _emit(_state.copyWith(position: position));
  }

  Future<void> _teardownPlayer() async {
    for (final StreamSubscription<dynamic> sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    final ja.AudioPlayer? player = _player;
    _player = null;
    await player?.dispose();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _teardownPlayer();
  }
}

/// media_kit 实现（音频不需要 VideoController）。**桌面（Windows/macOS/Linux）专用**。
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
