/// Android APK 安装器（平台通道）—— Flutter 侧没有可用的公开 APK 安装插件，
/// 用最小的 MethodChannel 调系统 `Intent.ACTION_VIEW`（FileProvider 暴露应用私有文件）。
///
/// 为什么必须走原生：
/// - `url_launcher` 的 `file://` 在 Android 7+ 会抛 `FileUriExposedException`
///   （StrictMode），必须用 `FileProvider.getUriForFile` 生成 `content://`；
/// - 系统安装器还需要 `FLAG_GRANT_READ_URI_PERMISSION`；
/// - 以上两点只能在 Kotlin 侧完成。
///
/// 约定：通道名 `com.ayla.ayla_flutter/update`，方法 `installApk`，参数 `{path}`。
/// 返回 `true` = 安装器已拉起；`false` = 系统/FileProvider 拒绝（退化为打开下载页）；
/// 抛 `PlatformException` = 通道本身出错。
///
/// ## 2026-11-02 事故与本次改动
/// APK 落点从「系统临时目录」（cacheDir）改到「数据根/updates」
/// （Android 上 = `getFilesDir()/updates`）后，Kotlin 侧仍只校验 cacheDir 且
/// `file_paths.xml` 只声明了 `<cache-path>` ⇒ **合法 APK 被判非法** ⇒ 静默退化
/// 「打开浏览器下载页」——用户看到的就是「明明下载好了，点安装却跳浏览器」。
///
/// 现在的契约：失败时返回**可展示的原因**（[AylaApkInstallOutcome.reason]），
/// 让调用方能提示用户，而不是默默把已下载好的包丢掉去开浏览器。
library;

import 'dart:io';

import 'package:flutter/services.dart';

/// 拉起 APK 安装器的结果。
class AylaApkInstallOutcome {
  const AylaApkInstallOutcome({
    required this.launched,
    this.reason,
  });

  /// 系统安装器已拉起。
  final bool launched;

  /// 未拉起时的原因（可直接展示给用户；null = 已拉起或非 Android）。
  final String? reason;

  static const AylaApkInstallOutcome ok =
      AylaApkInstallOutcome(launched: true);

  static const AylaApkInstallOutcome notAndroid =
      AylaApkInstallOutcome(launched: false);

  @override
  String toString() =>
      launched ? 'AylaApkInstallOutcome(launched)' : 'AylaApkInstallOutcome(failed: $reason)';
}

/// Android 安装器通道。
class AylaUpdateInstallLauncher {
  const AylaUpdateInstallLauncher();

  /// 通道名（必须与 MainActivity.kt 一致）。
  static const String channelName = 'com.ayla.ayla_flutter/update';

  /// 拉起系统 APK 安装器；非 Android 平台返回 [AylaApkInstallOutcome.notAndroid]。
  Future<AylaApkInstallOutcome> installApk(String path) async {
    if (!Platform.isAndroid) return AylaApkInstallOutcome.notAndroid;

    // 先自检文件是否真的在（这一步失败与系统无关，提示必须准确）。
    final File file = File(path);
    if (!await file.exists()) {
      return const AylaApkInstallOutcome(
        launched: false,
        reason: '安装包文件已不存在（可能被系统清理），请重新下载',
      );
    }

    final MethodChannel channel = const MethodChannel(channelName);
    try {
      final Object? result = await channel.invokeMethod<Object?>(
        'installApk',
        <String, Object?>{'path': path},
      );
      if (result == true) return AylaApkInstallOutcome.ok;
      return const AylaApkInstallOutcome(
        launched: false,
        reason: '系统没有接受这个安装包（可能是安装权限被关闭或包已损坏）。'
            '请在系统设置里允许「安装未知应用」，或重新下载后再试。',
      );
    } on MissingPluginException {
      // 老构建 / 未实现：明确退化，不把「没实现」伪装成「已安装」。
      return const AylaApkInstallOutcome(
        launched: false,
        reason: '当前安装包不含 APK 安装器（旧版本），请手动安装',
      );
    } on PlatformException catch (error) {
      return AylaApkInstallOutcome(
        launched: false,
        reason: '拉起安装器失败：${error.message ?? error.code}',
      );
    }
  }
}
