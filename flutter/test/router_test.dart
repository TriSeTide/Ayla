/// 路由表与守卫回归（`lib/router/app_router.dart` = web `src/App.tsx` 的等价物）。
///
/// 覆盖：未登录守卫 + `?next=` 回跳（**用户指示的有意偏离**，web 恒定 `/group`）·
/// 已登录访问公开页回跳 · catch-all · 声明顺序（`/posts/mine` 不被当成 postId）·
/// **路由层转场直通**（页面转场只由 `AylaPageTransition` 承担，2026-09-28 用户实报「太生硬」）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/router/app_router.dart';
import '../lib/router/shell_config.dart';
import '../lib/pages/pending_page.dart';
import '../lib/state/auth_state.dart';
import '../lib/theme/app_theme.dart';
import '../lib/theme/page_transitions.dart';

void main() {
  /// 转场直通：全部平台的 `PageTransitionsBuilder` 都必须**不是**平台默认那几种。
  ///
  /// 为什么要有这条锁：Flutter 的 `MaterialPage` 自带平台转场（Windows/Linux 默认
  /// `FadeUpwardsPageTransitionsBuilder`：300ms 上滑 + 整页淡入），会与库内
  /// `AylaPageTransition`（y +20 / scale .95 / 500ms 淡入）**叠加** ⇒ 位移与白屏时间翻倍。
  /// web 侧 React Router 不做转场、唯一 owner 是 `PageTransition.tsx`，此处对齐。
  test('路由层转场直通：全平台都不用平台默认转场', () {
    final PageTransitionsTheme theme = buildAylaTheme().pageTransitionsTheme;
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.fuchsia,
    ]) {
      final PageTransitionsBuilder? builder = theme.builders[platform];
      expect(builder, isNotNull, reason: '$platform 缺 builder');
      expect(
        builder,
        isNot(isA<FadeUpwardsPageTransitionsBuilder>()),
        reason: '$platform 仍是平台默认上滑转场（会与 AylaPageTransition 叠加）',
      );
      expect(builder, isNot(isA<ZoomPageTransitionsBuilder>()), reason: '$platform 仍是缩放转场');
    }
  });

  test('shell 纯函数：`/posts/mine` 与 `/posts/:postId` 的判定互不干扰', () {
    // go_router 按声明顺序匹配 ⇒ `/posts/mine` 必须排在 `/posts/:postId` 之前；
    // 这里锁住「两者是同段数路径」这个前提（顺序在 router 里保证）。
    expect(aylaMatchPath('/posts/mine', '/posts/mine')?['postId'], isNull);
    expect(aylaMatchPath('/posts/:postId', '/posts/mine')?['postId'], 'mine');
    expect(aylaIsPostDetailRoute('/posts/mine'), isTrue); // 纯模式匹配层面
  });

  /// ⚠️ 必须钉真实表面尺寸：默认 800×600 会把登录页的宽屏分栏（intro 420 + gap 48 +
  /// card 440）挤到 `RenderFlex overflowed`（实测溢出 100px）。


  /// 取一个**仍是占位页**的路由路径（自动跟随交付进度）。
  ///
  /// ⚠️ 为什么要探测：占位页的数量随批次递减，硬编码某条路径会在它交付时立刻失效
  /// （2026-09-28 已因此红过两次）。这里的候选按「尚未交付的域」列出，命中即返回；
  /// 全部交付后返回 null（调用方跳过该断言）。
  Future<String?> findPendingPath(WidgetTester tester, GoRouter router) async {
    // ⚠️ '/messages' 放最后：该路径会让 AppShell 的浮层（RefreshFab）触发
    // ParentDataWidget 冲突断言（与本用例无关的既有问题）。
    const List<String> candidates = <String>[
      '/posts/1',
      '/group/1',
      '/voice/v1',
      '/live/1',
      '/games/1',
      '/chat/c1',
      '/messages',
    ];
    for (final String path in candidates) {
      router.go(path);
      await tester.pumpAndSettle();
      if (find.text('该页面属后续批次').evaluate().isNotEmpty) return path;
    }
    return null;
  }

  Future<void> useViewport(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  testWidgets('未登录：任意受保护路由 ⇒ 落到登录页且带上 `?next=`', (WidgetTester tester) async {
    await useViewport(tester);
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    final GoRouter router = container.read(appRouterProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          // ⚠️ 必须用真实主题：`buildAylaTheme()` 里把全平台页面转场设为**直通**
          // （web 侧 React Router 不做转场，唯一 owner 是 `AylaPageTransition`）。
          // 用默认主题会让平台转场（FadeUpwards 等）与 `AylaPageSwap` 叠加 ——
          // 不仅观感生硬，还会让同一个 GoRouter 页面实例同时被 Navigator 与旧页槽位持有，
          // 直接触发 `Multiple widgets used the same GlobalKey`（本用例就是这么抓到的）。
          theme: buildAylaTheme(),
          // 与 `main.dart` 一致：业务根必须落在 Scaffold/Material 上，
          // 否则 TextField 报「No Material widget found」、Text 会长出黄色双下划线。
          builder: (BuildContext context, Widget? child) => Scaffold(
            backgroundColor: Colors.transparent,
            body: child,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('登录，回到Ayla'), findsOneWidget); // 落地登录页

    router.go('/profile');
    await tester.pumpAndSettle();
    expect(find.text('登录，回到Ayla'), findsOneWidget); // 仍被守卫拦住
    expect(router.state.uri.queryParameters['next'], '/profile');
  });

  testWidgets('已登录：访问 `/login?next=/favorites` ⇒ 回跳到收藏页', (WidgetTester tester) async {
    await useViewport(tester);
    final ProviderContainer container = ProviderContainer();
    container.read(authNotifierProvider.notifier).setTokens('access', 'refresh');
    final GoRouter router = container.read(appRouterProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          // ⚠️ 必须用真实主题：`buildAylaTheme()` 里把全平台页面转场设为**直通**
          // （web 侧 React Router 不做转场，唯一 owner 是 `AylaPageTransition`）。
          // 用默认主题会让平台转场（FadeUpwards 等）与 `AylaPageSwap` 叠加 ——
          // 不仅观感生硬，还会让同一个 GoRouter 页面实例同时被 Navigator 与旧页槽位持有，
          // 直接触发 `Multiple widgets used the same GlobalKey`（本用例就是这么抓到的）。
          theme: buildAylaTheme(),
          // 与 `main.dart` 一致：业务根必须落在 Scaffold/Material 上，
          // 否则 TextField 报「No Material widget found」、Text 会长出黄色双下划线。
          builder: (BuildContext context, Widget? child) => Scaffold(
            backgroundColor: Colors.transparent,
            body: child,
          ),
        ),
      ),
    );
    await tester.pump();

    router.go('/login?next=%2Ffavorites');
    await tester.pump();
    expect(router.state.uri.path, '/favorites');

    // ⚠️ 先卸树再释放 container：`AylaPageSwap` 在换页的 300ms 内两页并存，
    // 而测试 teardown 期会 finalize 整棵树 —— 此时若 router 已被 dispose，
    // 两页共享的 GoRouter 页面实例会撞上 `_debugVerifyGlobalKeyReservation`。
    // （真机不经过这条路径；换页本身已由 `child` 值语义修好。）
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });

  testWidgets('已登录：`?next` 指向登录/注册页时忽略（防回跳成环）', (WidgetTester tester) async {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(authNotifierProvider.notifier).setTokens('access', 'refresh');
    final GoRouter router = container.read(appRouterProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          // ⚠️ 必须用真实主题：`buildAylaTheme()` 里把全平台页面转场设为**直通**
          // （web 侧 React Router 不做转场，唯一 owner 是 `AylaPageTransition`）。
          // 用默认主题会让平台转场（FadeUpwards 等）与 `AylaPageSwap` 叠加 ——
          // 不仅观感生硬，还会让同一个 GoRouter 页面实例同时被 Navigator 与旧页槽位持有，
          // 直接触发 `Multiple widgets used the same GlobalKey`（本用例就是这么抓到的）。
          theme: buildAylaTheme(),
          // 与 `main.dart` 一致：业务根必须落在 Scaffold/Material 上，
          // 否则 TextField 报「No Material widget found」、Text 会长出黄色双下划线。
          builder: (BuildContext context, Widget? child) => Scaffold(
            backgroundColor: Colors.transparent,
            body: child,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    router.go('/login?next=%2Flogin');
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/group'); // 落到默认主页而不是回登录
  });

  test('转场分档：`/login` `/register` 无转场（web 里它们在 AppShell 之外）', () {
    expect(aylaIsTransitionFreePath('/login'), isTrue);
    expect(aylaIsTransitionFreePath('/register'), isTrue);
    expect(aylaIsTransitionFreePath('/login?next=%2Fprofile'), isTrue);
    expect(aylaIsTransitionFreePath('/group'), isFalse);
    expect(aylaIsTransitionFreePath('/profile'), isFalse); // panelOwned，但仍有转场 owner 判定
    expect(aylaIsTransitionFreePath(null), isFalse);
    // panelOwned 档（整页不动画，交由面板自编排）
    expect(aylaPanelOwnedPath('/profile'), isTrue);
    expect(aylaPanelOwnedPath('/favorites'), isTrue);
    expect(aylaPanelOwnedPath('/search'), isTrue);
    // ⚠️ 2026-10-01 改为 true（与 /voice /live /posts /games 同档）：用户实机窄屏
    // 「进入主页的动画有问题，重合了」—— /group 此前用 MaterialPage（300ms），
    // 而旧页（/live 等 panelOwned）被覆盖时 `AylaPageTransitionsBuilder` 直接返回 child
    //（**不退场**）⇒ 旧页停在原位、新页在上面淡入 = **两页硬叠**。
    // /group 与其余四条同属顶部导航模块 ⇒ 零时长、同屏只有一页。
    expect(aylaPanelOwnedPath('/group'), isTrue);
    expect(aylaPanelOwnedPath('/posts/mine'), isFalse); // 显式排除（见 shell_config 注释）
  });

  testWidgets('换页（/group → /favorites）转场进行中：不再抛 GlobalKey 冲突', (
    WidgetTester tester,
  ) async {
    await useViewport(tester);
    final ProviderContainer container = ProviderContainer();
    container.read(authNotifierProvider.notifier).setTokens('access', 'refresh');
    final GoRouter router = container.read(appRouterProvider);
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
    await tester.pump();

    router.go('/favorites');
    // 转场中途（500ms 进场窗口内）—— 早前用 `AylaPageSwap` 保留旧页时，
    // 这一步会抛 `Multiple widgets used the same GlobalKey`（旧页里的 shell navigator
    // 与新页共享同一 `GlobalObjectKey(navigatorKey.hashCode)`）。
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });

  testWidgets('PendingPage：首帧就是终值 —— 不做任何转场', (
    WidgetTester tester,
  ) async {
    await useViewport(tester);
    // ⚠️ 组件级断言（不经路由表）：占位页本身必须是「首帧终值 + 无入场淡入」。
    // 路由级的 NoTransitionPage 由下一条「不叠页」用例覆盖。
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAylaTheme(),
        home: const PendingPage(path: '/x', webSource: 'test'),
      ),
    );
    await tester.pump(); // **只一帧**
    expect(find.text('该页面属后续批次'), findsOneWidget);
    expect(
      tester
          .widgetList<Opacity>(find.byType(Opacity))
          .where((Opacity o) => o.opacity < 1.0)
          .toList(),
      isEmpty,
      reason: '未实现页不该有入场淡入（用户：没做的页面就别强加动画）',
    );
  });

  testWidgets('换页**不叠页**：转场窗口内只有一页内容（用户：别几帧同时显示两个页面）', (
    WidgetTester tester,
  ) async {
    await useViewport(tester);
    final ProviderContainer container = ProviderContainer();
    container.read(authNotifierProvider.notifier).setTokens('access', 'refresh');
    final GoRouter router = container.read(appRouterProvider);
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
    await tester.pump();

    // ⚠️ 起始路由（/group）自第 3 批起已是**真实页面**（HomePage）⇒ 不能再假定首帧
    // 落在占位页上；改为**动态探测**一个仍是占位页的路径后再断言
    // （路由交付后本用例自动跟随，不会再失效）。
    final String? pending = await findPendingPath(tester, router);
    if (pending == null) return; // 全部路由都已交付 ⇒ 本用例不再适用
    router.go(pending);
    await tester.pump(); // 回到待验证的起点（探测过程已 pumpAndSettle）
    await tester.pump(); // 首帧
    // 两个占位页的标题**逐字相同** ⇒ 若新旧页并存，这条会数到 2（正是「叠页」）。
    expect(
      find.text('该页面属后续批次'),
      findsOneWidget,
      reason: '首帧就有两页 ⇒ 路由层仍在做交叉转场',
    );
    // web 的转场窗口是「进场 500ms / 退场 300ms」—— 在这段里再数一次
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.text('该页面属后续批次'),
      findsOneWidget,
      reason: '转场窗口内出现两页 ⇒ 仍在叠页',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });

  testWidgets('登录 ↔ 注册：切换不叠页（用户截图：两张卡同屏）', (WidgetTester tester) async {
    await useViewport(tester);
    final ProviderContainer container = ProviderContainer();
    final GoRouter router = container.read(appRouterProvider);
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
    expect(find.text('登录，回到Ayla'), findsOneWidget); // 登录页副标题（唯一）

    router.go('/register');
    await tester.pump(); // 首帧
    expect(
      find.text('登录，回到Ayla'),
      findsNothing,
      reason: '登录页仍在树上 ⇒ 两个 route 并存（截图里的叠页）',
    );
    expect(find.text('创建账号'), findsOneWidget); // 注册页标题

    // 旧的 route 转场窗口（MaterialPage 的 transitionDuration = 300ms）内再数一次 ——
    // 这正是「PageTransitionsBuilder 只管视觉、不管时长」时会被抓到的区间。
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.text('登录，回到Ayla'),
      findsNothing,
      reason: '转场窗口内旧 route 仍在 ⇒ 没有真正删掉切换动画',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });

  testWidgets('catch-all：未知路径 ⇒ `/group`', (WidgetTester tester) async {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(authNotifierProvider.notifier).setTokens('access', 'refresh');
    final GoRouter router = container.read(appRouterProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          // ⚠️ 必须用真实主题：`buildAylaTheme()` 里把全平台页面转场设为**直通**
          // （web 侧 React Router 不做转场，唯一 owner 是 `AylaPageTransition`）。
          // 用默认主题会让平台转场（FadeUpwards 等）与 `AylaPageSwap` 叠加 ——
          // 不仅观感生硬，还会让同一个 GoRouter 页面实例同时被 Navigator 与旧页槽位持有，
          // 直接触发 `Multiple widgets used the same GlobalKey`（本用例就是这么抓到的）。
          theme: buildAylaTheme(),
          // 与 `main.dart` 一致：业务根必须落在 Scaffold/Material 上，
          // 否则 TextField 报「No Material widget found」、Text 会长出黄色双下划线。
          builder: (BuildContext context, Widget? child) => Scaffold(
            backgroundColor: Colors.transparent,
            body: child,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    router.go('/definitely-not-a-route');
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/group');
  });
}