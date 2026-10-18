/// Windows 覆盖安装脚本的逐字符契约 + 其它平台安装分派。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/update/update_api.dart';
import '../lib/core/update/update_applier.dart';
import '../lib/core/update/update_downloader.dart';
import '../lib/core/update/update_install_launcher.dart';

void main() {
  group('buildWindowsApplyScript', () {
    test('按 pid 结束进程 → robocopy 覆盖 → 启动新 exe', () {
      final String script = buildWindowsApplyScript(
        pid: 4321,
        sourceDir: r'C:\temp\ayla\extracted',
        targetDir: r'D:\Ayla',
        exeName: 'ayla_flutter.exe',
        logPath: r'C:\temp\ayla\apply.log',
      );
      final List<String> lines = script.split('\r\n');
      expect(lines.first, '@echo off');
      expect(script, contains('taskkill /PID 4321 /T /F'));
      expect(
        script,
        contains(r'robocopy "%SRC%" "%DST%" /E /COPY:DAT /R:3 /W:2'),
      );
      expect(script, contains(r'set "SRC=C:\temp\ayla\extracted"'));
      expect(script, contains(r'set "DST=D:\Ayla"'));
      expect(script, contains(r'start "" "%DST%\%EXE%"'));
      expect(script, contains('exit /b 0'));
      // 失败分支必须保留日志并 pause，不能静默退出
      expect(script, contains('if %RC% GEQ 8 ('));
      expect(script, contains('pause'));
    });

    test('源/目标路径通过变量引用，不拼进 robocopy 命令字面量', () {
      final String script = buildWindowsApplyScript(
        pid: 1,
        sourceDir: '/tmp/a',
        targetDir: '/tmp/b',
        exeName: 'ayla_flutter.exe',
        logPath: '/tmp/log',
      );
      expect(script, contains('robocopy "%SRC%" "%DST%"'));
      expect(script.split('robocopy "%SRC%" "%DST%"').length, 2);
    });
  });

  group('AylaUpdateApplier 平台分派', () {
    test('未知 kind：打开下载地址并返回 open_download', () async {
      final List<Uri> opened = <Uri>[];
      final AylaUpdateApplier applier = AylaUpdateApplier(
        openUrl: (Uri uri) async {
          opened.add(uri);
          return true;
        },
      );
      final AylaPreparedUpdateLike prepared = AylaPreparedUpdateLike(
        url: 'https://example.com/a.dmg',
        fileName: 'a.dmg',
        kind: 'dmg',
        sha256: 'a' * 64,
        size: 10,
      );
      final AylaUpdateApplyResult result = await _applyWith(applier, prepared);
      expect(result.mode, 'open_download');
      expect(opened.single.toString(), 'https://example.com/a.dmg');
    });

    test('iOS itms-services 安装页：优先打开 install_url', () async {
      final List<Uri> opened = <Uri>[];
      final AylaUpdateApplier applier = AylaUpdateApplier(
        platform: AylaUpdatePlatformKind.ios,
        openUrl: (Uri uri) async {
          opened.add(uri);
          return true;
        },
      );
      final AylaUpdateApplyResult result = await applier.apply(
        AylaPreparedUpdate(
          download: const AylaUpdateDownload(
            kind: 'ipa',
            url: 'https://example.com/a.ipa',
            fileName: 'a.ipa',
            size: 10,
            sha256:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            installUrl:
                'itms-services://?action=download-manifest&url=https://x/m.plist',
          ),
          filePath: '/tmp/a.ipa',
          bytes: 10,
          stagingDir: '/tmp/staging',
        ),
      );
      expect(result.mode, 'platform_store');
      expect(opened.single.scheme, 'itms-services');
    });

    test('Android：安装器拉起成功 ⇒ android_apk', () async {
      final _FakeInstallLauncher launcher = _FakeInstallLauncher(true);
      final AylaUpdateApplier applier = AylaUpdateApplier(
        platform: AylaUpdatePlatformKind.android,
        installLauncher: launcher,
        openUrl: (Uri uri) async => true,
      );
      final AylaUpdateApplyResult result = await applier.apply(
        _androidPrepared(),
      );
      expect(result.mode, 'android_apk');
      expect(launcher.calls, 1);
      expect(launcher.lastPath, '/tmp/staging/a.apk');
    });

    test('Android：无内置安装器 ⇒ 退化打开下载页', () async {
      final List<Uri> opened = <Uri>[];
      final AylaUpdateApplier applier = AylaUpdateApplier(
        platform: AylaUpdatePlatformKind.android,
        installLauncher: _FakeInstallLauncher(false),
        openUrl: (Uri uri) async {
          opened.add(uri);
          return true;
        },
      );
      final AylaUpdateApplyResult result = await applier.apply(
        _androidPrepared(),
      );
      expect(result.mode, 'open_download');
      expect(opened.single.toString(), 'https://example.com/a.apk');
    });

    test('Android：安装器抛错 ⇒ AylaUpdateApplyException（保留 APK）', () async {
      final AylaUpdateApplier applier = AylaUpdateApplier(
        platform: AylaUpdatePlatformKind.android,
        installLauncher: _FakeInstallLauncher.thrower(),
        openUrl: (Uri uri) async => true,
      );
      expect(
        () => applier.apply(_androidPrepared()),
        throwsA(isA<AylaUpdateApplyException>()),
      );
    });

    test('iOS 无 install_url ⇒ 打开下载地址', () async {
      final List<Uri> opened = <Uri>[];
      final AylaUpdateApplier applier = AylaUpdateApplier(
        platform: AylaUpdatePlatformKind.ios,
        openUrl: (Uri uri) async {
          opened.add(uri);
          return true;
        },
      );
      final AylaUpdateApplyResult result = await applier.apply(
        AylaPreparedUpdate(
          download: const AylaUpdateDownload(
            kind: 'ipa',
            url: 'https://example.com/a.ipa',
            fileName: 'a.ipa',
            size: 10,
            sha256:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          ),
          filePath: '/tmp/a.ipa',
          bytes: 10,
          stagingDir: '/tmp/staging',
        ),
      );
      expect(result.mode, 'open_download');
      expect(opened.single.toString(), 'https://example.com/a.ipa');
    });
  });
}

class _FakeInstallLauncher extends AylaUpdateInstallLauncher {
  _FakeInstallLauncher(this.result) : _throw = false;
  _FakeInstallLauncher.thrower() : result = false, _throw = true;

  final bool result;
  final bool _throw;
  int calls = 0;
  String? lastPath;

  @override
  Future<bool> installApk(String path) async {
    calls++;
    lastPath = path;
    if (_throw) throw StateError('user denied install');
    return result;
  }
}

AylaPreparedUpdate _androidPrepared() {
  return AylaPreparedUpdate(
    download: const AylaUpdateDownload(
      kind: 'apk',
      url: 'https://example.com/a.apk',
      fileName: 'a.apk',
      size: 10,
      sha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    ),
    filePath: '/tmp/staging/a.apk',
    bytes: 10,
    stagingDir: '/tmp/staging',
  );
}

/// 本测试文件内构造 AylaPreparedUpdate 的最小替身（避免触真实下载目录）。
class AylaPreparedUpdateLike {
  const AylaPreparedUpdateLike({
    required this.url,
    required this.fileName,
    required this.kind,
    required this.sha256,
    required this.size,
  });

  final String url;
  final String fileName;
  final String kind;
  final String sha256;
  final int size;
}

Future<AylaUpdateApplyResult> _applyWith(
  AylaUpdateApplier applier,
  AylaPreparedUpdateLike prepared,
) {
  return applier.apply(
    AylaPreparedUpdate(
      download: AylaUpdateDownload(
        kind: prepared.kind,
        url: prepared.url,
        fileName: prepared.fileName,
        size: prepared.size,
        sha256: prepared.sha256,
      ),
      filePath: '/tmp/does-not-matter',
      bytes: prepared.size,
      stagingDir: '/tmp/staging',
    ),
  );
}
