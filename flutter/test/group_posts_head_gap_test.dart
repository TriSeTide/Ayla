/// 群内帖子页「标题卡 → 内容区」纵向间距回归锁（2026-10-09 用户实报）。
///
/// ## 现象（用户真机 + Web 双向对照）
/// Flutter 端标题卡下沿与第一排帖子卡上沿**几乎贴合**（目视 ≈2–4px），两张卡的阴影互相压住；
/// Web 端标题卡与内容区之间有**明确间距**（用户像素扫描：标题卡下沿 y≈353，其下 y=345..400
/// 采到的是**极光背景**而非卡片）。⚠️ 用户给的是观测值，**不是**推导依据 —— 依据见下。
///
/// ## 根因（**事实源 = CSS 特异性，不是源码顺序**）
/// 两条规则争同一个元素 `.group-posts-list`：
///
/// | 规则 | 文件:行 | 特异性 | padding | gap |
/// |---|---|---|---|---|
/// | `.group-page .group-posts-list` | `group.css:409–417` | **0-2-0** | `var(--sp-4)` = **16** | `var(--sp-4)` = **16** |
/// | `.group-posts-list` | `posts.css:975–983` | 0-1-0 | `sp3 sp4` = 12/16 | **0** |
///
/// ⇒ **0-2-0 胜出**（与源码顺序无关）：`padding` 四向 16、`gap` 16。
/// `group.css:409–410` 的注释原文即此意：「三个场景统一四向 16px 外间距；**父容器 gap 明确
/// 保证头部与首个内容块留白**，不让 PullToRefresh 的包裹层改变头部与首张卡的几何关系。」
///
/// Flutter 侧调用点（`pages/group_posts_page.dart`）此前却按**败方**（posts.css）传了
/// `vertical: sp3` + `gap: 0` ⇒ 少 16px。语音 / 桌游两页本来就是 `sp4`+`sp4`（与 web 同）
/// ⇒ 当时只有帖子一个场景塌了。
///
/// ⚠️ **宽窄两档同值**：该规则**不在任何 `@media` 内**（`group.css` 最近的上一个 `@media`
/// 在 140–149 行、已闭合），`auroraqua.css:296` 那条只改 `margin-left`/`padding-left`
/// （宽屏专属的绘制带，不动 gap）⇒ 两档都是 16。
///
/// ## 口径
/// 库内 web CSS px == Flutter 逻辑 px，**1:1**（同 `group_scene_padding_test.dart` 头注）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/post.dart' show AylaPost;
import '../lib/core/net/dio_client.dart';
import '../lib/pages/group_posts_page.dart';
import '../lib/theme/app_theme.dart' show buildAylaTheme;
import '../lib/theme/tokens.dart';
import '../lib/widgets/group/group_scene.dart'
    show AylaGroupSceneHead, AylaGroupScenePlaceholder;
import '../lib/widgets/posts/masonry_grid.dart' show AylaMasonryGrid;
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

Map<String, dynamic> _post(int id) => <String, dynamic>{
      'id': id,
      'title': '帖子 $id',
      'body': '正文 $id',
      'author': <String, dynamic>{'id': 'u1', 'nickname': '小樱'},
      'author_id': 'u1',
      'group': 'g1',
      'allowed_group_ids': <String>['g1'],
      'images': <Object?>[],
      'is_viewed': false,
      'view_count': 3,
      'created_at': '2026-10-01T00:00:00Z',
    };

class _PostsAdapter implements HttpClientAdapter {
  _PostsAdapter({this.results = 3});

  /// 返回几条帖子（0 ⇒ 空态）。
  final int results;

  static const Map<String, List<String>> _json = <String, List<String>>{
    Headers.contentTypeHeader: <String>[Headers.jsonContentType],
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'GET' && options.path == '/posts/') {
      return ResponseBody.fromString(
        jsonEncode(<String, Object?>{
          'results': <Object?>[
            for (int i = 1; i <= results; i++) _post(i),
          ],
          'next_cursor': null,
          'has_more': false,
          'total': results,
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

const Size kWide = Size(1526, 900);
const Size kNarrow = Size(400, 900);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    DioClient.instance.init(tokenStore: _NoTokens(), onSessionExpired: () {});
  });

  setUp(() {
    DioClient.instance.dio.httpClientAdapter = _PostsAdapter();
  });

  void useAdapter(_PostsAdapter adapter) {
    DioClient.instance.dio.httpClientAdapter = adapter;
  }

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

  Future<void> pumpPage(WidgetTester tester, Size viewport) async {
    await tester.binding.setSurfaceSize(viewport);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host(const GroupPostsPage(groupId: 'g1'), viewport));
    await tester.pump();
    for (int i = 0; i < 8; i += 1) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  /// 「标题卡 → 首个内容块」的纵向间距 + 左内沿（两档共用判据）。
  void expectHeadSpacing(WidgetTester tester) {
    final Rect head = tester.getRect(find.byType(AylaGroupSceneHead));
    final List<Rect> cards = <Rect>[
      for (int i = 0; i < find.byType(AylaPostCard).evaluate().length; i += 1)
        tester.getRect(find.byType(AylaPostCard).at(i)),
    ];
    expect(cards, hasLength(3), reason: '后端返回 3 条帖子');

    final double gap = cards.first.top - head.bottom;
    expect(
      gap,
      AylaSpacing.sp4,
      reason: '★ 标题卡与首个内容块的间距必须是 16（group.css:409–417 的 gap: var(--sp-4)，'
          '特异性 0-2-0 压过 posts.css:975–983 的 gap: 0）；实测 $gap',
    );

    // 横向：内容带左沿 = 滚动容器左 padding（group.css:414 四向 sp4）
    final Rect grid = tester.getRect(find.byType(AylaMasonryGrid<AylaPost>));
    expect(
      head.left,
      AylaSpacing.sp4,
      reason: '标题卡左内沿 = 16（四向 sp4）',
    );
    expect(grid.left, head.left, reason: '内容带与标题卡同一内容轨道（左沿对齐）');
  }

  group('群内帖子：标题卡 → 内容区间距（group.css:409–417）', () {
    testWidgets('宽屏 1526：标题卡下沿 → 首卡上沿 = sp4(16)', (WidgetTester tester) async {
      await pumpPage(tester, kWide);
      expectHeadSpacing(tester);
    });

    testWidgets('窄屏 400：同为 sp4(16)（该规则不在任何 @media 内）',
        (WidgetTester tester) async {
      await pumpPage(tester, kNarrow);
      expectHeadSpacing(tester);
    });

    testWidgets('四向内距 = sp4：内容带上下右也各 16（posts.css 的 sp3 是败方）',
        (WidgetTester tester) async {
      await pumpPage(tester, kWide);
      final Rect head = tester.getRect(find.byType(AylaGroupSceneHead));
      final Rect grid = tester.getRect(find.byType(AylaMasonryGrid<AylaPost>));
      // 右内沿：内容带右沿 = 视口宽 − 16
      expect(kWide.width - grid.right, AylaSpacing.sp4,
          reason: '右内沿 16（四向 sp4；posts.css 的 sp3 sp4 在横向恰好也是 16，两者同值）');
      // 标题卡上沿 = 16（滚动容器顶部内距）
      expect(head.top, AylaSpacing.sp4,
          reason: '顶部内距 16（四向 sp4；**不是** posts.css 的 sp3=12）');
    });

    testWidgets('空态也有同一间距（web 的 gap 对三态都生效）', (WidgetTester tester) async {
      // web 结构：`.group-scene-head` 与 `<PullToRefresh>` 是 `.group-posts-list`
      // （flex + `gap: sp4`）的**兄弟**（`GroupPosts.tsx:390–448`）⇒ gap 对
      // 加载 / 空 / 列表**三态都生效**。Flutter 侧是 StickyHead(head, child) 嵌套、
      // 三态都在 child 里 ⇒ 语义等价，本用例把它钉住。
      useAdapter(_PostsAdapter(results: 0));
      await pumpPage(tester, kWide);
      final Rect head = tester.getRect(find.byType(AylaGroupSceneHead));
      final Rect placeholder = tester.getRect(find.byType(AylaGroupScenePlaceholder));
      expect(
        placeholder.top - head.bottom,
        AylaSpacing.sp4,
        reason: '空态占位壳与标题卡的间距同为 16（与列表态一致）',
      );
    });
  });
}
