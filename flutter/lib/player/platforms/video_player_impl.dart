/// HLS 平台实现：video_player（Android ExoPlayer / iOS AVPlayer）。
///
/// - 状态监听：value.isBuffering → stall 信号（自愈上游判定）；
///   value.hasError → fatal；position 前进 → resume 信号。
/// - live 贴边：play 前先 seek 到 `duration - 1 分片`（开发文档 §3 R1，见下）。
/// - 跳边：同一条目标计算 + play（等价 refreshToLiveEdge 的 seekable 末尾分支）。
library;

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import '../hls_player.dart';
import '../live_edge.dart';

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

  /// live 起播贴边目标（开发文档 §3 R1）。
  ///
  /// video_player 的 Dart 侧**没有** seekable 范围的 API（ExoPlayer 的
  /// `seekableRanges` 没有暴露到插件）⇒ 只能退回 `duration - 1 分片`。
  /// `duration` 在直播里同样是**整个 playlist 的总长**，直接 seek 到它会落到末尾
  /// （旧实现 `seekTo(duration)` 的语义错误，需求 §3.3 R1）⇒ 必须回退 1 个分片，
  /// 且 `duration` 必须大于 [kLiveEdgeMinDuration]（短视频/VOD 不该被"贴边"倒回去）。
  Duration? _liveEdgeTarget() {
    final c = _controller;
    if (c == null) return null;
    return aylaLiveEdgeSeekTarget(duration: c.value.duration);
  }

  /// 设置静音（= web `video.muted`）。
  ///
  /// 落成 `setVolume(0.0 / 1.0)`：`video_player` 的 `setVolume` 就是 `<video>.volume`
  /// 的等价物（0.0–1.0 线性），与 web 的 `muted` 在听感上一致，且不引入第二条状态
  /// （`muted` 与 `volume` 在 ExoPlayer 内部是同一组音频参数）。
  ///
  /// 不抛异常：控制器已释放 / 未初始化时静音只是「没生效」，不能打断播放链路。
  @override
  Future<void> setMuted(bool muted) async {
    try {
      await _controller?.setVolume(muted ? 0.0 : 1.0);
    } catch (_) {
      // 实例已 dispose / 尚未 initialize ⇒ 忽略。
    }
  }

  @override
  Future<void> play() async {
    final c = _controller;
    if (c == null) return;
    // live 贴边：先 seek 到边缘（等价 web 端 startLoad(-1) 从边缘起播），再 play。
    final Duration? target = _liveEdgeTarget();
    if (target != null) {
      await c.seekTo(target);
    }
    await c.play();
  }

  /// 跳到直播边缘（开发文档 §3 R1）。
  ///
  /// 成功判据 = **seek 之后 `value.isBuffering == false`**（用户方案明确要求）：
  /// ExoPlayer 的 `seekTo` 只保证「seek 请求被接受」，不一定已经在目标位置出画面；
  /// 若目标落在还没下载的分片里，它会进入 buffering 并可能停留很久。
  /// 此时返回 false 让调用方走「重建」兜底（顺序固定：先 seek，失败才 rebuild），
  /// 比让用户对着转圈等下去更可靠。
  @override
  Future<bool> seekToLiveEdge() async {
    final c = _controller;
    if (c == null) return false;
    final Duration? target = _liveEdgeTarget();
    if (target == null) return false;
    try {
      await c.seekTo(target);
      await c.play();
      // 给播放器一帧时间更新 value（seekTo 之后 isBuffering 才是目标位置的判定）。
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final VideoPlayerController? current = _controller;
      if (current == null || !identical(current, c)) return false;
      return !c.value.isBuffering && !c.value.hasError;
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
