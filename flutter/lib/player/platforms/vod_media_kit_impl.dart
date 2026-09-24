/// 点播平台实现：media_kit（Windows，mpv 内核）。
///
/// 与 `media_kit_impl.dart`（HLS 直播）同源：状态经 `player.stream.*` 投影到
/// [VodPlaybackState]；画面用 `Video(controls: NoVideoControls)` —— 控制条由
/// 库内 `_VodControls` 自绘（见 `player/vod_player.dart` 文件头的有意偏离说明）。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../vod_player.dart';

class MediaKitVod implements VodPlatformPlayer {
  @override
  void Function(VodPlaybackState state)? onStateChange;

  Player? _player;
  VideoController? _controller;
  final List<StreamSubscription<dynamic>> _subs = <StreamSubscription<dynamic>>[];
  VodPlaybackState _state = const VodPlaybackState();
  bool _initialized = false;
  bool _viewReady = false;

  @override
  bool get hasView => _viewReady;

  void _emit(VodPlaybackState next) {
    _state = next;
    onStateChange?.call(next);
  }

  @override
  Future<void> attach(
    String url, {
    required bool autoPlay,
    required bool muted,
  }) async {
    if (!_initialized) {
      MediaKit.ensureInitialized(); // 幂等
      _initialized = true;
    }
    final Player player = Player();
    _player = player;
    _controller = VideoController(player);
    _viewReady = true;

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

    // 音量：内联首帧静音（web `muted`），查看器放开（web `controls` 时 muted=false）
    await player.setVolume(muted ? 0 : 100);
    await player.open(Media(url), play: autoPlay);
  }

  @override
  Future<void> play() async => _player?.play();

  @override
  Future<void> pause() async => _player?.pause();

  @override
  Future<void> seek(Duration position) async => _player?.seek(position);

  @override
  Widget? buildView() {
    final VideoController? controller = _controller;
    if (controller == null) return null;
    return Video(controller: controller, controls: NoVideoControls);
  }

  @override
  Future<void> dispose() async {
    _viewReady = false;
    for (final StreamSubscription<dynamic> sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    await _player?.dispose();
    _player = null;
    _controller = null;
  }
}
