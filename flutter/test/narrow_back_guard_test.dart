/// 窄屏顶栏返回键的**判栈守卫**回归锁（web `layout/NarrowTopBar.tsx:69–78` 的等价物）。
///
/// 用户 2026-10 实报：「收藏页面左上角的返回键无法点击」。
///
/// ## 根因（已由 Lead 探针实测，本文件是它的回归锁）
/// 窄屏顶栏 search / favorites 两档的 `onBack` 此前是**裸 `context.pop()`**
/// （修复前 `layout/app_shell.dart:238 / :244`）：
///
/// - 进收藏页的**主路径**是「更多」菜单 → `_onMenuSelected` 的 `context.go('/favorites')`
///   （`app_shell.dart:123`）—— `go` 是**替换**当前路由，不是追加 ⇒ 路由栈只有一层；
/// - web 的 `navigate(-1)`（`NarrowTopBar.tsx:74`）在没有历史时是 **no-op**，界面不出错；
/// - Flutter 的 `GoRouter.pop()` 在栈底**抛 `GoError: There is nothing to pop`**
///   （`go_router-14.8.1/lib/src/delegate.dart:98–104`），而回调跑在按钮手势里
///   ⇒ 异常被吞掉 ⇒ **按钮看起来完全没反应**（不是禁用、不是变灰，是点了没动静）。
///
/// ## 修法与口径
/// 顶栏改走 `_AppShellState._narrowBack`（`app_shell.dart` 内）：`canPop ? pop : go('/group')`
/// —— 与库内既有三处**一字不差**：`favorites_page.dart:602`（宽屏目录返回键）、
/// `search_page.dart:1338`、`profile_page.dart:614`。
/// `/group` 是窄屏一级主页（`router/shell_config.dart:182–192` 的
/// `aylaIsNarrowTopBarRoute` 首个路径，也是 `aylaPrimaryModules` 的第一项）。
///
/// ## 本文件锁什么
/// ① **栈底**（`go('/favorites')` 进来）：点顶栏返回 ⇒ 落到 `/group`，且**零异常**
///    （修复前这条必抛 GoError、路径原地不动）；
/// ② **有历史**（`push('/favorites')` 进来）：点返回 ⇒ 回到上一页（pop 分支没被改坏）。
///
/// 口径同 `group_page_shell_test.dart:42–71` / `app_shell_fabs_test.dart:37–84`：
/// **真实 [AppShell] + 真实 GoRouter + 真实主题 + 真窄屏表面（375×812）**，
/// 不 mock 壳层、不 mock 顶栏 —— 否则量不到「壳层喂给顶栏的是哪个回调」。
///
/// ⚠️ 全程**零网络**：收藏页的取页走 `aylaFavoritesPageLoader` 注入点
/// （`pages/favorites_page.dart:77`，生产恒 null），其余页面逻辑保持真实。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:ayla_flutter/core/api/directory_page.dart' show AylaDirectoryPage;
import 'package:ayla_flutter/core/api/favorites_api.dart'
    show AylaFavoriteEntry;
import 'package:ayla_flutter/layout/app_shell.dart' show AppShell;
import 'package:ayla_flutter/pages/favorites_page.dart'
    show FavoritesPage, aylaFavoritesPageLoader;
import 'package:ayla_flutter/state/auth_state.dart' show authNotifierProvider;
import 'package:ayla_flutter/theme/app_theme.dart';
import 'package:ayla_flutter/theme/buttons.dart' show AylaIconButton;

/// 窄屏尺寸：375×812（web 断点 ≤768 ⇒ `AylaBreakpoints.isNarrow` 为真）。
const Size _narrow = Size(375, 812);

/// 一级主页（`shell_config.dart:182` 名单首项）—— 也是返回键的栈底兜底落点。
const String _home = '/group';

/// 上一页探针文本（`push('/favorites')` 的起点）。
const String _previousPageText = '上一页';

/// 推进若干帧（页面入场动画 + 收藏页首屏取数都在未来帧完成）。
Future<void> _settle(WidgetTester tester, {int frames = 8}) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 窄屏顶栏的返回钮（`top_nav.dart:893–901` 的 `_narrowBackButton` ⇒ `AylaIconButton`，
/// `semanticLabel: '返回'`）。
///
/// 用**组件属性**定位而不是 `find.bySemanticsLabel`：后者要求测试先
/// `tester.ensureSemantics()` 建语义树（本文件只验行为，不必引入该依赖）；
/// 这里要断言的正是「壳层喂给这个钮的 onPressed 是哪个回调」+ 点下去的结果。
Finder _narrowBackButton() => find.byWidgetPredicate(
      (Widget w) => w is AylaIconButton && w.semanticLabel == '返回',
      description: '窄屏顶栏返回钮（semanticLabel=返回）',
    );

void main() {
  // 生产路径恒为 null 的测试注入点 ⇒ 用例间必须复位，避免串味。
  setUp(() => aylaFavoritesPageLoader = null);
  tearDown(() => aylaFavoritesPageLoader = null);

  /// 启动**真实壳层链**（AppShell → AylaTopNav → FavoritesPage）+ 真实 GoRouter。
  ///
  /// 路由表最小化但**结构真实**：受保护页面挂在 [AppShell] 的 `ShellRoute` 下
  /// （与 `app_router.dart:208` 同形），`/favorites` 用 `FavoritesPage` 本体。
  Future<GoRouter> pumpApp(WidgetTester tester, String location) async {
    tester.view.physicalSize = _narrow;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.binding.setSurfaceSize(_narrow);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    // 登录态注入（同 `group_page_shell_test.dart:53`）：否则路由守卫把一切重定向到 /login。
    container.read(authNotifierProvider.notifier).setTokens('access', 'refresh');

    // 收藏页取页：返回空页（页面其余逻辑全真实；不碰网络）。
    aylaFavoritesPageLoader = (String? cursor) async =>
        const AylaDirectoryPage<AylaFavoriteEntry>();

    final GoRouter router = GoRouter(
      initialLocation: location,
      routes: <RouteBase>[
        ShellRoute(
          builder: (BuildContext context, GoRouterState state, Widget child) =>
              AppShell(child: child),
          routes: <RouteBase>[
            GoRoute(
              path: '/favorites',
              builder: (BuildContext c, GoRouterState s) =>
                  FavoritesPage(initialType: s.uri.queryParameters['type']),
            ),
            GoRoute(
              path: '/group',
              builder: (BuildContext c, GoRouterState s) =>
                  const Scaffold(body: Center(child: Text('一级主页'))),
            ),
            GoRoute(
              path: '/previous',
              builder: (BuildContext c, GoRouterState s) =>
                  const Scaffold(body: Center(child: Text(_previousPageText))),
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
          // 必须真实主题：默认主题的平台转场会与库内 `AylaPageTransitionsBuilder` 叠加。
          theme: buildAylaTheme(),
          builder: (BuildContext context, Widget? child) => Scaffold(
            backgroundColor: Colors.transparent,
            body: child,
          ),
        ),
      ),
    );
    await _settle(tester);
    return router;
  }

  testWidgets('① 栈底：go(\'/favorites\') 后点顶栏返回 ⇒ 回 /group 且零异常（修复前必抛 GoError）',
      (WidgetTester tester) async {
    final GoRouter router = await pumpApp(tester, '/favorites');
    expect(router.state.uri.path, '/favorites');
    // 前提确认：`go` 是替换 ⇒ 栈只有一层（这正是缺陷的触发条件）。
    expect(router.canPop(), isFalse,
        reason: 'go 不追加历史栈（web NarrowTopBar.tsx:116 的 navigate("/favorites") 同理）');

    // 走**真实顶栏返回钮**（semanticLabel「返回」，top_nav.dart:899），
    // 不直接调 `_narrowBack` —— 要验的是「壳层喂给顶栏的回调」是否正确。
    final Finder back = _narrowBackButton();
    expect(back, findsOneWidget, reason: '窄屏 favorites 档顶栏必须有返回钮');
    await tester.tap(back);
    await _settle(tester);

    expect(tester.takeException(), isNull,
        reason: '修复前裸 pop 抛 GoError: There is nothing to pop（被手势吞掉 ⇒ 键看起来没反应）');
    expect(router.state.uri.path, _home,
        reason: '栈底兜底 = 一级主页（favorites_page.dart:602 / search_page.dart:1338 同一口径）');
    expect(find.text('一级主页'), findsOneWidget);
  });

  testWidgets('② 有历史：push(\'/favorites\') 后点返回 ⇒ 回上一页（pop 分支仍然工作）',
      (WidgetTester tester) async {
    final GoRouter router = await pumpApp(tester, '/previous');
    router.push('/favorites');
    await _settle(tester);
    expect(router.state.uri.path, '/favorites');
    expect(router.canPop(), isTrue, reason: 'push 追加历史栈');

    final Finder back = _narrowBackButton();
    expect(back, findsOneWidget);
    await tester.tap(back);
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(router.state.uri.path, '/previous',
        reason: '有历史时必须 pop 回上一页，不能被兜底分支抢走');
    expect(find.text(_previousPageText), findsOneWidget);
  });
}
