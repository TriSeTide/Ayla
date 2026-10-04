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

/// reduced 档的子件构建（顶层函数：`MediaQuery` const 宿主里不能用闭包）。
Widget _reducedBuilder(BuildContext context, String identity) =>
    const Center(child: Text('空会话'));

/// [AylaPrimaryNavPage] 当前的**显示位移**（沿包装链累加 `Transform` 的 x 平移）。
///
/// 与「跟手弹性」用例同一取法：本件的树是
/// `AnimatedBuilder > Opacity > Transform.translate > GestureDetector > child`，
/// 只有一层 Transform，累计值即 `dragElastic × 原始位移`。
double _navDx(WidgetTester tester) {
  double dx = 0;
  for (final Transform tr in tester.widgetList<Transform>(
    find.descendant(
      of: find.byType(AylaPrimaryNavPage),
      matching: find.byType(Transform),
    ),
  )) {
    dx += tr.transform.storage[12];
  }
  return dx;
}

/// [AylaPrimaryNavPage] 方向变体进场的**可见度**（最外层 `Opacity` 的值）。
double _navOpacity(WidgetTester tester) {
  final Iterable<Opacity> all = tester.widgetList<Opacity>(
    find.descendant(
      of: find.byType(AylaPrimaryNavPage),
      matching: find.byType(Opacity),
    ),
  );
  return all.isEmpty ? 1 : all.first.opacity;
}

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

    testWidgets('退场：位移 0 → +20（web exit = offset(exitEdge)，**不许先瞬跳 ±20 再滑回**）', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<bool> show = ValueNotifier<bool>(true);
      addTearDown(show.dispose);
      await tester.pumpWidget(
        host(
          ValueListenableBuilder<bool>(
            valueListenable: show,
            builder: (BuildContext context, bool v, Widget? _) =>
                AylaPanelTransition(
                  show: v,
                  edge: AylaPanelEdge.right,
                  child: const SizedBox(height: 50, child: Text('面板')),
                ),
          ),
        ),
      );
      await tester.pump(kAylaPanelDuration); // 进场走完
      await tester.pump();

      double dx() => tester
          .widget<Transform>(
            find.descendant(
              of: find.byType(AylaPanelTransition),
              matching: find.byType(Transform),
            ),
          )
          .transform
          .storage[12];
      double opacity() => tester
          .widget<Opacity>(
            find.descendant(
              of: find.byType(AylaPanelTransition),
              matching: find.byType(Opacity),
            ),
          )
          .opacity;

      expect(dx(), closeTo(0, 0.01)); // center
      expect(opacity(), closeTo(1, 0.01));

      show.value = false;
      await tester.pump(); // 翻转帧（didUpdateWidget ⇒ reverse 刚起步，v 仍 ≈ 1）
      // ⚠️ 回归锁：旧实现此处是 20*1 = +20（瞬跳），修后是 20*(1-1) = 0
      expect(
        dx(),
        closeTo(0, 1.0),
        reason: '退场首帧必须还在 center（0），不能瞬跳到 ±20（web auroraquaMotion.ts:49）',
      );

      await tester.pump(const Duration(milliseconds: 150)); // easeInOut 中点
      expect(dx(), closeTo(kAylaPanelDistance / 2, 1.0));
      expect(opacity(), closeTo(0.5, 0.05));

      await tester.pump(const Duration(milliseconds: 200)); // 走完 300ms
      expect(dx(), closeTo(kAylaPanelDistance, 0.01)); // 停在 exitEdge 的 +20
      expect(opacity(), closeTo(0, 0.01));
    });

    testWidgets('退场到相反边：edge=right / exitEdge=left ⇒ 位移 0 → −20', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<bool> show = ValueNotifier<bool>(true);
      addTearDown(show.dispose);
      await tester.pumpWidget(
        host(
          ValueListenableBuilder<bool>(
            valueListenable: show,
            builder: (BuildContext context, bool v, Widget? _) =>
                AylaPanelTransition(
                  show: v,
                  edge: AylaPanelEdge.right,
                  exitEdge: AylaPanelEdge.left,
                  child: const SizedBox(height: 50, child: Text('面板')),
                ),
          ),
        ),
      );
      await tester.pump(kAylaPanelDuration);
      await tester.pump();

      show.value = false;
      await tester.pump();
      await tester.pump(kAylaPanelDuration);
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

    testWidgets('panels:false（空会话态）⇒ 宿主自己播：挂载从 +20/透明进到 center', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaConversationTransition(
            identity: 'empty',
            panels: false,
            builder: (BuildContext context, String identity) =>
                const Center(child: Text('空会话')),
          ),
        ),
      );
      await tester.pump(); // 首帧（didChangeDependencies 已 forward(from 0)）
      Transform tr() => tester.widget<Transform>(
        find.descendant(
          of: find.byType(AylaConversationTransition),
          matching: find.byType(Transform),
        ),
      );
      Opacity op() => tester.widget<Opacity>(
        find.descendant(
          of: find.byType(AylaConversationTransition),
          matching: find.byType(Opacity),
        ),
      );
      expect(tr().transform.storage[12], closeTo(kAylaPanelDistance, 1.0)); // 右 +20
      expect(op().opacity, closeTo(0, 0.05));

      await tester.pump(kAylaPanelDuration);
      await tester.pump();
      expect(tr().transform.storage[12], closeTo(0, 0.01)); // center
      expect(op().opacity, closeTo(1, 0.01));
    });

    testWidgets('panels:false ⇒ 旧件退场往左 −20 淡出，退完才挂新件', (
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
                  panels: false,
                  builder: (BuildContext context, String identity) =>
                      Center(child: Text('会话 $identity')),
                ),
          ),
        ),
      );
      await tester.pump(kAylaPanelDuration); // 首次进场走完
      await tester.pump();

      id.value = 'c2';
      await tester.pump();
      await tester.pump();
      // 退出中：旧件在、新件未挂（mode="wait"）
      expect(find.text('会话 c1'), findsOneWidget);
      expect(find.text('会话 c2'), findsNothing);

      double dxOf() => tester
          .widget<Transform>(
            find.descendant(
              of: find.byType(AylaConversationTransition),
              matching: find.byType(Transform),
            ),
          )
          .transform
          .storage[12];
      double opOf() => tester
          .widget<Opacity>(
            find.descendant(
              of: find.byType(AylaConversationTransition),
              matching: find.byType(Opacity),
            ),
          )
          .opacity;

      expect(dxOf(), closeTo(0, 1.0), reason: '退场首帧仍在 center（不瞬跳）');
      await tester.pump(const Duration(milliseconds: 150));
      expect(dxOf(), closeTo(-kAylaPanelDistance / 2, 1.5)); // 往左走（−10）
      expect(opOf(), closeTo(0.5, 0.05));
      await tester.pump(const Duration(milliseconds: 140)); // t=290，退场接近走完
      expect(dxOf(), lessThan(-15), reason: '旧件已大幅左移（目标 −20）');
      expect(opOf(), lessThan(0.2));

      await tester.pumpAndSettle(); // 退完 ⇒ 监听器挂新件并播进场（新件从 +20 进）
      expect(find.text('会话 c2'), findsOneWidget);
      expect(find.text('会话 c1'), findsNothing);
      expect(dxOf(), closeTo(0, 0.01), reason: '新件进场落点为 center');
    });

    testWidgets('panels:false + reduced-motion ⇒ 位移 0、不淡入（时长 0）', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: previewScope(
            const MediaQuery(
              data: MediaQueryData(
                size: Size(360, 300),
                disableAnimations: true,
              ),
              child: SizedBox(
                width: 360,
                height: 300,
                child: AylaConversationTransition(
                  identity: 'empty',
                  panels: false,
                  builder: _reducedBuilder,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final Transform tr = tester.widget<Transform>(
        find.descendant(
          of: find.byType(AylaConversationTransition),
          matching: find.byType(Transform),
        ),
      );
      final Opacity op = tester.widget<Opacity>(
        find.descendant(
          of: find.byType(AylaConversationTransition),
          matching: find.byType(Opacity),
        ),
      );
      expect(tr.transform.storage[12], 0); // distance = 0（reduced）
      expect(op.opacity, 1); // enter opacity = reduced ? 1 : 0
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

    testWidgets('松手未提交 ⇒ **200ms 动画回弹**（不是瞬时归零；审查 BUG-1）', (
      WidgetTester tester,
    ) async {
      // 事实源：web `PrimaryNavPage.tsx:27–30` 的 `dragConstraints={{0,0}}` +
      // `dragSnapToOrigin` —— framer-motion 的 constraints 回弹是 **spring 动画**，
      // 不是瞬时归零；量程取同文件 `AylaFullScreenSwipeBack._onEnd` 的 200ms 回弹
      // （`gestures.dart:504–512`，web `SPRING_BACK_DURATION` = 0.2s）。
      //
      // 修改前实测：松手那一帧位移由 80px 直接塌到 0（跳变），本用例会红。
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
      expect(_navDx(tester), closeTo(80, 2), reason: '跟手：100 × 0.8');

      await g.up();
      await tester.pump(); // 松手帧：回弹起手（位移仍在起点附近）
      await tester.pump(const Duration(milliseconds: 100)); // 200ms 的半程
      final double mid = _navDx(tester);
      expect(
        mid,
        greaterThan(2),
        reason: '松手后必须是**动画**：半程仍应明显偏离 0（瞬时归零 ⇒ 这里恒为 0）',
      );
      expect(
        mid,
        lessThan(76),
        reason: '半程应已明显离开起点（80px）向 0 收敛',
      );

      await tester.pumpAndSettle();
      expect(_navDx(tester), closeTo(0, 1), reason: '200ms 走完后归零');
    });

    testWidgets('direction 不变但 replayKey 变化 ⇒ 重播进场（web key={pathname}；审查 BUG-2）', (
      WidgetTester tester,
    ) async {
      // web `AppShell.tsx:116` 每次都换 `key={pathname}` ⇒ 每次路由变化必播；
      // Flutter 侧用一个 State 承载 ⇒ 用 `replayKey` 表达同一语义。
      // 只比较 direction 时，连续两次同方向切换的第二次不会重播（本用例的判据）。
      //
      // ⚠️ 驱动方式与本文件其它用例同法：`ValueNotifier` + `ValueListenableBuilder`
      //（第二次 `pumpWidget` 不会更新 `MaterialApp.home` 已经建立的 route child）。
      final ValueNotifier<String> key = ValueNotifier<String>('/live');
      addTearDown(key.dispose);
      await tester.pumpWidget(
        host(
          ValueListenableBuilder<String>(
            valueListenable: key,
            builder: (BuildContext context, String v, Widget? _) =>
                AylaPrimaryNavPage(
                  direction: 1,
                  replayKey: v,
                  child: const SizedBox(
                    height: 200,
                    child: Center(child: Text('一级页')),
                  ),
                ),
          ),
          width: 360,
        ),
      );
      await tester.pumpAndSettle();
      expect(_navOpacity(tester), closeTo(1, 0.01));

      // 同方向再切一次（direction 不变），只换 replayKey ⇒ 必须重播（回到 opacity 0 起）
      key.value = '/posts';
      await tester.pump();
      await tester.pump();
      expect(
        _navOpacity(tester),
        lessThan(0.5),
        reason: '重播判据必须包含 replayKey：否则 direction 相同 ⇒ 停在终态、无动画',
      );
      await tester.pumpAndSettle();
      expect(_navOpacity(tester), closeTo(1, 0.01));
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
