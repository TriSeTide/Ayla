/// 手机返回键的回归锁（2026-10-20 用户需求）。
///
/// ## 需求原文
/// 「确保手机返回按键正常触发返回，只有回到一级主页再按返回了才退出应用，
///   且退出应用前还要提示一次再按一次退出应用」。
///
/// ## 修复前的实测缺陷（本文件逐条锁住）
/// 由 `layout/app_back.dart` 文件头记录的机制链导致：**任何页面按返回都直接
/// `SystemNavigator.pop` 退出应用**（连主页也不例外），页面级 `PopScope` 一次都不触发。
///
/// ## 覆盖（五组）
/// ① 二级页（`/favorites`）按返回 ⇒ 回 `/group`，且**不发** `SystemNavigator.pop`；
/// ② 一级主页首次按返回 ⇒ 出现「再按一次退出应用」提示，**不退出**；
/// ③ 主页 2s 窗口内第二次按返回 ⇒ 发 `SystemNavigator.pop`；
/// ④ 主页首次按返回后超过窗口再按 ⇒ 仍只提示、不退出；
/// ⑤ 群场景按返回仍走群页三级兜底（不退出应用）。
///
/// ⚠️ 全程零网络：收藏页取页走 `aylaFavoritesPageLoader` 注入点。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/api/directory_page.dart' show AylaDirectoryPage;
import '../lib/core/api/favorites_api.dart' show AylaFavoriteEntry;
import '../lib/layout/app_back.dart'
    show AylaExitConfirm, AylaBackAction, aylaBackActionFor, kAylaExitHintText;
import '../lib/pages/favorites_page.dart' show aylaFavoritesPageLoader;
import '../lib/pages/group_page.dart' show GroupPage;
import '../lib/router/app_router.dart';
import '../lib/state/auth_state.dart';
import '../lib/theme/app_theme.dart';
import '../lib/widgets/shell/channel_sidebar.dart'
    show AylaChannelSidebar;

/// 真实外壳 + 真实路由 + 登录态注入（与 `group_page_shell_test.dart` 同款）。
Future<({ProviderContainer container, GoRouter router})> pumpApp(
  WidgetTester tester,
  Size size,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final ProviderContainer container = ProviderContainer();
  addTearDown(container.dispose);
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
  await tester.pumpAndSettle();
  return (container: container, router: router);
}

void main() {
  late List<String> platformCalls;

  setUp(() {
    platformCalls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform,
            (MethodCall call) async {
      platformCalls.add(call.method);
      return null;
    });
    aylaFavoritesPageLoader = (String? cursor) async =>
        const AylaDirectoryPage<AylaFavoriteEntry>(
          results: <AylaFavoriteEntry>[],
          nextCursor: null,
          total: 0,
        );
  });

  tearDown(() {
    aylaFavoritesPageLoader = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  bool sysPopped() => platformCalls.contains('SystemNavigator.pop');

  Future<void> pressBack(WidgetTester tester) async {
    platformCalls.clear();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  String pathOf(GoRouter router) =>
      router.routerDelegate.currentConfiguration.uri.toString();

  // ==========================================================================
  // ① 二级页 ⇒ 回一级主页，绝不退出应用
  // ==========================================================================
  group('① 二级页按返回：回一级主页（修复前是直接退出应用）', () {
    testWidgets('窄屏 /favorites 按返回 ⇒ /group 且不发 SystemNavigator.pop', (
      WidgetTester tester,
    ) async {
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester, const Size(400, 800));
      app.router.go('/favorites');
      await tester.pumpAndSettle();
      expect(pathOf(app.router), '/favorites');

      await pressBack(tester);

      expect(
        pathOf(app.router),
        '/group',
        reason: '二级页按返回必须回一级主页，而不是把 App 关掉',
      );
      expect(
        sysPopped(),
        isFalse,
        reason: '修复前这里会 SystemNavigator.pop ⇒ 用户看到「返回键直接退出应用」',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('宽屏 /favorites 同理（返回策略与断点无关）', (
      WidgetTester tester,
    ) async {
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester, const Size(1440, 900));
      app.router.go('/favorites');
      await tester.pumpAndSettle();

      await pressBack(tester);

      expect(pathOf(app.router), '/group');
      expect(sysPopped(), isFalse);
    });
  });

  // ==========================================================================
  // ②③ 一级主页：第一次提示、窗口内第二次才退出
  // ==========================================================================
  group('② 一级主页按返回：先提示「再按一次退出应用」', () {
    testWidgets('首次按返回 ⇒ 出现提示且不退出', (WidgetTester tester) async {
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester, const Size(400, 800));
      app.router.go('/group');
      await tester.pumpAndSettle();

      await pressBack(tester);

      expect(
        find.text(kAylaExitHintText),
        findsOneWidget,
        reason: '退出前必须提示一次（用户需求原文「再按一次退出应用」）',
      );
      expect(
        sysPopped(),
        isFalse,
        reason: '第一次按返回绝不能退出应用',
      );
      expect(
        pathOf(app.router),
        '/group',
        reason: '主页按返回不改路由',
      );
    });

    testWidgets('2s 窗口内第二次按返回 ⇒ 发 SystemNavigator.pop', (
      WidgetTester tester,
    ) async {
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester, const Size(400, 800));
      app.router.go('/group');
      await tester.pumpAndSettle();

      await pressBack(tester);
      expect(sysPopped(), isFalse, reason: '第一次只提示');

      // 窗口内（1s < 2s）
      await tester.pump(const Duration(seconds: 1));
      await pressBack(tester);

      expect(
        sysPopped(),
        isTrue,
        reason: '窗口内第二次按返回 = 用户确认退出',
      );
    });
  });

  // ==========================================================================
  // ④ 窗口过期：重新回到「第一次」
  // ==========================================================================
  group('④ 退出确认窗口会过期（状态机口径，见 ⑥ 的纯函数锁）', () {
    // ⚠️ 为什么这条不做 widget 级：`AylaExitConfirm` 用 `DateTime.now()`（真实墙钟），
    // 而 `tester.pump(Duration)` 只推进**测试假时钟**、不推进 `DateTime.now()`。
    // 在 widget 测试里"等 3 秒"实际是瞬间完成 ⇒ 窗口永不过期，断言恒假。
    // ⇒ 窗口语义由 ⑥ 的 `AylaExitConfirm` 纯函数锁（注入时钟）覆盖，
    //    这里只锁 widget 层「窗口未过期时第二次确实退出」这条可稳定断言的行为（见 ③）。
    testWidgets('连续两次按返回在默认窗口内 ⇒ 第二次退出（与 ③ 同一条链）', (
      WidgetTester tester,
    ) async {
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester, const Size(400, 800));
      app.router.go('/group');
      await tester.pumpAndSettle();

      await pressBack(tester);
      expect(sysPopped(), isFalse);
      expect(find.text(kAylaExitHintText), findsOneWidget);

      await pressBack(tester);
      expect(sysPopped(), isTrue);
    });
  });

  // ==========================================================================
  // ⑤ 群场景：仍走 GroupPage 的三级兜底，不退出应用
  // ==========================================================================
  group('⑤ 群场景按返回：不退出应用（群页三级兜底）', () {
    testWidgets('群场景栈底按返回 ⇒ 回群列表而非退出', (
      WidgetTester tester,
    ) async {
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester, const Size(400, 800));
      app.router.go('/group/g1');
      await tester.pumpAndSettle();
      expect(find.byType(GroupPage), findsOneWidget);
      while (tester.takeException() != null) {}

      // ⚠️ 群页挂载时 `AylaDirectoryController` 会在 build 期通知（`GroupPage._onChanged`
      // 裸 setState）—— 那是**既有**的独立缺陷（`test/setstate_during_build_test.dart`
      // 有专项登记），与本轮返回键改动无关。这里把它显式吃掉，避免干扰本条断言；
      // 本轮改动若真出错会表现为下面的路径断言失败。
      while (tester.takeException() != null) {}

      await pressBack(tester);
      while (tester.takeException() != null) {}

      expect(
        sysPopped(),
        isFalse,
        reason: '群场景按返回不能退出应用（修复前正是这条缺陷）',
      );
      expect(
        pathOf(app.router),
        '/group',
        reason: '群页栈底 ⇒ 三级兜底的第三条：回群列表',
      );
    });
  });

  // ==========================================================================
  // ⑦ 群内场景逐级回退（GroupPage PopScope 的 ① 档：场景历史栈）
  // ==========================================================================
  //
  // 这一组锁的是「修好返回键没把群页既有语义弄丢」——`GroupPage` 原 PopScope
  // 的 ① 档（场景历史栈）**与路由栈无关**：群内 chat → voice 切过场景后，
  // 即便路由栈还能 pop，返回键也必须先退场景（见 `layout/app_back.dart` 的
  // `aylaBackActionFor` 注释）。修复前那个 PopScope 收不到返回键，这条语义在真机上
  // 从未生效过；现在由 `GroupPage._handleSystemBack` 承接。
  group('⑦ 群内场景逐级回退', () {
    testWidgets('群内点场景 tab 后按返回 ⇒ 回上一场景（PopScope ① 档语义）', (
      WidgetTester tester,
    ) async {
      // 宽屏三列：场景 tab 在第二列侧栏（`group_page_shell_test.dart` 的 E3 同款）。
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester, const Size(1440, 900));
      app.router.go('/group/g1');
      await tester.pumpAndSettle();
      while (tester.takeException() != null) {}

      // 真实点击「语音」场景 ⇒ GroupPage._goScene 把 chat 压进场景历史栈。
      final Finder row = find.descendant(
        of: find.byType(AylaChannelSidebar),
        matching: find.text('语音'),
      );
      expect(row, findsWidgets, reason: '宽屏群页必须有场景侧栏');
      await tester.tap(row.first, warnIfMissed: false);
      await tester.pumpAndSettle();
      while (tester.takeException() != null) {}
      expect(pathOf(app.router), '/group/g1/voice');

      await pressBack(tester);
      while (tester.takeException() != null) {}

      expect(
        sysPopped(),
        isFalse,
        reason: '群内场景回退绝不能退出应用',
      );
      expect(
        pathOf(app.router),
        '/group/g1',
        reason: '场景栈里有 chat ⇒ 必须先退回 chat（PopScope ① 档语义）',
      );
    });

    testWidgets('群场景深链直达（场景栈空、路由栈空）按返回 ⇒ 回群列表', (
      WidgetTester tester,
    ) async {
      // 冷启动 deep-link 形态：没有场景历史、路由栈只有一层 ⇒ 三级兜底第 ③ 档。
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester, const Size(400, 800));
      app.router.go('/group/g1/voice');
      await tester.pumpAndSettle();
      while (tester.takeException() != null) {}

      await pressBack(tester);
      while (tester.takeException() != null) {}

      expect(sysPopped(), isFalse);
      expect(
        pathOf(app.router),
        '/group',
        reason: '都没有 ⇒ 回群列表，绝不交回系统（那会退出 App）',
      );
    });
  });

  // ==========================================================================
  // 纯函数契约（不依赖 widget 树，锁死分档判据）
  // ==========================================================================
  group('⑥ 分档纯函数与退出确认状态机', () {
    test('aylaBackActionFor：四档优先级', () {
      // 能 pop ⇒ 交回框架
      expect(
        aylaBackActionFor(canPop: true, pathname: '/favorites'),
        AylaBackAction.popRoute,
      );
      expect(
        aylaBackActionFor(canPop: true, pathname: '/group'),
        AylaBackAction.popRoute,
        reason: '主页若能 pop（有历史）⇒ 先回历史，不进入退出判定',
      );
      // 群场景：**优先于 canPop**（照抄 GroupPage PopScope 的 ① 场景栈 → ② 路由栈 顺序，
      // 场景栈回退与路由栈无关 ⇒ 不能因为「还能 pop」就跳过去）。
      expect(
        aylaBackActionFor(canPop: false, pathname: '/group/g1'),
        AylaBackAction.groupScene,
      );
      expect(
        aylaBackActionFor(canPop: true, pathname: '/group/g1'),
        AylaBackAction.groupScene,
        reason: '群内切过场景后即便路由栈还能 pop，也必须先回上一场景',
      );
      expect(
        aylaBackActionFor(canPop: false, pathname: '/group/g1/posts/9'),
        AylaBackAction.groupScene,
      );
      expect(
        aylaBackActionFor(canPop: true, pathname: '/group/g1/voice/v1'),
        AylaBackAction.groupScene,
      );
      // 二级页 ⇒ 回主页
      expect(
        aylaBackActionFor(canPop: false, pathname: '/favorites'),
        AylaBackAction.goHome,
      );
      expect(
        aylaBackActionFor(canPop: false, pathname: '/posts/mine'),
        AylaBackAction.goHome,
      );
      // 一级主页 ⇒ 双击退出
      expect(
        aylaBackActionFor(canPop: false, pathname: '/group'),
        AylaBackAction.homeExit,
      );
      expect(
        aylaBackActionFor(canPop: false, pathname: '/home'),
        AylaBackAction.homeExit,
        reason: '/home 是 /group 的兼容别名（shell_config.dart:84）',
      );
    });

    test('AylaExitConfirm：窗口内第二次为真、过期后重新计数', () {
      DateTime now = DateTime(2026, 10, 20, 12);
      final AylaExitConfirm confirm = AylaExitConfirm()..clock = () => now;

      expect(confirm.consume(), isFalse, reason: '第一次只提示');
      expect(confirm.armed, isTrue);

      now = now.add(const Duration(milliseconds: 500));
      expect(confirm.consume(), isTrue, reason: '窗口内第二次 ⇒ 退出');
      expect(confirm.armed, isFalse, reason: '退出后状态复位');

      // 走一遍过期档
      now = now.add(const Duration(seconds: 10));
      expect(confirm.consume(), isFalse, reason: '重新计数');
      now = now.add(const Duration(seconds: 3));
      expect(
        confirm.consume(),
        isFalse,
        reason: '超过 2s 窗口 ⇒ 仍视为第一次（不退出）',
      );
    });

    test('AylaExitConfirm.reset 清掉待确认', () {
      final AylaExitConfirm confirm = AylaExitConfirm();
      expect(confirm.consume(), isFalse);
      expect(confirm.armed, isTrue);
      confirm.reset();
      expect(confirm.armed, isFalse);
      expect(confirm.consume(), isFalse, reason: 'reset 后按下应重新提示');
    });
  });
}
