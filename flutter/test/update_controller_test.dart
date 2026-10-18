/// 更新编排（检查 → 会话 → 下载/安装状态机）的契约。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/update/app_version.dart';
import '../lib/core/update/update_api.dart';
import '../lib/core/update/update_applier.dart';
import '../lib/core/update/update_controller.dart';
import '../lib/core/update/update_downloader.dart';
import '../lib/widgets/base/update_dialog.dart';

class _FakeApi extends AylaUpdateApi {
  _FakeApi(this.result);

  final AylaUpdateCheck Function() result;
  int calls = 0;

  @override
  Future<AylaUpdateCheck> check({
    required AylaAppVersion version,
    String channel = AylaUpdateApi.defaultChannel,
    String? platform,
    String? arch,
  }) async {
    calls++;
    return result();
  }
}

class _FakeDownloader extends AylaUpdateDownloader {
  _FakeDownloader({required this.bytes, required this.sha});

  final Uint8List bytes;
  final String sha;
  int calls = 0;

  @override
  Future<AylaPreparedUpdate> download(
    AylaUpdateDownload download, {
    void Function(AylaUpdateProgress progress)? onProgress,
    Object? cancelToken,
  }) async {
    calls++;
    onProgress?.call(AylaUpdateProgress(received: 1, total: 2));
    onProgress?.call(AylaUpdateProgress(received: 2, total: 2));
    return AylaPreparedUpdate(
      download: download,
      filePath: '/tmp/fake.zip',
      bytes: bytes.length,
      stagingDir: '/tmp/staging',
    );
  }
}

class _FakeApplier extends AylaUpdateApplier {
  _FakeApplier({
    this.fail = false,
    this.result = const AylaUpdateApplyResult(
      mode: 'windows_zip',
      restarting: false,
    ),
  }) : super(openUrl: (Uri uri) async => true);

  final bool fail;
  final AylaUpdateApplyResult result;
  int calls = 0;

  @override
  Future<AylaUpdateApplyResult> apply(AylaPreparedUpdate prepared) async {
    calls++;
    if (fail) throw const AylaUpdateApplyException('安装器启动失败');
    return result;
  }
}

AylaUpdateCheck _availableCheck({bool mandatory = false}) {
  return const AylaUpdateCheck(
    channel: 'stable',
    updateAvailable: true,
    mandatory: false,
    degraded: false,
    reason: 'update_available',
    latest: AylaUpdateRelease(
      releaseId: 'stable-1.0.1-2',
      version: '1.0.1',
      build: 2,
      publishedAt: '',
      notes: '修复若干问题',
      minSupportedBuild: 0,
    ),
    download: AylaUpdateDownload(
      kind: 'zip',
      url: 'http://127.0.0.1:8100/releases/a.zip',
      fileName: 'a.zip',
      size: 2,
      sha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    ),
    currentVersion: '1.0.0',
    currentBuild: 1,
  );
}

void main() {
  test('登录后自动检查：有更新时打开会话；同一进程只自动检查一次', () async {
    final _FakeApi api = _FakeApi(() => _availableCheck());
    final List<AylaUpdateDialogSession> opened = <AylaUpdateDialogSession>[];
    final AylaUpdateController controller = AylaUpdateController(
      api: api,
      downloader: _FakeDownloader(bytes: Uint8List(2), sha: 'a' * 64),
      applier: _FakeApplier(),
      versionLoader: () async =>
          const AylaAppVersion(version: '1.0.0', build: 1),
      onDialogRequested: opened.add,
    );
    await controller.checkOnLogin();
    await controller.checkOnLogin();
    expect(api.calls, 1, reason: '登录后自动检查只执行一次');
    expect(opened, hasLength(1));
    expect(opened.single.state.phase, AylaUpdatePhase.available);
    expect(opened.single.state.release.build, 2);
  });

  test('检查失败：不打开会话，且返回 error（登录流程不受影响）', () async {
    final _FakeApi api = _FakeApi(
      () => throw const AylaUpdateException('network'),
    );
    final List<AylaUpdateDialogSession> opened = <AylaUpdateDialogSession>[];
    final AylaUpdateController controller = AylaUpdateController(
      api: api,
      downloader: _FakeDownloader(bytes: Uint8List(2), sha: 'a' * 64),
      applier: _FakeApplier(),
      versionLoader: () async =>
          const AylaAppVersion(version: '1.0.0', build: 1),
      onDialogRequested: opened.add,
    );
    final AylaUpdateCheckResult? result = await controller.checkOnLogin();
    expect(result!.failed, isTrue);
    expect(opened, isEmpty);
  });

  test('degraded（清单缺失）：不打开会话，不当成“有更新”', () async {
    final _FakeApi api = _FakeApi(
      () => const AylaUpdateCheck(
        channel: 'stable',
        updateAvailable: false,
        mandatory: false,
        degraded: true,
        reason: 'manifest_unavailable',
        latest: null,
        download: null,
        currentVersion: '1.0.0',
        currentBuild: 1,
      ),
    );
    final List<AylaUpdateDialogSession> opened = <AylaUpdateDialogSession>[];
    final AylaUpdateController controller = AylaUpdateController(
      api: api,
      versionLoader: () async =>
          const AylaAppVersion(version: '1.0.0', build: 1),
      onDialogRequested: opened.add,
    );
    final AylaUpdateCheckResult result = await controller.checkManually();
    expect(result.degraded, isTrue);
    expect(result.hasUpdate, isFalse);
    expect(opened, isEmpty);
  });

  test('下载 → 准备安装 → 应用：状态机与回调按序推进', () async {
    final _FakeDownloader downloader = _FakeDownloader(
      bytes: Uint8List(2),
      sha: 'a' * 64,
    );
    final _FakeApplier applier = _FakeApplier(
      result: const AylaUpdateApplyResult(
        mode: 'windows_zip',
        restarting: false,
      ),
    );
    final List<AylaUpdateApplyResult> applied = <AylaUpdateApplyResult>[];
    final List<AylaUpdateDialogSession> opened = <AylaUpdateDialogSession>[];
    final AylaUpdateController controller = AylaUpdateController(
      api: _FakeApi(() => _availableCheck()),
      downloader: downloader,
      applier: applier,
      versionLoader: () async =>
          const AylaAppVersion(version: '1.0.0', build: 1),
      onDialogRequested: opened.add,
      onApplied: (AylaUpdateApplyResult result) async => applied.add(result),
    );
    await controller.checkManually();
    final AylaUpdateDialogSession session = opened.single;
    await session.startDownload();
    expect(session.state.phase, AylaUpdatePhase.ready);
    expect(session.state.progress, 1);
    await session.applyNow();
    expect(applier.calls, 1);
    expect(applied, hasLength(1));
    expect(controller.activeSession, isNull);
  });

  test('Windows 重启分支：onApplied 之后请求退出进程', () async {
    final List<int> exits = <int>[];
    final List<AylaUpdateDialogSession> opened = <AylaUpdateDialogSession>[];
    final AylaUpdateController controller = AylaUpdateController(
      api: _FakeApi(() => _availableCheck()),
      downloader: _FakeDownloader(bytes: Uint8List(2), sha: 'a' * 64),
      applier: _FakeApplier(
        result: const AylaUpdateApplyResult(
          mode: 'windows_zip',
          restarting: true,
        ),
      ),
      versionLoader: () async =>
          const AylaAppVersion(version: '1.0.0', build: 1),
      onDialogRequested: opened.add,
      requestExit: exits.add,
      exitDelay: Duration.zero,
    );
    await controller.checkManually();
    final AylaUpdateDialogSession session = opened.single;
    await session.startDownload();
    await session.applyNow();
    expect(exits, <int>[0], reason: '覆盖脚本已启动，进程必须退出以释放文件锁');
  });

  test('安装失败：进入 failed 且保留可重试的包（不重复下载）', () async {
    final _FakeDownloader downloader = _FakeDownloader(
      bytes: Uint8List(2),
      sha: 'a' * 64,
    );
    final _FakeApplier applier = _FakeApplier(fail: true);
    final List<AylaUpdateDialogSession> opened = <AylaUpdateDialogSession>[];
    final AylaUpdateController controller = AylaUpdateController(
      api: _FakeApi(() => _availableCheck()),
      downloader: downloader,
      applier: applier,
      versionLoader: () async =>
          const AylaAppVersion(version: '1.0.0', build: 1),
      onDialogRequested: opened.add,
    );
    await controller.checkManually();
    final AylaUpdateDialogSession session = opened.single;
    await session.startDownload();
    await session.applyNow();
    expect(session.state.phase, AylaUpdatePhase.failed);
    expect(session.state.error, contains('安装器启动失败'));
    await session.startDownload();
    expect(downloader.calls, 1, reason: '已下载并校验过的包不应重复下载');
    expect(session.state.phase, AylaUpdatePhase.ready);
  });

  test('手动检查不会因单飞标记被登录检查短路', () async {
    final _FakeApi api = _FakeApi(() => _availableCheck());
    final AylaUpdateController controller = AylaUpdateController(
      api: api,
      versionLoader: () async =>
          const AylaAppVersion(version: '1.0.0', build: 1),
      downloader: _FakeDownloader(bytes: Uint8List(2), sha: 'a' * 64),
      applier: _FakeApplier(),
      onDialogRequested: (_) {},
    );
    await controller.checkOnLogin();
    await controller.checkManually();
    expect(api.calls, 2);
  });
}
