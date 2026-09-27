/// 手势与转场族定向测试 —— 对照 `auroraquaMotion.ts` / `useSwipeCommit.ts` / `useEdgeSwipeBack.ts` /
/// `ConversationTransition.tsx` / `FullScreenSwipeBack.tsx` / `PrimaryNavPage.tsx`。
///
/// 覆盖：松手判定三条规则（阈值优先 / 甩动补充 / 方向锁让位）· 面板四向进场位移与透明度 ·
/// `mode="wait"` 宿主（旧件先退、退出中不可点、退完挂最新件）· 右滑返回（过阈值 / 不过阈值回弹 / 快速甩）·
/// 横滑切页（过 1/3 宽 ⇒ onNavigate）。
/// ⚠️ 一态一用例；手势用 `tester.timedDrag` / `flingFrom` 驱动。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/preview_theme.dart';
import '../lib/widgets/motion/gestures.dart';

void main() {
  Widget host(Widget child, {double width = 360}) => MaterialApp(
    home: previewScope(
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, height: 300, child: child),
      ),
    ),
  );

  group('aylaResolveSwipeCommit（useSwipeCommit.ts 32–36 / 79）', () {
    test('净位移 ≥ 宽/3 ⇒ 按方向判定（web：左滑 = +1 = next）', () {
      expect(
        aylaResolveSwipeCommit(net: -130, cross: 0, velocity: 0, size: 360),
        1, reason: '手指左滑 ⇒ forward ⇒ +1（下一项）',
      );
      expect(
        aylaResolveSwipeCommit(net: 130, cross: 0, velocity: 0, size: 360),
        -1, reason: '手指右滑 ⇒ -1（上一项）',
      );
      expect(
        aylaResolveSwipeCommit(net: 60, cross: 0, velocity: 0, size: 360),
        0,
      );
    });

    test('位移不足但同向甩动（≥300px/s 且 ≥40px）⇒ 判定；反向甩不判定', () {
      expect(
        aylaResolveSwipeCommit(net: -50, cross: 0, velocity: -400, size: 360),
        1,
      );
      expect(
        aylaResolveSwipeCommit(net: -20, cross: 0, velocity: -400, size: 360),
        0, reason: '位移太小（<40）',
      );
      expect(
        aylaResolveSwipeCommit(net: -50, cross: 0, velocity: 400, size: 360),
        0, reason: 'web 要求 sign(velocity) === sign(net)（反向甩不算）',
      );
    });

    test('方向锁让位：跨轴位移占优 ⇒ 不判定', () {
      expect(
        aylaResolveSwipeCommit(net: 130, cross: 200, velocity: 500, size: 360),
        0,
      );
    });
  });

  group('AylaPanelTransition（panelVariants：±20 / 300ms）', () {
    testWidgets('右滑入：首帧在 +20、透明；到点归零', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaPanelTransition(
            edge: AylaPanelEdge.right,
            child: SizedBox(height: 50, child: Text('面板')),
          ),
        ),
      );
      await tester.pump();
      final Transform tr = tester.widget<Transform>(
        find.descendant(
          of: find.byType(AylaPanelTransition),
          matching: find.byType(Transform),
        ),
      );
      expect(tr.transform.storage[12], closeTo(kAylaPanelDistance, 0.01)); // +20
      expect(
        tester
            .widget<Opacity>(
              find.descendant(
                of: find.byType(AylaPanelTransition),
                matching: find.byType(Opacity),
              ),
            )
            .opacity,
        0,
      );
      await tester.pump(kAylaPanelDuration);
      final Transform done = tester.widget<Transform>(
        find.descendant(
          of: find.byType(AylaPanelTransition),
          matching: find.byType(Transform),
        ),
      );
      expect(done.transform.storage[12], closeTo(0, 0.01));
    });

    testWidgets('左滑入首帧在 −20（四方向各自符号正确）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaPanelTransition(
            edge: AylaPanelEdge.left,
            child: SizedBox(height: 50, child: Text('面板')),
          ),
        ),
      );
      await tester.pump();
      final Transform tr = tester.widget<Transform>(
        find.descendant(
          of: find.byType(AylaPanelTransition),
          matching: find.byType(Transform),
        ),
      );
      expect(tr.transform.storage[12], closeTo(-kAylaPanelDistance, 0.01));
    });
  });

  group('AylaConversationTransition（AnimatePresence mode="wait" 等价）', () {
    testWidgets('切 identity：旧件先退（300ms 内新件未挂），退完挂最新件', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<String> id = ValueNotifier<String>('c1');
      addTearDown(id.dispose);
      await tester.pumpWidget(
        host(
          ValueListenableBuilder<String>(
            valueListenable: id,
            builder: (BuildContext context, String v, Widget? _) =>
                AylaConversationTransition(
                  identity: v,
                  builder: (BuildContext context, String identity) =>
                      Center(child: Text('会话 $identity')),
                ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('会话 c1'), findsOneWidget);

      id.value = 'c2';
      await tester.pump();
      await tester.pump();
      // 退出中：旧件仍在、新件**未挂**（mode="wait"）
      expect(find.text('会话 c1'), findsOneWidget);
      expect(find.text('会话 c2'), findsNothing);

      await tester.pump(kAylaPanelDuration); // 退出走完 ⇒ 监听器挂新件
      await tester.pumpAndSettle(); // 新件进场也走完
      expect(find.text('会话 c2'), findsOneWidget);
      expect(find.text('会话 c1'), findsNothing);
    });
  });

  group('AylaFullScreenSwipeBack（useEdgeSwipeBack：120px / 300px/s）', () {
    testWidgets('右滑 ≥120px ⇒ 触发 onBack', (WidgetTester tester) async {
      int back = 0;
      await tester.pumpWidget(
        host(
          AylaFullScreenSwipeBack(
            onBack: () => back++,
            child: const SizedBox(
              height: 200,
              child: Center(child: Text('页面')),
            ),
          ),
        ),
      );
      await tester.drag(find.text('页面'), const Offset(160, 0));
      await tester.pumpAndSettle();
      expect(back, 1);
    });

    testWidgets('右滑不足且慢 ⇒ 回弹、不触发', (WidgetTester tester) async {
      int back = 0;
      await tester.pumpWidget(
        host(
          AylaFullScreenSwipeBack(
            onBack: () => back++,
            child: const SizedBox(
              height: 200,
              child: Center(child: Text('页面')),
            ),
          ),
        ),
      );
      await tester.timedDrag(
        find.text('页面'),
        const Offset(60, 0),
        const Duration(milliseconds: 600), // 慢拖 ⇒ 速度低
      );
      await tester.pumpAndSettle();
      expect(back, 0);
    });

    testWidgets('enabled=false ⇒ 手势关闭（滑了也不返回）', (WidgetTester tester) async {
      int back = 0;
      await tester.pumpWidget(
        host(
          AylaFullScreenSwipeBack(
            enabled: false,
            onBack: () => back++,
            child: const SizedBox(
              height: 200,
              child: Center(child: Text('页面')),
            ),
          ),
        ),
      );
      await tester.drag(find.text('页面'), const Offset(200, 0));
      await tester.pumpAndSettle();
      expect(back, 0);
    });
  });

  group('AylaPrimaryNavPage（PrimaryNavPage.tsx：1/3 宽判定 + 弹性 .8）', () {
    testWidgets('web 语义：手指从右向左滑过 1/3 宽 ⇒ onNavigate(+1)（下一项）', (
      WidgetTester tester,
    ) async {
      final List<int> log = <int>[];
      await tester.pumpWidget(
        host(
          AylaPrimaryNavPage(
            direction: 0,
            onNavigate: log.add,
            child: const SizedBox(
              height: 200,
              child: Center(child: Text('一级页')),
            ),
          ),
          width: 360,
        ),
      );
      await tester.timedDrag(
        find.text('一级页'),
        const Offset(-200, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      expect(log, <int>[1], reason: 'web `forward = net < 0` ⇒ 左滑 = +1 = 下一项');
    });

    testWidgets('两方向落点符合「左滑上一页 / 右滑下一页」+ 首页环绕', (
      WidgetTester tester,
    ) async {
      // 用户规则 = web 映射：`commit = 手指右移 ? +1 : -1`，落到 `(idx + commit + len) % len`
      int tab = 1; // 从中间页起，两方向都能动
      const List<String> tabs = <String>['首页', '语音', '直播'];
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (BuildContext context, StateSetter set) => AylaPrimaryNavPage(
              key: ValueKey<int>(tab),
              direction: 0,
              // onNavigate 是**步进**语义：+1 = 下一页
              onNavigate: (int step) => set(
                () => tab = (tab + step + tabs.length) % tabs.length,
              ),
              child: Center(child: Text('第 ${tab + 1} 页 · ${tabs[tab]}')),
            ),
          ),
          width: 360,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('第 2 页 · 语音'), findsOneWidget);

      // 手指从右向左滑 ⇒ **下一页**（用户规则；此前实现反了）
      await tester.timedDrag(
        find.text('第 2 页 · 语音'),
        const Offset(-200, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      expect(find.text('第 3 页 · 直播'), findsOneWidget, reason: '从右向左滑应去下一页');

      // 手指从左向右滑 ⇒ **上一页**
      await tester.timedDrag(
        find.text('第 3 页 · 直播'),
        const Offset(200, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      expect(find.text('第 2 页 · 语音'), findsOneWidget, reason: '从左向右滑应回上一页');
    });

    testWidgets('跟手弹性：拖 100px 时显示位移 ≈80px（不得指数衰减到 0）', (
      WidgetTester tester,
    ) async {
      // 回归：早前把弹性乘进累计量 ⇒ 每帧 ×0.8、几帧归零，表现为「划不动」（用户实测）
      await tester.pumpWidget(
        host(
          const AylaPrimaryNavPage(
            direction: 0,
            child: SizedBox(
              height: 200,
              child: Center(child: Text('一级页')),
            ),
          ),
          width: 360,
        ),
      );
      final TestGesture g = await tester.startGesture(
        tester.getCenter(find.text('一级页')),
      );
      await g.moveBy(const Offset(100, 0));
      await tester.pump();
      double dx = 0;
      for (final Transform tr in tester.widgetList<Transform>(
        find.descendant(
          of: find.byType(AylaPrimaryNavPage),
          matching: find.byType(Transform),
        ),
      )) {
        dx += tr.transform.storage[12];
      }
      expect(dx, closeTo(80, 2)); // 100 × 0.8
      await g.up();
      await tester.pumpAndSettle();
    });

    testWidgets('小位移慢拖 ⇒ 不切页', (WidgetTester tester) async {
      final List<int> log = <int>[];
      await tester.pumpWidget(
        host(
          AylaPrimaryNavPage(
            direction: 0,
            onNavigate: log.add,
            child: const SizedBox(
              height: 200,
              child: Center(child: Text('一级页')),
            ),
          ),
          width: 360,
        ),
      );
      await tester.timedDrag(
        find.text('一级页'),
        const Offset(-40, 0),
        const Duration(milliseconds: 600),
      );
      await tester.pumpAndSettle();
      expect(log, isEmpty);
    });
  });
}
