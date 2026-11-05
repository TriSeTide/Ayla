/// Android APK 安装器（平台通道）—— Flutter 侧没有可用的公开 APK 安装插件，
/// 用最小的 MethodChannel 调系统 `Intent.ACTION_VIEW`（FileProvider 暴露应用私有文件）。
///
/// 为什么必须走原生：
/// - `url_launcher` 的 `file://` 在 Android 7+ 会抛 `FileUriExposedException`
///   （StrictMode），必须用 `FileProvider.getUriForFile` 生成 `content://`；
/// - 系统安装器还需要 `FLAG_GRANT_READ_URI_PERMISSION`；
/// - 以上两点只能在 Kotlin 侧完成。
///
/// 约定：通道名 `com.ayla.ayla_flutter/update`，方法 `installApk`（参数 `{path}`），
/// 另有 `canInstallPackages` / `openInstallPermissionSettings` 两个辅助方法。
///
/// ## 2026-11-02 事故与改动
/// APK 落点从「系统临时目录」（cacheDir）改到「数据根/updates」
/// （Android 上 = `getFilesDir()/updates`）后，Kotlin 侧仍只校验 cacheDir 且
/// `file_paths.xml` 只声明了 `<cache-path>` ⇒ **合法 APK 被判非法** ⇒ 静默退化
/// 「打开浏览器下载页」——用户看到的就是「明明下载好了，点安装却跳浏览器」。
///
/// ## 2026-11-05：权限缺失必须**可引导**，不能归成一团「可能…或…」
/// 旧实现只回 Boolean ⇒ 一切失败都被归一成「可能是安装权限被关闭或包已损坏」，
/// 用户**没有任何跳设置的入口**（同仓 `SYSTEM_ALERT_WINDOW` 是有引导弹窗的，
/// 见 `layout/app_shell.dart` 的 `_overlayGuideOpen`）。现在原生返回
/// `{launched, reason, permissionRequired}`，本文件把 `permissionRequired` 单独建模，
/// 由调用方弹「去设置」引导（`AylaUpdateInstallPermissionGuide`）。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

/// 拉起 APK 安装器的结果。
class AylaApkInstallOutcome {
  const AylaApkInstallOutcome({
    required this.launched,
    this.reason,
    this.permissionRequired = false,
  });

  /// 系统安装器已拉起。
  final bool launched;

  /// 未拉起时的原因（可直接展示给用户；null = 已拉起或非 Android）。
  final String? reason;

  /// 失败原因是**缺「安装未知应用」权限**（调用方应弹「去设置」引导）。
  final bool permissionRequired;

  static const AylaApkInstallOutcome ok = AylaApkInstallOutcome(launched: true);

  static const AylaApkInstallOutcome notAndroid =
      AylaApkInstallOutcome(launched: false);

  @override
  String toString() => launched
      ? 'AylaApkInstallOutcome(launched)'
      : 'AylaApkInstallOutcome(failed: $reason, permissionRequired: $permissionRequired)';
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
      final Object? raw = await channel.invokeMethod<Object?>(
        'installApk',
        <String, Object?>{'path': path},
      );
      return _outcomeOf(raw);
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

  /// 是否已授予「安装未知应用」权限（非 Android / 旧系统 ⇒ true）。
  Future<bool> canInstallPackages() async {
    if (!Platform.isAndroid) return true;
    try {
      return await const MethodChannel(channelName)
              .invokeMethod<bool>('canInstallPackages') ??
          true;
    } on MissingPluginException {
      // 旧构建没有这个方法：按「未知 ⇒ 不阻断」处理（真失败时 installApk 会报）。
      return true;
    } catch (error) {
      debugPrint('[AylaUpdate] canInstallPackages 失败（按可安装处理）：$error');
      return true;
    }
  }

  /// 跳「安装未知应用」授权页（本应用）。返回是否成功打开。
  Future<bool> openInstallPermissionSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await const MethodChannel(channelName)
              .invokeMethod<bool>('openInstallPermissionSettings') ??
          false;
    } on MissingPluginException {
      return false;
    } catch (error) {
      debugPrint('[AylaUpdate] openInstallPermissionSettings 失败：$error');
      return false;
    }
  }

  /// 解析原生回执：新构建回 `{launched, reason, permissionRequired}`，
  /// 旧构建回 `true/false` —— 两种形态都接受（向后兼容升级用户）。
  AylaApkInstallOutcome _outcomeOf(Object? raw) {
    if (raw is bool) {
      if (raw) return AylaApkInstallOutcome.ok;
      return const AylaApkInstallOutcome(
        launched: false,
        reason: '系统没有接受这个安装包，请重试或手动安装',
      );
    }
    if (raw is Map) {
      final bool launched = raw['launched'] == true;
      if (launched) return AylaApkInstallOutcome.ok;
      final Object? reason = raw['reason'];
      return AylaApkInstallOutcome(
        launched: false,
        reason: reason is String && reason.trim().isNotEmpty
            ? reason.trim()
            : '系统没有接受这个安装包，请重试或手动安装',
        permissionRequired: raw['permissionRequired'] == true,
      );
    }
    return const AylaApkInstallOutcome(
      launched: false,
      reason: '安装器返回了无法识别的结果',
    );
  }
}
