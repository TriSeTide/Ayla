/// 点播播放器平台工厂（与 [player/platforms/hls_platform.dart] 同一约定）。
///
/// - Windows：media_kit（mpv 内核，`MediaKit.ensureInitialized()` 幂等调用）；
/// - Android/iOS：video_player（ExoPlayer / AVPlayer）。
library;

import 'dart:io' show Platform;

import '../vod_player.dart';
import 'vod_media_kit_impl.dart';
import 'vod_video_player_impl.dart';

/// 按平台创建点播播放器。
VodPlatformPlayer createVodPlatformPlayer() {
  if (Platform.isWindows) {
    return MediaKitVod();
  }
  return VideoPlayerVod();
}
