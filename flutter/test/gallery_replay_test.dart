/// 画布「动画族一键重播」机制回归（2026-09-28，用户点名的小任务）。
///
/// 覆盖两件事：
/// 1. **合成手势 helper**（`aylaSyntheticDrag`，定义在 `preview/component_gallery.dart`）——
///    跟手类组件的正确性只存在于「位移随时间的形状」里，静止终态看不出来；
///    本 helper 是画布按钮「模拟下拉刷新 / 模拟右滑返回」的驱动，必须真的能驱动组件。
/// 2. `AylaRevealScope(replayKey:)` 的重播语义已由 `cleanup_2026_09_20_test.dart` 覆盖，
///    本文件不重复；画布上的「重播入场（四档）」按钮只是它的接线。
///
/// ⚠️ helper 内部按 16ms/步 `await Future.delayed`：在 widget test 里由 `tester.pump(16ms)`
/// 推进虚拟时钟，故必须先起 drag 的 Future、逐步 pump、最后再 await 它。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/preview/component_gallery.dart' show aylaSyntheticDrag;
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/media_interaction.dart';
import '../lib/widgets/motion/gestures.dart';

void main() {
  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  /// 驱动一个由 `aylaSyntheticDrag` 起的手势直到完成（每步 16ms）。
  Future<void> drive(WidgetTester tester, Future<void> drag) async {
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await drag;
  }

  testWidgets('合成下拉（110px 越 threshold 64）⇒ AylaPullToRefresh 触发 onRefresh', (
    WidgetTester tester,
  ) async {
    int refreshes = 0;
    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(
      host(
        Center(
          child: SizedBox(
            width: 320,
            height: 420,
            child: AylaPullToRefresh(
              key: key,
              isAtTop: () => true,
              onRefresh: () async {
                refreshes++;
              },
              child: ListView(
                physics: const NeverScrollableScrollPhysics(),
                children: const <Widget>[SizedBox(height: 900, child: Text('内容'))],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final RenderBox box =
        key.currentContext!.findRenderObject()! as RenderBox;
    final Offset start =
        box.localToGlobal(Offset.zero) + Offset(box.size.width / 2, 24);
    final Future<void> drag =
        aylaSyntheticDrag(start: start, delta: const Offset(0, 110));
    await drive(tester, drag);
    // 刷新态停留 + 收起
    await tester.pump(const Duration(milliseconds: 400));

    expect(refreshes, 1, reason: '下拉 110px 越过 threshold 64 ⇒ 释放必须触发刷新');
  });

  testWidgets('合成下拉（30px 未过 threshold）⇒ 不触发 onRefresh，指示器回弹', (
    WidgetTester tester,
  ) async {
    int refreshes = 0;
    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(
      host(
        Center(
          child: SizedBox(
            width: 320,
            height: 420,
            child: AylaPullToRefresh(
              key: key,
              isAtTop: () => true,
              onRefresh: () async {
                refreshes++;
              },
              child: ListView(
                physics: const NeverScrollableScrollPhysics(),
                children: const <Widget>[SizedBox(height: 900, child: Text('内容'))],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final RenderBox box =
        key.currentContext!.findRenderObject()! as RenderBox;
    final Offset start =
        box.localToGlobal(Offset.zero) + Offset(box.size.width / 2, 24);
    final Future<void> drag =
        aylaSyntheticDrag(start: start, delta: const Offset(0, 30));
    await drive(tester, drag);
    await tester.pump(const Duration(milliseconds: 400));

    expect(refreshes, 0, reason: '未过阈值 ⇒ 只回弹，不刷新');
  });

  testWidgets('合成右滑 200px ⇒ AylaFullScreenSwipeBack 触发 onBack', (
    WidgetTester tester,
  ) async {
    int backs = 0;
    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(
      host(
        Center(
          child: SizedBox(
            width: 340,
            height: 120,
            child: AylaFullScreenSwipeBack(
              key: key,
              onBack: () => backs++,
              child: Container(
                alignment: Alignment.center,
                color: const Color(0x22FFFFFF),
                child: const Text('右滑'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final RenderBox box =
        key.currentContext!.findRenderObject()! as RenderBox;
    final Offset start =
        box.localToGlobal(Offset.zero) + Offset(24, box.size.height / 2);
    final Future<void> drag =
        aylaSyntheticDrag(start: start, delta: const Offset(200, 0));
    await drive(tester, drag);
    await tester.pump(const Duration(milliseconds: 400));

    expect(backs, 1, reason: '位移 200 ≥ 120 且速度 ≥300px/s ⇒ 必须触发返回');
  });
}