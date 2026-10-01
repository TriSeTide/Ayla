/// 全屏预加载门 × 路由页面互斥装配的回归锁 —— 对照 web \`App.tsx:48–51\`。
///
/// ## 为什么必须锁「实绘尺寸」
/// 2026-10-01 用户实机：「**全屏加载界面那个转圈圈怎么没了**」。
/// 根因是 \`AylaAppGate\` 早期把门内嵌进一个**没设 \`fit\` 的 Stack**：
/// 默认 \`StackFit.loose\` 下 Stack 的尺寸由**非定位子级**决定，而门打开时唯一的
/// 非定位子级恰好是 **offstage 的 \`Offstage\`**（\`RenderOffstage\` 在 offstage 时
/// \`sizedByParent = true\`、\`computeDryLayout → constraints.smallest\`，
/// 见 \`rendering/proxy_box.dart:3896–3910\`）⇒ Stack 塌成 **0×0**
/// ⇒ \`Positioned.fill\` 的门被填成 0×0 ⇒ **整个门不可见**。
///
/// ⚠️ 该塌陷**只在门打开时**发生（正是需要它的时刻），ready 后页面一切正常
/// ⇒ 症状表现为「页面没事，只是加载界面没了」⇒ **只断言"门存在"会漏过**，
/// 必须断言门的**实绘尺寸 == 视口**。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/app_init.dart';
import '../lib/layout/app_gate.dart';
import '../lib/theme/app_theme.dart';
import '../lib/widgets/base/loading.dart' show AylaFullScreenLoader;

/// 在途的预加载（测试末尾必须 complete，否则 \`AppInit\` 的 20s 超时定时器会
/// 让 flutter_test 以 \`!timersPending\` 失败）。
Completer<void>? _pending;

/// 收尾：放开在途预加载 ⇒ 状态机走完 ⇒ 超时定时器被取消。
Future<void> _finishGate(WidgetTester tester) async {
  final Completer<void>? pending = _pending;
  _pending = null;
  pending?.complete();
  await tester.pump();
}

/// 把门置于指定状态（\`AppInit\` 是单例，测试间必须复位）。
Future<void> _pumpGate(
  WidgetTester tester, {
  required AppInitStatus status,
  bool showGallery = false,
  Size viewport = const Size(800, 600),
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(AppInit.instance.reset);

  // 用真实状态机驱动（而不是测试专用后门）：loading 只在「有在途预加载」时可达，
  // 用一个受控的 Completer 表达（测试末尾释放，见 _finishGate）。
  final Completer<void> pending = Completer<void>();
  _pending = pending;
  aylaCoreDataLoader = (String? _) => pending.future;
  if (status == AppInitStatus.loading) {
    unawaited(AppInit.instance.run(userId: 'u1'));
  } else if (status == AppInitStatus.ready) {
    aylaCoreDataLoader = (String? _) => Future<void>.value();
    await AppInit.instance.run(userId: 'u1');
  }

  await tester.pumpWidget(
    MaterialApp(
      theme: buildAylaTheme(),
      // ⚠️ **必须复现 main.dart 的真实嵌套**：本件在生产里嵌在一个默认（loose）的
      // `Stack` 里（`main.dart` 的 `AylaAuroraBackground > Stack`）。
      // 若直接把它当 `home:`（tight 约束），`constraints.constrain(Size(0,0))` 会被
      // tight 约束夹回视口尺寸 ⇒ **看起来没 bug**（2026-10-01 实测：去掉 fit 该用例仍绿）
      // ⇒ 锁就是假的。套一层 loose 容器后，内层 Stack 的 size 才会真的塌成 0×0。
      home: TickerMode(
        enabled: false,
        child: Stack(
          children: <Widget>[
            AylaAppGate(
              page: const ColoredBox(
                color: Color(0xFF00FF00),
                child: SizedBox.expand(key: ValueKey<String>('page')),
              ),
              showGallery: showGallery,
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('门打开：门实绘尺寸 == 视口（Stack 塌成 0×0 的回归锁）', (WidgetTester tester) async {
    await _pumpGate(tester, status: AppInitStatus.loading);

    final Finder gate = find.byType(AylaFullScreenLoader);
    expect(gate, findsOneWidget, reason: 'loading 时门必须显示');
    expect(
      tester.getSize(gate),
      const Size(800, 600),
      reason: '门必须铺满视口；若 Stack 未设 fit=expand，Offstage 会把它量成 0×0',
    );
    await _finishGate(tester);
  });

  testWidgets('门打开：路由页面 offstage 且不绘制（不串页）', (WidgetTester tester) async {
    await _pumpGate(tester, status: AppInitStatus.loading);

    // ⚠️ 直接取 AylaAppGate 内的那个 Offstage：不能用 page 的 key 反查 ——
    // offstage 的子树会被 deactivate，ancestor 查找拿不到它。
    final Offstage offstage = tester.widget<Offstage>(
      find.descendant(
        of: find.byType(AylaAppGate),
        matching: find.byType(Offstage),
      ),
    );
    expect(offstage.offstage, isTrue, reason: 'loading 时页面必须 offstage（web 是根本不渲染 Routes）');
    await _finishGate(tester);
  });

  testWidgets('ready：页面可见、门消失', (WidgetTester tester) async {
    await _pumpGate(tester, status: AppInitStatus.ready);

    expect(find.byType(AylaFullScreenLoader), findsNothing);
    final Offstage offstage = tester.widget<Offstage>(
      find.descendant(
        of: find.byType(AylaAppGate),
        matching: find.byType(Offstage),
      ),
    );
    expect(offstage.offstage, isFalse);
    expect(find.byKey(const ValueKey<String>('page')), findsOneWidget);
    await _finishGate(tester);
  });

  testWidgets('画布态：页面退场、门不显示（与改动前一致）', (WidgetTester tester) async {
    await _pumpGate(tester, status: AppInitStatus.loading, showGallery: true);

    expect(find.byType(AylaFullScreenLoader), findsNothing);
    await _finishGate(tester);
  });
}
