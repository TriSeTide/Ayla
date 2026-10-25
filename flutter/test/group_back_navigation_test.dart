/// 群内「返回键逐级回退」回归锁 —— 用户 2026-10-23 实报
/// 「修复所有界面尤其是群内界面返回键的问题，是返回到上一级而不是返回到主页，要跟 web 一样」。
///
/// ## 修复前的缺陷（两条独立成因）
/// **① 群内「列表 → 房内 / 详情」不记场景历史**
/// GroupVoicePage 点房卡、GroupPostsPage 点帖子卡、宽屏侧栏点房行，全都是
/// context.go 到子路由，而 _sceneHistory 只有 _goScene 会写。于是进房/进详情后
/// 按返回：_popScene() 拿到的是更早的场景（甚至空栈）⇒ 跳过列表直接换场景 / 回主页。
///
/// **② 场景根之下（子路由）没有「先回列表」这一档**
/// 进房不改变场景，所以场景栈里那条是「上一个场景」而不是「列表」。
/// 此前没有这一档 ⇒ 同上，第一下就跳场景。
///
/// ## web 事实源
/// - GroupPage.tsx:286-292 goScene = navigate（push）
/// - GroupVoice.tsx:114-119 进房 = navigate（push）；:141 房内返回 = 回列表
/// - GroupPosts.tsx:426-432 进详情 = navigate（push）
/// - GroupPage.tsx:300-315 侧栏点房行 = navigate（push）
///
/// ## 为什么不能用 context.push 复刻
/// 群页 5 条路由共用 kAylaGroupShellPageKey ⇒ push 必抛 keyReservation 断言
/// （router/app_router.dart:113-121、no_group_push_test.dart、2026-10-19 两次红屏）。
/// ⇒ 只能靠 GroupPage._sceneHistory + 「回场景根」两档合作。
///
/// ## 测试口径：走真实生产路由 + 真实系统返回键通道
/// 与 back_button_exit_test.dart 同款：真 appRouterProvider + 真 AppShell +
/// tester.binding.handlePopRoute()（= 系统返回键进入 AylaBackButtonHost 的那条路）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/api/directory_page.dart' show AylaDirectoryPage;
import '../lib/core/api/favorites_api.dart' show AylaFavoriteEntry;
import '../lib/layout/app_back.dart' show aylaClearEntryOrigin;
import '../lib/pages/favorites_page.dart' show aylaFavoritesPageLoader;
import '../lib/router/app_router.dart';
import '../lib/state/auth_state.dart';
import '../lib/state/social_store.dart'
    show AylaSocialKind, AylaSocialOptions, aylaSocialStore;
import '../lib/theme/app_theme.dart';

/// 固定推进若干帧。
///
/// ⚠️ 房内分支会起媒体会话 / 自愈计时器 ⇒ pumpAndSettle 永不「静止」
/// （实测 pumpAndSettle timed out）。本组只关心路由落点，固定推进足够。
Future<void> settle(WidgetTester tester) async {
  for (int i = 0; i < 6; i += 1) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  while (tester.takeException() != null) {}
}

void main() {
  setUp(() {
    aylaFavoritesPageLoader = (String? cursor) async =>
        const AylaDirectoryPage<AylaFavoriteEntry>(
          results: <AylaFavoriteEntry>[],
          nextCursor: null,
          total: 0,
        );
    aylaClearEntryOrigin();
    aylaSocialStore.reset();
  });

  tearDown(() {
    aylaFavoritesPageLoader = null;
    aylaClearEntryOrigin();
    aylaSocialStore.reset();
  });

  /// 真实外壳 + 真实路由 + 登录态注入（与 back_button_exit_test.dart 同款）。
  Future<({ProviderContainer container, GoRouter router})> pumpApp(
    WidgetTester tester,
    Size size,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    container.read(authNotifierProvider.notifier).setTokens('access', 'refresh');
    aylaSocialStore.userId = 'me';
    aylaSocialStore.requestOverride =
        (AylaSocialKind kind, AylaSocialOptions options, String? cursor) async =>
            const AylaDirectoryPage<Object>();

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
    await settle(tester);
    return (container: container, router: router);
  }

  String pathOf(GoRouter router) =>
      router.routerDelegate.currentConfiguration.uri.toString();

  /// 系统返回键（与真机同一条通道：handlePopRoute → AylaBackButtonHost）。
  Future<void> pressBack(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await settle(tester);
  }

  group('群内子路由返回 ⇒ 先回列表，不回主页', () {
    testWidgets('① 直达房内（场景栈空）按返回 ⇒ 回群内语音列表',
        (WidgetTester tester) async {
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester, const Size(420, 900));
      app.router.go('/group/g1/voice/v1');
      await settle(tester);
      expect(pathOf(app.router), '/group/g1/voice/v1');

      await pressBack(tester);

      expect(
        pathOf(app.router),
        '/group/g1/voice',
        reason: '房内 ⇒ 语音房列表（web GroupVoice.tsx:141 的 navigate 落点）',
      );
      expect(pathOf(app.router), isNot('/group'), reason: '绝不能一步回主页');
    });

    testWidgets('② 直达帖子详情（场景栈空）按返回 ⇒ 回群内帖子列表',
        (WidgetTester tester) async {
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester, const Size(420, 900));
      app.router.go('/group/g1/posts/42');
      await settle(tester);
      expect(pathOf(app.router), '/group/g1/posts/42');

      await pressBack(tester);

      expect(
        pathOf(app.router),
        '/group/g1/posts',
        reason: '详情 ⇒ 帖子列表（web PostDetailPage 的 returnTo = /group/:id/posts）',
      );
      expect(pathOf(app.router), isNot('/group'), reason: '绝不能一步回主页');
    });

    testWidgets('③ 直达直播间（场景栈空）按返回 ⇒ 回群内直播列表',
        (WidgetTester tester) async {
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester, const Size(420, 900));
      app.router.go('/group/g1/live/7');
      await settle(tester);

      await pressBack(tester);

      expect(pathOf(app.router), '/group/g1/live');
      expect(pathOf(app.router), isNot('/group'));
    });
  });

  group('群内深层返回的完整梯度', () {
    testWidgets('④ 真实链路：群聊 → 点「语音」tab → 进房 → 连按返回逐级回退',
        (WidgetTester tester) async {
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester, const Size(420, 900));
      app.router.go('/group/g1');
      await settle(tester);

      // 1) 进语音场景根（等价点顶栏「语音」tab 后的落点；点 tab 依赖侧栏/顶栏时序，
      //    本组只验返回梯度，故直接 go 到同一 URL）
      app.router.go('/group/g1/voice');
      await settle(tester);
      expect(pathOf(app.router), '/group/g1/voice');

      // 2) 进房（模拟列表点卡：GroupPage._openGroupChild 会记历史再 go）
      app.router.go('/group/g1/voice/v1');
      await settle(tester);
      expect(pathOf(app.router), '/group/g1/voice/v1');

      // 3) 返回 ⇒ 语音房列表
      await pressBack(tester);
      expect(
        pathOf(app.router),
        '/group/g1/voice',
        reason: '★ 房内 ⇒ 语音房列表（这一步修复前会跳到群聊/主页）',
      );

      // 4) 再返回 ⇒ 回群聊（场景历史里那条 chat，由第 1 步写入）
      await pressBack(tester);
      expect(
        pathOf(app.router),
        '/group/g1',
        reason: '★ 列表 ⇒ 上一场景（chat）',
      );
    });

    testWidgets('⑤ 冷启动直达房内：两次返回后仍先回列表再回场景根',
        (WidgetTester tester) async {
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester, const Size(420, 900));
      app.router.go('/group/g1/voice/v1');
      await settle(tester);

      await pressBack(tester);
      expect(pathOf(app.router), '/group/g1/voice',
          reason: '第一下：房内 ⇒ 列表（修复前会直接跳过）');

      await pressBack(tester);
      // 冷启动直达 ⇒ 场景历史为空。「上一级」= 本群聊天场景（群壳），
      // **不是**群列表主页（2026-10-23 三条兜底修正）。
      expect(
        pathOf(app.router),
        '/group/g1',
        reason: '★ 第二下回到本群聊天场景，而不是一步跳到 /group 群列表',
      );
      expect(pathOf(app.router), isNot('/group'));
    });
  });

  group('群外：无来源时仍回主页（旧行为保留）', () {
    testWidgets('⑥ 直接进收藏页、栈空无来源 ⇒ 回 /group', (WidgetTester tester) async {
      final ({ProviderContainer container, GoRouter router}) app =
          await pumpApp(tester, const Size(420, 900));
      app.router.go('/favorites');
      await settle(tester);
      expect(pathOf(app.router), '/favorites');

      await pressBack(tester);

      expect(pathOf(app.router), '/group');
    });
  });
}
