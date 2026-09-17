/// HLS 平台实现：video_player（Android ExoPlayer / iOS AVPlayer）。
///
/// - 状态监听：value.isBuffering → stall 信号（自愈上游判定）；
///   value.hasError → fatal；position 前进 → resume 信号。
/// - live 贴边：play 前先 seekTo(duration)（等价 web 端 startLoad(-1) 从边缘起播）。
/// - 跳边：seekTo(duration) + play（等价 refreshToLiveEdge 的 seekable 末尾分支）。
library;

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import '../hls_player.dart';

class VideoPlayerHls implements HlsPlatformPlayer {
  @override
  void Function(HlsState state)? onStateChange;

  @override
  void Function()? onStall;

  @override
  void Function()? onResume;

  @override
  void Function(String detail)? onFatal;

  VideoPlayerController? _controller;
  bool _stalled = false;
  Duration _lastPosition = Duration.zero;

  @override
  Future<void> attach(String url) async {
    await _controller?.dispose();
    final c = VideoPlayerController.networkUrl(Uri.parse(url));
    _controller = c;
    c.addListener(_onTick);
    onStateChange?.call(HlsState.loading);
    try {
      await c.initialize();
    } catch (e) {
      onFatal?.call('initialize 失败: $e');
      rethrow;
    }
  }

  void _onTick() {
    final c = _controller;
    if (c == null) return;
    if (c.value.hasError) {
      onFatal?.call(c.value.errorDescription ?? '播放错误');
      return;
    }
    final buffering = c.value.isBuffering;
    final pos = c.value.position;
    if (buffering) {
      if (!_stalled) {
        _stalled = true;
        onStall?.call();
      }
    } else {
      if (_stalled) {
        _stalled = false;
        onResume?.call();
      }
      if (pos != _lastPosition) {
        _lastPosition = pos;
        onResume?.call();
      }
    }
    onStateChange?.call(buffering ? HlsState.buffering : HlsState.playing);
  }

  @override
  Future<void> play() async {
    final c = _controller;
    if (c == null) return;
    // live 贴边：先 seek 到末尾（等价 startLoad(-1)），再 play
    if (c.value.duration > Duration.zero) {
      await c.seekTo(c.value.duration);
    }
    await c.play();
  }

  @override
  Future<bool> seekToLiveEdge() async {
    final c = _controller;
    if (c == null) return false;
    try {
      final d = c.value.duration;
      if (d > Duration.zero) {
        await c.seekTo(d);
        await c.play();
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget? buildView() {
    final c = _controller;
    if (c == null) return null;
    return VideoPlayer(c);
  }

  @override
  Future<void> dispose() async {
    _stalled = false;
    await _controller?.dispose();
    _controller = null;
  }
}
