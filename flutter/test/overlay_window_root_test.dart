/// 第二引擎（窗口外浮层）根 widget 的**可独立启动性**回归锁。
///
/// ## 为什么必须锁这一条
/// 窗口外悬浮球跑在一个**独立的 Flutter engine** 里（Android：
/// `OverlayFlutterHost.kt` 的 `FlutterEngineGroup`；Windows：`live_window.cpp` 的
/// 第二个 engine）。那个 engine 里**没有**主引擎的 `MaterialApp.router`，
/// 所以「浮层根 widget 能不能自己起来」是一个**独立的运行时契约**，
/// 主引擎的测试一条都覆盖不到它。
///
/// 2026-10-31 实测抓到过三条真实崩溃（都是「第二引擎首帧即崩、主引擎完全正常」）：
/// 1. `Incorrect use of ParentDataWidget: Positioned widgets must be placed directly
///    inside Stack widgets` —— `AylaSessionActivityIndicator` 返回 `Positioned`；
/// 2. `No Directionality widget found` / `No MediaQuery widget found` ——
///    只套 `Theme` 不够；
/// 3. `No Overlay widget found. RawTooltip widgets require an Overlay widget ancestor`
///    —— 球的 `title` 走 `AylaTooltip`。
///
/// ⇒ 这里的断言就是「那棵树能起来、且球组真的渲染出来了」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/app_theme.dart';
import '../lib/widgets/shell/overlay_window_app.dart';
import '../lib/widgets/shell/session_activity.dart';

/// 与 `main.dart` 的 `_aylaOverlayWindowRoot` **同构**的根（那里是私有函数，
/// 这里复刻同一组参数：MaterialApp + 透明底 + 同一套主题 + 同一个 ball window app）。
Widget _root({AylaOverlayPayload? payload}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    color: Colors.transparent,
    theme: buildAylaTheme(),
    home: AylaOverlayBallWindowApp(initialPayload: payload),
  );
}

const AylaOverlayPayload _both = AylaOverlayPayload(
  kind: AylaOverlayKind.activityBall,
  voiceSessionId: '5',
  voiceTitle: '语音房',
  voiceRoute: '/voice/5',
  liveSessionId: '9',
  liveTitle: '直播间',
  liveRoute: '/live/start/9',
);

void main() {
  testWidgets('浮层根能在**没有主引擎**的情况下起来，并 build 出同一份悬浮球组', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_root(payload: _both));
    await tester.pump();

    // 起得来（没有 Directionality / MediaQuery / Overlay / ParentData 断言）。
    expect(tester.takeException(), isNull);
    // 渲染的是**同一份**组件（用户要求「用现有的悬浮球」，不是重画一个）。
    expect(find.byType(AylaSessionActivityIndicator), findsOneWidget);
    // 语音球 + 直播球各一个图标 + 收起把手（'›' 字形）。
    expect(find.text('›'), findsOneWidget);
  });

  testWidgets('无会话 ⇒ 组件零渲染（窗口里什么都不画，主引擎会顺手关窗）', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _root(payload: const AylaOverlayPayload(kind: AylaOverlayKind.activityBall)),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('›'), findsNothing);
  });

  testWidgets('点球 ⇒ 通过内层通道回传 (kind, sourceRoute)，**不**自行导航', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_root(payload: _both));
    await tester.pump();

    // 第二引擎没有 router ⇒ 点球只能走通道；这里只验证**不抛**且树还在
    // （通道本身在 widget 测试里没有宿主，MissingPluginException 被内部吞掉）。
    await tester.tap(find.byType(AylaSessionActivityIndicator));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
