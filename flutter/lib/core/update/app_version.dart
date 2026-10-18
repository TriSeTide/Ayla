/// 应用版本（`package_info_plus` 的薄包装 + 可注入测试替身）。
///
/// 更新检查的「当前版本」必须来自**真实安装包**，不能由 pubspec 常量猜：
/// - Android：`versionName` / `versionCode`（Gradle `flutter.versionName/Code`）
/// - iOS：`CFBundleShortVersionString` / `CFBundleVersion`
/// - Windows：exe 的 FileVersion（由 `Runner.rc` 的 `FLUTTER_VERSION*` 写入）
///
/// Windows 的 FileVersion 由构建命令 `--build-name=a.b.c --build-number=n` 注入；
/// `flutter build windows` 会把 `1.0.0+1` 写成 `1.0.0.1`（变成四段）。因此这里按
/// 「前三段 version、最后一段 build」解析，同时对四段/两段/一段都给出确定结果。
library;

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 版本快照。
@immutable
class AylaAppVersion {
  const AylaAppVersion({
    required this.version,
    required this.build,
    this.packageName = '',
    this.appName = '',
  });

  /// 语义化版本（`1.2.3`；缺失段补 0）。
  final String version;

  /// 构建号（非负整数；无法解析时为 0）。
  final int build;

  /// 包名（诊断用）。
  final String packageName;

  /// 应用名（诊断用）。
  final String appName;

  /// `1.2.3+4` 的可读形式。
  String get display => build > 0 ? '$version+$build' : version;

  /// 用于 `/updates/check/` 查询的两个字段。
  Map<String, String> get query => <String, String>{
    'version': version,
    'build': '$build',
  };

  @override
  String toString() => 'AylaAppVersion($display)';
}

/// 从平台版本字符串解析（纯函数，定向测试的入口）。
///
/// 规则（确定性、无静默假设）：
/// 1. 去掉首尾空白；空串 ⇒ version=`0.0.0`、build=0；
/// 2. 含 `+` 时以 `+` 后的部分作为 build（Flutter 的 `--build-name=--build-number` 形态）；
/// 3. 否则按点分段：
///    - 4 段 ⇒ 前三段 version、第四段 build（Windows exe 的 `1.0.0.1`）；
///    - 3 段及以下 ⇒ 全部为 version、build 用传入的 buildNumber；
///    - 超过 4 段 ⇒ 前四段之外的部分忽略（版本号本身不合法，但不应让应用无法启动）。
AylaAppVersion parseAppVersion({
  required String version,
  String? buildNumber,
  String packageName = '',
  String appName = '',
}) {
  final String rawVersion = version.trim();
  final String rawBuild = (buildNumber ?? '').trim();
  if (rawVersion.isEmpty && rawBuild.isEmpty) {
    return AylaAppVersion(
      version: '0.0.0',
      build: 0,
      packageName: packageName,
      appName: appName,
    );
  }
  String versionPart = rawVersion;
  int build = _parseBuild(rawBuild);
  final int plus = rawVersion.indexOf('+');
  List<String> segments;
  if (plus >= 0) {
    versionPart = rawVersion.substring(0, plus);
    final int plusBuild = _parseBuild(rawVersion.substring(plus + 1));
    if (plusBuild > 0) build = plusBuild;
    segments = versionPart.split('.');
  } else {
    segments = rawVersion.split('.');
    if (segments.length >= 4) {
      final int exeBuild = _parseBuild(segments[3]);
      if (exeBuild > 0) build = exeBuild;
      segments = segments.sublist(0, 3);
    }
  }
  final List<String> normalized = <String>[
    for (int i = 0; i < 3; i++)
      _normalizeSegment(i < segments.length ? segments[i] : ''),
  ];
  final String normalizedVersion = normalized.join('.');
  return AylaAppVersion(
    version: normalizedVersion.isEmpty ? '0.0.0' : normalizedVersion,
    build: build,
    packageName: packageName,
    appName: appName,
  );
}

String _normalizeSegment(String segment) {
  final String trimmed = segment.trim();
  if (trimmed.isEmpty) return '0';
  // FileVersion 允许前导零/非数字尾巴；只保留数字前缀，其余按 0（不伪造语义）
  final RegExpMatch? match = RegExp(r'^\d+').firstMatch(trimmed);
  if (match == null) return '0';
  return '${int.tryParse(match.group(0)!) ?? 0}';
}

int _parseBuild(String raw) {
  final String trimmed = raw.trim();
  if (trimmed.isEmpty) return 0;
  final RegExpMatch? match = RegExp(r'^\d+').firstMatch(trimmed);
  if (match == null) return 0;
  return int.tryParse(match.group(0)!) ?? 0;
}

/// 读取真实安装包版本。
///
/// - 失败（平台插件不可用 / 测试宿主无 PackageInfo）⇒ 返回 `0.0.0+0` 并 `debugPrint`；
///   更新检查仍会执行，但服务端会把它当成极旧版本（用户至少能看到「有更新」）。
///   这比让整个应用起不来更符合「更新不是启动硬依赖」。
Future<AylaAppVersion> loadAppVersion() async {
  try {
    final PackageInfo info = await PackageInfo.fromPlatform();
    return parseAppVersion(
      version: info.version,
      buildNumber: info.buildNumber,
      packageName: info.packageName,
      appName: info.appName,
    );
  } catch (error) {
    debugPrint('[AylaUpdate] 读取安装包版本失败（按 0.0.0+0 继续）：$error');
    return const AylaAppVersion(version: '0.0.0', build: 0);
  }
}
