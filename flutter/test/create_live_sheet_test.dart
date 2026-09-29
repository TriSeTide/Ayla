/// 「创建直播间」浮层接线回归 —— web `layout/CreateFab.tsx:24–114`（live 分支）+ `LiveStartSheet.tsx:86`。
///
/// 覆盖：
/// ① `/live` 点右下 FAB ⇒「开始直播」弹层 + [AylaLiveStartSheet]（选择器）出现；
/// ② 点已有直播间 ⇒ 关浮层 + 进 `/live/start/:channelId`（tsx:36–39）；
/// ③「+ 添加新的直播间」⇒ `createLiveChannel('新直播间', group)` + 进新建 id（tsx:41–48），
///    创建中按钮「创建中…」并禁用（tsx:79–82）；
/// ④ 建播失败 ⇒ 弹层内「创建直播间失败：…」且**不导航**（tsx:49–53）；
/// ⑤ 其它 handler（`/posts`）已接真表单：占位只留给**未知 handler**
///    （`create_forms_test.dart` ⑤ 覆盖兜底；本文件只锁「不再走旧占位文案」）。
///
/// 数据源替身：[AylaCreateLiveForm.listPage] / [AylaCreateLiveForm.createChannel]
/// （默认走 `AylaLiveApi`，widget test 不发网络请求）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/api/directory_page.dart' show AylaDirectoryPage;
import '../lib/core/api/live_api.dart' show AylaDirectoryLiveEntry;
import '../lib/core/net/dio_client.dart' show ApiException;
import '../lib/layout/app_shell.dart';
import '../lib/layout/create_sheet_forms.dart';
import '../lib/state/auth_state.dart';
import '../lib/theme/app_theme.dart';
import '../lib/theme/buttons.dart' show AylaCreateFab;
import '../lib/theme/glass.dart' show AylaGlassButton;
import '../lib/widgets/live/live_channel_snapshot.dart'
    show AylaLiveChannelSnapshot;
import '../lib/widgets/live/live_hall.dart'
    show AylaLiveCardData, AylaLiveStatus;
import '../lib/widgets/live/live_rail.dart' show AylaLiveStartSheet;
import '../lib/widgets/posts/post_editor.dart' show AylaPostEditor;
import '../lib/widgets/shell/create_sheet.dart' show AylaCreateSheet;

/// 已登录用户（目录请求带 `owner=` + 当前用户 id；web `useOwnedLiveDirectory` 的 owner）。
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

AylaDirectoryLiveEntry _entry(
  String id,
  String title, {
  AylaLiveStatus? status,
}) => AylaDirectoryLiveEntry(
  card: AylaLiveCardData(id: id, title: title, status: status),
  ownerId: 'u-me',
  isOwner: true,
  createdAt: '2026-01-01T00:00:00.000Z',
);

AylaDirectoryPage<AylaDirectoryLiveEntry> _page(
  List<AylaDirectoryLiveEntry> items,
) => AylaDirectoryPage<AylaDirectoryLiveEntry>(
  results: items,
  total: items.length,
);

void main() {
  /// 宿主 A：完整 `AppShell`（走真实路由解析 ⇒ 测 ① / ⑤ 的 FAB 与 handler 分支）。
  ///
  /// 与 `app_shell_fabs_test.dart` 同款最小宿主（不 import 整张路由表）。
  Future<void> pumpShell(WidgetTester tester, String location) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(authNotifierProvider.notifier)
        .setTokens('access', 'refresh');
    final GoRouter router = GoRouter(
      initialLocation: location,
      routes: <RouteBase>[
        ShellRoute(
          builder: (BuildContext context, GoRouterState state, Widget child) =>
              AppShell(child: child),
          routes: <RouteBase>[
            for (final String path in <String>['/live', '/posts'])
              GoRoute(
                path: path,
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
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// 宿主 B：直接挂 `AylaCreateSheet` + [AylaCreateLiveForm]（注入替身），
  /// 最小路由表 = `/live`（弹层）+ `/live/start/:channelId`（打点页 `studio:<id>`）。
  Future<void> pumpLiveForm(
    WidgetTester tester, {
    required AylaOwnedLivePageRequest listPage,
    AylaCreateLiveChannelFn? createChannel,
    VoidCallback? onClose,
    String? groupId,
  }) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(authNotifierProvider.notifier)
      ..setTokens('access', 'refresh')
      ..setUser(_me);
    final VoidCallback close = onClose ?? () {};
    Future<AylaLiveChannelSnapshot> unused(
      String title, {
      String? group,
    }) async => throw StateError('本用例不应调 createLiveChannel');
    final GoRouter router = GoRouter(
      initialLocation: '/live',
      routes: <RouteBase>[
        GoRoute(
          path: '/live',
          builder: (BuildContext c, GoRouterState s) => AylaCreateSheet(
            title: '开始直播',
            onClose: close,
            child: AylaCreateLiveForm(
              groupId: groupId,
              onClose: close,
              listPage: listPage,
              createChannel: createChannel ?? unused,
            ),
          ),
        ),
        GoRoute(
          path: '/live/start/:channelId',
          builder: (BuildContext c, GoRouterState s) =>
              Text('studio:${s.pathParameters['channelId']}'),
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
    // 首帧 + 目录首页返回（替身立即完成）+ 弹层窄屏入场（250ms）的余量。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('① /live：点 FAB ⇒「开始直播」弹层 + 开播选择器', (WidgetTester tester) async {
    await pumpShell(tester, '/live');
    expect(
      find.byType(AylaCreateFab),
      findsOneWidget,
      reason: 'shellConfig.ts:336–343 —— /live 的 FAB 动作 handler=live',
    );

    await tester.tap(find.byType(AylaCreateFab));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // 窄屏贴底上滑 250ms

    expect(find.text('开始直播'), findsOneWidget, reason: 'CreateFab.tsx:84 固定标题');
    expect(find.byType(AylaLiveStartSheet), findsOneWidget);
    expect(
      find.text('选择一个直播间开始'),
      findsOneWidget,
      reason: 'LiveStartSheet.tsx:32',
    );
    expect(
      find.textContaining('未接线的创建动作'),
      findsNothing,
      reason: 'live 分支已接真表单，不落未知 handler 兜底',
    );
  });

  testWidgets('② 点已有直播间 ⇒ 关浮层 + 进 /live/start/<id>', (
    WidgetTester tester,
  ) async {
    int closed = 0;
    await pumpLiveForm(
      tester,
      listPage: (String? cursor, String? owner) async =>
          _page(<AylaDirectoryLiveEntry>[_entry('lc9', '我的深夜电台')]),
      onClose: () => closed += 1,
    );

    expect(find.text('我的深夜电台'), findsOneWidget);
    await tester.tap(find.text('我的深夜电台'));
    await tester.pumpAndSettle();

    expect(find.text('studio:lc9'), findsOneWidget);
    expect(closed, 1, reason: 'CreateFab.tsx:37 setOpen(false) 在 navigate 之前');
  });

  testWidgets('③「+ 添加新的直播间」⇒ 调 createLiveChannel 并进新 id（创建中禁用）', (
    WidgetTester tester,
  ) async {
    final List<({String title, String? group})> calls =
        <({String title, String? group})>[];
    final Completer<AylaLiveChannelSnapshot> pending =
        Completer<AylaLiveChannelSnapshot>();
    int closed = 0;
    await pumpLiveForm(
      tester,
      listPage: (String? cursor, String? owner) async =>
          _page(<AylaDirectoryLiveEntry>[]),
      createChannel: (String title, {String? group}) {
        calls.add((title: title, group: group));
        return pending.future;
      },
      onClose: () => closed += 1,
    );

    await tester.tap(find.text('+ 添加新的直播间'));
    await tester.pump();

    expect(calls.length, 1);
    expect(calls.single.title, '新直播间', reason: 'CreateFab.tsx:46 固定标题');
    expect(calls.single.group, isNull, reason: '/live 的 action.groupId = null');
    // tsx:82「创建中…」档 + tsx:79 的 `disabled={creatingNew}`
    final Finder creating = find.byWidgetPredicate(
      (Widget w) => w is AylaGlassButton && w.label == '创建中…',
    );
    expect(creating, findsOneWidget);
    expect(tester.widget<AylaGlassButton>(creating).onPressed, isNull);

    pending.complete(const AylaLiveChannelSnapshot(id: 'lc10', title: '新直播间'));
    await tester.pumpAndSettle();

    expect(find.text('studio:lc10'), findsOneWidget);
    expect(closed, 1, reason: 'tsx:47 setOpen(false) 在 navigate 之前');
  });

  testWidgets('④ 建播失败 ⇒ 显示「创建直播间失败」且不导航', (WidgetTester tester) async {
    int closed = 0;
    await pumpLiveForm(
      tester,
      listPage: (String? cursor, String? owner) async =>
          _page(<AylaDirectoryLiveEntry>[]),
      createChannel: (String title, {String? group}) async =>
          throw const ApiException(400, '名称重复'),
      onClose: () => closed += 1,
    );

    await tester.tap(find.text('+ 添加新的直播间'));
    await tester.pumpAndSettle();

    expect(find.textContaining('创建直播间失败'), findsOneWidget); // tsx:47/50
    expect(find.textContaining('studio:'), findsNothing);
    expect(
      find.byType(AylaLiveStartSheet),
      findsOneWidget,
      reason: 'tsx:49–53 失败保留浮层（只有成功才 setOpen(false)）',
    );
    expect(closed, 0);
  });

  testWidgets('⑤ 其它 handler（/posts）已接真表单（占位只留给未知 handler）', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester, '/posts');
    await tester.tap(find.byType(AylaCreateFab));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byType(AylaPostEditor),
      findsOneWidget,
      reason: 'CreateFab.tsx:93–103 —— post handler 已接真表单',
    );
    expect(find.textContaining('未接线的创建动作'), findsNothing);
    expect(find.byType(AylaLiveStartSheet), findsNothing);
  });
}
