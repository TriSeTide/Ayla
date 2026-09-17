/// HLS 平台工厂。
///
/// - Android/iOS：video_player（见 video_player_impl.dart）；
/// - Windows：media_kit（mpv 内核，见 media_kit_impl.dart；运行库
///   media_kit_libs_windows_video 已在 CMake 构建时校验下载）。
library;

import 'dart:io' show Platform;

import '../hls_player.dart';
import 'media_kit_impl.dart';
import 'video_player_impl.dart';

/// 平台工厂。
HlsPlatformPlayer createHlsPlatformPlayer() {
  if (Platform.isWindows) {
    return MediaKitHls();
  }
  return VideoPlayerHls();
}
