/// 群内帖子页**三连缺陷**（2026-10-09 用户实报）的行为级回归锁。
///
/// ## 三条事实源（web）
/// | 缺陷 | web | 行 |
/// |---|---|---|
/// | ① 下拉刷新缺失 | `GroupPosts.tsx` 的 `<PullToRefresh isAtTop={isAtTop} onRefresh={refresh}>` 包住三态 | 398（`isAtTop` 182） |
/// | ② 分享键 | `PostCard.tsx` 的 `<ShareButton>` **无条件渲染**（不依赖页面注入） | 146–153 |
/// | ③ 已读未读 + 跳转标签 | `usePostViewTracking`（视口上报）+ 上/下未读标签 | 267–279 · 281–356 · 450–476 |
///
/// ## 为什么用 dio 的 `httpClientAdapter`
/// 同 `group_posts_page_test.dart` 的文件头：`TestWidgetsFlutterBinding` 的 FakeAsync 时钟
/// 会把回环 socket 的完成时机从 `pump` 的可推进范围里摘出去 ⇒ 换 dio 官方扩展点
/// （仓内先例 `media_upload_test.dart:151/294`），请求在 microtask 上完成、`pump` 可推进。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RendererBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/models/conversation.dart' show AylaConversationSummary;
import '../lib/core/net/dio_client.dart';
import '../lib/pages/group_posts_page.dart';
import '../lib/state/chat_providers.dart' show chatStateProvider;
import '../lib/theme/app_theme.dart';
import '../lib/widgets/base/media_interaction.dart' show AylaPullToRefresh;
import '../lib/widgets/base/share.dart' show AylaShareButton, AylaShareSheet;
import '../lib/widgets/posts/masonry_grid.dart' show aylaClearMasonryMemory;
import '../lib/widgets/posts/post_card.dart' show AylaPostCard;

class _NoTokens implements AuthTokenStore {
  @override
  String? get accessToken => null;
  @override
  String? get refreshToken => null;
  @override
  void setTokens(String access, String? refresh) {}
  @override
  void clear() {}
}

Map<String, dynamic> _postJson(int id, {bool viewed = false}) => <String, dynamic>{
      'id': id,
      'title': '帖子 $id',
      'body': '正文 $id',
      'author': <String, dynamic>{'id': 'u1', 'nickname': '小樱'},
      'author_id': 'u1',
      'group': 'g1',
      'allowed_group_ids': <String>['g1'],
      'images': <Object?>[],
      'is_viewed': viewed,
      'view_count': 3,
      'comment_count': 1,
      'is_author': false,
      'created_at': '2026-10-01T00:00:00Z',
    };

/// 最小帖子后端：实现本链路打到的 `GET /posts/` 与 `POST /posts/views/`。
class _PostsAdapter implements HttpClientAdapter {
  _PostsAdapter({this.postCount = 3, this.hasMore = false});

  final int postCount;
  final bool hasMore;

  /// 列表请求次数（下拉刷新断言用）。
  int listHits = 0;

  /// 最近一次浏览上报的 id 列表（视口上报断言用）。
  List<String> lastViewIds = <String>[];

  /// 已上报过的 id（模拟后端幂等去重：第二次上报返回空 `updated`）。
  final Set<String> reported = <String>{};

  static const Map<String, List<String>> _json = <String, List<String>>{
    Headers.contentTypeHeader: <String>[Headers.jsonContentType],
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'POST' && options.path == '/posts/views/') {
      final Object? body = options.data;
      lastViewIds = <String>[
        if (body is Map && body['post_ids'] is List)
          for (final Object? o in body['post_ids'] as List) '$o',
      ];
      // 幂等：只有**首次**上报的 id 出现在 updated 里（web 契约原话：
      // 「仅含本次实际新增浏览的帖子」）。
      final Map<String, Object?> fresh = <String, Object?>{
        for (final String id in lastViewIds)
          if (reported.add(id)) id: 9,
      };
      return ResponseBody.fromString(
        jsonEncode(<String, Object?>{'updated': fresh}),
        200,
        headers: _json,
      );
    }
    if (options.method == 'GET' && options.path == '/posts/') {
      listHits += 1;
      return ResponseBody.fromString(
        jsonEncode(<String, Object?>{
          'results': <Object?>[
            for (int i = 1; i <= postCount; i++) _postJson(i),
          ],
          'next_cursor': hasMore ? 'c1' : null,
          'has_more': hasMore,
          'total': postCount,
        }),
        200,
        headers: _json,
      );
    }
    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{
        'results': <Object?>[],
        'next_cursor': null,
        'has_more': false,
        'total': 0,
      }),
      200,
      headers: _json,
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _PostsAdapter adapter;

  setUpAll(() {
    DioClient.instance.init(tokenStore: _NoTokens(), onSessionExpired: () {});
  });

  setUp(() {
    aylaClearMasonryMemory();
    adapter = _PostsAdapter();
    DioClient.instance.dio.httpClientAdapter = adapter;
  });

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = const Size(560, 700),
    _PostsAdapter? custom,
  }) async {
    if (custom != null) {
      adapter = custom;
      DioClient.instance.dio.httpClientAdapter = custom;
    }
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    final GoRouter router = GoRouter(
      initialLocation: '/group/g1/posts',
      routes: <RouteBase>[
        GoRoute(
          path: '/group/:id/posts',
          pageBuilder: (BuildContext c, GoRouterState s) => NoTransitionPage<void>(
            child: GroupPostsPage(groupId: s.pathParameters['id'] ?? ''),
          ),
        ),
        GoRoute(
          path: '/group/:id/posts/:postId',
          pageBuilder: (BuildContext c, GoRouterState s) => NoTransitionPage<void>(
            child: GroupPostsPage(
              groupId: s.pathParameters['id'] ?? '',
              postId: s.pathParameters['postId'],
            ),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: buildAylaTheme(),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: Scaffold(backgroundColor: Colors.transparent, body: child),
          ),
        ),
      ),
    );
    // 推到列表卡片出现（dio 链里既有 microtask 也有 Timer ⇒ 每 5 轮补 1ms pump）。
    for (int i = 0; i < 400 && find.byType(AylaPostCard).evaluate().isEmpty; i++) {
      await tester.pump(
        i % 5 == 0 ? const Duration(milliseconds: 1) : Duration.zero,
      );
    }
    await tester.pump();
    await tester.pump();
    return container;
  }

  /// 收尾：放掉延迟 Timer（stagger / 去抖 / 分页组件的 Timer）。
  Future<void> drain(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  List<String> jumpTags(WidgetTester tester) => <String>[
        for (final Text t in tester.widgetList<Text>(find.byType(Text)))
          if ((t.data ?? '').contains('未读帖子')) t.data!,
      ];

  // ======================= ① 下拉刷新 =======================

  group('① 下拉刷新（web tsx 398）', () {
    testWidgets('列表态挂上 AylaPullToRefresh，且过阈值下拉会重拉首页', (WidgetTester tester) async {
      await pump(tester);
      expect(find.byType(AylaPostCard), findsNWidgets(3));
      expect(
        find.byType(AylaPullToRefresh),
        findsOneWidget,
        reason: 'web tsx 398 把三态都包在 <PullToRefresh> 里 ⇒ Flutter 侧必须挂上',
      );

      final int before = adapter.listHits;
      final Rect box = tester.getRect(find.byType(AylaPullToRefresh));
      final TestGesture gesture = await tester.startGesture(
        Offset(box.center.dx, box.top + 40),
      );
      await tester.pump();
      // dy = 120 > threshold 64（与 pull_to_refresh_unbounded_test 同款手势）
      await gesture.moveTo(Offset(box.center.dx, box.top + 160));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        adapter.listHits,
        before + 1,
        reason: '过阈值松手必须触发 onRefresh（= web 的 refresh = load）',
      );
      await drain(tester);
    });

    testWidgets('未越过阈值 ⇒ 回弹、不重拉', (WidgetTester tester) async {
      await pump(tester);
      final int before = adapter.listHits;
      final Rect box = tester.getRect(find.byType(AylaPullToRefresh));
      final TestGesture gesture = await tester.startGesture(
        Offset(box.center.dx, box.top + 40),
      );
      await tester.pump();
      await gesture.moveTo(Offset(box.center.dx, box.top + 80)); // dy = 40 < 64
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(adapter.listHits, before, reason: '不足阈值不得触发刷新（web createPullTracker）');
      await drain(tester);
    });

    testWidgets('内容未超一屏时**不得**出现 unbounded 高度断言', (WidgetTester tester) async {
      // 回归锁（`pull_to_refresh_unbounded_test.dart` 的 P0）：本页是
      // SingleChildScrollView 宿主 ⇒ 子级主轴约束 0..∞，Stack 双 Positioned 会崩。
      await pump(tester, custom: _PostsAdapter(postCount: 1));
      expect(tester.takeException(), isNull);
      expect(find.byType(AylaPostCard), findsOneWidget);
      await drain(tester);
    });
  });

  // ======================= ② 分享键 =======================

  group('② 分享键（web PostCard.tsx:146–153 无条件渲染）', () {
    testWidgets('底排分享键三张卡各一枚、全部已接线（onPressed != null）', (WidgetTester tester) async {
      await pump(tester);
      expect(find.byType(AylaPostCard), findsNWidgets(3));

      final List<AylaShareButton> shares =
          tester.widgetList<AylaShareButton>(find.byType(AylaShareButton)).toList();
      expect(
        shares.length,
        3,
        reason: 'web PostCard.tsx:146 的 <ShareButton> 是**无条件渲染** ⇒ 非 detail 档恒有一枚',
      );
      expect(
        shares.every((AylaShareButton s) => s.onPressed != null),
        isTrue,
        reason: 'onPressed == null ⇒ AylaShareButton 判禁用、指针变 not-allowed（用户实报的形态）',
      );
      expect(tester.takeException(), isNull);
      await drain(tester);
    });

    testWidgets('hover 分享键的实际指针是 click（不是 not-allowed）', (WidgetTester tester) async {
      await pump(tester);
      final Finder share = find.byType(AylaShareButton).first;
      final TestGesture mouse =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(share));
      await tester.pump();

      // 与用户实报的「悬停直接变禁止」直接对应：`theme/buttons.dart:176–178`
      // 在 `onPressed == null` 时给 `SystemMouseCursors.forbidden`。
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
        reason: '底排分享键必须可点（web 无条件渲染且永远可点）',
      );
      await drain(tester);
    });

    testWidgets('点击分享键 ⇒ 打开分享弹窗', (WidgetTester tester) async {
      await pump(tester);
      expect(find.byType(AylaShareSheet), findsNothing);
      await tester.tap(find.byType(AylaShareButton).first, warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byType(AylaShareSheet),
        findsOneWidget,
        reason: 'web ShareButton 内部 createPortal 打开 ShareSheet（不依赖页面注入）',
      );
      await drain(tester);
    });
  });

  // ======================= ③ 已读未读 + 跳转标签 =======================

  group('③ 已读未读与跳转标签（web tsx 267–279 · 281–356 · 450–476）', () {
    testWidgets('视口内的帖子会上报浏览（去抖 300ms 后批量一次）', (WidgetTester tester) async {
      await pump(tester, custom: _PostsAdapter(postCount: 3));
      expect(find.byType(AylaPostCard), findsNWidgets(3));

      // 300ms 去抖（web FLUSH_DELAY_MS）
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        adapter.lastViewIds,
        isNotEmpty,
        reason: '进入视口即视为浏览（web usePostViewTracking）——首屏三张都应在视口内',
      );
      expect(adapter.lastViewIds.toSet(), <String>{'1', '2', '3'});
      // 一次批量上报（不是每帖一次请求）
      expect(adapter.lastViewIds.length, 3);
      await drain(tester);
    });

    testWidgets('视口内的未读按中心归入上/下（web tsx 316–321 的兜底档）', (WidgetTester tester) async {
      // ⚠️ 这条锁的是 web 的**原文规则**，不是「视口内就不显示」——
      // tsx 312–322 三分支：`bottom < 容器顶` ⇒ 上方；`top > 容器底` ⇒ 下方；
      // **否则（在视口内）** ⇒ 按「卡片中心 vs 视口中心」归入上/下
      //（注释原话：「视口内：按中心相对视口中心归入上/下（上报去抖期间仍可跳转）」）。
      // 单帖落在视口上半 ⇒ 计入「上方」⇒ 显示上标签。这是 web 的既定行为。
      await pump(tester, custom: _PostsAdapter(postCount: 1));
      expect(find.byType(AylaPostCard), findsOneWidget);
      expect(
        jumpTags(tester),
        <String>['↑ 1 条未读帖子'],
        reason: '视口内上半 ⇒ 归入「上方」（web tsx 318–321）',
      );
      await drain(tester);
    });

    testWidgets('滚过若干未读后：出现「↑ N 条未读帖子」且点击回到第一条未读',
        (WidgetTester tester) async {
      await pump(
        tester,
        size: const Size(560, 700),
        custom: _PostsAdapter(postCount: 10),
      );
      expect(find.byType(AylaPostCard), findsNWidgets(10));

      await tester.drag(find.byType(Scrollable).first, const Offset(0, -1200));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      final List<String> tags = jumpTags(tester);
      expect(
        tags.where((String t) => t.startsWith('↑')).length,
        1,
        reason: '上方有未读时必须出现上标签（web tsx 451–463）；实际=$tags',
      );

      final ScrollPosition pos =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      final double before = pos.pixels;
      expect(before, greaterThan(0), reason: '前提：确实滚下去了');

      await tester.tap(find.textContaining('↑ '), warnIfMissed: false);
      await tester.pump();
      await tester.pump();
      expect(
        pos.pixels,
        lessThan(before),
        reason: '点击上标签必须滚向第一条未读（web jumpToUnread("above")）',
      );
      await drain(tester);
    });

    testWidgets('已读（is_viewed=true）的帖子不计入未读标签', (WidgetTester tester) async {
      await pump(
        tester,
        size: const Size(560, 700),
        custom: _ReadAdapter(),
      );
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -1200));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(
        jumpTags(tester),
        isEmpty,
        reason: '全部 is_viewed=true ⇒ 无未读 ⇒ 无标签（web tsx 281–285）',
      );
      await drain(tester);
    });
  });
}

/// 全部帖子 `is_viewed=true` 的后端（已读档）。
class _ReadAdapter extends _PostsAdapter {
  _ReadAdapter() : super(postCount: 10);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'GET' && options.path == '/posts/') {
      listHits += 1;
      return ResponseBody.fromString(
        jsonEncode(<String, Object?>{
          'results': <Object?>[
            for (int i = 1; i <= postCount; i++) _postJson(i, viewed: true),
          ],
          'next_cursor': null,
          'has_more': false,
          'total': postCount,
        }),
        200,
        headers: const <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      );
    }
    return super.fetch(options, requestStream, cancelFuture);
  }
}
