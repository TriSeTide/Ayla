/// 群内直播「群内开播」浮层接线回归 —— web `pages/group/GroupLive.tsx`（197 行）。
///
/// P0-6 的缺陷本体：群内直播只有「直接新建直播间」一条入口
/// （`_createLive()` 直调 `createLiveChannel('新直播间')`），web 的
/// `CreateSheet title="群内开播"` + `LiveStartSheet`（**选已有直播间 / 新建**双分支）
/// 完全没有；房内 `LiveRoomBody` 也没接 `onCreateNewChannel`。
///
/// 覆盖（全部走**真实** `GroupLivePage`，只替换三个数据出口）：
/// ① 空态：「创建群内直播」⇒ 开「群内开播」浮层（tsx 141–144），**不**直接建台；
/// ② 浮层里点已有直播间 ⇒ 关浮层 + 进 `/live/start/<id>`（tsx 90–96）；
/// ③ 浮层里「+ 添加新的直播间」⇒ `createLiveChannel('新直播间', groupId)` +
///    进新频道控制台（tsx 98–111），创建中按钮「创建中…」并禁用；
/// ④ 建播失败 ⇒ 浮层内「创建直播间失败：…」且**不导航**（tsx 106–108）；
/// ⑤ 房内：`AylaLiveRoomBody` 拿到 `onCreateNewChannel`（tsx 179–182），
///    点它同样开同一份浮层。
///
/// ⚠️ 数据出口注入点见 `group_live_page.dart` 的文件级 @visibleForTesting 变量
/// （形态与 `group_page.dart` 的 `aylaGroupPageSubgroupsLoader` 同款）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/api/directory_page.dart' show AylaDirectoryPage;
import '../lib/core/api/live_api.dart' show AylaDirectoryLiveEntry;
import '../lib/core/net/dio_client.dart' show ApiException;
import '../lib/layout/create_sheet_forms.dart' show AylaOwnedLivePageRequest;
import '../lib/pages/group_live_page.dart';
import '../lib/state/auth_state.dart';
import '../lib/state/directory_events.dart' show AylaDirectoryKind;
import '../lib/state/directory_store.dart'
    show aylaDirectoryStore, AylaDirectoryOptions;
import '../lib/theme/app_theme.dart';
import '../lib/theme/glass.dart' show AylaGlassButton;
import '../lib/widgets/live/live_channel_snapshot.dart'
    show AylaLiveChannelSnapshot;
import '../lib/widgets/live/live_hall.dart'
    show AylaLiveCardData, AylaLiveStatus;
import '../lib/widgets/live/live_rail.dart' show AylaLiveStartSheet;
import '../lib/widgets/live/live_room_body.dart' show AylaLiveRoomBody;
import '../lib/widgets/shell/create_sheet.dart' show AylaCreateSheet;

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

/// 群内直播条目。
///
/// ⚠️ `allowedGroupIds` **必须含 `g1`**：本页现在读共享目录缓存，
/// `AylaDirectoryStore._matchesQueryOf` 会按 `record.options.groupId` 过滤
/// （`directory_store.dart:—` 的「groupId != null ⇒ 必须命中 allowedGroupIds」）——
/// 不带白名单的条目会被判为「不属于本群」而不入列（这是**正确**的语义，
/// 旧版页面私有 PagedList 没有这层过滤，故此前用裸 `_entry` 也能通过）。
AylaDirectoryLiveEntry _entry(
  String id,
  String title, {
  List<String> allowedGroupIds = const <String>['g1'],
}) =>
    AylaDirectoryLiveEntry(
      card: AylaLiveCardData(id: id, title: title),
      ownerId: 'u-me',
      isOwner: true,
      allowedGroupIds: allowedGroupIds,
      createdAt: '2026-01-01T00:00:00.000Z',
    );

AylaDirectoryPage<T> _page<T>(List<T> items) =>
    AylaDirectoryPage<T>(results: items, total: items.length);

void main() {
  // 三个数据出口全部注入；但页面内其它请求（频道详情 / 徽标 / WS）会真的发出去 ⇒
  // 清掉 flutter_test 的「一律 400」mock 让它们走正常网络失败路径（各消费点静默降级）。
  HttpOverrides.global = null;

  tearDown(() {
    aylaGroupLivePageDirectoryLoader = null;
    aylaGroupLivePageOwnedLivePage = null;
    aylaGroupLivePageCreateChannel = null;
  });

  /// 宿主：最小 GoRouter（`/group/:id/live` 挂真实 GroupLivePage；
  /// `/live/start/:channelId` 是打点页，用于断言「进控制台」）。
  Future<ProviderContainer> pumpGroupLive(
    WidgetTester tester, {
    Size viewport = const Size(1440, 900),
    VoidCallback? onExit,
  }) async {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(authNotifierProvider.notifier)
      ..setTokens('access', 'refresh')
      ..setUser(_me);
    // ⚠️ **群内直播目录已改为「读共享目录缓存」**（2026-10-20 热更新审计 R2：
    // web `GroupLive.tsx:27` 的 `useDirectoryPage("live", {groupId})`）。
    // 取页从此由 `AylaDirectoryStore` 统一承担 ⇒ 测试的数据出口注入点也要跟着
    // 换成 store 的 `requestOverride`（`@visibleForTesting`，测试内可用），
    // 只替换「live + 本群」这一个 kind，其余 kind 直接返回空页。
    aylaDirectoryStore.userId = _me.id;
    aylaDirectoryStore.requestOverride = (
      AylaDirectoryKind kind,
      AylaDirectoryOptions options,
      String? cursor,
    ) async {
      if (kind != AylaDirectoryKind.live) {
        return _page<Object>(<Object>[]);
      }
      // 群内直播目录（options.groupId == g1）走注入的 loader；
      // 「我的直播间」目录（options.owner != null，供「群内开播」浮层的选择器用）
      // 走 ownedLivePage —— 两者现在都是**同一个共享 store** 的不同 record。
      if (options.owner != null) {
        final AylaOwnedLivePageRequest? owned = aylaGroupLivePageOwnedLivePage;
        if (owned == null) return _page<Object>(<Object>[]);
        final AylaDirectoryPage<AylaDirectoryLiveEntry> page =
            await owned(cursor, options.owner);
        return AylaDirectoryPage<Object>(
          results: page.results.cast<Object>(),
          total: page.total,
          hasMore: page.hasMore,
          nextCursor: page.nextCursor,
        );
      }
      if (options.groupId != 'g1') {
        return _page<Object>(<Object>[]);
      }
      final AylaGroupLiveDirectoryLoader? loader =
          aylaGroupLivePageDirectoryLoader;
      if (loader == null) return _page<Object>(<Object>[]);
      final AylaDirectoryPage<AylaDirectoryLiveEntry> page =
          await loader('g1', cursor);
      return AylaDirectoryPage<Object>(
        results: page.results.cast<Object>(),
        total: page.total,
        hasMore: page.hasMore,
        nextCursor: page.nextCursor,
      );
    };
    addTearDown(() {
      aylaDirectoryStore.requestOverride = null;
      aylaDirectoryStore.reset();
    });
    final GoRouter router = GoRouter(
      initialLocation: '/group/g1/live',
      routes: <RouteBase>[
        GoRoute(
          path: '/group/:id/live',
          builder: (BuildContext c, GoRouterState s) => GroupLivePage(
            groupId: 'g1',
            onExit: onExit,
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
          builder: (BuildContext context, Widget? child) => Scaffold(
            backgroundColor: Colors.transparent,
            body: child,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return container;
  }

  /// 空态：群内直播目录为空 ⇒ 走 tsx 131–165 的空态分支。
  Future<ProviderContainer> pumpEmpty(
    WidgetTester tester, {
    Size viewport = const Size(1440, 900),
  }) async {
    aylaGroupLivePageDirectoryLoader = (String groupId, String? cursor) async =>
        _page<AylaDirectoryLiveEntry>(<AylaDirectoryLiveEntry>[]);
    aylaGroupLivePageOwnedLivePage = (String? cursor, String? owner) async =>
        _page<AylaDirectoryLiveEntry>(<AylaDirectoryLiveEntry>[
          _entry('lc1', '我的深夜电台'),
        ]);
    return pumpGroupLive(tester, viewport: viewport);
  }

  testWidgets('① 空态「创建群内直播」⇒ 开「群内开播」浮层（不直接建台）', (
    WidgetTester tester,
  ) async {
    await pumpEmpty(tester);
    expect(find.text('群内还没有直播'), findsOneWidget);
    expect(find.byType(AylaCreateSheet), findsNothing);
    expect(find.byType(AylaLiveStartSheet), findsNothing);

    await tester.tap(find.text('创建群内直播'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byType(AylaCreateSheet),
      findsOneWidget,
      reason: 'tsx 153–162 —— CreateSheet 包住 LiveStartSheet',
    );
    expect(find.text('群内开播'), findsOneWidget, reason: 'tsx 154 / 186 的标题');
    expect(
      find.byType(AylaLiveStartSheet),
      findsOneWidget,
      reason: 'tsx 155 / 187 —— 选已有 / 新建双分支的选择器',
    );
    expect(
      find.text('选择一个直播间开始'),
      findsOneWidget,
      reason: 'LiveStartSheet.tsx:32 的 intro',
    );
  });

  testWidgets('② 浮层里点已有直播间 ⇒ 关浮层 + 进 /live/start/<id>', (
    WidgetTester tester,
  ) async {
    await pumpEmpty(tester);
    await tester.tap(find.text('创建群内直播'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('我的深夜电台'), findsOneWidget);
    await tester.tap(find.text('我的深夜电台'));
    await tester.pumpAndSettle();

    expect(
      find.text('studio:lc1'),
      findsOneWidget,
      reason: 'tsx 90–96 —— handleLiveStarted 关浮层后 navigate(/live/start/<id>)',
    );
  });

  testWidgets('③ 「+ 添加新的直播间」⇒ createLiveChannel(groupId) + 进新频道控制台', (
    WidgetTester tester,
  ) async {
    final List<({String title, String? group})> calls =
        <({String title, String? group})>[];
    final Completer<AylaLiveChannelSnapshot> pending =
        Completer<AylaLiveChannelSnapshot>();
    aylaGroupLivePageCreateChannel =
        (String title, {String? group}) {
      calls.add((title: title, group: group));
      return pending.future;
    };
    await pumpEmpty(tester);
    await tester.tap(find.text('创建群内直播'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('+ 添加新的直播间'));
    await tester.pump();

    expect(calls.length, 1);
    expect(calls.single.title, '新直播间', reason: 'tsx 103 固定标题');
    expect(calls.single.group, 'g1', reason: 'tsx 103 —— 群内开播带本群 id');
    // tsx 158 / 190 的 creatingNew ⇒ 按钮「创建中…」+ disabled
    final Finder creating = find.byWidgetPredicate(
      (Widget w) => w is AylaGlassButton && w.label == '创建中…',
    );
    expect(creating, findsOneWidget);
    expect(tester.widget<AylaGlassButton>(creating).onPressed, isNull);

    pending.complete(const AylaLiveChannelSnapshot(id: 'lc9', title: '新直播间'));
    await tester.pumpAndSettle();

    expect(find.text('studio:lc9'), findsOneWidget);
  });

  testWidgets('④ 建播失败 ⇒ 浮层内「创建直播间失败：…」且不导航', (
    WidgetTester tester,
  ) async {
    aylaGroupLivePageCreateChannel =
        (String title, {String? group}) async =>
            throw const ApiException(400, '名称重复');
    await pumpEmpty(tester);
    await tester.tap(find.text('创建群内直播'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('+ 添加新的直播间'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('创建直播间失败'),
      findsOneWidget,
      reason: 'tsx 106–108 —— 失败保留浮层并展示原因',
    );
    expect(find.textContaining('studio:'), findsNothing);
    expect(
      find.byType(AylaLiveStartSheet),
      findsOneWidget,
      reason: 'tsx 104–105 只有成功才 setShowCreate(false)',
    );
  });

  testWidgets('⑤ 房内：AylaLiveRoomBody 拿到 onCreateNewChannel（tsx 179–182）', (
    WidgetTester tester,
  ) async {
    // 群内直播目录给一条 ⇒ 直接进房（tsx 61–67 的 currentId 自动取第一个）。
    aylaGroupLivePageDirectoryLoader = (String groupId, String? cursor) async =>
        _page<AylaDirectoryLiveEntry>(<AylaDirectoryLiveEntry>[
          _entry('7', '群里的直播'),
        ]);
    await pumpGroupLive(tester);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byType(AylaLiveRoomBody),
      findsOneWidget,
      reason: 'tsx 167-184 group live direct enter first room',
    );
    final AylaLiveRoomBody body =
        tester.widget<AylaLiveRoomBody>(find.byType(AylaLiveRoomBody));
    expect(
      body.onCreateNewChannel,
      isNotNull,
      reason: 'tsx 179–182 —— LiveRoomBody 的 onCreateNewChannel 必须接线',
    );
    expect(body.hideRail, isTrue, reason: 'tsx 183 —— 群内子界面无侧栏');

    // 点它 ⇒ 同一份「群内开播」浮层
    body.onCreateNewChannel!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AylaCreateSheet), findsOneWidget);
    expect(find.text('群内开播'), findsOneWidget);
  });
}
