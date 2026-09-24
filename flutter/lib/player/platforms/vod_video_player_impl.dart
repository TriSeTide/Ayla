/// 点播平台实现：video_player（Android ExoPlayer / iOS AVPlayer）。
///
/// 状态经 `controller.value` 投影到 [VodPlaybackState]；`preload="metadata"` 的
/// 内联首帧语义 = 初始化后 `play()` 不调用（初始化完成即渲染首帧）。
library;

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import '../vod_player.dart';

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
    final VideoPlayerController c = VideoPlayerController.networkUrl(
      Uri.parse(url),
    );
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
