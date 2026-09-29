/// AylaPanelSwap 定向测试 —— web `hooks/useTabPanelMotion.ts` /
/// `hooks/usePanelSwapMotion.ts` 的语义锁。
///
/// 关键差别（两条 hook **有意不同**，别统一）：
/// - tab 档：300ms 单段 `opacity 0 / x +20` → `1 / 0`（easeInOut）；not-ready 期间
///   **冻结基线** ⇒ 之后**补播**；
/// - swap 档：600ms 双段（下移淡出 y +20 → 回位淡入，每段 easeOut）；基线**始终推进**
///   ⇒ 没有补播。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/preview_theme.dart';
import '../lib/widgets/motion/panel_swap.dart';

/// 取 [AylaPanelSwap] 当前呈现的 (opacity, dx, dy)：读它内部第一个 Opacity/Transform。
({double opacity, double dx, double dy}) sample(WidgetTester tester) {
  final Opacity op = tester.widget<Opacity>(
    find.descendant(of: find.byType(AylaPanelSwap).first, matching: find.byType(Opacity)).first,
  );
  final Transform tr = tester.widget<Transform>(
    find.descendant(of: find.byType(AylaPanelSwap).first, matching: find.byType(Transform)).first,
  );
  final Matrix4 m = tr.transform;
  return (opacity: op.opacity, dx: m.storage[12], dy: m.storage[13]);
}

void main() {
  testWidgets('tab 档：identity 变化就地播 300ms，x +20 → 0 + 淡入', (WidgetTester tester) async {
    String id = 'a';
    late StateSetter set;
    await tester.pumpWidget(previewScope(MaterialApp(
      home: StatefulBuilder(
        builder: (BuildContext context, StateSetter s) {
          set = s;
          return AylaPanelSwap(
            identity: id,
            mode: AylaPanelSwapMode.tab,
            child: const SizedBox(width: 100, height: 40),
          );
        },
      ),
    )));
    expect(sample(tester).dx, 0, reason: '静止态应在 center');

    set(() => id = 'b');
    await tester.pump();
    final ({double opacity, double dx, double dy}) early = sample(tester);
    expect(early.opacity, lessThan(0.1), reason: 'tab 档起点应是 opacity 0');
    expect(early.dx, closeTo(AylaPanelSwap.distance, 0.5), reason: 'tab 档起点应是 x +20');

    await tester.pump(const Duration(milliseconds: 150));
    final ({double opacity, double dx, double dy}) mid = sample(tester);
    expect(mid.opacity, greaterThan(0.1));
    expect(mid.dx, lessThan(AylaPanelSwap.distance));

    await tester.pumpAndSettle();
    expect(sample(tester).dx, 0);
    expect(sample(tester).opacity, 1);
  });

  testWidgets('swap 档：600ms 双段（下移淡出 → 回位淡入），起点是「当前样式」', (
    WidgetTester tester,
  ) async {
    String id = 'a';
    late StateSetter set;
    await tester.pumpWidget(previewScope(MaterialApp(
      home: StatefulBuilder(
        builder: (BuildContext context, StateSetter s) {
          set = s;
          return AylaPanelSwap(
            identity: id,
            mode: AylaPanelSwapMode.swap,
            child: const SizedBox(width: 100, height: 40),
          );
        },
      ),
    )));

    set(() => id = 'b');
    await tester.pump();
    final ({double opacity, double dx, double dy}) start = sample(tester);
    expect(start.opacity, 1, reason: 'swap 档起点 = 当前样式（不透明）');
    expect(start.dy, 0);

    await tester.pump(const Duration(milliseconds: 300)); // 中点 = 完全下移淡出
    final ({double opacity, double dx, double dy}) half = sample(tester);
    expect(half.opacity, lessThan(0.1), reason: '中点应是 opacity 0');
    expect(half.dy, closeTo(AylaPanelSwap.distance, 1.5), reason: '中点应是 y +20');

    await tester.pumpAndSettle();
    expect(sample(tester).dy, 0);
    expect(sample(tester).opacity, 1);
  });

  testWidgets('establishBaseline：只记基线、不播（首次选中默认组不算换场）', (WidgetTester tester) async {
    String id = 'a';
    late StateSetter set;
    await tester.pumpWidget(previewScope(MaterialApp(
      home: StatefulBuilder(
        builder: (BuildContext context, StateSetter s) {
          set = s;
          return AylaPanelSwap(
            identity: id,
            establishBaseline: true,
            child: const SizedBox(width: 100, height: 40),
          );
        },
      ),
    )));
    set(() => id = 'b');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(sample(tester).opacity, 1, reason: '基线帧不应播动画');
    expect(sample(tester).dx, 0);
  });

  testWidgets('not-ready（tab 档）冻结基线 ⇒ 变 ready 后补播', (WidgetTester tester) async {
    String id = 'a';
    bool enabled = true;
    late StateSetter set;
    await tester.pumpWidget(previewScope(MaterialApp(
      home: StatefulBuilder(
        builder: (BuildContext context, StateSetter s) {
          set = s;
          return AylaPanelSwap(
            identity: id,
            enabled: enabled,
            child: const SizedBox(width: 100, height: 40),
          );
        },
      ),
    )));
    set(() {
      enabled = false;
      id = 'b';
    });
    await tester.pump();
    expect(sample(tester).opacity, 1, reason: 'not-ready 期间不播');
    set(() => enabled = true);
    await tester.pump();
    expect(sample(tester).opacity, lessThan(0.1), reason: 'tab 档 not-ready 后应变 ready 补播');
  });

  testWidgets('reduced-motion：直通子树、不建动画层', (WidgetTester tester) async {
    await tester.pumpWidget(previewScope(
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          home: AylaPanelSwap(
            identity: 'a',
            child: SizedBox(width: 100, height: 40),
          ),
        ),
      ),
    ));
    expect(
      find.descendant(of: find.byType(AylaPanelSwap), matching: find.byType(Opacity)),
      findsNothing,
    );
  });
}
