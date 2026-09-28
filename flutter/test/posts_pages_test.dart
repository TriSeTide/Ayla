/// 帖子域页面（PostsHubPage / MyPostsPage / UserPostsPage）与纯逻辑的定向测试。
///
/// 分两层（与 hub_pages_test 同口径）：
/// 1. **纯函数**：分类 → 后端参数表 / 前端二次过滤 / 热门排序（PostsHubPage.tsx:54–60、124–129）
///    与详情页绝对时间格式化（PostDetailPage.tsx:627）；
/// 2. **页面首帧与状态**：骨架根数与页头（tsx 317–322 / MyPostsPage.tsx 180–186）、
///    空/错态（MyPostsPage.tsx 187–188、UserPostsRoute.tsx 57–69）—— 无网络下不崩、错误静默。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/post.dart';
import '../lib/core/models/visibility.dart';
import '../lib/pages/hub_support.dart';
import '../lib/pages/my_posts_page.dart';
import '../lib/pages/post_detail_page.dart';
import '../lib/widgets/posts/post_detail_chrome.dart';
import '../lib/pages/posts_hub_page.dart';
import '../lib/theme/buttons.dart' show AylaIconButton;
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/loading.dart' show AylaSkeleton;
import '../lib/widgets/base/page_state.dart' show AylaPageState;
import '../lib/widgets/posts/post_page_chrome.dart';

AylaPost _post(
  int id, {
  AylaPostVisibility? visibility,
  String? authorId,
  int? viewCount,
}) =>
    AylaPost(
      id: id,
      title: '帖子 $id',
      body: '正文',
      visibility: visibility,
      authorId: authorId,
      author: AylaPostAuthor(id: authorId ?? 'u1', nickname: '小樱'),
      viewCount: viewCount,
    );

Widget _host(Widget child, {Size viewport = const Size(1440, 900)}) {
  return ProviderScope(
    child: MaterialApp(
      home: Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: viewport),
          child: previewScope(child),
        ),
      ),
    ),
  );
}

Future<void> _pump(WidgetTester tester, Widget page, {Size viewport = const Size(1440, 900)}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_host(page, viewport: viewport));
}

void main() {
  group('分类 → 后端参数（PostsHubPage.tsx:54–60 的 TAB_QUERY）', () {
    test('all / hot 只传 scope=feed', () {
      expect(aylaPostTabQuery('all').scope, 'feed');
      expect(aylaPostTabQuery('all').visibility, isNull);
      expect(aylaPostTabQuery('all').friends, isFalse);
      expect(aylaPostTabQuery('hot').scope, 'feed');
      expect(aylaPostTabQuery('hot').visibility, isNull);
    });

    test('public → visibility=public；friends → friends=1；mine → scope=mine', () {
      expect(aylaPostTabQuery('public').visibility, 'public');
      expect(aylaPostTabQuery('friends').friends, isTrue);
      expect(aylaPostTabQuery('mine').scope, 'mine');
      expect(aylaPostTabQuery('mine').visibility, isNull);
    });
  });

  group('前端二次过滤 + 热门排序（tsx 124–129）', () {
    test('公开档按 visibility 过滤（缺失不算公开）', () {
      final List<AylaPost> posts = <AylaPost>[
        _post(1, visibility: AylaPostVisibility.public),
        _post(2, visibility: AylaPostVisibility.friends),
        _post(3),
      ];
      final List<AylaPost> visible = aylaHubVisiblePosts(posts, 'public');
      expect(visible.map((AylaPost p) => p.id), <int>[1]);
    });

    test('好友档按 author_id ∈ 好友集合（author_id 缺失不命中）', () {
      final List<AylaPost> posts = <AylaPost>[
        _post(1, authorId: 'u9'),
        _post(2, authorId: 'u8'),
        _post(3),
      ];
      final List<AylaPost> visible = aylaHubVisiblePosts(
        posts,
        'friends',
        friendIds: <String>{'u9'},
      );
      expect(visible.map((AylaPost p) => p.id), <int>[1]);
    });

    test('热门档只排序不筛内容（view_count 降序）', () {
      final List<AylaPost> posts = <AylaPost>[
        _post(1, viewCount: 5),
        _post(2, viewCount: 30),
        _post(3, viewCount: 12),
      ];
      final List<AylaPost> visible = aylaHubVisiblePosts(posts, 'hot');
      expect(visible.map((AylaPost p) => p.id), <int>[2, 3, 1]);
    });

    test('热门档：view_count 为 null 时按 web 的 NaN 语义保持原序（不写 0）', () {
      final List<AylaPost> posts = <AylaPost>[
        _post(1),
        _post(2, viewCount: 30),
        _post(3),
      ];
      final List<AylaPost> visible = aylaHubVisiblePosts(posts, 'hot');
      expect(visible.map((AylaPost p) => p.id), <int>[1, 2, 3]);
    });

    test('全部 / 我的档原样返回（我的档后端已过滤）', () {
      final List<AylaPost> posts = <AylaPost>[_post(1), _post(2)];
      expect(aylaHubVisiblePosts(posts, 'all').map((AylaPost p) => p.id),
          <int>[1, 2]);
      expect(aylaHubVisiblePosts(posts, 'mine').map((AylaPost p) => p.id),
          <int>[1, 2]);
    });
  });

  group('详情页绝对时间（PostDetailPage.tsx:627）', () {
    test('有效 ISO → zh-CN 形状（月日不补零、时分秒补零、本地时区）', () {
      final String? label = aylaPostDetailTime('2026-09-28T12:05:07Z');
      expect(label, isNotNull);
      final DateTime local = DateTime.parse('2026-09-28T12:05:07Z').toLocal();
      expect(label, '${local.year}/${local.month}/${local.day} '
          '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}:'
          '${local.second.toString().padLeft(2, '0')}');
    });

    test('缺失 / 非法 ISO → null（不渲染时间行；web 会显示 Invalid Date ⇒ 有意偏离）', () {
      expect(aylaPostDetailTime(null), isNull);
      expect(aylaPostDetailTime(''), isNull);
      expect(aylaPostDetailTime('不是时间'), isNull);
    });
  });

  group('页面首帧与状态', () {
    testWidgets('PostsHubPage：首帧三根 120 高骨架 + 侧栏 Posts / 帖子', (
      WidgetTester tester,
    ) async {
      await _pump(tester, const PostsHubPage());
      expect(find.byType(AylaSkeleton), findsNWidgets(3));
      expect(find.text('帖子'), findsOneWidget); // 侧栏标题
      // kicker 走 CSS 的 text-transform: uppercase（directory-filters.css:80）
      expect(find.text('POSTS'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 50));
    });

    testWidgets('PostsHubPage：请求失败 → 全空态（还没有帖子 / 点右下角 + 发布第一条帖子）', (
      WidgetTester tester,
    ) async {
      await _pump(tester, const PostsHubPage());
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('还没有帖子'), findsOneWidget);
      expect(find.text('点右下角 + 发布第一条帖子'), findsOneWidget);
      expect(find.byType(AylaSkeleton), findsNothing);
    });

    testWidgets('MyPostsPage（我的）：页头「我的帖子」+ 两根骨架（无间距）', (
      WidgetTester tester,
    ) async {
      await _pump(tester, const MyPostsPage());
      expect(find.text('我的帖子'), findsOneWidget);
      expect(find.byType(AylaSkeleton), findsNWidgets(2));
      await tester.pump(const Duration(milliseconds: 50));
    });

    testWidgets('MyPostsPage：请求失败 → 错误态（desc + 重试）', (WidgetTester tester) async {
      await _pump(tester, const MyPostsPage());
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('重试'), findsOneWidget);
      expect(find.byType(AylaSkeleton), findsNothing);
    });

    testWidgets('UserPostsPage：show_content 取不到 → blocked 守卫态（对方未开启内容展示）', (
      WidgetTester tester,
    ) async {
      await _pump(tester, const UserPostsPage(userId: 'u9'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('对方未开启内容展示'), findsOneWidget);
      expect(find.text('对方关闭了「向他人展示内容」，暂时无法查看其帖子'), findsOneWidget);
      expect(find.text('返回主页'), findsOneWidget);
    });
  });

  group('MyPostsHead / PostsSkeleton 几何（posts.css 598–605 / 628–675）', () {
    testWidgets('页头：gap sp3 + padding sp2 sp4 + 1px 玻璃底边 + 返回键 40', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const Scaffold(body: AylaMyPostsHead(title: '我的帖子')),
        viewport: const Size(600, 400),
      );
      final Padding pad = tester.widget<Padding>(
        find.descendant(
          of: find.byType(AylaMyPostsHead),
          matching: find.byWidgetPredicate(
            (Widget w) =>
                w is Padding &&
                w.padding ==
                    const EdgeInsets.symmetric(
                      horizontal: AylaSpacing.sp4,
                      vertical: AylaSpacing.sp2,
                    ),
          ),
        ),
      );
      expect(pad.padding, isNotNull);
      expect(
        find.descendant(
          of: find.byType(AylaMyPostsHead),
          matching: find.byWidgetPredicate((Widget w) {
            if (w is! DecoratedBox) return false;
            final Decoration? d = w.decoration;
            if (d is! BoxDecoration) return false;
            final BoxBorder? border = d.border;
            if (border is! Border) return false;
            final BorderSide bottom = border.bottom;
            // border-bottom: 1px solid var(--glass-border)（**只有底边**：
            // 返回键自己的 Border.all 也会命中"有底边"，故要求其余三边为 none）
            return border.top == BorderSide.none &&
                border.left == BorderSide.none &&
                border.right == BorderSide.none &&
                bottom != BorderSide.none &&
                bottom.width == 1;
          }),
        ),
        findsOneWidget,
      );
    });

    testWidgets('骨架：三根 120 高、前两根间距 12（hub 档 centered:false 不加居中）', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const Scaffold(body: AylaPostsSkeleton(centered: false)),
        viewport: const Size(600, 800),
      );
      final List<Rect> bars = <Rect>[
        for (int i = 0; i < 3; i += 1)
          tester.getRect(find.byType(AylaSkeleton).at(i)),
      ];
      for (final Rect r in bars) {
        expect(r.height, 120);
      }
      expect(bars[1].top - bars[0].bottom, 12);
      expect(bars[2].top - bars[1].bottom, 12);
    });
  });

  group('PostDetailPage 首帧与空态（PostDetailPage.tsx 399–438）', () {
    testWidgets('首帧 → 详情骨架 + 头部「帖子」（不渲染输入区）', (WidgetTester tester) async {
      await _pump(tester, const PostDetailPage(postId: '999'));
      expect(find.byType(AylaPostDetailSkeleton), findsOneWidget);
      expect(find.text('帖子'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 50));
    });

    testWidgets('取不到帖子 → 空态（error 文案优先，web tsx 433 的 error ?? 帖子不存在）+ 返回键', (
      WidgetTester tester,
    ) async {
      await _pump(tester, const PostDetailPage(postId: '999'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('返回'), findsOneWidget);
      expect(find.byType(AylaPostDetailSkeleton), findsNothing);
      expect(find.byType(AylaPostDetailEmpty), findsOneWidget);
    });

    testWidgets('非数字 postId → 空态（不崩、不发请求）', (WidgetTester tester) async {
      await _pump(tester, const PostDetailPage(postId: 'abc'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('帖子不存在'), findsOneWidget);
    });

    // 2026-09-28 用户裁决「修」：空/错态补顶栏 + 空态档（不再是「无头 + 文案贴顶」）。
    // 内距/间距逐值取自 web 既有空态规范：.home-state（home.css:622–629）
    // = padding sp12 sp6 + gap sp4；整页居中同 .home-wide-empty（home.css:673–682）。
    testWidgets('空态档：chrome 顶栏 + home-state 内距（sp12 sp6）+ gap sp4 + 整页居中', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        AylaPostDetailChrome(
          onBack: () {},
          body: AylaPostDetailEmpty(message: '帖子不存在', onBack: () {}),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      // 顶栏与加载态同构（tsx 404–409）：返回键 + 「帖子」
      expect(find.byType(AylaIconButton), findsOneWidget);
      expect(find.text('帖子'), findsOneWidget);
      // 空态文案 + 既有 ghost「返回」出口（MyPostsPage.tsx:187 的错态结构）
      expect(find.text('帖子不存在'), findsOneWidget);
      expect(find.text('返回'), findsOneWidget);
      // 内距 = sp12 / sp6（home.css:627），间距 = sp4（home.css:626）
      final Iterable<Padding> paddings = tester.widgetList<Padding>(find.byType(Padding));
      expect(
        paddings.any(
          (Padding p) =>
              p.padding ==
              const EdgeInsets.symmetric(
                vertical: AylaSpacing.sp12,
                horizontal: AylaSpacing.sp6,
              ),
        ),
        isTrue,
      );
      final Iterable<Column> columns = tester.widgetList<Column>(find.byType(Column));
      expect(columns.any((Column c) => c.spacing == AylaSpacing.sp4), isTrue);
      // 整页居中（home.css:677–678 的 justify-content: center）：空态档外层是一个撑满的 Center
      final Finder wrapper = find
          .ancestor(of: find.byType(AylaPageState), matching: find.byType(Center))
          .first;
      final Rect box = tester.getRect(wrapper);
      expect(box.width, 1440); // .post-detail-state 撑满顶栏之下的剩余区域（flex: 1 ⇒ Expanded）
      expect(
        tester.getRect(find.byType(AylaPageState)).center.dy,
        closeTo(box.center.dy, 0.5),
      );
    });

    testWidgets('错态档：同一空态档几何，文案取自 error（不落「帖子不存在」兜底）', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        AylaPostDetailChrome(
          onBack: () {},
          body: AylaPostDetailEmpty(message: '帖子加载失败', onBack: () {}),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('帖子加载失败'), findsOneWidget);
      expect(find.text('帖子不存在'), findsNothing);
      expect(find.byType(AylaPageState), findsOneWidget);
      expect(find.text('返回'), findsOneWidget);
    });
  });

}
