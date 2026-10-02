/// 群内帖子子界面的入场动画定向测试 —— 事实源 `GroupPosts.tsx:378` 的
/// `useListEntryMotion(listRef, ".posts-feed-item", suppressed, replayNonce)`
/// 与 `hooks/useListEntryMotion.ts:74–80` 的动画配方：
///
/// ```
/// { opacity: 0, transform: translateY(20px) } → { opacity: 1, transform: translateY(0) }
/// duration 300 · easing ease-out · fill backwards · delay = staggerDelay(index)
/// ```
///
/// 动画挂在**每卡外层** `.posts-feed-item`（`tsx 419–423`），不是卡本体。
///
/// 覆盖三件事：
/// ① 卡片挂载后有入场（位移从 +20 → 0）；
/// ② reduced-motion（`MediaQuery.disableAnimations`）不播；
/// ③ 从详情返回列表**不重播**（`skipRevealRestoreKey === scrollRestoreKey`，
///    `tsx 91–93 / 362–365 / 428–430` 与 `tsx 378–380` 的 suppressed 表达式）。
///
/// ## 为什么用 dio 的 `httpClientAdapter`
/// 页面数据只能从 `AylaPostsApi.listPosts` 进来（无 `requestOverride` 注入点，
/// 与 `posts_frames_test.dart` 的帧桥不同）。`HttpServer` 回环在这里不可用：
/// `TestWidgetsFlutterBinding` 的 FakeAsync 时钟会把 socket 的完成时机从
/// `pump` 的可推进范围内摘出去（实测 `hits == 0`、页面永远停在「正在加载帖子…」）。
/// 换用 dio 官方扩展点（仓内先例：`media_upload_test.dart:151/294`）后请求在
/// microtask 上完成，`pump` 即可推进 —— 这是测试宿主差异，不影响被测语义。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/models/post.dart' show AylaPost;
import '../lib/core/net/dio_client.dart';
import '../lib/pages/group_posts_page.dart';
import '../lib/theme/app_theme.dart';
import '../lib/widgets/base/reveal.dart';
import '../lib/theme/tokens.dart' show AylaSpacing;
import '../lib/widgets/posts/masonry_grid.dart'
    show AylaMasonryGrid, aylaClearMasonryMemory;
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

Map<String, dynamic> _postJson(int id) => <String, dynamic>{
  'id': id,
  'title': '帖子 $id',
  'body': '正文 $id',
  'author': <String, dynamic>{'id': 'u1', 'nickname': '小樱'},
  'author_id': 'u1',
  'group': 'g1',
  'allowed_group_ids': <String>[],
  'images': <Object?>[],
  'is_viewed': false,
  'created_at': '2026-10-01T00:00:00Z',
};

/// 最小帖子后端：只实现本链路打到的 `GET /posts/`（其余 404）。
class _PostsAdapter implements HttpClientAdapter {
  int hits = 0;

  static const Map<String, List<String>> _json = <String, List<String>>{
    Headers.contentTypeHeader: <String>[Headers.jsonContentType],
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    hits += 1;
    if (options.method == 'GET' && options.path == '/posts/') {
      return ResponseBody.fromString(
        jsonEncode(<String, Object?>{
          'results': <Object?>[_postJson(1), _postJson(2)],
          'next_cursor': null,
          'has_more': false,
          'total': 2,
        }),
        200,
        headers: _json,
      );
    }
    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{'detail': 'not found'}),
      404,
      headers: _json,
    );
  }

  @override
  void close({bool force = false}) {}
}

/// reduced 档判据的说明文案（避免在 `reason:` 字符串里换行）。
const String reducedReason = 'reduced-motion ⇒ 不播入场（无 translateY 偏移）';

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

  GoRouter makeRouter() => GoRouter(
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

  Widget app(GoRouter router, {bool reduced = false}) => ProviderScope(
        child: MaterialApp.router(
          routerConfig: router,
          theme: buildAylaTheme(),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: child,
            ),
          ),
        ),
      );

  /// 推到列表卡片出现。
  ///
  /// ⚠️ 两次 pump 的差异（实测）：dio 的请求链里既有 microtask 也有 `Timer`，
  /// 而 `pump(Duration.zero)` **只 flush microtask、不推进 Timer**
  /// ⇒ 每 5 轮补一次 1ms 的 pump。**先检查后推进**（不是先推进后检查）
  /// ⇒ 卡片挂载那一帧不会被多推 1ms，位移判据仍读到动画起点。
  Future<void> waitForCards(WidgetTester tester) async {
    int step = 0;
    while (find.byType(AylaPostCard).evaluate().isEmpty) {
      if (step > 80) {
        fail('列表卡片未出现（adapter hits=${adapter.hits}）——正文=${_texts(tester)}');
      }
      step += 1;
      await tester.pump(
        step % 5 == 0 ? const Duration(milliseconds: 1) : Duration.zero,
      );
    }
  }

  /// 收尾：把树上的延迟 Timer 全部放掉，避免 `_verifyInvariants` 的
  /// 「A Timer is still pending even after the widget tree was disposed.」
  ///（本页有 stagger delay Timer 与分页组件的 Timer）。
  Future<void> drainTimers(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  /// 第 `index` 张卡的入场包装层（`.posts-feed-item` 的等价物）。
  Finder revealItemAt(int index) => find
      .ancestor(
        of: find.byType(AylaPostCard).at(index),
        matching: find.byType(AylaRevealItem),
      )
      .first;

  testWidgets('① 卡片挂载后有入场：位移 +20 → 0（useListEntryMotion.ts:74–80）',
      (WidgetTester tester) async {
    await tester.pumpWidget(app(makeRouter()));
    await waitForCards(tester);

    // 挂载帧 = 动画起点 `{ opacity: 0, transform: translateY(20px) }`
    // 容差 1px：等待循环里最多推过 1ms 的时长（对 20px 的起点无实质影响）。
    expect(
      revealDy(tester, 0),
      closeTo(AylaRevealMotion.distance, 1.0),
      reason: '起点位移 = distance 20（auroraquaMotion.ts:12）',
    );

    // 第 1 张 delay 0 → 首帧即 `forward()`；第 2 张 delay 50 → 需要先让 Timer 到期。
    // ⚠️ `pump(Duration)` 只产生**一帧**：Timer 到期与动画 tick 在同一帧里，
    // 动画起点被设在那一帧的时间戳上 ⇒ 要两段推进。
    await tester.pump(const Duration(milliseconds: 400)); // Timer 到期 + 第 1 张走完
    await tester.pump(const Duration(milliseconds: 400)); // 第 2 张走完
    await tester.pump();
    expect(revealDy(tester, 0), closeTo(0, 0.01));
    expect(revealDy(tester, 1), closeTo(0, 0.01));
    // 对照用例②：非 reduced 档包装层里**有** `Opacity` + `Transform`
    expect(
      find.descendant(of: revealItemAt(0), matching: find.byType(Opacity)),
      findsWidgets,
    );
    await drainTimers(tester);
  });

  testWidgets('①b stagger：delay = min(index*50, 300)（第 1 张 0 / 第 2 张 50）',
      (WidgetTester tester) async {
    await tester.pumpWidget(app(makeRouter()));
    await waitForCards(tester);

    // ⚠️ 不能用 `find.byType(AylaRevealItem).at(i)`：页面里还有别处的 reveal 层
    //（`AylaGroupSceneHead` 自己也挂一个）⇒ 必须从卡片向上取第一个。
    final AylaRevealItem first = tester.widget<AylaRevealItem>(revealItemAt(0));
    final AylaRevealItem second = tester.widget<AylaRevealItem>(revealItemAt(1));
    // `delay = staggerDelay(index, staggerMs: 50)` = min(index*50, 300)
    //（useRevealOnEnter.ts:48–49）
    expect(first.delay, Duration.zero);
    expect(second.delay, const Duration(milliseconds: 50));
    // 玻璃安全档（AylaPostCard 是 AylaGlassCard 子树，`fadeGlass: false` 必需）
    expect(first.fadeGlass, isFalse);
    expect(second.fadeGlass, isFalse);
    await drainTimers(tester);
  });

  testWidgets('② reduced-motion（disableAnimations）⇒ 不挂动画、直出终态',
      (WidgetTester tester) async {
    await tester.pumpWidget(app(makeRouter(), reduced: true));
    await waitForCards(tester);

    expect(revealItemAt(0), findsOneWidget);
    // `AylaRevealItem.build` 在 reduced 档直接 `return widget.child`（`reveal.dart`）
    // ⇒ 位移一个都不挂。判据用「卡片绘制位相对**网格**顶的偏移」：
    //   · 非 reduced 首帧 = distance 20（用例①的 revealDy 同源）；
    //   · reduced = 0。
    // `tester.getRect` 走 `localToGlobal`，会带上祖先 `Transform` 的位移 ⇒ 该判据有效。
    // ⚠️ 基准取网格（`AylaMasonryGrid` 在 `AylaRevealItem` 之外 ⇒ 自身无位移），
    // 而不是网格内容的顶（后者会把两种档都减去同一个 sp3=12 内距）。
    final double offset = tester
            .getRect(find.byType(AylaPostCard).first)
            .top -
        tester.getRect(find.byType(AylaMasonryGrid<AylaPost>)).top;
    expect(offset, closeTo(0, 0.01), reason: reducedReason);
    await drainTimers(tester);
  });

  testWidgets('③ 从详情返回列表：本次首帧不播入场（不重播）',
      (WidgetTester tester) async {
    final GoRouter router = makeRouter();
    await tester.pumpWidget(app(router));
    await waitForCards(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(revealDy(tester, 0), closeTo(0, 0.01)); // 首轮入场已结束

    // 进详情（等价点卡片 → `_openPost`）。
    await tester.tap(find.byType(AylaPostCard).first);
    await tester.pump();
    await tester.pump();
    expect(find.byType(AylaPostCard), findsNothing); // 列表已卸载

    // 返回列表
    router.go('/group/g1/posts');
    await tester.pump();
    await tester.pump();

    // 判据：列表卡片重新挂载，但 suppress 命中 ⇒ **当帧即终态**（位移 0）。
    // 若 suppress 未接上（或 `didUpdateWidget` 未登记），这里会是 +20。
    expect(find.byType(AylaPostCard), findsNWidgets(2));
    expect(
      revealDy(tester, 0),
      closeTo(0, 0.01),
      reason: '从详情返回时首帧不播入场（GroupPosts.tsx:378–380 的 suppressed）',
    );
    await drainTimers(tester);
  });
}

/// 目标子树所属 `AylaRevealItem` 自己那一层 `Transform` 的平移量 y。
double revealDy(WidgetTester tester, int index) => tester
    .widget<Transform>(
      find
          .descendant(
            of: find
                .ancestor(
                  of: find.byType(AylaPostCard).at(index),
                  matching: find.byType(AylaRevealItem),
                )
                .first,
            matching: find.byType(Transform),
          )
          .first,
    )
    .transform
    .storage[13];

List<String> _texts(WidgetTester tester) => <String>[
      for (final Text t in tester.widgetList<Text>(find.byType(Text)))
        if (t.data != null) t.data!,
    ];