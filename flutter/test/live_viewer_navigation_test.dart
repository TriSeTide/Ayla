/// 「在看名单弹层里点观众 → 个人主页」的**页面层接线**回归锁。
///
/// ## 缺陷本体（2026-11-04 用户实报）
/// 「观看直播的人的头像点击无法跳转」。根因**不在弹层组件**（它老老实实读
/// `AylaLiveViewerSheetData.onOpenProfile`，`live_viewers.dart:496`），
/// 而在三个直播页**都没给这个字段赋值**：
///
/// | 位置 | 修复前的样子 |
/// |---|---|
/// | `live_room_page.dart` / `live_studio_page.dart` | 把跳转挂在 `AylaLiveRoomBody.onOpenProfile` 上 —— 那个参数**全文件零处读取**（死参数） |
/// | `group_live_page.dart` | 连 `onOpenProfile:` 都没传 |
/// | `AylaLiveViewerSheetController.load()` | `onOpenProfile: _value.onOpenProfile` 是**自我复制**，而 `_value` 初值恒 null |
///
/// ⇒ `data.onOpenProfile?.call(viewer)` 恒 null：点行只关弹层、不跳转。
///
/// ## 为什么这个测试不能只测组件
/// `live_viewers_test.dart` 里「点整行 → 回调」是**用例自己喂** `onOpenProfile`，
/// 量不到「真实页面喂了什么」—— 这正是 skill 第五批记的「参数注入型组件必须查调用点」。
/// 本文件全部走**真实页面 + 真 GoRouter**，断言点落在 `body.data.viewerSheet.onOpenProfile`
/// （弹层真正读的那个字段），并**真调用**它验证落点（自己 → `/profile`，他人 → `/user/:id`）。
///
/// 事实源：web `components/live/LiveViewerSheet.tsx:121–124` 的
/// `goUserProfile(me, viewer.user_id)` + `onClose()`；
/// 跳转口径 `utils/navigation.ts:24–35`。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/api/directory_page.dart' show AylaDirectoryPage;
import '../lib/core/api/live_api.dart'
    show AylaDirectoryLiveEntry, AylaLiveViewer, AylaLiveViewersResult;
import '../lib/core/media/media_signer.dart';
import '../lib/pages/group_live_page.dart';
import '../lib/pages/live_room_page.dart';
import '../lib/pages/live_studio_page.dart';
import '../lib/state/auth_state.dart';
import '../lib/state/directory_events.dart' show AylaDirectoryKind;
import '../lib/state/directory_store.dart'
    show AylaDirectoryOptions, aylaDirectoryStore;
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/live/live_hall.dart' show AylaLiveCardData;
import '../lib/widgets/live/live_room_body.dart' show AylaLiveRoomBody;
import '../lib/widgets/live/live_viewers.dart'
    show
        AylaLiveViewerItem,
        AylaLiveViewerSheet,
        AylaLiveViewerSheetData,
        AylaLiveViewerStrip;
import '../lib/pages/live_support.dart' show AylaLiveViewerSheetController;

const String kMe = 'u-me';

AuthUser _me() => const AuthUser(
      id: kMe,
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

/// 落点打点：`/profile`（自己）与 `/user/:id`（他人）。
const String kProfileMark = 'route:/profile';
String userMark(String id) => 'route:/user/$id';

/// 群内直播目录条目（必须带 `allowedGroupIds` 含 `g1`，见 directory_store 的过滤口径）。
AylaDirectoryLiveEntry groupEntry(String id) => AylaDirectoryLiveEntry(
      card: AylaLiveCardData(id: id, title: '群里的直播'),
      ownerId: kMe,
      isOwner: true,
      allowedGroupIds: const <String>['g1'],
      createdAt: '2026-01-01T00:00:00.000Z',
    );

void main() {
  // 直播页会渲染头像 ⇒ 不触真实签名请求（与 `avatar_navigation_test.dart` 同款隔离）。
  setUp(() => MediaSigner.instance.detach());
  tearDown(() {
    MediaSigner.instance.detach();
    // 目录缓存的测试注入点（群内直播用例会设置它们）—— 每个用例后复位，
    // 避免跨用例串台。
    aylaGroupLivePageDirectoryLoader = null;
    aylaGroupLivePageOwnedLivePage = null;
    aylaDirectoryStore.requestOverride = null;
    aylaDirectoryStore.reset();
  });

  /// 宿主：真 GoRouter（`/room` = 被测算页面，其余是落点打点页）+ 真 ProviderContainer。
  Future<ProviderContainer> pumpPage(
    WidgetTester tester,
    Widget Function() page, {
    String location = '/room',
    bool signedIn = false,
    Size viewport = const Size(1440, 900),
  }) async {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    if (signedIn) {
      container.read(authNotifierProvider.notifier)
        ..setTokens('access', 'refresh')
        ..setUser(_me());
    }
    final GoRouter router = GoRouter(
      initialLocation: location,
      routes: <RouteBase>[
        GoRoute(
          path: location,
          builder: (BuildContext c, GoRouterState s) => previewScope(page()),
        ),
        GoRoute(
          path: '/profile',
          builder: (BuildContext c, GoRouterState s) =>
              const Text(kProfileMark),
        ),
        GoRoute(
          path: '/user/:id',
          builder: (BuildContext c, GoRouterState s) =>
              Text(userMark(s.pathParameters['id']!)),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return container;
  }

  /// 从真实页面取出装配好的 `AylaLiveRoomBody`（页面层把数据喂给它的那一次）。
  AylaLiveRoomBody bodyOf(WidgetTester tester) =>
      tester.widget<AylaLiveRoomBody>(find.byType(AylaLiveRoomBody));

  group('直播页：在看名单行点击 → 个人主页（LiveViewerSheet.tsx:121–124）', () {
    testWidgets('LiveRoomPage：弹层数据里带跳转回调，他人 → /user/:id', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, () => const LiveRoomPage(channelId: '7'));
      final AylaLiveRoomBody body = bodyOf(tester);

      // ⚠️ 断言点必须是**弹层真正读的那个字段**（不是已删除的死参数）。
      expect(
        body.data.viewerSheet.onOpenProfile,
        isNotNull,
        reason: '页面必须把「点名单行 → 个人主页」送进 AylaLiveViewerSheetData；'
            '否则 live_viewers.dart 的 data.onOpenProfile?.call(viewer) 恒 null，'
            '点行只关弹层、不跳转（本次用户实报的根因）',
      );

      body.data.viewerSheet.onOpenProfile!(
        const AylaLiveViewerItem(userId: 'u-other', nickname: '小樱'),
      );
      await tester.pumpAndSettle();
      expect(find.text(userMark('u-other')), findsOneWidget);
    });

    testWidgets('LiveRoomPage：已登录且点的是自己 → /profile（goUserProfile 的 me 语义）', (
      WidgetTester tester,
    ) async {
      await pumpPage(
        tester,
        () => const LiveRoomPage(channelId: '7'),
        signedIn: true,
      );
      final AylaLiveRoomBody body = bodyOf(tester);
      expect(body.data.viewerSheet.onOpenProfile, isNotNull);

      body.data.viewerSheet.onOpenProfile!(
        const AylaLiveViewerItem(userId: kMe, nickname: '我'),
      );
      await tester.pumpAndSettle();
      expect(find.text(kProfileMark), findsOneWidget);
    });

    testWidgets('LiveStudioPage（开播控制台）：弹层数据里带跳转回调', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, () => const LiveStudioPage(channelId: '7'));
      final AylaLiveRoomBody body = bodyOf(tester);
      expect(
        body.data.viewerSheet.onOpenProfile,
        isNotNull,
        reason: '控制台与观看页共用同一弹层，必须同样接线',
      );

      body.data.viewerSheet.onOpenProfile!(
        const AylaLiveViewerItem(userId: 'u-other'),
      );
      await tester.pumpAndSettle();
      expect(find.text(userMark('u-other')), findsOneWidget);
    });
  });

  group('群内直播：在看名单行点击 → 个人主页', () {
    AylaDirectoryLiveEntry entry(String id) => AylaDirectoryLiveEntry(
          card: AylaLiveCardData(id: id, title: '群里的直播'),
          ownerId: kMe,
          isOwner: true,
          allowedGroupIds: const <String>['g1'],
          createdAt: '2026-01-01T00:00:00.000Z',
        );

    tearDown(() {
      aylaGroupLivePageDirectoryLoader = null;
      aylaGroupLivePageOwnedLivePage = null;
      aylaDirectoryStore.requestOverride = null;
      aylaDirectoryStore.reset();
    });

    testWidgets('GroupLivePage：弹层数据里带跳转回调，他人 → /user/:id', (
      WidgetTester tester,
    ) async {
      aylaGroupLivePageDirectoryLoader = (String groupId, String? cursor) async =>
          AylaDirectoryPage<AylaDirectoryLiveEntry>(
            results: <AylaDirectoryLiveEntry>[entry('7')],
            total: 1,
          );
      aylaGroupLivePageOwnedLivePage =
          (String? cursor, String? owner) async =>
              AylaDirectoryPage<AylaDirectoryLiveEntry>(
                results: <AylaDirectoryLiveEntry>[entry('7')],
                total: 1,
              );
      aylaDirectoryStore.userId = kMe;
      aylaDirectoryStore.requestOverride = (
        AylaDirectoryKind kind,
        AylaDirectoryOptions options,
        String? cursor,
      ) async {
        if (kind != AylaDirectoryKind.live || options.groupId != 'g1') {
          return AylaDirectoryPage<Object>(results: <Object>[], total: 0);
        }
        final AylaDirectoryPage<AylaDirectoryLiveEntry> page =
            await aylaGroupLivePageDirectoryLoader!('g1', cursor);
        return AylaDirectoryPage<Object>(
          results: page.results.cast<Object>(),
          total: page.total,
          hasMore: page.hasMore,
          nextCursor: page.nextCursor,
        );
      };

      await pumpPage(
        tester,
        () => GroupLivePage(groupId: 'g1'),
        location: '/group/g1/live',
      );
      // 目录到达 → 自动进第一个直播间（GroupLive.tsx:61–67）。
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      final AylaLiveRoomBody body = bodyOf(tester);
      expect(
        body.data.viewerSheet.onOpenProfile,
        isNotNull,
        reason: '群内直播此前连 onOpenProfile 都没传（本页有 selfId，见 build 里 selfId 取值）',
      );

      body.data.viewerSheet.onOpenProfile!(
        const AylaLiveViewerItem(userId: 'u-other'),
      );
      await tester.pumpAndSettle();
      expect(find.text(userMark('u-other')), findsOneWidget);
    });
  });

  // ================= 真实手势链路：观众条 → 弹层 → 点行 =================
  //
  // 上面几组锁「页面把回调送进了弹层数据」；这一组用**真手势**走完组件侧那段
  // （整排按钮 → 弹层 → 名单行），回调用的是页面接线时用的**同一个**静态方法
  // （AylaLiveViewerSheetController.openProfile）⇒ 两段合起来才是完整链路。
  group('真实手势：条 → 弹层 → 点行 → 落点', () {
    const List<AylaLiveViewerItem> watchers = <AylaLiveViewerItem>[
      AylaLiveViewerItem(userId: 'u-other', nickname: '小樱'),
      AylaLiveViewerItem(userId: kMe, nickname: '我'),
    ];

    Future<void> pumpStrip(WidgetTester tester) async {
      await pumpPage(
        tester,
        () => Builder(
          builder: (BuildContext context) => Center(
            child: SizedBox(
              width: 480,
              child: AylaLiveViewerStrip(
                count: 2,
                viewers: watchers,
                // 与页面接线同一形状：data.viewerSheet.copyWith(onOpenProfile: …)
                sheet: const AylaLiveViewerSheetData(
                  viewers: watchers,
                  count: 2,
                ).copyWith(
                  onOpenProfile: (AylaLiveViewerItem viewer) =>
                      AylaLiveViewerSheetController.openProfile(
                    context,
                    currentUserId: kMe,
                    targetUserId: viewer.userId,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    Finder byLabel(String label) => find.byWidgetPredicate(
          (Widget w) => w is Semantics && w.properties.label == label,
        );

    testWidgets('点整排开弹层、点「小樱」行 → /user/u-other 且弹层已关', (
      WidgetTester tester,
    ) async {
      await pumpStrip(tester);

      await tester.tap(byLabel('正在观看 2 人，查看完整名单'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('正在观看 · 2 人'), findsOneWidget);

      await tester.tap(byLabel('查看 小樱 的个人主页'));
      await tester.pumpAndSettle();

      expect(find.text(userMark('u-other')), findsOneWidget);
      expect(find.text('正在观看 · 2 人'), findsNothing, reason: 'tsx 123：跳转后关闭弹层');
    });

    testWidgets('点「我」行 → /profile（goUserProfile 的 me 语义）', (
      WidgetTester tester,
    ) async {
      await pumpStrip(tester);

      await tester.tap(byLabel('正在观看 2 人，查看完整名单'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(byLabel('查看 我 的个人主页'));
      await tester.pumpAndSettle();
      expect(find.text(kProfileMark), findsOneWidget);
    });
  });

  // ============== 失败态「重试」键（LiveViewerSheet.tsx:94–100） ==============
  //
  // 与上面同一形态的第二个缺口（2026-11-04 同轮收口）：`AylaLiveViewerSheetData.onRetry`
  // 三页都不赋值 ⇒ `live_viewers.dart:452` 的 `onPressed: data.onRetry` 恒 null，
  // 弹层进 503/读取失败态后「重试」点了完全没反应 —— 而那是 presence 存储不可用时
  // 唯一的恢复出路。
  //
  // web 侧自洽：`LiveViewerSheet.tsx:94–100` 的重试 = `setReloadToken(v => v + 1)`
  // → `useEffect([channelId, reloadToken])` 重拉。
  group('失败态「重试」键：页面接线 + 回调真的能再拉一次', () {
    AylaLiveViewersResult page({int count = 2}) => AylaLiveViewersResult(
          channelId: '7',
          count: count,
          hasMore: false,
          viewers: const <AylaLiveViewer>[
            AylaLiveViewer(userId: 'u1', nickname: '小冰'),
            AylaLiveViewer(userId: 'u2', nickname: '小樱'),
          ],
        );

    testWidgets('弹层错误态：点「重试」→ onRetry 被调用（组件侧真实手势）', (
      WidgetTester tester,
    ) async {
      int retries = 0;
      await pumpPage(
        tester,
        () => AylaLiveViewerSheet(
          preview: const <AylaLiveViewerItem>[],
          data: AylaLiveViewerSheetData(
            error: '暂时读不到在看名单',
            onRetry: () => retries += 1,
          ),
          onClose: () {},
        ),
      );

      expect(find.text('暂时读不到在看名单'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(retries, 1, reason: 'tsx 94–100：重试键必须真的触发重拉');
    });

    testWidgets('LiveRoomPage：弹层数据里带 onRetry', (WidgetTester tester) async {
      await pumpPage(tester, () => const LiveRoomPage(channelId: '7'));
      final AylaLiveRoomBody body = bodyOf(tester);
      expect(
        body.data.viewerSheet.onRetry,
        isNotNull,
        reason: 'onRetry 为 null ⇒ live_viewers.dart:452 的 onPressed 为 null ⇒ 重试键点了没反应',
      );
    });

    testWidgets('LiveStudioPage：弹层数据里带 onRetry', (WidgetTester tester) async {
      await pumpPage(tester, () => const LiveStudioPage(channelId: '7'));
      expect(bodyOf(tester).data.viewerSheet.onRetry, isNotNull);
    });

    testWidgets('GroupLivePage：弹层数据里带 onRetry', (WidgetTester tester) async {
      aylaGroupLivePageDirectoryLoader = (String groupId, String? cursor) async =>
          AylaDirectoryPage<AylaDirectoryLiveEntry>(
            results: <AylaDirectoryLiveEntry>[groupEntry('7')],
            total: 1,
          );
      aylaGroupLivePageOwnedLivePage =
          (String? cursor, String? owner) async =>
              AylaDirectoryPage<AylaDirectoryLiveEntry>(
                results: <AylaDirectoryLiveEntry>[groupEntry('7')],
                total: 1,
              );
      aylaDirectoryStore.userId = kMe;
      aylaDirectoryStore.requestOverride = (
        AylaDirectoryKind kind,
        AylaDirectoryOptions options,
        String? cursor,
      ) async {
        if (kind != AylaDirectoryKind.live || options.groupId != 'g1') {
          return AylaDirectoryPage<Object>(results: <Object>[], total: 0);
        }
        final AylaDirectoryPage<AylaDirectoryLiveEntry> p =
            await aylaGroupLivePageDirectoryLoader!('g1', cursor);
        return AylaDirectoryPage<Object>(
          results: p.results.cast<Object>(),
          total: p.total,
          hasMore: p.hasMore,
          nextCursor: p.nextCursor,
        );
      };

      await pumpPage(
        tester,
        () => GroupLivePage(groupId: 'g1'),
        location: '/group/g1/live',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        bodyOf(tester).data.viewerSheet.onRetry,
        isNotNull,
        reason: "群内直播此前连 onRetry 也没传（本页 channelId 是 int ⇒ 用 '\$channelId'）",
      );
    });

    // ---- 证明「失败态点重试」不会被 load() 的 `if (_loading) return` 卡住 ----
    //
    // 这是本任务里**唯一不能只靠断言参数存在**的部分：`load()` 开头有并发门，
    // 如果失败路径没有把 `_loading` 复位，`retry()` 会静默 no-op（键看着能点、实际没拉）。
    test('失败后 _loading 已复位 ⇒ retry() 真的再拉一次（不被并发门吞掉）', () async {
      int calls = 0;
      final AylaLiveViewerSheetController controller =
          AylaLiveViewerSheetController(
        fetcher: (String channelId) async {
          calls += 1;
          if (calls == 1) throw StateError('presence unavailable'); // 模拟 503
          return page();
        },
      );
      addTearDown(controller.dispose);

      await controller.load('7');
      expect(calls, 1);
      expect(controller.value.error, isNotNull, reason: '第一次必须落成失败态');

      // 失败态点「重试」：走的是页面接线时用的同一个闭包工厂。
      controller.retry('7')();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        calls,
        2,
        reason: '若失败路径没复位 _loading，load() 会在 if (_loading) return 处直接返回，'
            'calls 会停在 1 —— 重试键就成了「看着能点、实际不拉」',
      );
      expect(controller.value.viewers, isNotNull, reason: '重试成功 ⇒ 名单到达');
      expect(controller.value.error, isNull);
    });

    test('retry 闭包捕获的是传入的 channelId（不会重拉错频道）', () async {
      final List<String> asked = <String>[];
      final AylaLiveViewerSheetController controller =
          AylaLiveViewerSheetController(
        fetcher: (String channelId) async {
          asked.add(channelId);
          return page();
        },
      );
      addTearDown(controller.dispose);

      controller.retry('lc-42')();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(asked, <String>['lc-42']);
    });

    test('并发门确实存在：在途时 retry 不叠加第二次请求（对照上一条）', () async {
      int calls = 0;
      final Completer<AylaLiveViewersResult> gate =
          Completer<AylaLiveViewersResult>();
      final AylaLiveViewerSheetController controller =
          AylaLiveViewerSheetController(
        fetcher: (String channelId) {
          calls += 1;
          return gate.future;
        },
      );
      addTearDown(controller.dispose);

      final Future<void> first = controller.load('7');
      controller.retry('7')(); // 在途 → 被 if (_loading) return 挡掉
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1, reason: '在途时不得并发叠加请求');

      gate.complete(page());
      await first;
      expect(controller.value.viewers, isNotNull);
    });
  });

  group('死参数已删除（防「以后又有人以为它有效」）', () {
    test('AylaLiveRoomBody 不再有 onOpenProfile 字段；三个页面不再对它赋值', () {
      const String bodyFile = 'lib/widgets/live/live_room_body.dart';
      final String bodySrc = File(bodyFile).readAsStringSync();
      expect(
        bodySrc.contains('final ValueChanged<AylaLiveViewerItem>? onOpenProfile'),
        isFalse,
        reason: '这个字段零处读取，是本次 bug 的成因（跳转挂在它上面看起来接好了）',
      );
      expect(bodySrc.contains('this.onOpenProfile,'), isFalse);

      for (final String page in <String>[
        'lib/pages/live_room_page.dart',
        'lib/pages/live_studio_page.dart',
      ]) {
        final String src = File(page).readAsStringSync();
        expect(
          src.contains('onOpenProfile: (AylaLiveViewerItem item)'),
          isFalse,
          reason: '$page 不应再向 AylaLiveRoomBody 的死参数赋值',
        );
        // 正接线必须在场：弹层数据里带回调。
        expect(
          src.contains('viewerSheet: viewerSheet.value.copyWith('),
          isTrue,
          reason: '$page 必须把 onOpenProfile 送进 AylaLiveViewerSheetData',
        );
      }
      final String groupSrc =
          File('lib/pages/group_live_page.dart').readAsStringSync();
      expect(groupSrc.contains('viewerSheet: viewerSheet.value.copyWith('), isTrue);
    });
  });
}
