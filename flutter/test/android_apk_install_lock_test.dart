/// **Android APK 安装链路回归锁**（2026-11-02 用户实报：
/// 「手机端更新的时候下载后点安装，跳到浏览器去下载了，明明已经下载好了」）。
///
/// ## 事故根因
/// 存储整改把 APK 落点从 `getTemporaryDirectory()`（= cacheDir）改成了
/// 「数据根/updates」（Android 上 = `getFilesDir()/updates`）。但：
/// 1. `MainActivity.installApk` 仍然只校验 `cacheDir` ⇒ **合法 APK 被判非法路径**；
/// 2. `file_paths.xml` 只声明了 `<cache-path>` ⇒ FileProvider 也不认这个路径。
/// 两者任一都会让 `installApk` 返回 false，而旧 `update_applier` **静默退化为
/// 打开浏览器下载页** ⇒ 用户看到「明明下载好了却跳浏览器」。
///
/// ## 本锁固定四件事
/// 1. **落点契约**：Android 的 updates 目录必须在 `getApplicationSupportDirectory()`
///    （= `getFilesDir()`）之下，而不是 cacheDir；
/// 2. **FileProvider 授权**：`file_paths.xml` 必须同时声明 `<files-path>` 与
///    `<cache-path>`（前者是现行落点，后者兼容旧版本残留）；
/// 3. **原生校验**：`installApk` 必须同时接受 filesDir 与 cacheDir；
/// 4. **不再静默跳浏览器**：`update_applier` 只有「构建没有安装器」才允许开下载页，
///    其余失败必须抛出可展示原因。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 工程根（测试从 `flutter/` 目录运行）。
File _f(String relative) => File(relative);

void main() {
  group('APK 落点与 FileProvider 授权', () {
    test('file_paths.xml 同时声明 files-path 与 cache-path', () {
      final File xml =
          _f('android/app/src/main/res/xml/file_paths.xml');
      expect(xml.existsSync(), isTrue, reason: '缺少 file_paths.xml');

      final String src = xml.readAsStringSync();
      expect(
        src.contains('<files-path'),
        isTrue,
        reason: '必须声明 <files-path>：现行 APK 落点 = getFilesDir()/updates。'
            '只声明 <cache-path> 会让 FileProvider 拒绝该路径 ⇒ 安装器静默失败',
      );
      expect(
        src.contains('<cache-path'),
        isTrue,
        reason: '必须保留 <cache-path>：兼容从旧版本升级上来、'
            '残留在 cacheDir/updates 的安装包',
      );
      // 两个根都要覆盖到 updates/
      expect(
        RegExp(r'<files-path[^>]*path="updates/"').hasMatch(src),
        isTrue,
        reason: '<files-path> 必须覆盖 updates/ 子目录',
      );
      expect(
        RegExp(r'<cache-path[^>]*path="updates/"').hasMatch(src),
        isTrue,
      );
    });

    test('installApk 同时接受 filesDir 与 cacheDir', () {
      final File kt = _f(
        'android/app/src/main/kotlin/com/ayla/ayla_flutter/MainActivity.kt',
      );
      expect(kt.existsSync(), isTrue);

      final String src = kt.readAsStringSync();
      expect(
        src.contains('filesDir'),
        isTrue,
        reason: 'installApk 必须接受 filesDir（现行落点）。'
            '只认 cacheDir 是 2026-11-02「点安装跳浏览器」的直接原因',
      );
      expect(
        src.contains('cacheDir'),
        isTrue,
        reason: 'installApk 必须保留 cacheDir（旧版本残留包）',
      );
      // 仍然必须拒绝任意路径
      expect(
        src.contains('allowedRoots') || src.contains('startsWith'),
        isTrue,
        reason: '必须保留「只允许应用私有目录」的路径校验',
      );
    });

    test('Android 的 updates 目录在应用私有 files 目录下（不是 cacheDir）', () {
      final File sp = _f('lib/core/storage/ayla_storage_paths.dart');
      final String src = sp.readAsStringSync();
      // Android 分支使用 getApplicationSupportDirectory()（= getFilesDir()）
      expect(
        src.contains('getApplicationSupportDirectory'),
        isTrue,
        reason: 'Android 数据根应取 getApplicationSupportDirectory()（= filesDir 族），'
            '与 file_paths.xml 的 <files-path> 对齐',
      );
      expect(
        src.contains('kAylaUpdatesDirName'),
        isTrue,
        reason: 'updates 目录名必须集中定义，便于与 file_paths.xml 对账',
      );
    });
  });

  group('不再静默跳浏览器', () {
    test('update_applier 只在「没有内置安装器」时才打开下载页', () {
      final File f = _f('lib/core/update/update_applier.dart');
      final String src = f.readAsStringSync();

      // 失败分支必须抛错（throw AylaUpdateApplyException），而不是直接 _openUrl
      expect(
        src.contains('throw AylaUpdateApplyException'),
        isTrue,
        reason: '安装失败必须如实告知原因，不能静默退化',
      );
      // 关键：打开下载页前必须有「旧版本」这类显式判据
      expect(
        src.contains('旧版本'),
        isTrue,
        reason: '只有「当前构建没有内置安装器」才允许打开下载页；'
            '其余失败（权限被关 / 路径被拒 / 包损坏）必须抛错',
      );
    });

    test('安装器返回可展示原因（不是裸 bool）', () {
      final File f = _f('lib/core/update/update_install_launcher.dart');
      final String src = f.readAsStringSync();
      expect(
        src.contains('AylaApkInstallOutcome'),
        isTrue,
        reason: '返回值必须带 reason，否则调用方无法告知用户真实原因',
      );
      expect(
        src.contains('reason'),
        isTrue,
      );
      // 文件不存在时要有准确提示（不是笼统「失败了」）
      expect(
        src.contains('安装包文件已不存在'),
        isTrue,
      );
    });
  });
}
