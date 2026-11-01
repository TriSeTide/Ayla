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

class VideoPlayerHls implements HlsPlatformPlayer, HlsVideoMetrics {
  @override
  void Function(HlsState state)? onStateChange;

  @override
  void Function()? onStall;

  @override
  void Function()? onResume;

  @override
  void Function(String detail)? onFatal;

  @override
  void Function(Duration position)? onPosition;

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
        // 位置前进 = 真的出画面（ExoPlayer/AVPlayer 同样会在缓冲时保持 playing）。
        onPosition?.call(pos);
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

  /// 画面宽高比（= web `<video>.videoWidth / .videoHeight`）。
  ///
  /// ## 为什么不用 `value.aspectRatio`
  /// ① 它**不可空**：未初始化时返回 `1.0` —— 那会让调用方把「不知道比例」
  ///    当成「正方形画面」，在全屏里收出一个正方形黑块（本文件的语义是 null = 不知道）；
  /// ② 它**不含旋转**：而 `VideoPlayer` widget 自己会套
  ///    `RotatedBox(quarterTurns: rotationCorrection ~/ 90)`
  ///    （`video_player/lib/video_player.dart:1207–1229`）⇒ 渲染出来的盒子在
  ///    90°/270° 时是 `h×w`。本 getter 描述的必须是**渲染后**的比例，
  ///    否则等比盒与实际画面差 90°（直播流基本恒为 0，但不能靠这个假设）。
  @override
  double? get videoAspectRatio {
    final VideoPlayerValue? v = _controller?.value;
    if (v == null || !v.isInitialized) return null;
    final Size size = v.size;
    if (size.width <= 0 || size.height <= 0) return null;
    final bool swapped = v.rotationCorrection % 180 == 90;
    final double ratio =
        swapped ? size.height / size.width : size.width / size.height;
    return ratio.isFinite && ratio > 0 ? ratio : null;
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
