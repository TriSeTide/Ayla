/// FAB 创建入口四个 handler 的接线回归 —— web `layout/CreateFab.tsx:75–114`。
///
/// 覆盖：
/// ① `/group` `/voice` `/posts` `/games` 点右下 FAB ⇒ 各自渲染**真表单**
///    （`GroupCreateDialog` / `VoiceChannelCreate` / `PostEditor` / `GameRoomCreate`），
///    且不再出现兜底占位文案（web `tsx:75–114`）；
/// ② `post` 成功后按 `groupId` 有无分流导航（`tsx:97–100`）；
/// ③ `game` 成功后分流导航（`tsx:107–111`）；
/// ④ `voice` 成功后关浮层（`tsx:80`）+ 新频道写进 voice 状态
///    （`VoiceChannelCreate.tsx:44–45`）；
/// ⑤ 未知 handler 仍走兜底占位（防回归）。
///
/// 数据源替身：四个接线件都带可注入的取数 / 提交参数（默认走真实 api，
/// widget test 不发网络请求）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/api/voice_api.dart' show AylaVoiceChannelSnapshot;
import '../lib/core/models/post.dart' show AylaPost, AylaPostDraft;
import '../lib/core/models/visibility.dart' show AylaPostVisibility;
import '../lib/layout/app_shell.dart';
import '../lib/layout/create_sheet_forms.dart';
import '../lib/router/shell_config.dart' show AylaFabAction;
import '../lib/state/auth_state.dart';
import '../lib/state/room_providers.dart' show voiceStateProvider;
import '../lib/theme/app_theme.dart';
import '../lib/theme/buttons.dart' show AylaCreateFab;
import '../lib/widgets/game/game_room_create.dart'
    show AylaGameRoomCreate, AylaGameRoomCreateRequest;
import '../lib/widgets/group/group_create_dialog.dart'
    show AylaGroupCreateDialog;
import '../lib/widgets/posts/post_editor.dart' show AylaPostEditor;
import '../lib/widgets/shell/create_sheet.dart' show AylaCreateSheet;
import '../lib/widgets/voice/voice_channel_create.dart'
    show AylaVoiceChannelCreate;
import '../lib/widgets/voice/voice_channels.dart' show AylaVoiceCardData;

/// 表单宿主路径（打点页挂在别的路径上，导航后表单卸载、打点文案出现）。
const String _formRoute = '/form';

void main() {
  /// 宿主 A：完整 `AppShell`（走真实路由解析 ⇒ 测 ① 的各 handler 分支）。
  ///
  /// 与 `create_live_sheet_test.dart` 的宿主 A 同款最小宿主（不 import 整张路由表）。
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
            for (final String path in <String>[
              '/group',
              '/voice',
              '/posts',
              '/games',
            ])
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

  /// 点 FAB + 等浮层入场（窄屏贴底上滑 250ms）。
  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byType(AylaCreateFab));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 宽屏宿主 B：[_formRoute] 上挂 `CreateSheet + 接线件`（注入替身），
  /// 其余路径是打点页（`marker` 里的 `{id}` 用路径参数替换）。
  Future<ProviderContainer> pumpForm(
    WidgetTester tester, {
    required Widget form,
    required List<({String path, String marker})> markers,
  }) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(authNotifierProvider.notifier)
        .setTokens('access', 'refresh');
    final GoRouter router = GoRouter(
      initialLocation: _formRoute,
      routes: <RouteBase>[
        GoRoute(
          path: _formRoute,
          builder: (BuildContext c, GoRouterState s) => Scaffold(
            backgroundColor: Colors.transparent,
            body: AylaCreateSheet(
              // 标题不与任何表单按钮文案相同（避免 find.text 撞车）。
              title: '创建表单',
              onClose: () {},
              child: form,
            ),
          ),
        ),
        for (final ({String path, String marker}) m in markers)
          GoRoute(
            path: m.path,
            builder: (BuildContext c, GoRouterState s) => Text(
              // 路径参数名随路由不同：`/posts/:postId` ⇒ `postId`，
              // `/group/:id/posts` ⇒ `id`（marker 里统一写 `{id}`）。
              m.marker.replaceAll(
                '{id}',
                s.pathParameters['id'] ?? s.pathParameters['postId'] ?? '',
              ),
            ),
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

  Finder fieldWithHint(String hint) => find.byWidgetPredicate(
        (Widget w) => w is TextField && w.decoration?.hintText == hint,
      );

  // ===================== ① 四个 handler 打开后渲染对应组件 =====================

  testWidgets('① /group：FAB ⇒ 建群对话框（自带弹层，不套 CreateSheet）', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester, '/group');
    expect(
      find.byType(AylaCreateFab),
      findsOneWidget,
      reason: 'shellConfig.ts:246–248 —— /group 的 FAB 动作 handler=group',
    );

    await openSheet(tester);

    expect(find.byType(AylaGroupCreateDialog), findsOneWidget);
    expect(
      find.byType(AylaCreateSheet),
      findsNothing,
      reason: 'CreateFab.tsx:75–77 —— 建群不套 CreateSheet（组件自带弹层）',
    );
    expect(find.textContaining('未接线的创建动作'), findsNothing);
  });

  testWidgets('① /voice：FAB ⇒「创建语音房」浮层 + 建频道表单', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester, '/voice');
    await openSheet(tester);

    expect(find.text('创建语音房'), findsOneWidget, reason: 'shellConfig.ts:250 label');
    expect(find.byType(AylaCreateSheet), findsOneWidget);
    expect(find.byType(AylaVoiceChannelCreate), findsOneWidget);
    expect(find.textContaining('未接线的创建动作'), findsNothing);
  });

  testWidgets('① /posts：FAB ⇒「发帖」浮层 + 帖子编辑器', (WidgetTester tester) async {
    await pumpShell(tester, '/posts');
    await openSheet(tester);

    expect(find.text('发帖'), findsOneWidget, reason: 'shellConfig.ts:256 label');
    expect(find.byType(AylaCreateSheet), findsOneWidget);
    expect(find.byType(AylaPostEditor), findsOneWidget);
    expect(find.textContaining('未接线的创建动作'), findsNothing);
  });

  testWidgets('① /games：FAB ⇒「创建桌游室」浮层 + 建房间表单', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester, '/games');
    await openSheet(tester);

    expect(find.text('创建桌游室'), findsOneWidget, reason: 'shellConfig.ts:259 label');
    expect(find.byType(AylaCreateSheet), findsOneWidget);
    expect(find.byType(AylaGameRoomCreate), findsOneWidget);
    expect(find.textContaining('未接线的创建动作'), findsNothing);
  });

  // ===================== ② post 成功后分流导航 =====================

  testWidgets('② post 成功（一级）⇒ 关浮层 + /posts/<post.id>', (
    WidgetTester tester,
  ) async {
    int closed = 0;
    await pumpForm(
      tester,
      form: AylaCreatePostForm(
        loadGroups: () async => const <AylaGroupOption>[],
        createPost: (AylaPostDraft draft) async => const AylaPost(id: 42),
        onClose: () => closed += 1,
      ),
      markers: <({String path, String marker})>[
        (path: '/posts/:postId', marker: 'post:{id}'),
        (path: '/group/:id/posts', marker: 'group-posts:{id}'),
      ],
    );

    await tester.enterText(fieldWithHint('标题（必填）'), '标题');
    await tester.enterText(fieldWithHint('正文（必填）'), '正文');
    await tester.pump();
    await tester.tap(find.text('发布'));
    await tester.pumpAndSettle();

    expect(
      find.text('post:42'),
      findsOneWidget,
      reason: 'CreateFab.tsx:99 —— 一级 ⇒ /posts/:post.id',
    );
    expect(closed, 1, reason: 'tsx:98 setOpen(false) 在 navigate 之前');
  });

  testWidgets('② post 成功（群内）⇒ 关浮层 + /group/<id>/posts', (
    WidgetTester tester,
  ) async {
    int closed = 0;
    await pumpForm(
      tester,
      form: AylaCreatePostForm(
        groupId: 'g1',
        loadGroups: () async => const <AylaGroupOption>[],
        createPost: (AylaPostDraft draft) async => const AylaPost(id: 42),
        onClose: () => closed += 1,
      ),
      markers: <({String path, String marker})>[
        (path: '/posts/:postId', marker: 'post:{id}'),
        (path: '/group/:id/posts', marker: 'group-posts:{id}'),
      ],
    );

    await tester.enterText(fieldWithHint('标题（必填）'), '标题');
    await tester.enterText(fieldWithHint('正文（必填）'), '正文');
    await tester.pump();
    await tester.tap(find.text('发布'));
    await tester.pumpAndSettle();

    expect(
      find.text('group-posts:g1'),
      findsOneWidget,
      reason: 'CreateFab.tsx:99 —— 群内 ⇒ /group/:groupId/posts（不用 post.id）',
    );
    expect(closed, 1);
  });

  // ===================== ③ game 成功后分流导航 =====================

  testWidgets('③ game 成功（一级）⇒ 关浮层 + /games', (WidgetTester tester) async {
    int closed = 0;
    await pumpForm(
      tester,
      form: AylaCreateGameForm(
        loadGroups: () async => const <AylaGroupOption>[],
        createRoom: (AylaGameRoomCreateRequest request, {String? group}) async {},
        onClose: () => closed += 1,
      ),
      markers: <({String path, String marker})>[
        (path: '/games', marker: 'games'),
        (path: '/group/:id/games', marker: 'group-games:{id}'),
      ],
    );

    await tester.enterText(fieldWithHint('桌游室名称'), '深夜桌游室');
    await tester.pump();
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(
      find.text('games'),
      findsOneWidget,
      reason: 'CreateFab.tsx:110 —— 一级 ⇒ /games',
    );
    expect(find.text('group-games:'), findsNothing);
    expect(closed, 1, reason: 'tsx:108 setOpen(false) 在 navigate 之前');
  });

  testWidgets('③ game 成功（群内）⇒ 关浮层 + /group/<id>/games', (
    WidgetTester tester,
  ) async {
    int closed = 0;
    await pumpForm(
      tester,
      form: AylaCreateGameForm(
        groupId: 'g1',
        loadGroups: () async => const <AylaGroupOption>[],
        createRoom: (AylaGameRoomCreateRequest request, {String? group}) async {},
        onClose: () => closed += 1,
      ),
      markers: <({String path, String marker})>[
        (path: '/games', marker: 'games'),
        (path: '/group/:id/games', marker: 'group-games:{id}'),
      ],
    );

    await tester.enterText(fieldWithHint('桌游室名称'), '深夜桌游室');
    await tester.pump();
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(
      find.text('group-games:g1'),
      findsOneWidget,
      reason: 'CreateFab.tsx:110 —— 群内 ⇒ /group/:groupId/games',
    );
    expect(closed, 1);
  });

  // ===================== ④ voice 成功后关浮层 =====================

  testWidgets('④ voice 成功 ⇒ 关浮层 + 新频道写进 voice 状态', (
    WidgetTester tester,
  ) async {
    int closed = 0;
    final ProviderContainer container = await pumpForm(
      tester,
      form: AylaCreateVoiceForm(
        loadGroups: () async => const <AylaGroupOption>[],
        createChannel: (
          String name, {
          String? group,
          AylaPostVisibility? visibility,
          List<String>? allowedGroupIds,
        }) async =>
            const AylaVoiceChannelSnapshot(id: 'vc7', name: '深夜电台'),
        onClose: () => closed += 1,
      ),
      markers: const <({String path, String marker})>[
        (path: '/voice', marker: 'voice-hub'),
      ],
    );

    await tester.enterText(fieldWithHint('新语音频道名称'), '深夜电台');
    await tester.pump();
    await tester.tap(find.text('建频道'));
    await tester.pumpAndSettle();

    expect(closed, 1, reason: 'CreateFab.tsx:80 —— onCreated={() => setOpen(false)}');
    expect(
      container
          .read(voiceStateProvider)
          .channelCards
          .map((AylaVoiceCardData c) => c.id)
          .toList(growable: false),
      contains('vc7'),
      reason: 'VoiceChannelCreate.tsx:44–45 store.setChannels 的等价物',
    );
  });

  // ===================== ⑤ 未知 handler 兜底（防回归） =====================

  testWidgets('⑤ 未知 handler ⇒ 兜底占位文案（不静默、不猜动作）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAylaTheme(),
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: aylaCreateFormFor(
            const AylaFabAction(
              key: 'mystery-action',
              label: '神秘创建',
              groupId: null,
              plannedStep: 'F9',
              handler: 'mystery',
            ),
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('未接线的创建动作'), findsOneWidget);
    expect(find.textContaining('mystery-action'), findsOneWidget);
    expect(find.textContaining('handler=mystery'), findsOneWidget);
    expect(find.byType(AylaPostEditor), findsNothing);
    expect(find.byType(AylaVoiceChannelCreate), findsNothing);
    expect(find.byType(AylaGameRoomCreate), findsNothing);
    expect(find.byType(AylaGroupCreateDialog), findsNothing);
  });
}
