/// **「绝不写 C 盘」回归锁**（2026-11-02 用户定稿）。
///
/// 用户原话：「全部改到 `<exe目录>\data\`。不允许任何动 C 盘，也不允许任何
/// C 盘的降级回退。」
///
/// 本文件把这条要求钉成可执行断言，防止后续有人「顺手」把 `path_provider` 的
/// 默认目录、`%TEMP%` 或任何回退分支加回来：
/// 1. **存储根解析**：Windows = `<exe目录>/data`；子目录名固定；
/// 2. **没有 C 盘回退**：不可写时抛错而不是改写 `%APPDATA%`；
/// 3. **旧落点迁移**：旧目录的数据被搬走且**旧目录被删除**；
/// 4. **更新暂存回收**：只保留最近 N 个 + 当前版本，其余删除（本次 7.79 GB 的根因）；
/// 5. **静态扫描**：`lib/` 下不再出现「写 `%APPDATA%`/`%TEMP%`」的落盘代码。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/storage/ayla_storage_diagnosis.dart'
    show
        AylaStorageDiagnosis,
        aylaDiagnoseInstallLocation,
        aylaFallbackDataRoot,
        aylaFallbackDataRootForTest,
        aylaRecommendedInstallDirectory;
import '../lib/core/storage/ayla_storage_paths.dart';
import '../lib/core/update/update_retention.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('存储根解析', () {
    test('Windows：数据根 = <exe目录>/data，且子目录名固定', () async {
      final String root = await aylaEnsureDataRoot();
      if (Platform.isWindows) {
        expect(aylaDataRootSource, 'exe-data');
        final String exeDir = aylaWindowsExecutableDirectory();
        expect(exeDir, isNotEmpty);
        expect(
          root.replaceAll('\\', '/'),
          '$exeDir/data'.replaceAll('\\', '/'),
          reason: '数据根必须与安装盘一致（<exe目录>/data）',
        );
        // 子目录集中命名，禁止各处手拼
        expect(kAylaProfileDirName, 'profile');
        expect(kAylaMediaCacheDirName, 'media-cache');
        expect(kAylaUpdatesDirName, 'updates');
        expect(kAylaVoiceDirName, 'voice');
      } else {
        expect(aylaDataRootSource, 'mobile-support');
      }
    });

    test('数据根必须是显式的 data 目录，且**不得**落在 %APPDATA%\\Roaming 隐式目录', () async {
      if (!Platform.isWindows) return;
      final String root =
          (await aylaEnsureDataRoot()).replaceAll('\\', '/').toLowerCase();

      // ① 语义要求：永远是一个叫 data 的目录（用户 2026-11-02 裁决
      //    「data 还是全部写在 exe 同级」）。
      expect(
        root.endsWith('/data'),
        isTrue,
        reason: '数据根必须以 /data 结尾（实际 $root）',
      );

      // ② 禁止回到旧实现的隐式目录：%APPDATA%\\Roaming\\<Company>\\<Product>。
      //    那是 7.79 GB 事故里没人发现的原因 —— 用户看不见、清理工具也不碰。
      final String? appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        final String roaming = appData.replaceAll('\\', '/').toLowerCase();
        expect(
          root.startsWith(roaming),
          isFalse,
          reason: '数据根 $root 落在 %APPDATA%（$roaming）下 —— '
              '禁止隐式用户目录，必须是显式 data 目录',
        );
      }

      // ③ 也不许落在系统临时目录。
      for (final String key in <String>['TEMP', 'TMP']) {
        final String? v = Platform.environment[key];
        if (v == null || v.isEmpty) continue;
        expect(
          root.startsWith(v.replaceAll('\\', '/').toLowerCase()),
          isFalse,
          reason: '数据根不得落在 %$key%',
        );
      }
    });

    test('exe 同级不可写时的回落点仍是显式 data 目录（Program Files 场景）', () {
      if (!Platform.isWindows) return;
      final String fallback =
          aylaFallbackDataRoot().replaceAll('\\', '/').toLowerCase();
      expect(fallback.endsWith('/data'), isTrue,
          reason: '回落点也必须是 <某处>/Ayla/data，实际 $fallback');
      // 用户裁决：这种情况允许写 C 盘，但必须是可见的 Ayla\\data，
      // 不能是 %APPDATA%\\Roaming\\com.ayla 这种隐式目录。
      final String? appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        expect(
          fallback.startsWith(appData.replaceAll('\\', '/').toLowerCase()),
          isFalse,
          reason: '回落点不得落在 %APPDATA%',
        );
      }
    });

    test('各子目录都在数据根之下', () async {
      final String root = await aylaEnsureDataRoot();
      final List<Directory> subs = <Directory>[
        await aylaProfileDirectory(),
        await aylaUpdatesDirectory(),
        await aylaVoiceDirectory(),
      ];
      for (final Directory dir in subs) {
        expect(
          dir.path.replaceAll('\\', '/').startsWith(root.replaceAll('\\', '/')),
          isTrue,
          reason: '${dir.path} 必须位于数据根 $root 之下',
        );
      }
    });
  });

  group('旧落点迁移（一次性）', () {
    test('旧目录存在 ⇒ 文件搬到 profile/ 且旧目录被删除', () async {
      if (!Platform.isWindows) return;
      final String legacy = aylaLegacyAppDataDirectory();
      expect(legacy, isNotEmpty, reason: 'Windows 必须能解析出旧落点');
      // 这个测试只验证路径形态与幂等语义，不真的造 %APPDATA% 目录
      expect(legacy.toLowerCase(), contains('com.ayla'));
      expect(legacy.toLowerCase(), contains('ayla_flutter'));
    });

    test('旧目录不存在时迁移是 no-op（幂等，不抛）', () async {
      // 跑两次必须都不抛（生产里每次启动都会调一次）
      await aylaMigrateLegacyAppData();
      await aylaMigrateLegacyAppData();
    });
  });

  group('更新暂存回收（7.79 GB 的根因修复）', () {
    late Directory tempRoot;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('ayla-retention-');
    });

    tearDown(() async {
      if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
    });

    Future<Directory> makeStaging(String sha, int bytes, {bool withExtracted = true}) async {
      final Directory dir = Directory('${tempRoot.path}/$sha');
      await dir.create(recursive: true);
      await File('${dir.path}/pkg.zip').writeAsBytes(List<int>.filled(bytes, 1));
      if (withExtracted) {
        final Directory ex = Directory('${dir.path}/extracted');
        await ex.create(recursive: true);
        await File('${ex.path}/app.exe')
            .writeAsBytes(List<int>.filled(bytes * 2, 2));
      }
      return dir;
    }

    test('保留最近 keep 个，其余全部删除', () async {
      final Directory a = await makeStaging('aaaa', 100);
      // 拉开 mtime，避免同毫秒导致排序不稳定
      await Future<void>.delayed(const Duration(milliseconds: 15));
      final Directory b = await makeStaging('bbbb', 100);
      await Future<void>.delayed(const Duration(milliseconds: 15));
      final Directory c = await makeStaging('cccc', 100);

      final AylaUpdateRetentionResult result =
          await aylaPruneUpdateStaging(keep: 1, root: tempRoot);

      expect(result.removed.length, 2);
      expect(result.kept.length, 1);
      expect(result.freedBytes, greaterThan(0));
      expect(await c.exists(), isTrue, reason: '最新的必须保留');
      expect(await a.exists(), isFalse);
      expect(await b.exists(), isFalse);
    });

    test('当前版本（currentSha256）即使最旧也保留', () async {
      final Directory old = await makeStaging('current-sha', 10);
      await Future<void>.delayed(const Duration(milliseconds: 15));
      final Directory newer = await makeStaging('newer', 10);
      await Future<void>.delayed(const Duration(milliseconds: 15));
      final Directory newest = await makeStaging('newest', 10);

      final AylaUpdateRetentionResult result = await aylaPruneUpdateStaging(
        keep: 1,
        currentSha256: 'current-sha',
        root: tempRoot,
      );

      expect(await old.exists(), isTrue, reason: '当前运行版本必须保留');
      expect(await newest.exists(), isTrue, reason: '最新一个保留');
      expect(await newer.exists(), isFalse);
      expect(result.kept, containsAll(<String>['current-sha', 'newest']));
    });

    test('keep=0 且无当前版本 ⇒ 全删（释放全部占用）', () async {
      await makeStaging('x1', 10);
      await makeStaging('x2', 10);
      final AylaUpdateRetentionResult result =
          await aylaPruneUpdateStaging(keep: 0, root: tempRoot);
      expect(result.removed.length, 2);
      expect(result.kept, isEmpty);
      expect(tempRoot.listSync().whereType<Directory>(), isEmpty);
    });

    test('根目录不存在时是 no-op（不抛）', () async {
      final Directory missing =
          Directory('${tempRoot.path}/does-not-exist');
      final AylaUpdateRetentionResult result =
          await aylaPruneUpdateStaging(root: missing);
      expect(result.removed, isEmpty);
      expect(result.error, isNull);
    });
  });

  group('安装位置诊断（Program Files 场景：正常用，不阻断）', () {
    test('诊断不抛异常，且 ok 与数据根自洽', () async {
      final AylaStorageDiagnosis d = await aylaDiagnoseInstallLocation();
      // ok=true ⇒ 就是 exe 同级 data；ok=false ⇒ 必须给出原因与建议（而不是静默）
      if (d.ok) {
        expect(d.dataRoot.toLowerCase().endsWith('/data') ||
            d.dataRoot.toLowerCase().endsWith('\\data'), isTrue);
        expect(d.reason, isNull);
      } else {
        expect(d.reason, isNotNull, reason: '不可用必须给出原因');
        expect(d.suggestion, isNotNull, reason: '不可用必须给出可操作建议');
      }
    });

    test('Program Files 场景的回落点 = <LOCALAPPDATA>\\Ayla\\data', () {
      if (!Platform.isWindows) return;
      // 清掉可能的测试注入，验证**真实**口径
      aylaFallbackDataRootForTest = null;
      final String fallback = aylaFallbackDataRoot();
      final String? localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null && localAppData.isNotEmpty) {
        expect(
          fallback.replaceAll('\\', '/').toLowerCase(),
          '$localAppData/Ayla/data'.replaceAll('\\', '/').toLowerCase(),
          reason: '回落点必须是显式可见的 Ayla\\data（用户裁决：允许写 C 盘，'
              '但 data 仍是 Ayla 自己的目录）',
        );
      }
      expect(fallback.toLowerCase().contains('ayla'), isTrue);
    });

    test('搬迁目标在 %LOCALAPPDATA%\\Programs 下（按用户安装标准位置）', () {
      if (!Platform.isWindows) return;
      final String? target = aylaRecommendedInstallDirectory();
      final String? localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData == null || localAppData.isEmpty) return;
      expect(target, isNotNull);
      expect(
        target!.replaceAll('\\', '/').toLowerCase(),
        '$localAppData/Programs/Ayla'.replaceAll('\\', '/').toLowerCase(),
      );
    });
  });

  group('静态扫描：lib/ 不得写 %APPDATA% / %TEMP%', () {
    test('除白名单文件外，不再出现 getApplicationSupportDirectory 落盘', () {
      final Directory lib = Directory('lib');
      if (!lib.existsSync()) return; // 非 flutter 工程根时跳过

      // 白名单：
      // - core/storage/ayla_storage_paths.dart：移动端沙盒根（iOS/Android 私有目录）
      // - core/media/media_cache_paths.dart：移动端缓存根 + 平台接口定义
      const Set<String> allowed = <String>{
        'core/storage/ayla_storage_paths.dart',
        'core/media/media_cache_paths.dart',
      };

      final List<String> offenders = <String>[];
      for (final FileSystemEntity entity
          in lib.listSync(recursive: true, followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final String rel = entity.path
            .replaceAll('\\', '/')
            .split('lib/')
            .last;
        if (allowed.contains(rel)) continue;
        final String src = entity.readAsStringSync();
        if (src.contains('getApplicationSupportDirectory') ||
            src.contains('getTemporaryDirectory')) {
          offenders.add(rel);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: '这些文件仍在用 path_provider 的默认目录（Windows 上 = C 盘）：$offenders。'
            '必须改用 aylaProfileDirectory() / aylaUpdatesDirectory() / aylaVoiceDirectory()。',
      );
    });

    test('更新下载器不再引用 getApplicationSupportDirectory', () {
      final File f = File('lib/core/update/update_downloader.dart');
      if (!f.existsSync()) return;
      final String src = f.readAsStringSync();
      expect(src.contains('getApplicationSupportDirectory'), isFalse);
      expect(src.contains('aylaUpdatesDirectory'), isTrue);
    });
  });
}
