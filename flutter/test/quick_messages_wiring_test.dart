/// 红点快捷消息栏的 **渲染接线** 回归 —— web layout/AppShell.tsx:158–161 +
/// layout/QuickMessageFab.tsx:24–32 + components/chat/QuickMessagesSheet.tsx。
///
/// P0-3 的缺陷本体：AylaQuickMessagesSheet 组件完整、quickMessagesOpen 状态也在，
/// 但 AppShell **没有任何一处渲染它** ⇒ 窄屏点左下角红点按钮只会把状态置 true，
/// 屏幕上什么都不出现。本文件锁死这条链路。
///
/// 覆盖：
/// ① 窄屏 + quickMessagesOpen ⇒ 面板出现（且是带取数的宿主 AylaQuickMessagesHost）；
/// ② 关闭键 ⇒ 面板消失 + store 回 false（web onClose 只调 setQuickMessagesOpen(false)）；
/// ③ 遮罩点击 ⇒ 同上（web QuickMessagesSheet.tsx:175）；
/// ④ 宽屏（>768）即使 open 也**不渲染**（web 的 isNarrow && quickMessagesOpen 左项）；
/// ⑤ 状态驱动：store 置 true ⇒ 面板出现；置 false ⇒ 消失（AppShell 是唯一渲染者）。
///
/// ⚠️ 本文件**不发真实网络请求**：HttpOverrides.global = null（清掉 flutter_test 的
/// 「一律 400」mock）后，壳层/宿主发出的请求会连 127.0.0.1:8100 失败 —— 所有消费点
/// 都是静默降级（badgesProvider.fetch / elysiaProfileProvider / 会话分页各自 catch），
/// 因此面板仍会渲染、只是列表为空；断言只看**结构与状态**，不看数据内容。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/layout/app_shell.dart';
import '../lib/pages/quick_messages_support.dart' show AylaQuickMessagesHost;
import '../lib/state/auth_state.dart';
import '../lib/state/shell_state.dart' show shellUiProvider;
import '../lib/theme/app_theme.dart';
import '../lib/widgets/chat/quick_messages_sheet.dart'
    show AylaQuickMessagesSheet;
import '../lib/widgets/chat/request_rows.dart' show AylaRequestsPanel;

/// 已登录用户（壳层要读 authNotifierProvider.user 才画出消息入口）。
const AuthUser _me = AuthUser(
  id: 'u-me',
  username: 'me',
  nickname: '我',
  avatar: '',
  signature: '',
  status: '',
  online: true,
  displayStatus: '',
  dateJoined: '',
  isInVoice: false,
  voiceRoomId: null,
  isLive: false,
  liveRoomId: null,
  showContent: true,
  email: '',
);

void main() {
  // flutter_test 会把 HttpOverrides.global 换成「一律 400」的 mock；本文件不需要
  // mock 响应（消费点全部静默降级），清掉它避免误导。
  HttpOverrides.global = null;

  /// 窄/宽屏宿主 + 最小路由（/group 是一级导航页 = QuickMessageFab 的展示页，
  /// web AppShell.tsx:140–146）。
  Future<ProviderContainer> pumpShell(
    WidgetTester tester, {
    required Size viewport,
    bool quickMessagesOpen = false,
  }) async {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(authNotifierProvider.notifier)
      ..setTokens('access', 'refresh')
      ..setUser(_me);
    container
        .read(shellUiProvider.notifier)
        .setQuickMessagesOpen(quickMessagesOpen);
    final GoRouter router = GoRouter(
      initialLocation: '/group',
      routes: <RouteBase>[
        ShellRoute(
          builder: (BuildContext context, GoRouterState state, Widget child) =>
              AppShell(child: child),
          routes: <RouteBase>[
            GoRoute(
              path: '/group',
              builder: (BuildContext c, GoRouterState s) =>
                  const SizedBox.shrink(),
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
          builder: (BuildContext context, Widget? child) =>
              Scaffold(backgroundColor: Colors.transparent, body: child),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return container;
  }

  testWidgets('① 窄屏 + quickMessagesOpen ⇒ 快捷消息栏出现（AppShell.tsx:159–161）', (
    WidgetTester tester,
  ) async {
    await pumpShell(
      tester,
      viewport: const Size(375, 812),
      quickMessagesOpen: true,
    );

    expect(
      find.byType(AylaQuickMessagesSheet),
      findsOneWidget,
      reason: 'web AppShell.tsx:159 —— isNarrow && quickMessagesOpen ⇒ 渲染面板',
    );
    expect(
      find.byType(AylaQuickMessagesHost),
      findsOneWidget,
      reason: '渲染的必须是带取数/装配的宿主，而不是裸展示件（web tsx 自己取数）',
    );
    // 遮罩层铺满视口（.quick-messages-overlay { position: fixed; inset: 0 }，
    // messages.css 343–347）；面板本身 70% 高由 AylaModalCard 表达（已有测试覆盖）。
    expect(
      tester.getSize(find.byType(AylaQuickMessagesSheet)).width,
      closeTo(375, 0.5),
    );
    expect(
      tester.getSize(find.byType(AylaQuickMessagesSheet)).height,
      closeTo(812, 0.5),
    );
  });

  testWidgets('② 关闭键 ⇒ 面板消失 + store 回 false（web onClose 的唯一动作）', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await pumpShell(
      tester,
      viewport: const Size(375, 812),
      quickMessagesOpen: true,
    );
    expect(container.read(shellUiProvider).quickMessagesOpen, isTrue);

    await tester.tap(find.byKey(const ValueKey<String>('quick-messages-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      container.read(shellUiProvider).quickMessagesOpen,
      isFalse,
      reason: 'web AppShell.tsx:160 —— onClose 回写 setQuickMessagesOpen(false)',
    );
    expect(find.byType(AylaQuickMessagesSheet), findsNothing);
  });

  testWidgets('③ 点遮罩（上 30%）⇒ 关闭（web QuickMessagesSheet.tsx:175）', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await pumpShell(
      tester,
      viewport: const Size(375, 812),
      quickMessagesOpen: true,
    );

    // 面板占下 70% ⇒ y = 812*0.3 = 243 以上是遮罩
    await tester.tapAt(const Offset(180, 60));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(container.read(shellUiProvider).quickMessagesOpen, isFalse);
    expect(find.byType(AylaQuickMessagesSheet), findsNothing);
  });

  testWidgets('④ 宽屏（>768）即使 open 也不渲染（AppShell.tsx:159 左项 isNarrow）', (
    WidgetTester tester,
  ) async {
    await pumpShell(
      tester,
      viewport: const Size(1440, 900),
      quickMessagesOpen: true,
    );

    expect(
      find.byType(AylaQuickMessagesSheet),
      findsNothing,
      reason: 'web 的 isNarrow && quickMessagesOpen —— 宽屏没有快捷消息栏',
    );
  });

  testWidgets('⑤ 状态驱动：store true ⇒ 出现；store false ⇒ 消失（唯一渲染者 = AppShell）', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await pumpShell(
      tester,
      viewport: const Size(375, 812),
    );
    expect(find.byType(AylaQuickMessagesSheet), findsNothing);

    container.read(shellUiProvider.notifier).setQuickMessagesOpen(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AylaQuickMessagesSheet), findsOneWidget);

    container.read(shellUiProvider.notifier).setQuickMessagesOpen(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(AylaQuickMessagesSheet), findsNothing);
  });

  testWidgets('⑥ 空数据路径：两个 tab 都渲染、切认证 tab 不崩（web tsx 178–202）', (
    WidgetTester tester,
  ) async {
    // 宿主的数据出口全部走真实 API（本测试环境网络不可达）⇒ 各分页静默失败、
    // 列表为空。这是**最保守的空值路径**：面板必须照样出现且可切 tab。
    await pumpShell(
      tester,
      viewport: const Size(375, 812),
      quickMessagesOpen: true,
    );

    expect(find.text('私信'), findsOneWidget);
    expect(find.text('认证消息'), findsOneWidget);
    // 私信 tab 列表空态（AylaConversationList 的 emptyText）
    expect(find.textContaining('暂无会话'), findsOneWidget);

    await tester.tap(find.text('认证消息'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 认证 tab 已切过去：四分组按「有数据 或 loading 或 error 或 hasMore」渲染
    // （web tsx 274–321 的 `shouldRender`）；本环境网络不可达 ⇒ 各组落在 error 档，
    // 分组标题仍然出现（这正是 web 的空值/失败路径，不是空态文案）。
    expect(find.text('好友申请'), findsOneWidget);
    expect(find.byType(AylaRequestsPanel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
