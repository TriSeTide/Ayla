/// 更新编排（检查 → 会话 → 下载/安装状态机）的契约。
library;

import 'dart:async';
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
  // ⚠️ 之前这里把 `mandatory` 参数写死成 `false`（形参从未被使用）⇒ 任何
  // 「强制更新」用例实际上测的都是普通更新。2026-11-05 补用例时才发现。
  return AylaUpdateCheck(
    channel: 'stable',
    updateAvailable: true,
    mandatory: mandatory,
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

  // ================= 2026-11-05 审计修复的回归锁 =================

  test('强制更新：postpone 不再绕过 mandatory（潜伏雷已堵）', () async {
    final List<AylaUpdateDialogSession> opened = <AylaUpdateDialogSession>[];
    final AylaUpdateController controller = AylaUpdateController(
      api: _FakeApi(() => _availableCheck(mandatory: true)),
      downloader: _FakeDownloader(bytes: Uint8List(2), sha: 'a' * 64),
      applier: _FakeApplier(),
      versionLoader: () async =>
          const AylaAppVersion(version: '1.0.0', build: 1),
      onDialogRequested: opened.add,
    );
    await controller.checkManually();
    final AylaUpdateDialogSession session = opened.single;
    expect(session.state.mandatory, isTrue);
    session.postpone();
    expect(session.closed, isFalse, reason: '强制更新不能被 postpone 关掉');
    expect(controller.activeSession, isNotNull);
  });

  test('版本读不到（build=0）：自动检查不弹窗，手动检查如实报错', () async {
    final List<AylaUpdateDialogSession> opened = <AylaUpdateDialogSession>[];
    final AylaUpdateController controller = AylaUpdateController(
      api: _FakeApi(() => _availableCheck()),
      downloader: _FakeDownloader(bytes: Uint8List(2), sha: 'a' * 64),
      applier: _FakeApplier(),
      // 模拟 package_info 读取失败的回退值（loadAppVersion 的 0.0.0+0）。
      versionLoader: () async =>
          const AylaAppVersion(version: '0.0.0', build: 0),
      onDialogRequested: opened.add,
    );
    await controller.checkOnLogin();
    expect(opened, isEmpty, reason: '读不到版本时不能弹假更新（否则会被强制更新锁死）');

    final AylaUpdateCheckResult manual = await controller.checkManually();
    expect(manual.failed, isTrue);
    expect(manual.error, contains('无法读取'));
    expect(opened, isEmpty);
  });

  test('resetForNewSession：复位 checking、丢弃在途会话、换会话后可再检查', () async {
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
    expect(opened, hasLength(1));
    expect(controller.checking, isFalse);

    controller.resetForNewSession();
    expect(controller.loginCheckDone, isFalse);
    expect(controller.activeSession, isNull);
    expect(controller.checking, isFalse, reason: '卡住的在途检查不能挡住下一次手动检查');

    await controller.checkOnLogin();
    expect(api.calls, 2, reason: '换登录会话后应当再检查一次');
    expect(opened, hasLength(2));
  });

  test('跨登出才返回的检查结果：丢弃，不在新会话里弹窗', () async {
    final List<AylaUpdateDialogSession> opened = <AylaUpdateDialogSession>[];
    late AylaUpdateController controller;
    // 让 check 卡住，模拟「请求在途时用户登出」。
    final _GatedApi gated = _GatedApi(() => _availableCheck());
    controller = AylaUpdateController(
      api: gated,
      downloader: _FakeDownloader(bytes: Uint8List(2), sha: 'a' * 64),
      applier: _FakeApplier(),
      versionLoader: () async =>
          const AylaAppVersion(version: '1.0.0', build: 1),
      onDialogRequested: opened.add,
    );
    final Future<AylaUpdateCheckResult?> inflight = controller.checkOnLogin();
    // 请求还没回来就换会话。
    controller.resetForNewSession();
    gated.release();
    await inflight;
    expect(opened, isEmpty, reason: '旧会话的检查结果不能在换会话后弹窗');
    expect(controller.activeSession, isNull);
  });
}

/// 可放行的更新 API 替身（用来模拟「请求在途时登出」）。
class _GatedApi extends AylaUpdateApi {
  _GatedApi(this.result);

  final AylaUpdateCheck Function() result;
  final Completer<void> _gate = Completer<void>();

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<AylaUpdateCheck> check({
    required AylaAppVersion version,
    String channel = AylaUpdateApi.defaultChannel,
    String? platform,
    String? arch,
  }) async {
    await _gate.future;
    return result();
  }
}