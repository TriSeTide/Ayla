/// 点播平台实现：video_player（Android ExoPlayer / iOS AVPlayer）。
///
/// 状态经 `controller.value` 投影到 [VodPlaybackState]；`preload="metadata"` 的
/// 内联首帧语义 = 初始化后 `play()` 不调用（初始化完成即渲染首帧）。
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import '../../core/media/audio_playback.dart' show aylaIsLocalMediaPath;
import '../vod_player.dart';

/// [src] 是否是本地文件路径（而不是 http/https 网络地址）。
///
/// 与语音播放共用同一套判定（[aylaIsLocalMediaPath]），避免两处口径漂移：
/// 语音侧缓存命中给的是 `File.path` 裸绝对路径，视频侧同理。
bool aylaIsLocalVideoPath(String src) => aylaIsLocalMediaPath(src);

/// 把 [src] 归一成 `File` 能接受的绝对路径。
///
/// - `file:///E:/x.mp4` → `E:\x.mp4`（`Uri.toFilePath` 会做平台分隔符转换）；
/// - 其余（裸 Windows 路径 `E:\x.mp4` / POSIX 路径）原样返回。
String aylaLocalVideoFilePath(String src) {
  final Uri? uri = Uri.tryParse(src);
  if (uri != null && uri.scheme.toLowerCase() == 'file') {
    return uri.toFilePath();
  }
  return src;
}

/// 按 [src] 构造点播控制器：本地文件 → `file` 源，其余 → `networkUrl`。
///
/// 抽成顶层函数是**测试注入点**：控制器构造本身不碰原生插件，
/// 单测可直接断言 `controller.dataSourceType`（`DataSourceType.file/network`），
/// 不需要 mock video_player 的平台通道。
@visibleForTesting
VideoPlayerController aylaVodVideoPlayerController(String src) =>
    aylaIsLocalVideoPath(src)
        ? VideoPlayerController.file(File(aylaLocalVideoFilePath(src)))
        : VideoPlayerController.networkUrl(Uri.parse(src));

class VideoPlayerVod implements VodPlatformPlayer {
  @override
  void Function(VodPlaybackState state)? onStateChange;

  VideoPlayerController? _controller;
  VodPlaybackState _state = const VodPlaybackState();

  @override
  bool get hasView => _controller?.value.isInitialized ?? false;

  void _emit(VodPlaybackState next) {
    _state = next;
    onStateChange?.call(next);
  }

  void _onTick() {
    final VideoPlayerController? c = _controller;
    if (c == null) return;
    final VideoPlayerValue v = c.value;
    if (v.hasError) {
      _emit(_state.copyWith(error: v.errorDescription ?? '播放错误'));
      return;
    }
    _emit(
      _state.copyWith(
        position: v.position,
        duration: v.duration,
        playing: v.isPlaying,
        buffering: v.isBuffering,
      ),
    );
  }

  @override
  Future<void> attach(
    String url, {
    required bool autoPlay,
    required bool muted,
  }) async {
    await _controller?.dispose();
    // 本地文件（漫游缓存命中 / 本地录制）必须走 file 源：
    // Android ExoPlayer 与 iOS AVPlayer 都不接受裸绝对路径当网络 URL
    // （`E:\x.mp4` / `/data/.../x.mp4` 都不是合法 URL），会直接初始化失败。
    // 判定口径与 `core/media/audio_playback.dart` 的 `aylaIsLocalMediaPath`
    // 一致：只有 http/https 才算网络源。
    final VideoPlayerController c = aylaVodVideoPlayerController(url);
    _controller = c;
    c.addListener(_onTick);
    await c.initialize();
    await c.setVolume(muted ? 0 : 1);
    _onTick();
    if (autoPlay) await c.play();
  }

  @override
  Future<void> play() async => _controller?.play();

  @override
  Future<void> pause() async => _controller?.pause();

  @override
  Future<void> seek(Duration position) async => _controller?.seekTo(position);

  @override
  Widget? buildView() {
    final VideoPlayerController? c = _controller;
    if (c == null || !c.value.isInitialized) return null;
    return VideoPlayer(c);
  }

  @override
  Future<void> dispose() async {
    final VideoPlayerController? c = _controller;
    _controller = null;
    if (c != null) {
      c.removeListener(_onTick);
      await c.dispose();
    }
  }
}
