/// 窄屏一级五页横滑接线测试（审查报告 **A1** + **BUG-1/BUG-2**）。
///
/// 事实源：
/// - `AppShell.tsx:113–128` —— `primaryTabNarrow ? <PrimaryNavPage …>{outlet}</PrimaryNavPage>
///   : <PageTransition …>`（**二选一分支**）；
/// - `AppShell.tsx:60` —— `primaryTabNarrow = isNarrow && isPrimaryTabPath(pathname)`；
/// - `AppShell.tsx:116` —— `key={pathname}`（每次切换重挂 ⇒ 必播）；
/// - `PrimaryNavPage.tsx:57–76` —— 松手判定 `resolveSwipeCommit` +
///   落点 `PRIMARY_TAB_PATHS[(idx + commit + len) % len]`；
/// - `usePrimaryNavSwipeDirection.ts:18–35` —— direction 由一级 tab 顺序索引差给出。
///
/// Flutter 侧此前**零调用点**（全 lib 仅定义与画布样张引用）⇒ 窄屏用户在五个一级页
/// 之间无法横滑。本测试钉住「已接线」，以及三条判据：
/// ① 窄屏一级 tab ⇒ 挂 `AylaPrimaryNavPage`；② **宽屏不挂**（既有转场路径不变）；
/// ③ 左滑 = 下一项；④ 同方向连切必重播（`replayKey`）。
///
/// ⚠️ 宿主走**最小路由**（与 `app_shell_fabs_test` 同法）：不引真实页面树。
/// 真实页面（`/live` 的 `LiveHubPage.initState` 等）带着既有的
/// `setState() during build` 噪声（`home_page.dart:159–170` 的订阅注销时机），
/// 会把「壳层行为」的判据淹没在无关异常里；壳层的判据只依赖 `pathname` + 视口宽。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/layout/app_shell.dart';
import '../lib/router/shell_config.dart';
import '../lib/state/auth_state.dart';
import '../lib/theme/app_theme.dart';
import '../lib/widgets/motion/gestures.dart'
    show AylaPrimaryNavPage, kAylaDragElastic;
import '../lib/widgets/shell/bottom_tabs.dart' show AylaPrimaryModule;

/// 一级五页的**最小页面**（每条路由一个可识别的文本）。
Widget pageFor(AylaPrimaryModule m) =>
    Center(child: Text('一级页 ${m.path}', key: ValueKey<String>(m.path)));

/// 启动最小壳层路由（375×812 窄屏 / 1440×900 宽屏）。
Future<GoRouter> pumpShell(WidgetTester tester, Size size, String location) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final ProviderContainer container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(authNotifierProvider.notifier).setTokens('access', 'refresh');
  final GoRouter router = GoRouter(
    initialLocation: location,
    routes: <RouteBase>[
      GoRoute(path: '/messages', builder: (BuildContext c, GoRouterState s) => const SizedBox.shrink()),
      GoRoute(path: '/profile', builder: (BuildContext c, GoRouterState s) => const SizedBox.shrink()),
      ShellRoute(
        builder: (BuildContext context, GoRouterState state, Widget child) =>
            AppShell(child: child),
        routes: <RouteBase>[
          for (final AylaPrimaryModule m in aylaPrimaryTabOrder)
            GoRoute(
              path: m.path,
              builder: (BuildContext c, GoRouterState s) => pageFor(m),
            ),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: buildAylaTheme(),
        builder: (BuildContext context, Widget? child) => Scaffold(
          backgroundColor: Colors.transparent,
          body: child,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

Finder get navPage => find.byType(AylaPrimaryNavPage);

String pathOf(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.path;

/// 横滑容器当前的显示位移（沿包装链累加 `Transform` 的 x 平移）。
double navDx(WidgetTester tester) {
  double dx = 0;
  for (final Transform tr in tester.widgetList<Transform>(
    find.descendant(of: navPage, matching: find.byType(Transform)),
  )) {
    dx += tr.transform.storage[12];
  }
  return dx;
}

/// 横滑容器方向变体进场的可见度（最外层 `Opacity`）。
double navOpacity(WidgetTester tester) {
  final Iterable<Opacity> all = tester.widgetList<Opacity>(
    find.descendant(of: navPage, matching: find.byType(Opacity)),
  );
  return all.isEmpty ? 1 : all.first.opacity;
}

void main() {
  group('A1 接线判据（AppShell.tsx:60 / 113–128）', () {
    testWidgets('窄屏一级 tab（/live）⇒ 挂 AylaPrimaryNavPage', (WidgetTester tester) async {
      await pumpShell(tester, const Size(375, 812), '/live');
      expect(navPage, findsOneWidget, reason: 'AppShell.tsx:114 的 primaryTabNarrow 分支');
      expect(find.byKey(const ValueKey<String>('/live')), findsOneWidget);
    });

    testWidgets('**宽屏**一级 tab（/live）⇒ 不挂（既有路径不变）', (WidgetTester tester) async {
      await pumpShell(tester, const Size(1440, 900), '/live');
      expect(
        navPage,
        findsNothing,
        reason: 'AppShell.tsx:114 是二选一：宽屏走 PageTransition，不得挂横滑容器',
      );
      expect(find.byKey(const ValueKey<String>('/live')), findsOneWidget);
    });

    testWidgets('窄屏**非一级页**（/messages、/profile）⇒ 不挂', (WidgetTester tester) async {
      final GoRouter router = await pumpShell(tester, const Size(375, 812), '/messages');
      expect(navPage, findsNothing, reason: 'isPrimaryTabPath 只精确匹配一级路径');
      router.go('/profile');
      await tester.pumpAndSettle();
      expect(navPage, findsNothing, reason: '/profile 不是一级 tab');
    });
  });

  group('A1 落点与方向（PrimaryNavPage.tsx:57–76 / usePrimaryNavSwipeDirection.ts）', () {
    testWidgets('左滑 > 1/3 宽 ⇒ 主页 → 帖子（下一个）', (WidgetTester tester) async {
      final GoRouter router = await pumpShell(tester, const Size(375, 812), '/group');
      expect(navPage, findsOneWidget);
      // 375/3 = 125 ⇒ -200 过阈值；net < 0 ⇒ forward ⇒ +1 = 下一项。
      await tester.timedDrag(
        navPage,
        const Offset(-200, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      expect(pathOf(router), '/posts', reason: '主页索引 2 ⇒ +1 ⇒ posts');
    });

    testWidgets('右滑 > 1/3 宽 ⇒ 主页 → 直播（上一个）', (WidgetTester tester) async {
      final GoRouter router = await pumpShell(tester, const Size(375, 812), '/group');
      await tester.timedDrag(
        navPage,
        const Offset(200, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      expect(pathOf(router), '/live', reason: '主页索引 2 ⇒ -1 ⇒ live');
    });

    testWidgets('环绕：语音（索引 0）右滑 ⇒ 桌游（索引 4，末项）', (WidgetTester tester) async {
      final GoRouter router = await pumpShell(tester, const Size(375, 812), '/voice');
      await tester.timedDrag(
        navPage,
        const Offset(200, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      expect(pathOf(router), '/games', reason: 'PrimaryNavPage.tsx:72 的 (idx+commit+len)%len');
    });

    testWidgets('跟手弹性 .8 在壳层仍生效（kAylaDragElastic）', (WidgetTester tester) async {
      await pumpShell(tester, const Size(375, 812), '/group');
      // 拖在**内容**上（容器的中心即内容），避免命中 FAB。
      final TestGesture g = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey<String>('/group'))),
      );
      await g.moveBy(const Offset(100, 0));
      await tester.pump();
      expect(navDx(tester), closeTo(100 * kAylaDragElastic, 2));
      await g.up();
      await tester.pumpAndSettle();
    });

    testWidgets('未过阈值 ⇒ 不换页，回弹后归零', (WidgetTester tester) async {
      final GoRouter router = await pumpShell(tester, const Size(375, 812), '/group');
      await tester.timedDrag(
        navPage,
        const Offset(-40, 0),
        const Duration(milliseconds: 600),
      );
      await tester.pumpAndSettle();
      expect(pathOf(router), '/group');
      expect(navDx(tester), closeTo(0, 1), reason: '回弹走完必须归零');
    });
  });

  group('A1 同方向连切必重播（AppShell.tsx:116 的 key={pathname}；审查 BUG-2）', () {
    testWidgets('主页 ⇒ 帖子 ⇒ 桌游（两次都是下一项）⇒ 第二次仍能落页', (
      WidgetTester tester,
    ) async {
      final GoRouter router = await pumpShell(tester, const Size(375, 812), '/group');
      await tester.timedDrag(
        navPage,
        const Offset(-200, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      expect(pathOf(router), '/posts');

      // 第二次：帖子 ⇒ 桌游 —— direction **仍为 +1**（同方向）。
      await tester.timedDrag(
        navPage,
        const Offset(-200, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      expect(pathOf(router), '/games', reason: '同方向连切必须仍能落页');
    });

    testWidgets('重播：同 direction 换 pathname ⇒ 回到 enter（opacity 0 起）', (
      WidgetTester tester,
    ) async {
      final GoRouter router = await pumpShell(tester, const Size(375, 812), '/group');
      // 主页 ⇒ 帖子（direction +1），跑完进场
      router.go('/posts');
      await tester.pumpAndSettle();
      expect(navOpacity(tester), closeTo(1, 0.01));

      // 帖子 ⇒ 桌游：direction 仍 +1（同方向）⇒ 只有 replayKey 变化
      router.go('/games');
      await tester.pump();
      await tester.pump();
      expect(
        navOpacity(tester),
        lessThan(0.5),
        reason: '重播判据必须包含 replayKey：否则 direction 相同 ⇒ 停在终态、无动画',
      );
      await tester.pumpAndSettle();
      expect(navOpacity(tester), closeTo(1, 0.01));
    });
  });

  group('shell_config 纯函数（usePrimaryNavSwipeDirection.ts:18–35 逐条对齐）', () {
    test('aylaIsPrimaryTabPath：精确匹配 + /home 别名', () {
      for (final AylaPrimaryModule m in aylaPrimaryTabOrder) {
        expect(aylaIsPrimaryTabPath(m.path), isTrue, reason: m.path);
      }
      expect(aylaIsPrimaryTabPath('/home'), isTrue, reason: '/home 是 /group 的兼容别名');
      expect(aylaIsPrimaryTabPath('/live/abc'), isFalse, reason: '子路由不是一级 tab');
      expect(aylaIsPrimaryTabPath('/group/g1'), isFalse);
      expect(aylaIsPrimaryTabPath('/messages'), isFalse);
    });

    test('aylaPrimaryTabIndex：主页（含 /home）索引 2；非一级页 -1', () {
      expect(aylaPrimaryTabIndex('/voice'), 0);
      expect(aylaPrimaryTabIndex('/live'), 1);
      expect(aylaPrimaryTabIndex('/group'), 2);
      expect(aylaPrimaryTabIndex('/home'), 2, reason: '别名归主页索引');
      expect(aylaPrimaryTabIndex('/posts'), 3);
      expect(aylaPrimaryTabIndex('/games'), 4);
      expect(aylaPrimaryTabIndex('/messages'), -1);
    });

    test('aylaPrimaryTabDirection：索引差；任一端非一级页 ⇒ 0', () {
      expect(aylaPrimaryTabDirection('/group', '/posts'), 1, reason: '主页 → 帖子：+1');
      expect(aylaPrimaryTabDirection('/live', '/voice'), -1, reason: '直播 → 语音：-1');
      expect(aylaPrimaryTabDirection('/voice', '/games'), 1);
      expect(aylaPrimaryTabDirection('/group', '/home'), 0, reason: '同页（别名）⇒ 0');
      expect(aylaPrimaryTabDirection('/group', '/messages'), 0, reason: '非一级页 ⇒ 0');
      expect(aylaPrimaryTabDirection('/messages', '/group'), 0);
    });
  });
}
