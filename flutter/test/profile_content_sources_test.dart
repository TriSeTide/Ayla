/// 个人主页「内容分区」**数据源**定向测试 —— 逐条对照
/// `web/src/components/ProfileContentSections.tsx:63–105` 与
/// `lib/pages/profile_content_support.dart`。
///
/// 五个必测面（交付要求 ①–⑤）：
/// ① 有 `live_room_id` ⇒ 按该 id 取详情并渲染直播卡；
/// ② 403（`can_view` 不可见）⇒ **不渲染该卡且不报错**；
/// ③ 帖子 3 条 ⇒ 渲染 3 行 +「更多帖子」；
/// ④ 真失败 ⇒ **显式错误态**（不是空列表）；
/// ⑤ `mine` 与 other 的空态文案与「更多帖子」目标不同。
/// 另有：`is_live` / `is_in_voice` 为真但 room id 为 null 的 else 分支、非 403 失败带来源
/// 前缀（登记偏离 web）、骨架初值、`cancel` 语义、`show_content = false` 不装载（tsx:201 守卫）。
///
/// ⚠️ 全程 `pump()` 而**不** `pumpAndSettle()`：帖子骨架（`AylaSkeleton` 的 frost-pulse）
/// 与头像光环呼吸都是**无限循环**动画 ⇒ `pumpAndSettle` 会一直等下去（同
/// `profile_content_sections_test.dart` 的口径）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/api/users_api.dart' show AylaFriendRelation, AylaUserDetail;
import '../lib/core/models/user_public.dart';
import '../lib/core/net/dio_client.dart';
import '../lib/pages/profile_content_support.dart';
import '../lib/pages/profile_page.dart';
import '../lib/pages/user_profile_page.dart';
import '../lib/state/auth_state.dart';
import '../lib/theme/app_theme.dart' show buildAylaTheme;
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/loading.dart' show AylaSkeleton;
import '../lib/widgets/base/profile_content_sections.dart';

// ======================= 公共替身数据 =======================

const List<AylaProfilePostItem> _threePosts = <AylaProfilePostItem>[
  AylaProfilePostItem(id: 'p1', title: '帖子一'),
  AylaProfilePostItem(id: 'p2', title: '帖子二'),
  AylaProfilePostItem(id: 'p3', title: '帖子三'),
];

/// 本人页的登录用户（`GET /me/` 的投影；本页只读 id 与 is_live/is_in_voice/room id）。
const AuthUser _me = AuthUser(
  id: 'u1',
  username: 'ayla',
  nickname: '爱莉',
  avatar: '',
  signature: '你好',
  status: 'auto',
  online: true,
  displayStatus: '在线',
  dateJoined: '2026-01-01',
  isInVoice: false,
  voiceRoomId: null,
  isLive: false,
  liveRoomId: null,
  showContent: false,
  email: 'a@b.c',
);

/// `GET /users/u2/` 的替身结果（`relation` 非 self ⇒ 不会触发 /profile 重定向）。
AylaUserDetail _detail({bool showContent = true}) => AylaUserDetail(
      user: const AylaUserPublic(id: 'u2', username: 'bob', nickname: '鲍勃'),
      relation: AylaFriendRelation.none,
      showContent: showContent,
      signature: '嗨',
    );

// ======================= 装载宿主（等价页面接线） =======================

/// 装载 → 渲染：等价页面里「快照 → `AylaProfileContentSections` 数据入参」的那几行。
class _ContentHost extends StatefulWidget {
  const _ContentHost({required this.target, required this.fetchers});

  final AylaProfileContentTarget target;
  final AylaProfileContentFetchers fetchers;

  @override
  State<_ContentHost> createState() => _ContentHostState();
}

class _ContentHostState extends State<_ContentHost> {
  AylaProfileContentState _state = const AylaProfileContentState();
  AylaProfileContentLoad? _load;

  @override
  void initState() {
    super.initState();
    _load = aylaLoadProfileContent(
      target: widget.target,
      fetchers: widget.fetchers,
      onUpdate: (AylaProfileContentState next) => setState(() => _state = next),
    );
  }

  @override
  void dispose() {
    _load?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AylaProfileContentSections(
        displayName: widget.target.mine ? '爱莉' : '鲍勃',
        mine: widget.target.mine,
        live: _state.live,
        voice: _state.voice,
        posts: _state.posts,
        postsLoading: _state.postsLoading,
        postsError: _state.error,
      );
}

void main() {
  // ⚠️ 默认宽屏视口（≥769）：≤768 会走窄屏单列，直播/语音上下堆叠。
  Widget host(
    AylaProfileContentTarget target,
    AylaProfileContentFetchers fetchers, {
    Size viewport = const Size(900, 900),
  }) {
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: SizedBox.fromSize(
              size: viewport,
              child: SingleChildScrollView(
                child: _ContentHost(target: target, fetchers: fetchers),
              ),
            ),
          ),
        ),
      ),
    );
  }

  group('装载（profile_content_support.dart）', () {
    testWidgets('① 直播中：按 live_room_id 取详情并渲染直播卡（tsx 73–79 / 113–135）', (
      WidgetTester tester,
    ) async {
      final List<String> asked = <String>[];
      await tester.pumpWidget(host(
        const AylaProfileContentTarget(
          ownerId: 'u1',
          mine: true,
          isLive: true,
          liveRoomId: '77',
        ),
        AylaProfileContentFetchers(
          live: (String roomId) async {
            asked.add(roomId);
            return const AylaProfileLiveData(
              id: '77',
              title: '爱莉的直播间',
              ownerNickname: '爱莉',
            );
          },
          posts: (String ownerId, bool mine) async =>
              const <AylaProfilePostItem>[],
        ),
      ));
      await tester.pump();
      await tester.pump();

      expect(asked, <String>['77'], reason: '取数用的是 owner.live_room_id');
      expect(find.text('正在直播'), findsOneWidget);
      expect(find.text('爱莉的直播间'), findsOneWidget);
      expect(find.text('LIVE'), findsOneWidget);
      expect(find.text('爱莉 正在直播'), findsOneWidget); // tsx 130 副行
    });

    testWidgets('① 补：is_live 为真但 live_room_id 为 null ⇒ 不发请求、不渲染该卡（tsx 77–79 else）', (
      WidgetTester tester,
    ) async {
      int liveCalls = 0;
      await tester.pumpWidget(host(
        const AylaProfileContentTarget(ownerId: 'u1', mine: true, isLive: true),
        AylaProfileContentFetchers(
          live: (String roomId) async {
            liveCalls++;
            return const AylaProfileLiveData(id: 'x', title: '不该出现');
          },
          posts: (String ownerId, bool mine) async =>
              const <AylaProfilePostItem>[],
        ),
      ));
      await tester.pump();
      await tester.pump();

      expect(liveCalls, 0);
      expect(find.text('正在直播'), findsNothing);
      expect(find.text('不该出现'), findsNothing);
    });

    testWidgets('② 403（can_view 不可见）⇒ 直播/语音都不渲染该卡且不报错（tsx 76/84）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(
        const AylaProfileContentTarget(
          ownerId: 'u1',
          mine: false,
          isLive: true,
          liveRoomId: '9',
          isInVoice: true,
          voiceRoomId: '5',
        ),
        AylaProfileContentFetchers(
          live: (String roomId) async =>
              throw const ApiException(403, 'can_view 不满足'),
          voice: (String roomId) async =>
              throw const ApiException(403, 'can_view 不满足'),
          posts: (String ownerId, bool mine) async =>
              const <AylaProfilePostItem>[],
        ),
      ));
      await tester.pump();
      await tester.pump();

      expect(find.text('正在直播'), findsNothing);
      expect(find.text('正在语音'), findsNothing);
      expect(find.textContaining('can_view'), findsNothing);
      // 403 不是「取到 0 条」也不是错误态 ⇒ 帖子卡落在**空态**（他人档文案，tsx 176）
      expect(find.text('暂无帖子'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('② 补：直播非 403 失败 ⇒ 错误态可见并带来源前缀（登记偏离 web 的静默）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(
        const AylaProfileContentTarget(
          ownerId: 'u1',
          mine: true,
          isLive: true,
          liveRoomId: '9',
        ),
        AylaProfileContentFetchers(
          live: (String roomId) async =>
              throw const ApiException(500, '服务器开小差了'),
          posts: (String ownerId, bool mine) async =>
              const <AylaProfilePostItem>[],
        ),
      ));
      await tester.pump();
      await tester.pump();

      expect(find.text('正在直播'), findsNothing);
      // 「失败不得静默」：组件只有这一个错误位 ⇒ 带来源前缀并入（文件头差异 3）
      expect(find.text('直播间加载失败：服务器开小差了'), findsOneWidget);
    });

    testWidgets('③ 帖子 3 条 ⇒ 渲染 3 行 + 计数徽标 +「更多帖子」（tsx 89–101 / 162–197）', (
      WidgetTester tester,
    ) async {
      final List<String> calls = <String>[];
      await tester.pumpWidget(host(
        const AylaProfileContentTarget(ownerId: 'u2', mine: false),
        AylaProfileContentFetchers(
          posts: (String ownerId, bool mine) async {
            calls.add(ownerId + (mine ? ':mine' : ':other'));
            return _threePosts;
          },
        ),
      ));
      await tester.pump();
      await tester.pump();

      expect(calls, <String>['u2:other'], reason: '他人页取 owner 口径（tsx 91）');
      expect(find.byType(AylaSkeleton), findsNothing);
      expect(find.text('帖子一'), findsOneWidget);
      expect(find.text('帖子二'), findsOneWidget);
      expect(find.text('帖子三'), findsOneWidget);
      expect(find.text('3'), findsOneWidget); // .profile-content-count
      expect(find.text('更多帖子'), findsOneWidget);
    });

    testWidgets('③ 补：取数在途 ⇒ 三条高 44 骨架（tsx 67 / 168–172）', (
      WidgetTester tester,
    ) async {
      final Completer<List<AylaProfilePostItem>> pending =
          Completer<List<AylaProfilePostItem>>();
      await tester.pumpWidget(host(
        const AylaProfileContentTarget(ownerId: 'u1', mine: true),
        AylaProfileContentFetchers(
          posts: (String ownerId, bool mine) => pending.future,
        ),
      ));
      await tester.pump();

      expect(find.byType(AylaSkeleton), findsNWidgets(3));
      expect(tester.getSize(find.byType(AylaSkeleton).first).height, 44);
      expect(find.text('更多帖子'), findsNothing);

      pending.complete(const <AylaProfilePostItem>[]);
      await tester.pump();
      await tester.pump();
      expect(find.byType(AylaSkeleton), findsNothing);
      expect(find.text('还没有发帖'), findsOneWidget); // 0 条 ⇒ 真空态（不是错误态）
    });

    testWidgets('④ 帖子真失败 ⇒ 显式错误态，**不是空列表**（tsx 97–101 / 174）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(
        const AylaProfileContentTarget(ownerId: 'u1', mine: true),
        AylaProfileContentFetchers(
          posts: (String ownerId, bool mine) async =>
              throw const ApiException(500, '服务器开小差了'),
        ),
      ));
      await tester.pump();
      await tester.pump();

      // web 口径：e.message（tsx 99）
      expect(find.text('服务器开小差了'), findsOneWidget);
      // 关键区分：既不是「还没有发帖」也不是「暂无帖子」，更没有列表/更多键
      expect(find.text('还没有发帖'), findsNothing);
      expect(find.text('暂无帖子'), findsNothing);
      expect(find.text('更多帖子'), findsNothing);
    });

    testWidgets('④ 补：非 ApiException 失败 ⇒ 兜底文案「帖子加载失败」（web tsx:99 原文）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(
        const AylaProfileContentTarget(ownerId: 'u1', mine: true),
        AylaProfileContentFetchers(
          posts: (String ownerId, bool mine) async => throw StateError('boom'),
        ),
      ));
      await tester.pump();
      await tester.pump();

      expect(find.text('帖子加载失败'), findsOneWidget);
      expect(find.text('还没有发帖'), findsNothing);
    });

    testWidgets('⑤a 空态文案：mine ⇒「还没有发帖」（tsx 176）', (WidgetTester tester) async {
      await tester.pumpWidget(host(
        const AylaProfileContentTarget(ownerId: 'u1', mine: true),
        AylaProfileContentFetchers(
          posts: (String ownerId, bool mine) async =>
              const <AylaProfilePostItem>[],
        ),
      ));
      await tester.pump();
      await tester.pump();
      expect(find.text('还没有发帖'), findsOneWidget);
      expect(find.text('暂无帖子'), findsNothing);
    });

    testWidgets('⑤a 空态文案：other ⇒「暂无帖子」（tsx 176）', (WidgetTester tester) async {
      await tester.pumpWidget(host(
        const AylaProfileContentTarget(ownerId: 'u2', mine: false),
        AylaProfileContentFetchers(
          posts: (String ownerId, bool mine) async =>
              const <AylaProfilePostItem>[],
        ),
      ));
      await tester.pump();
      await tester.pump();
      expect(find.text('暂无帖子'), findsOneWidget);
      expect(find.text('还没有发帖'), findsNothing);
    });
  });

  group('取数参数、跳转目标与 cancel（web 的 query 与 Link to）', () {
    test('帖子参数：mine ⇒ scope=mine；他人 ⇒ owner=<id>（tsx 91）', () {
      final ({String? scope, String? owner}) mine =
          aylaProfilePostsQuery(ownerId: 'u1', mine: true);
      expect(mine.scope, 'mine');
      expect(mine.owner, isNull);

      final ({String? scope, String? owner}) other =
          aylaProfilePostsQuery(ownerId: 'u2', mine: false);
      expect(other.scope, isNull);
      expect(other.owner, 'u2');
    });

    test('帖子取前 3 条（tsx 91 的 limit: 3）', () {
      expect(kAylaProfilePostsLimit, 3);
    });

    test('⑤b「更多帖子」目标：mine ⇒ /posts/mine；他人 ⇒ /user/<id>/posts（tsx 105）', () {
      expect(aylaProfileMorePostsPath(mine: true, ownerId: 'u1'), '/posts/mine');
      expect(
        aylaProfileMorePostsPath(mine: false, ownerId: 'u2'),
        '/user/u2/posts',
      );
    });

    test('行跳转目标：直播 / 语音 / 帖子（tsx 119/145/181）', () {
      expect(aylaProfileLivePath('l1'), '/live/l1');
      expect(aylaProfileVoicePath('v1'), '/voice/v1');
      expect(aylaProfilePostPath('p1'), '/posts/p1');
    });

    test('cancel：作废后在途结果不落地（web cleanup 的 cancelled = true，tsx 102）', () async {
      final List<AylaProfileContentState> seen = <AylaProfileContentState>[];
      final AylaProfileContentLoad load = aylaLoadProfileContent(
        target: const AylaProfileContentTarget(ownerId: 'u1', mine: true),
        fetchers: AylaProfileContentFetchers(
          posts: (String ownerId, bool mine) async => _threePosts,
        ),
        onUpdate: seen.add,
      );
      load.cancel();
      // 让 microtask 与替身的 await 全部走完
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(seen, isEmpty);
    });

    test('未 cancel：正常回调完整快照（postsLoading 由 true 转 false）', () async {
      final List<AylaProfileContentState> seen = <AylaProfileContentState>[];
      aylaLoadProfileContent(
        target: const AylaProfileContentTarget(ownerId: 'u1', mine: true),
        fetchers: AylaProfileContentFetchers(
          posts: (String ownerId, bool mine) async => _threePosts,
        ),
        onUpdate: seen.add,
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(1));
      expect(seen.single.postsLoading, isFalse);
      expect(seen.single.posts, hasLength(3));
      expect(seen.single.error, isNull);
    });
  });

  group('页面接线（/profile 与 /user/:id）', () {
    /// 页面级宿主：真 Router + 注入替身（范本 `create_live_sheet_test.dart` 的最小路由表）。
    /// 落地页文案即「跳到了哪」的凭证。
    Future<void> pumpPage(
      WidgetTester tester, {
      required String initialLocation,
      required Widget page,
      required ProviderContainer container,
    }) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final GoRouter router = GoRouter(
        initialLocation: initialLocation,
        routes: <RouteBase>[
          GoRoute(
            path: initialLocation,
            builder: (BuildContext c, GoRouterState s) => page,
          ),
          // ⚠️ /posts/mine 必须排在 /posts/:postId 之前（同 app_router.dart 的声明顺序纪律）
          GoRoute(path: '/posts/mine', builder: (c, s) => const Text('MY-POSTS')),
          GoRoute(
            path: '/user/:userId/posts',
            builder: (c, s) =>
                Text("USER-POSTS:${s.pathParameters['userId'] ?? ''}"),
          ),
          GoRoute(
            path: '/posts/:postId',
            builder: (c, s) =>
                Text("POST-DETAIL:${s.pathParameters['postId'] ?? ''}"),
          ),
          GoRoute(
            path: '/live/:channelId',
            builder: (c, s) =>
                Text("LIVE-ROOM:${s.pathParameters['channelId'] ?? ''}"),
          ),
          GoRoute(
            path: '/voice/:channelId',
            builder: (c, s) =>
                Text("VOICE-ROOM:${s.pathParameters['channelId'] ?? ''}"),
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
    }

    testWidgets('ProfilePage：scope=mine + 3 条渲染 +「更多帖子」跳 /posts/mine（tsx 310/105）', (
      WidgetTester tester,
    ) async {
      final List<String> calls = <String>[];
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(authNotifierProvider.notifier)
        ..setTokens('access', 'refresh')
        ..setUser(_me);

      await pumpPage(
        tester,
        initialLocation: '/profile',
        container: container,
        page: ProfilePage(
          debugFetchers: AylaProfileContentFetchers(
            posts: (String ownerId, bool mine) async {
              calls.add(ownerId + (mine ? ':mine' : ':other'));
              return _threePosts;
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // 两列入场动画走完

      expect(calls, <String>['u1:mine'], reason: '本人页走 scope=mine');
      expect(find.text('帖子一'), findsOneWidget);
      expect(find.text('还没有发帖'), findsNothing);

      await tester.tap(find.text('更多帖子'));
      await tester.pump();
      await tester.pump();
      expect(find.text('MY-POSTS'), findsOneWidget);
    });

    testWidgets('ProfilePage：0 条 ⇒「还没有发帖」（mine 空态，tsx 176）', (
      WidgetTester tester,
    ) async {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(authNotifierProvider.notifier)
        ..setTokens('access', 'refresh')
        ..setUser(_me);

      await pumpPage(
        tester,
        initialLocation: '/profile',
        container: container,
        page: ProfilePage(
          debugFetchers: AylaProfileContentFetchers(
            posts: (String ownerId, bool mine) async =>
                const <AylaProfilePostItem>[],
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('还没有发帖'), findsOneWidget);
      expect(find.text('暂无帖子'), findsNothing);
    });

    testWidgets('UserProfilePage：owner=<id> + 3 条渲染 +「更多帖子」跳 /user/u2/posts（tsx 203/105）', (
      WidgetTester tester,
    ) async {
      final List<String> calls = <String>[];
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);

      await pumpPage(
        tester,
        initialLocation: '/user/u2',
        container: container,
        page: UserProfilePage(
          userId: 'u2',
          debugUserDetail: (String userId) async => _detail(),
          debugFetchers: AylaProfileContentFetchers(
            posts: (String ownerId, bool mine) async {
              calls.add(ownerId + (mine ? ':mine' : ':other'));
              return _threePosts;
            },
          ),
        ),
      );
      await tester.pump(); // 资料到手
      await tester.pump(); // 内容分区到手
      await tester.pump(const Duration(milliseconds: 400));

      expect(calls, <String>['u2:other'], reason: '他人页走 owner=<id>');
      expect(find.text('帖子一'), findsOneWidget);

      await tester.tap(find.text('更多帖子'));
      await tester.pump();
      await tester.pump();
      expect(find.text('USER-POSTS:u2'), findsOneWidget);
    });

    testWidgets('UserProfilePage：0 条 ⇒「暂无帖子」（other 空态，tsx 176）', (
      WidgetTester tester,
    ) async {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);

      await pumpPage(
        tester,
        initialLocation: '/user/u2',
        container: container,
        page: UserProfilePage(
          userId: 'u2',
          debugUserDetail: (String userId) async => _detail(),
          debugFetchers: AylaProfileContentFetchers(
            posts: (String ownerId, bool mine) async =>
                const <AylaProfilePostItem>[],
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('暂无帖子'), findsOneWidget);
      expect(find.text('还没有发帖'), findsNothing);
    });

    testWidgets('UserProfilePage：对方 show_content=false ⇒ 不装载、不渲染内容分区（tsx 201 守卫）', (
      WidgetTester tester,
    ) async {
      int postCalls = 0;
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);

      await pumpPage(
        tester,
        initialLocation: '/user/u2',
        container: container,
        page: UserProfilePage(
          userId: 'u2',
          debugUserDetail: (String userId) async => _detail(showContent: false),
          debugFetchers: AylaProfileContentFetchers(
            posts: (String ownerId, bool mine) async {
              postCalls++;
              return _threePosts;
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(postCalls, 0, reason: '看不到就不发请求（web tsx:201 的 show_content && 守卫）');
      expect(find.text('更多帖子'), findsNothing);
      expect(find.text('暂无帖子'), findsNothing);
    });
  });
}
