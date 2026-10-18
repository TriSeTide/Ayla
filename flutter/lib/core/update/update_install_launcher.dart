/// Android APK 安装器（平台通道）—— Flutter 侧没有可用的公开 APK 安装插件，
/// 用最小的 MethodChannel 调系统 `Intent.ACTION_VIEW`（FileProvider 暴露缓存文件）。
///
/// 为什么必须走原生：
/// - `url_launcher` 的 `file://` 在 Android 7+ 会抛 `FileUriExposedException`
///   （StrictMode），必须用 `FileProvider.getUriForFile` 生成 `content://`；
/// - 系统安装器还需要 `FLAG_GRANT_READ_URI_PERMISSION`；
/// - 以上两点只能在 Kotlin 侧完成。
///
/// 约定：通道名 `com.ayla.ayla_flutter/update`，方法 `installApk`，参数 `{path}`。
/// 返回 `true` = 安装器已拉起；`false` = 当前构建没有原生实现（退化为打开下载页）；
/// 抛 `PlatformException` = 系统拒绝（调用方展示错误并保留 APK）。
library;

import 'dart:io';

import 'package:flutter/services.dart';

/// Android 安装器通道。
class AylaUpdateInstallLauncher {
  const AylaUpdateInstallLauncher();

  /// 通道名（必须与 MainActivity.kt 一致）。
  static const String channelName = 'com.ayla.ayla_flutter/update';

  /// 拉起系统 APK 安装器；非 Android 平台直接返回 false。
  Future<bool> installApk(String path) async {
    if (!Platform.isAndroid) return false;
    final MethodChannel channel = const MethodChannel(channelName);
    try {
      final Object? result = await channel.invokeMethod<Object?>(
        'installApk',
        <String, Object?>{'path': path},
      );
      return result == true;
    } on MissingPluginException {
      // 老构建/未实现：明确退化，不把「没实现」伪装成「已安装」。
      return false;
    }
  }
}
