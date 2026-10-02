/// 问题 6 真根因回归锁 —— 群内场景「卡片**左右**留空没对齐」（双层左右内距叠加）。
///
/// ## 事实源（web，逐条）
/// | 场景 | web | 行 | 结论 |
/// |---|---|---|---|
/// | 群内**桌游** | `boardgame.css` | 254–259 | `.group-games-grid`：**没有 padding 声明 ⇒ 0**；`repeat(2, 1fr)` ⇒ **恒 2 列** |
/// | 群内桌游外层 | `group.css` | 411–417 | `.group-page .group-games { padding: var(--sp-4) }`（0-2-0 压过 `boardgame.css:247–252` 的 `sp3 sp4`）⇒ **左右留白只此一处 = 16** |
/// | 群内**语音** | `voice.css` | 690–695 | `.group-voice .voice-channel-list`：**`padding: 0` 显式归零**（:694）；`repeat(2, 1fr)` ⇒ **恒 2 列**（:692） |
/// | 群内语音外层 | `group.css` | 411–417 · 420–424 | `padding: sp4` + 底部 68（避让 FAB） |
/// | 群内**帖子** | `posts.css` | 607–612 ≺ **989–992** | `.group-posts-feed { padding: 0 }` 同特异性**按源码顺序**压掉 `.posts-feed` 的 `sp3 sp4`（并因后置压掉 ≥1025 档 `sp4 sp6`，posts.css:664–668）⇒ 流自身 padding **0** |
/// | 群内帖子外层 | `group.css` · `posts.css` | 413–417 · 975–983 | `.group-page .group-posts-list { padding: sp4 }`（0-2-0）压掉 `.group-posts-list { padding: sp3 sp4 }`（0-1-0）⇒ 四向 sp4 |
///
/// 口径：**库内 web CSS px == Flutter 逻辑 px，1:1**。
///
/// ## 为什么走「真实页面 + 假 HttpClientAdapter」
/// 缺陷不在组件、而在**调用点**：`AylaGamesGrid` / `AylaVoiceChannelList` 的「默认 padding」
/// 本身没错（一级页与画布要用它），错的是**群内调用点没传 `EdgeInsets.zero`**
/// ⇒ 外层 `sp4` 与内层基样式 `sp4` 叠加。纯组件测试量不到这条（它是调用点口径），
/// 所以本文件挂**真实页面**、喂**真实后端形状**的响应，量真实渲染出来的卡片矩形。
///
/// ⚠️ 为什么不用真实回环 `HttpServer`（`posts_frames_test.dart` 那套）：widget test 的请求在
/// **fake-async zone** 里发起，socket 连接永远不会进展（实测：`runAsync` 窗口内服务器收不到
/// 任何请求，收尾还报 `A Timer is still pending`）。改用 dio 自己的 `HttpClientAdapter` 接缝：
/// 不碰 socket、响应在同一 zone 的微任务里落地，**数据链路（JSON → 模型 → Pager → 网格）仍然真实**，
/// 唯一被替换的是传输层（本用例不测传输）。
///
/// ## 修复前 / 后实测（1526 宽，本文件量到的同一口径）
/// ```
/// 修复前：群内桌游 卡0 left=32 右余=32、4 列；群内语音 卡0 left=32 右余=32
/// 修复后：群内桌游 卡0 left=16 卡1 right=1510（右余=16）gap=12、2 列 741 宽
///         群内语音 卡0 left=16 卡1 right=1510（右余=16）gap=12、2 列 741 宽
///         群内帖子 卡0 left=16 右列 right=1510（右余=16）
/// ```
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/post.dart' show AylaPost;
import '../lib/core/net/dio_client.dart';
import '../lib/pages/group_games_page.dart';
import '../lib/pages/group_posts_page.dart';
import '../lib/pages/group_voice_page.dart';
import '../lib/theme/app_theme.dart' show buildAylaTheme;
import '../lib/theme/tokens.dart';
import '../lib/widgets/game/game_room_card.dart' show AylaGameRoomCard;
import '../lib/widgets/game/games_grid.dart' show AylaGamesGrid;
import '../lib/widgets/posts/masonry_grid.dart' show AylaMasonryGrid;
import '../lib/widgets/posts/post_card.dart' show AylaPostCard;
import '../lib/widgets/voice/voice_channels.dart'
    show AylaVoiceCardData, AylaVoiceChannelCard, AylaVoiceChannelList;

// ===========================================================================
// 假传输层：三个目录端点 → 真实后端形状（DirectoryPage）
// ===========================================================================

Map<String, dynamic> _page(List<Map<String, dynamic>> results) =>
    <String, dynamic>{
      'results': results,
      'next_cursor': null,
      'has_more': false,
      'total': results.length,
    };

class _DirectoryAdapter implements HttpClientAdapter {
  /// 4 条 ⇒ 群内恒 2 列时正好两行。
  int rooms = 4;
  int channels = 4;
  int posts = 3;

  /// 收到的请求（断言页面确实按 `group_id` / `scope` 取数，而不是吃了别处缓存）。
  final List<RequestOptions> requests = <RequestOptions>[];

  Object? _bodyFor(String path) {
    if (path.endsWith('/boardgame/rooms/')) {
      return _page(<Map<String, dynamic>>[
        for (int i = 1; i <= rooms; i += 1)
          <String, dynamic>{
            'id': i,
            'name': '桌游室 $i',
            'status': 'waiting',
            'owner': <String, dynamic>{'id': 'u1', 'nickname': '房主'},
            'owner_id': 'u1',
            'allowed_group_ids': <String>['g1'],
            'created_at': '2026-10-01T00:00:00Z',
          },
      ]);
    }
    if (path.endsWith('/voice/channels/')) {
      return _page(<Map<String, dynamic>>[
        for (int i = 1; i <= channels; i += 1)
          <String, dynamic>{
            'id': '$i',
            'name': '语音房 $i',
            'owner_nickname': '房主',
            'member_count': 2,
            'visibility': 'public',
            'allowed_group_ids': <String>['g1'],
            'created_at': '2026-10-01T00:00:00Z',
          },
      ]);
    }
    if (path.endsWith('/posts/')) {
      return _page(<Map<String, dynamic>>[
        for (int i = 1; i <= posts; i += 1)
          <String, dynamic>{
            'id': i,
            'title': '帖子 $i',
            'body': '正文 $i',
            'author': <String, dynamic>{'id': 'u2', 'nickname': '小樱'},
            'author_id': 'u2',
            'group': 'g1',
            'allowed_group_ids': <String>['g1'],
            'images': <Object?>[],
            'is_viewed': false,
            'created_at': '2026-10-01T00:00:00Z',
          },
      ]);
    }
    // 收藏状态等旁路：空壳（不影响几何断言）。
    return <String, dynamic>{};
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(_bodyFor(options.path)),
      200,
      headers: <String, List<String>>{
        // 显式 UTF-8（中文名称不能变乱码）。
        'content-type': <String>['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

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

// ===========================================================================

/// 视口：宽窗（问题 6 的验收口径）与窄屏。
const Size kWide = Size(1526, 900);
const Size kNarrow = Size(400, 900);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _DirectoryAdapter adapter;

  setUpAll(() {
    adapter = _DirectoryAdapter();
    // `DioClient.dio` 是 late final ⇒ 必须先 init 才会构造，随后换掉传输层。
    DioClient.instance.init(tokenStore: _NoTokens(), onSessionExpired: () {});
    DioClient.instance.dio.httpClientAdapter = adapter;
  });

  setUp(() => adapter.requests.clear());

  Future<void> useViewport(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  /// 真实页面宿主（`Scaffold` 必须：群内帖子底部输入框是 Material `TextField`）。
  Widget host(Widget child, Size viewport) => ProviderScope(
        child: MaterialApp(
          theme: buildAylaTheme(),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(size: viewport),
                child: SizedBox(
                  width: viewport.width,
                  height: viewport.height,
                  child: child,
                ),
              ),
            ),
          ),
        ),
      );

  /// 挂页面 → 数据落地 → 入场动画走完（几何断言必须在**终态**上量）。
  Future<void> pumpPage(WidgetTester tester, Widget page, Size viewport) async {
    await useViewport(tester, viewport);
    await tester.pumpWidget(host(page, viewport));
    await tester.pump(); // 假适配器的响应在同一 zone 的微任务里落地
    for (int i = 0; i < 8; i += 1) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  List<Rect> rects(WidgetTester tester, Finder f) => <Rect>[
        for (int i = 0; i < f.evaluate().length; i += 1) tester.getRect(f.at(i)),
      ];

  bool asked(RequestOptions o, String suffix, String key, String value) =>
      o.path.endsWith(suffix) && o.uri.queryParameters[key] == value;

  // =========================================================================
  // 群内桌游
  // =========================================================================
  group('群内桌游：卡片左右留空（boardgame.css:254–259 + group.css:411–417）', () {
    testWidgets('1526：左右留空各 16（**不是 32**）· 恒 2 列 · 间隙 sp3', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, const GroupGamesPage(groupId: 'g1'), kWide);

      expect(
        adapter.requests.any((RequestOptions o) =>
            asked(o, '/boardgame/rooms/', 'group_id', 'g1')),
        isTrue,
        reason: '群内目录必须带 group_id 过滤（GroupGames.tsx:20）',
      );

      final List<Rect> cards = rects(tester, find.byType(AylaGameRoomCard));
      expect(cards, hasLength(4), reason: '后端返回 4 个房间');

      // ★ 核心判据：左右留白各 16（外层 .group-page .group-games 的 sp4）
      expect(cards[0].left, AylaSpacing.sp4,
          reason: '★ 左留空必须是 16（修前 32 = 外层 16 + 内层默认 sp4 16）');
      expect(kWide.width - cards[1].right, AylaSpacing.sp4,
          reason: '★ 右留空必须是 16（第二列卡片右沿 = 1526 − 16）');

      // ★ 恒 2 列：第 3 张回到第一列（修前未传 columns ⇒ 1526 ≥ 769 走 4 列）
      expect(cards[2].left, cards[0].left, reason: '★ 群内恒 2 列（boardgame.css:256）');
      expect(cards[1].top, cards[0].top, reason: '前两张同一行');
      expect(cards[2].top, greaterThan(cards[0].top), reason: '第 3 张换行');
      expect(cards[3].left, cards[1].left, reason: '第 4 张在第二列');

      // 列间隙 = gap sp3（boardgame.css:257）
      expect(cards[1].left - cards[0].right, AylaSpacing.sp3);
      // 等宽：(1526 − 2×16 − 12) / 2 = 741
      expect(cards[0].width, closeTo((1526 - 2 * 16 - 12) / 2, 0.01));
      expect(cards[1].width, closeTo(cards[0].width, 0.01));
      // 内层网格自身不占位（padding: 0）
      final Rect grid = tester.getRect(find.byType(AylaGamesGrid));
      expect(grid.left, cards[0].left);
      expect(grid.right, cards[1].right);
    });

    testWidgets('窄屏（400）：左右留空仍各 16', (WidgetTester tester) async {
      await pumpPage(tester, const GroupGamesPage(groupId: 'g1'), kNarrow);
      final List<Rect> cards = rects(tester, find.byType(AylaGameRoomCard));
      expect(cards, hasLength(4));
      expect(cards[0].left, AylaSpacing.sp4,
          reason: '窄屏同样 sp4（.group-page 的 sp4 无媒体查询）');
      expect(kNarrow.width - cards[1].right, AylaSpacing.sp4);
      expect(cards[1].left - cards[0].right, AylaSpacing.sp3);
    });

    testWidgets('对照：内层不传 padding 时才是 32（证明本修复非空转）', (
      WidgetTester tester,
    ) async {
      await useViewport(tester, kWide);
      // 复刻修前形状：同一个外层 sp4 壳 + **默认 padding** 的网格。
      await tester.pumpWidget(
        host(
          const Padding(
            padding: EdgeInsets.all(AylaSpacing.sp4),
            child: AylaGamesGrid(
              children: <Widget>[
                SizedBox(key: ValueKey<int>(0), height: 60),
                SizedBox(key: ValueKey<int>(1), height: 60),
              ],
            ),
          ),
          kWide,
        ),
      );
      await tester.pump();
      expect(
        tester.getRect(find.byKey(const ValueKey<int>(0))).left,
        AylaSpacing.sp4 * 2,
        reason: '修前形状 = 外层 16 + 内层默认 sp4 16 = 32（用户实报的那条）',
      );
    });
  });

  // =========================================================================
  // 群内语音
  // =========================================================================
  group('群内语音：卡片左右留空（voice.css:690–695 + group.css:411–417）', () {
    testWidgets('1526：左右留空各 16（**不是 32**）· 恒 2 列 · 间隙 sp3', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, const GroupVoicePage(groupId: 'g1'), kWide);

      expect(
        adapter.requests.any((RequestOptions o) =>
            asked(o, '/voice/channels/', 'group_id', 'g1')),
        isTrue,
        reason: '群内目录必须带 group_id 过滤（GroupVoice.tsx:40）',
      );

      final List<Rect> cards = rects(tester, find.byType(AylaVoiceChannelCard));
      expect(cards, hasLength(4));

      // ★ 核心判据：padding: 0（voice.css:694）⇒ 左右留白只剩外层 sp4
      expect(cards[0].left, AylaSpacing.sp4,
          reason: '★ 左留空必须是 16（修前 32 = 外层 16 + 基样式 sp4 16）');
      expect(kWide.width - cards[1].right, AylaSpacing.sp4,
          reason: '★ 右留空必须是 16');

      // ★ 恒 2 列（voice.css:692；:647–659 的两条媒体查询只作用于 .voice-hub）
      expect(cards[2].left, cards[0].left, reason: '★ 群内恒 2 列');
      expect(cards[1].top, cards[0].top);
      expect(cards[2].top, greaterThan(cards[0].top));
      expect(cards[1].left - cards[0].right, AylaSpacing.sp3);

      final Rect list = tester.getRect(find.byType(AylaVoiceChannelList));
      expect(list.left, cards[0].left, reason: '列表自身 padding = 0');
      expect(list.right, cards[1].right);
    });

    testWidgets('窄屏（400）：左右留空仍各 16', (WidgetTester tester) async {
      await pumpPage(tester, const GroupVoicePage(groupId: 'g1'), kNarrow);
      final List<Rect> cards = rects(tester, find.byType(AylaVoiceChannelCard));
      expect(cards, hasLength(4));
      expect(cards[0].left, AylaSpacing.sp4);
      expect(kNarrow.width - cards[1].right, AylaSpacing.sp4);
      expect(cards[1].left - cards[0].right, AylaSpacing.sp3);
    });

    testWidgets('对照：内层不传 padding 时才是 32（证明本修复非空转）', (
      WidgetTester tester,
    ) async {
      await useViewport(tester, kWide);
      await tester.pumpWidget(
        host(
          Padding(
            padding: const EdgeInsets.all(AylaSpacing.sp4),
            child: AylaVoiceChannelList(
              channels: const <AylaVoiceCardData>[
                AylaVoiceCardData(id: '1', name: '甲'),
                AylaVoiceCardData(id: '2', name: '乙'),
              ],
            ),
          ),
          kWide,
        ),
      );
      await tester.pump();
      expect(
        tester.getRect(find.byType(AylaVoiceChannelCard).first).left,
        AylaSpacing.sp4 * 2,
        reason: '修前形状 = 外层 16 + 基样式 sp4 16 = 32',
      );
    });
  });

  // =========================================================================
  // 群内帖子（同一条根因：.group-posts-feed 的 padding: 0 未接线）
  // =========================================================================
  group('群内帖子：左右留空（posts.css:989–992）', () {
    testWidgets('1526：左右留空各 16 · 双列瀑布流（posts.css:677–691）', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, const GroupPostsPage(groupId: 'g1'), kWide);

      expect(
        adapter.requests.any((RequestOptions o) =>
            asked(o, '/posts/', 'scope', 'group:g1')),
        isTrue,
        reason: '群内帖子必须按 scope=group:<id> 取流（GroupPosts.tsx:97–164）',
      );

      final List<Rect> cards = rects(tester, find.byType(AylaPostCard));
      expect(cards, hasLength(3), reason: '后端返回 3 条帖子');

      // `.group-posts-feed { padding: 0 }` ⇒ 左右只由外层 sp4 给
      expect(cards[0].left, AylaSpacing.sp4,
          reason: '★ 左留空 16（修前 32 = 外层 16 + .posts-feed 基样式 sp4 16）');
      // 列容器铺满内容带：右沿 = 1526 − 16
      final Rect grid = tester.getRect(find.byType(AylaMasonryGrid<AylaPost>));
      expect(grid.left, AylaSpacing.sp4);
      expect(kWide.width - grid.right, AylaSpacing.sp4);
      for (final Rect c in cards) {
        expect(c.left, greaterThanOrEqualTo(AylaSpacing.sp4));
        expect(kWide.width - c.right, greaterThanOrEqualTo(0));
      }
      // ≥1025 双列（posts.css:677–691）：存在落在右半区的卡片
      expect(
        cards.any((Rect c) => c.left > kWide.width / 2),
        isTrue,
        reason: '≥1025 走双列瀑布流（.posts-feed.is-masonry）',
      );
    });

    testWidgets('窄屏（400）：左右留空各 16 · 单列', (WidgetTester tester) async {
      await pumpPage(tester, const GroupPostsPage(groupId: 'g1'), kNarrow);
      final List<Rect> cards = rects(tester, find.byType(AylaPostCard));
      expect(cards, hasLength(3));
      expect(cards[0].left, AylaSpacing.sp4);
      expect(kNarrow.width - cards[0].right, AylaSpacing.sp4);
      // <1025 单列：没有卡片落在右半区
      expect(cards.every((Rect c) => c.left < kNarrow.width / 2), isTrue);
    });
  });
}
