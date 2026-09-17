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
    return Video(controller: vc);
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
