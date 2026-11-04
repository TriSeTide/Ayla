/// 宽屏主页**第一列（群头像侧栏）入场动画**的行为锁 —— 2026-11-02 用户实报修复。
///
/// ## 用户口径（原文两轮）
/// 1. 「修复 Ayla Flutter 主页群聊界面第一列群头像侧栏的滑入动画，滑入行为要与 web 端一致」；
/// 2. 「在主页切换群聊时第一列侧栏不播放动画，只修进入和离开主页时的播放」。
///
/// ## 行为矩阵（本文件逐条锁住）
///
/// | 场景 | 第一列是否播入场 |
/// |---|---|
/// | 进入主页（含从别的页面回来、含冷启动） | **播**（x −20 → 0 + 淡入，300ms easeInOut） |
/// | 主页内**切群**（`/group/a → /group/b`） | **不播** |
/// | 主页内**切场景**（`/group/a → /group/a/voice`） | **不播** |
/// | 离开主页 | 随页面一起消失（web 同：外壳整个卸载） |
///
/// 判据取**真实路由 + 真实主题 + 1440×900**（与 `router_test` / `group_page_shell_test` 同源），
/// 量的是第一列玻璃件的**全局左边距**：播入场时它从 12−20 = **−8** 起步，
/// 终值 **12**（`AylaServerRail.wideMargin` 的左 12）；不播则恒为 12。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/app_init.dart';
import '../lib/layout/app_gate.dart';
import '../lib/router/app_router.dart';
import '../lib/state/auth_state.dart';
import '../lib/theme/app_theme.dart';
import '../lib/theme/glass.dart' show AylaGlassSurface;
import '../lib/widgets/shell/server_rail.dart';

/// 第一列玻璃列的**全局左边距**（NaN = 不在树上）。
double railLeft(WidgetTester tester) {
  final Finder glass = find.descendant(
    of: find.byType(AylaServerRail, skipOffstage: false),
    matching: find.byType(AylaGlassSurface, skipOffstage: false),
    skipOffstage: false,
  );
  if (glass.evaluate().isEmpty) return double.nan;
  return tester.getTopLeft(glass.first).dx;
}

/// 第一列入场的**起笔值**（web `panelVariants(reduced,'left')` 的 −20 位移）。
const double _enterStartLeft = 12 - 20;

/// 第一列入场的终值（`AylaServerRail.wideMargin` 的左边距 12）。
const double _restLeft = 12;

Future<({ProviderContainer container, GoRouter router, Completer<void>? gate})>
    _boot(WidgetTester tester, {bool gated = false}) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(const Size(1440, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  Completer<void>? gate;
  if (gated) {
    gate = Completer<void>();
    aylaCoreDataLoader = (String? _) => gate!.future;
    addTearDown(AppInit.instance.reset);
    unawaited(AppInit.instance.run(userId: 'u1'));
  }

  final ProviderContainer container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(authNotifierProvider.notifier).setTokens('access', 'refresh');
  final GoRouter router = container.read(appRouterProvider);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        // 必须真实主题（否则平台转场会叠进来，见 `router_test` 文件头）。
        theme: buildAylaTheme(),
        builder: (BuildContext context, Widget? child) => Scaffold(
          backgroundColor: Colors.transparent,
          body: gated
              ? AylaAppGate(page: child ?? const SizedBox.shrink())
              : (child ?? const SizedBox.shrink()),
        ),
      ),
    ),
  );
  if (!gated) await tester.pumpAndSettle();
  return (container: container, router: router, gate: gate);
}

/// 逐帧采样左边的取值集合（用于判定「有没有播位移」）。
Future<Set<double>> _sampleLefts(
  WidgetTester tester,
  int frames, {
  Duration step = const Duration(milliseconds: 16),
}) async {
  final Set<double> seen = <double>{};
  for (int i = 0; i < frames; i += 1) {
    await tester.pump(step);
    final double left = railLeft(tester);
    if (!left.isNaN) seen.add(double.parse(left.toStringAsFixed(1)));
  }
  return seen;
}

void main() {
  testWidgets('进入主页：第一列播入场（−20 左入 → 归位）', (WidgetTester tester) async {
    final ({ProviderContainer container, GoRouter router, Completer<void>? gate})
        app = await _boot(tester);

    app.router.go('/group/g1');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      railLeft(tester),
      closeTo(_enterStartLeft, 0.6),
      reason: '进入主页的第一帧，第一列应处在 −20 的入场起笔位',
    );

    final Set<double> seen = await _sampleLefts(tester, 24);
    expect(seen.length, greaterThan(3), reason: '应有连续位移帧（不是一帧跳变）：$seen');

    await tester.pumpAndSettle();
    expect(railLeft(tester), closeTo(_restLeft, 0.01), reason: '入场结束必须精确归位到 12');
  });

  testWidgets('主页内切群：第一列**不**播入场（位移恒为终值）', (WidgetTester tester) async {
    final ({ProviderContainer container, GoRouter router, Completer<void>? gate})
        app = await _boot(tester);
    app.router.go('/group/g1');
    await tester.pumpAndSettle();
    expect(railLeft(tester), closeTo(_restLeft, 0.01));

    app.router.go('/group/g2');
    await tester.pump();
    final Set<double> seen = await _sampleLefts(tester, 24);
    expect(
      seen,
      <double>{_restLeft},
      reason: '切群时第一列是**选项卡**语义（web ServerRail 无 key、motion owner 不重挂）'
          '⇒ 位移只应是终值 12，出现的其他取值都是「又滑入了一次」：$seen',
    );
  });

  testWidgets('主页内切场景：第一列**不**播入场', (WidgetTester tester) async {
    final ({ProviderContainer container, GoRouter router, Completer<void>? gate})
        app = await _boot(tester);
    app.router.go('/group/g1');
    await tester.pumpAndSettle();

    app.router.go('/group/g1/voice');
    await tester.pump();
    final Set<double> seen = await _sampleLefts(tester, 24);
    expect(
      seen,
      <double>{_restLeft},
      reason: '切场景同样复用同一个宽屏外壳（PageTransition 把 /group/* 归一成 wide-group-shell）'
          '⇒ 第一列不得重播入场：$seen',
    );
  });

  testWidgets('离开主页再回来：第一列**重新**播入场（web 外壳重挂）', (WidgetTester tester) async {
    final ({ProviderContainer container, GoRouter router, Completer<void>? gate})
        app = await _boot(tester);
    app.router.go('/group/g1');
    await tester.pumpAndSettle();

    // 离开主页（一级 tab 页 ⇒ 群工作区外壳整体卸载，与 web 同）。
    app.router.go('/voice');
    await tester.pumpAndSettle();
    expect(
      find.byType(AylaServerRail, skipOffstage: false),
      findsNothing,
      reason: '离开主页后第一列必须不在树上（不是 offstage 留着——那会吃掉下一次入场）',
    );

    app.router.go('/group/g1');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      railLeft(tester),
      closeTo(_enterStartLeft, 0.6),
      reason: '回到主页是一个**新的**外壳生命周期 ⇒ 必须重新播入场',
    );
    await tester.pumpAndSettle();
    expect(railLeft(tester), closeTo(_restLeft, 0.01));
  });

  /// ⚠️ 冷启动：全屏预加载门用 `Offstage` 盖住路由子树，而 **Offstage 不绘制但动画照跑**
  /// （`Offstage` 官方文档原文：“Animations continue to run in offstage children”）。
  /// 修前实测：门关闭期间入场就跑完了，门一开用户看到的是静止的终态。
  /// ⇒ 页面在门盖着时**推迟**抬起开关，等 `AppInit` 离开 loading 那一帧再播。
  testWidgets('冷启动：入场等到预加载门打开那一帧才播（不被门吃掉）', (WidgetTester tester) async {
    final ({ProviderContainer container, GoRouter router, Completer<void>? gate})
        app = await _boot(tester, gated: true);
    app.router.go('/group/g1');
    // 门开着：跑够 480ms（远超过 300ms 入场时长，若此刻就播，门开后已无位移可看）。
    for (int i = 0; i < 30; i += 1) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      railLeft(tester),
      closeTo(_restLeft, 0.01),
      reason: '门关着时第一列应停在终值（冻结），而不是已经在看不见的地方跑完',
    );

    app.gate!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      railLeft(tester),
      closeTo(_enterStartLeft, 0.6),
      reason: '门打开的瞬间必须才开始播入场（用户此刻才看得见）',
    );

    final Set<double> seen = await _sampleLefts(tester, 24);
    expect(seen.length, greaterThan(3), reason: '应有连续位移帧：$seen');
    await tester.pumpAndSettle();
    expect(railLeft(tester), closeTo(_restLeft, 0.01));
  });
}
