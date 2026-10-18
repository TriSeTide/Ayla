/// HLS 平台实现：media_kit（Windows/mpv 内核）。
///
/// - mpv 运行库经 media_kit_libs_windows_video 打包（CMake 构建时校验
///   build/windows/x64/mpv-dev-*.7z 的 MD5，匹配则跳过下载）；
/// - 事件：player.stream.playing/buffering/error/position 映射为
///   onStateChange/onStall/onResume/onFatal 信号；
/// - 视图：VideoController + Video widget（media_kit_video）。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../hls_player.dart';

class MediaKitHls implements HlsPlatformPlayer {
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

  Player? _player;
  VideoController? _videoController;
  final List<StreamSubscription> _subs = [];
  bool _initialized = false;

  @override
  Future<void> attach(String url) async {
    if (!_initialized) {
      MediaKit.ensureInitialized();
      _initialized = true;
    }
    final p = Player();
    _player = p;
    _videoController = VideoController(p);

    _subs.add(p.stream.playing.listen((v) {
      onStateChange?.call(v ? HlsState.playing : HlsState.buffering);
      if (v) onResume?.call();
    }));
    _subs.add(p.stream.buffering.listen((v) {
      if (v) {
        onStall?.call();
        onStateChange?.call(HlsState.buffering);
      }
    }));
    _subs.add(p.stream.error.listen((e) {
      onFatal?.call(e);
    }));
    // 位置前进 = 真的出画面（mpv 在「连上但没数据」时 playing 也为 true，
    // 不能只靠 playing 判定 —— 见 hls_player.dart 的 kMaxAutoRebuilds 注释）。
    _subs.add(p.stream.position.listen((pos) => onPosition?.call(pos)));

    onStateChange?.call(HlsState.loading);
    await p.open(Media(url), play: true);
  }

  @override
  Future<void> play() async {
    await _player?.play();
  }

  @override
  Future<bool> seekToLiveEdge() async {
    final p = _player;
    if (p == null) return false;
    try {
      final dur = p.state.duration;
      if (dur > Duration.zero) {
        await p.seek(dur);
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget? buildView() {
    final vc = _videoController;
    if (vc == null) return null;
    // `controls: NoVideoControls` **必须显式传**：media_kit 默认挂 AdaptiveVideoControls，
    // 会在画面之上叠一层自带控制条 + 缓冲时的大号白色进度圈（用户截图里那个白色 U 形圈），
    // 与 Ayla 自己的悬浮控件重复。web 的 <video> 不带 controls，这里同样只交出画面。
    return Video(controller: vc, controls: NoVideoControls);
  }

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _player?.dispose();
    _player = null;
    _videoController = null;
  }
}
