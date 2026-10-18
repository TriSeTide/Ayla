/// 更新弹窗渲染契约（按 phase 显示按钮/进度/强制更新不可关闭）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/update/update_api.dart';
import '../lib/theme/app_theme.dart';
import '../lib/widgets/base/update_dialog.dart';

class _FakeController extends AylaUpdateDialogController {
  _FakeController(this._state);

  AylaUpdateDialogState _state;
  int downloads = 0;
  int applies = 0;
  int postpones = 0;

  void setState(AylaUpdateDialogState next) {
    _state = next;
    notifyListeners();
  }

  @override
  AylaUpdateDialogState get state => _state;

  @override
  Future<void> applyNow() async {
    applies++;
  }

  @override
  void postpone() {
    postpones++;
  }

  @override
  Future<void> startDownload() async {
    downloads++;
  }
}

const AylaUpdateRelease _release = AylaUpdateRelease(
  releaseId: 'stable-1.0.1-2',
  version: '1.0.1',
  build: 2,
  publishedAt: '2026-10-18T12:00:00Z',
  notes: '修复若干问题\n优化启动速度',
  minSupportedBuild: 0,
);

const AylaUpdateDownload _download = AylaUpdateDownload(
  kind: 'zip',
  url: 'https://example.com/a.zip',
  fileName: 'a.zip',
  size: 100,
  sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
);

AylaUpdateDialogState _state(
  AylaUpdatePhase phase, {
  bool mandatory = false,
  double? progress,
  String? error,
}) {
  return AylaUpdateDialogState(
    phase: phase,
    release: _release,
    download: _download,
    mandatory: mandatory,
    progress: progress,
    error: error,
  );
}

Future<void> _pump(
  WidgetTester tester,
  AylaUpdateDialogController controller, {
  VoidCallback? onClose,
  bool showPostpone = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAylaTheme(),
      home: Scaffold(
        body: AylaUpdateDialog(
          controller: controller,
          onClose: onClose ?? () {},
          showPostpone: showPostpone,
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('available：显示发布说明与「立即更新」，点击触发下载', (WidgetTester tester) async {
    final _FakeController controller = _FakeController(
      _state(AylaUpdatePhase.available),
    );
    await _pump(tester, controller);
    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('1.0.1+2'), findsOneWidget);
    expect(find.textContaining('优化启动速度'), findsOneWidget);
    await tester.tap(find.text('立即更新'));
    await tester.pump();
    expect(controller.downloads, 1);
  });

  testWidgets('mandatory：标题为「需要更新」、无稍后/关闭、遮罩不可关', (WidgetTester tester) async {
    final _FakeController controller = _FakeController(
      _state(AylaUpdatePhase.available, mandatory: true),
    );
    int closed = 0;
    await _pump(tester, controller, onClose: () => closed++);
    expect(find.text('需要更新'), findsOneWidget);
    expect(find.text('稍后'), findsNothing);
    expect(find.text('必须更新'), findsOneWidget);
    // 点遮罩（卡片外部）不应关闭
    await tester.tapAt(const Offset(4, 4));
    await tester.pump();
    expect(closed, 0);
  });

  testWidgets('downloading：按钮禁用并显示进度', (WidgetTester tester) async {
    final _FakeController controller = _FakeController(
      _state(AylaUpdatePhase.downloading, progress: 0.42),
    );
    await _pump(tester, controller);
    expect(find.text('下载中…'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    // 组件库按钮在禁用态不响应点击；直接校验下载回调未被触发即可。
    await tester.tap(find.text('下载中…'));
    await tester.pump();
    expect(controller.downloads, 0);
  });

  testWidgets('ready：显示「安装并重启」', (WidgetTester tester) async {
    final _FakeController controller = _FakeController(
      _state(AylaUpdatePhase.ready, progress: 1),
    );
    await _pump(tester, controller);
    expect(find.text('安装并重启'), findsOneWidget);
    await tester.tap(find.text('安装并重启'));
    await tester.pump();
    expect(controller.applies, 1);
  });

  testWidgets('failed：显示错误与「重试」', (WidgetTester tester) async {
    final _FakeController controller = _FakeController(
      _state(AylaUpdatePhase.failed, error: '更新包 SHA-256 校验失败'),
    );
    await _pump(tester, controller);
    expect(find.textContaining('SHA-256'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(controller.downloads, 1);
  });
}
