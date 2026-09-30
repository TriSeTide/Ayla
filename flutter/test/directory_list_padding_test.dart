/// 目录页内容区**列表容器内距**定向测试 —— 把 web 的组规则在**同一逻辑视口**
/// （1536×824）下逐条对账，数字与总控 2026-09-29 的 Playwright 实测一致。
///
/// ## 事实源（`Ayla/web/src/styles`）
/// | web | 行 | 规则 |
/// |---|---|---|
/// | `directory-filters.css` | 171–180 | `.directory-page .directory-content :is(…)` 组规则：列表容器 `padding-left/right: 0`（该规则**不在媒体查询内** ⇒ 窄屏同样归零） |
/// | `directory-filters.css` | 199–208 | ≥769 同组 `padding-top: 0`（首卡顶边与侧栏玻璃卡顶边对齐）；底部不动（注释 192「底部呼吸空间不动」） |
/// | `voice.css` | 505–511 | `.voice-hub .voice-channel-list { padding: var(--sp-3) var(--sp-4) }`（基样式） |
/// | `boardgame.css` | 232–237 | `.games-grid { padding: var(--sp-3) var(--sp-4) }`（基样式） |
/// | `profile.css` | 452–456 · 458–465 | `.favorites-skeleton` / `.favorites-list` 基样式内距 sp4 / sp3 sp4 |
/// | `posts.css` | 607–612 · 628–635 · 664–668 | `.posts-feed` / `.posts-skeleton` 基样式 `padding: sp3 sp4`（≤1024）⇒ ≥1025 覆写 `sp4 sp6`（**底部 sp4**；顶部/左右仍被上面的组规则归零） |
/// | `directory-filters.css` | 185–187 | `.favorites-content .home-state { padding-top: sp3 }`（收藏页空态顶部覆盖） |
///
/// ## 复现数字（1536×824）
/// 内容带宽 **1260**（x 256…1516）= 1536 − 2×12（页 padding）− 224（侧栏）− 12（body gap）
/// + 2×12（≥769 绘制带外扩）− 2×20（内容 padding `sp2+sp3`）；
/// 4 列槽宽 `(1260 − 3×12) / 4 = **306**` —— 与 web `.voice-channel-list` / `.games-grid` 实测相同。
///
/// ⚠️ 页面层只验「首帧骨架已接线」（真实数据分支需要网络，本仓测试不 mock HTTP）；
/// 列表件的几何由「目录页三件套 + 真实列表件」的用例覆盖（调用点传的
/// [aylaDirectoryListPadding] 与各页面调用点逐字相同）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/pages/favorites_page.dart';
import '../lib/pages/games_hub_page.dart';
import '../lib/pages/my_posts_page.dart';
import '../lib/pages/posts_hub_page.dart';
import '../lib/pages/voice_hub_page.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/directory_page.dart';
import '../lib/widgets/base/loading.dart';
import '../lib/widgets/base/profile_and_filters.dart';
import '../lib/widgets/game/games_grid.dart';
import '../lib/widgets/posts/masonry_grid.dart';
import '../lib/widgets/posts/post_page_chrome.dart';
import '../lib/widgets/search/search_history_chips.dart';
import '../lib/widgets/voice/voice_channels.dart';

void main() {
  const Size wide = Size(1536, 824);
  const Size narrow = Size(375, 720);

  const List<({String key, String label})> options =
      <({String key, String label})>[
    (key: 'all', label: '全部'),
    (key: 'voice', label: '语音'),
  ];

  /// 把测试表面设成目标视口（⚠️ 只覆写 MediaQuery 不够，根 view 也要钉）。
  Future<void> useViewport(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  /// 有界宿主（等价 web `.directory-page { height: 100% }` 的父级）。
  Widget host(
    Widget child, {
    Size viewport = wide,
    bool disableAnimations = false,
  }) {
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: viewport,
              disableAnimations: disableAnimations,
            ),
            child: SizedBox.expand(child: child),
          ),
        ),
      ),
    );
  }

  /// 有界宿主 + Riverpod（真实帖子页在 initState 读 `shellUiProvider`）。
  Widget hostScoped(Widget child, {Size viewport = wide}) {
    return ProviderScope(
      child: host(child, viewport: viewport, disableAnimations: true),
    );
  }

  /// 目录页三件套（`.directory-page` + 侧栏 + `.directory-content`），内容为给定列表件。
  Widget shell({required Widget child, bool narrowHost = false}) {
    return AylaDirectoryPage(
      filters: AylaDirectoryFilters(
        label: '语音分类',
        options: options,
        value: 'all',
        narrow: narrowHost,
        onChange: (String _) {},
      ),
      content: AylaDirectoryContent(fadeGlass: false, child: child),
    );
  }

  List<AylaVoiceCardData> channels(int n) => <AylaVoiceCardData>[
        for (int i = 0; i < n; i++)
          AylaVoiceCardData(id: '$i', name: '语音房 $i'),
      ];

  List<Widget> cells(int n) => <Widget>[
        for (int i = 0; i < n; i++)
          SizedBox(key: ValueKey<int>(i), height: 60, child: Text('room-$i')),
      ];

  /// 等入场动画走完（内容区 300ms + 侧栏 300ms）。
  Future<void> settle(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 400));

  group('aylaDirectoryListPadding（171–180 + 199–208）', () {
    Future<EdgeInsets> paddingAt(
      WidgetTester tester,
      double width, {
      double top = AylaSpacing.sp3,
      double bottom = AylaSpacing.sp3,
      bool zeroTopWhenWide = true,
    }) async {
      late EdgeInsets result;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: Size(width, 824)),
            child: Builder(
              builder: (BuildContext context) {
                result = aylaDirectoryListPadding(
                  context,
                  top: top,
                  bottom: bottom,
                  zeroTopWhenWide: zeroTopWhenWide,
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      return result;
    }

    testWidgets('≥769 ⇒ 左右 0 / 顶部 0 / 底部 sp3', (WidgetTester tester) async {
      expect(
        await paddingAt(tester, 1536),
        const EdgeInsets.fromLTRB(0, 0, 0, AylaSpacing.sp3),
      );
    });

    testWidgets('≤768 ⇒ 左右仍 0（171–180 无媒体查询）/ 顶部回列表自身 sp3',
        (WidgetTester tester) async {
      expect(
        await paddingAt(tester, 375),
        const EdgeInsets.fromLTRB(0, AylaSpacing.sp3, 0, AylaSpacing.sp3),
      );
    });

    testWidgets('zeroTopWhenWide: false（.conv-loading 口径）⇒ 顶部保持 sp3',
        (WidgetTester tester) async {
      expect(
        await paddingAt(tester, 1536, zeroTopWhenWide: false),
        const EdgeInsets.fromLTRB(0, AylaSpacing.sp3, 0, AylaSpacing.sp3),
      );
    });

    testWidgets('底部可覆写（收藏骨架 sp4）', (WidgetTester tester) async {
      expect(
        await paddingAt(tester, 1536, top: AylaSpacing.sp4, bottom: AylaSpacing.sp4),
        const EdgeInsets.fromLTRB(0, 0, 0, AylaSpacing.sp4),
      );
    });
  });

  group('语音列表（voice.css:505–511 + 组规则）', () {
    testWidgets('≥769：内容带 x 256…1516（宽 1260）· 4 列槽宽 306 · gap 12', (
      WidgetTester tester,
    ) async {
      await useViewport(tester, wide);
      await tester.pumpWidget(
        host(
          shell(
            child: Builder(
              builder: (BuildContext context) => AylaVoiceChannelList(
                channels: channels(4),
                padding: aylaDirectoryListPadding(context),
              ),
            ),
          ),
        ),
      );
      await settle(tester);

      final Rect list = tester.getRect(find.byType(AylaVoiceChannelList));
      expect(list.left, 256);
      expect(list.width, 1260);

      final List<Rect> cards = <Rect>[
        for (int i = 0; i < 4; i++)
          tester.getRect(find.byType(AylaVoiceChannelCard).at(i)),
      ];
      // 4 列等宽：槽宽 = (1260 − 3×12) / 4 = 306（web 实测同值）
      expect(cards[0].width, 306);
      expect(cards[1].left - cards[0].right, AylaSpacing.sp3); // gap 12
      // 左右 padding = 0：首卡贴内容带左沿、末卡贴右沿
      expect(cards[0].left, list.left);
      expect(list.right - cards[3].right, 0);
      // 顶部 padding = 0：首卡顶边与侧栏玻璃卡顶边对齐（199–208）
      expect(cards[0].top, list.top);
      expect(list.top, tester.getTopLeft(find.byType(AylaDirectoryFilters)).dy);
      // 底部 padding = sp3：不贴底、也不多出
      expect(list.bottom - cards[0].bottom, AylaSpacing.sp3);
    });

    testWidgets('≤768：左右仍 0（内容带左沿 x 16）· 顶部 sp3 · 底部 sp3', (
      WidgetTester tester,
    ) async {
      await useViewport(tester, narrow);
      await tester.pumpWidget(
        host(
          shell(
            narrowHost: true,
            child: Builder(
              builder: (BuildContext context) => AylaVoiceChannelList(
                channels: channels(4),
                padding: aylaDirectoryListPadding(context),
              ),
            ),
          ),
          viewport: narrow,
        ),
      );
      await settle(tester);

      final Rect list = tester.getRect(find.byType(AylaVoiceChannelList));
      final List<Rect> cards = <Rect>[
        for (int i = 0; i < 4; i++)
          tester.getRect(find.byType(AylaVoiceChannelCard).at(i)),
      ];
      expect(list.left, AylaSpacing.sp4); // 内容区自身 padding sp4，列表不再叠加
      expect(cards[0].width, 165.5); // (375 − 2×16 − 12) / 2
      expect(cards[0].left, list.left);
      expect(cards[0].top - list.top, AylaSpacing.sp3); // 顶部不归零
      expect(list.bottom - cards[3].bottom, AylaSpacing.sp3); // 底部 sp3
    });
  });

  group('桌游网格（boardgame.css:232–237 + 组规则）', () {
    testWidgets('≥769：内容带 x 256…1516（宽 1260）· 4 列槽宽 306 · gap 12', (
      WidgetTester tester,
    ) async {
      await useViewport(tester, wide);
      await tester.pumpWidget(
        host(
          shell(
            child: Builder(
              builder: (BuildContext context) => AylaGamesGrid(
                padding: aylaDirectoryListPadding(context),
                children: cells(4),
              ),
            ),
          ),
        ),
      );
      await settle(tester);

      final Rect grid = tester.getRect(find.byType(AylaGamesGrid));
      expect(grid.left, 256);
      expect(grid.width, 1260);

      final Rect r0 = tester.getRect(find.text('room-0'));
      final Rect r1 = tester.getRect(find.text('room-1'));
      expect(r0.width, 306);
      expect(r1.left - r0.right, AylaSpacing.sp3);
      expect(r0.left, grid.left);
      expect(r0.top, grid.top); // 顶部 0
      expect(grid.bottom - r0.bottom, AylaSpacing.sp3); // 底部 sp3
      expect(grid.top, tester.getTopLeft(find.byType(AylaDirectoryFilters)).dy);
    });

    testWidgets('≤768：左右仍 0 · 顶部 sp3 · 底部 sp3', (WidgetTester tester) async {
      await useViewport(tester, narrow);
      await tester.pumpWidget(
        host(
          shell(
            narrowHost: true,
            child: Builder(
              builder: (BuildContext context) => AylaGamesGrid(
                padding: aylaDirectoryListPadding(context),
                children: cells(4),
              ),
            ),
          ),
          viewport: narrow,
        ),
      );
      await settle(tester);

      final Rect grid = tester.getRect(find.byType(AylaGamesGrid));
      final Rect r0 = tester.getRect(find.text('room-0'));
      final Rect r3 = tester.getRect(find.text('room-3'));
      expect(grid.left, AylaSpacing.sp4);
      expect(r0.left, grid.left);
      expect(r0.width, 165.5);
      expect(r0.top - grid.top, AylaSpacing.sp3);
      expect(grid.bottom - r3.bottom, AylaSpacing.sp3);
    });
  });

  group('收藏列表（profile.css:458–465 / 524–532 + 组规则）', () {
    testWidgets('≥769 双列：左右 0 / 顶部 0 / 底部 sp4（.is-masonry 档）', (
      WidgetTester tester,
    ) async {
      await useViewport(tester, wide);
      await tester.pumpWidget(
        host(
          shell(
            child: Builder(
              builder: (BuildContext context) => AylaMasonryGrid<int>(
                items: const <int>[0, 1, 2, 3],
                itemKey: (int v) => v,
                memoryKey: 'test-favorites',
                columns: 2,
                padding: aylaDirectoryListPadding(context),
                masonryPadding: aylaDirectoryListPadding(
                  context,
                  bottom: AylaSpacing.sp4,
                ),
                itemBuilder: (BuildContext context, int v, int index) =>
                    SizedBox(height: 40, child: Text('fav-$v')),
              ),
            ),
          ),
        ),
      );
      await settle(tester);

      final Rect r0 = tester.getRect(find.text('fav-0'));
      final Rect r1 = tester.getRect(find.text('fav-1'));
      expect(r0.left, 256); // 左右 0（内容带左沿）
      expect(r1.left - r0.right, AylaSpacing.sp3); // .is-masonry gap sp3
      expect(r0.width, 624); // (1260 − 12) / 2
    });
  });

  group('搜索历史 chips（search.css:11–17 + 组规则 171–180）', () {
    Finder chipsPadding() => find
        .descendant(
          of: find.byType(AylaSearchHistoryChips),
          matching: find.byType(Padding),
        )
        .first;

    testWidgets('不传 padding ⇒ 基样式 sp3 sp4 sp3（画布 / 独立档不变）', (
      WidgetTester tester,
    ) async {
      await useViewport(tester, wide);
      await tester.pumpWidget(
        host(shell(child: const AylaSearchHistoryChips(history: <String>['爱莉']))),
      );
      await settle(tester);
      expect(
        tester.widget<Padding>(chipsPadding()).padding,
        AylaSearchHistoryChips.inset,
      );
    });

    testWidgets('目录页档 ⇒ 左右 0 / 顶部保 sp3（不在 199–208 名单内）', (
      WidgetTester tester,
    ) async {
      await useViewport(tester, wide);
      await tester.pumpWidget(
        host(
          shell(
            child: Builder(
              builder: (BuildContext context) => AylaSearchHistoryChips(
                history: const <String>['爱莉'],
                padding: aylaDirectoryListPadding(
                  context,
                  zeroTopWhenWide: false,
                ),
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      expect(
        tester.widget<Padding>(chipsPadding()).padding,
        const EdgeInsets.fromLTRB(0, AylaSpacing.sp3, 0, AylaSpacing.sp3),
      );
    });
  });

  group('非目录上下文默认契约不变（群内场景 / 画布样张；171–180 只作用于目录页）', () {
    testWidgets('语音列表不传 padding ⇒ 基样式 sp4/sp3（首卡再内缩 16 / 下移 12）', (
      WidgetTester tester,
    ) async {
      await useViewport(tester, wide);
      await tester.pumpWidget(
        host(shell(child: AylaVoiceChannelList(channels: channels(2)))),
      );
      await settle(tester);

      final Rect card = tester.getRect(find.byType(AylaVoiceChannelCard).first);
      expect(card.left, 272); // 256（内容带）+ 16（基样式 sp4）
      expect(card.top, AylaSpacing.sp3 * 2); // 12（内容）+ 12（基样式 sp3）
    });

    testWidgets('桌游网格不传 padding ⇒ 基样式 sp3 sp4（boardgame.css:232–237）', (
      WidgetTester tester,
    ) async {
      await useViewport(tester, wide);
      await tester.pumpWidget(
        host(shell(child: AylaGamesGrid(children: cells(4)))),
      );
      await settle(tester);

      final Rect r0 = tester.getRect(find.text('room-0'));
      expect(r0.left, 272);
      expect(r0.top, AylaSpacing.sp3 * 2);
    });

    testWidgets('桌游骨架不传 padding ⇒ 同 .games-grid 基样式', (
      WidgetTester tester,
    ) async {
      await useViewport(tester, wide);
      await tester.pumpWidget(
        host(shell(child: const AylaGamesGridSkeleton())),
      );
      await settle(tester);

      final Finder bar = find.byType(AylaSkeleton).first;
      expect(tester.getTopLeft(bar).dx, 272);
      expect(tester.getTopLeft(bar).dy, AylaSpacing.sp3 * 2);
    });
  });

  group('页面首帧接线（真实页面 ⇒ 骨架左右贴内容带，不是 +16）', () {
    testWidgets('VoiceHubPage：.conv-loading 左右 0 / 顶部保 sp3', (
      WidgetTester tester,
    ) async {
      await useViewport(tester, wide);
      await tester.pumpWidget(
        host(
          const VoiceHubPage(),
          disableAnimations: true,
        ),
      );
      final Finder bar = find.byType(AylaSkeleton).first;
      expect(tester.getTopLeft(bar).dx, 256); // 未接线时是 272（基样式 sp4）
      expect(tester.getTopLeft(bar).dy, AylaSpacing.sp3 * 2); // 内容 12 + 骨架 sp3
      expect(tester.getSize(bar).width, 306); // 4 列（1536 ≥ 1440）
      await tester.pumpAndSettle();
    });

    testWidgets('GamesHubPage：.games-grid.games-grid-loading 左右 0 / 顶部 0', (
      WidgetTester tester,
    ) async {
      await useViewport(tester, wide);
      await tester.pumpWidget(
        host(
          const GamesHubPage(),
          disableAnimations: true,
        ),
      );
      final Finder bar = find.byType(AylaSkeleton).first;
      expect(tester.getTopLeft(bar).dx, 256);
      expect(tester.getTopLeft(bar).dy, AylaSpacing.sp3); // 首卡顶边与侧栏顶边对齐
      expect(tester.getSize(bar).width, 306);
      await tester.pumpAndSettle();
    });

    testWidgets('FavoritesPage：.favorites-skeleton 左右 0 / 顶部 0', (
      WidgetTester tester,
    ) async {
      await useViewport(tester, wide);
      await tester.pumpWidget(
        host(
          const FavoritesPage(),
          disableAnimations: true,
        ),
      );
      final Finder bar = find.byType(AylaSkeleton).first;
      expect(tester.getTopLeft(bar).dx, 256);
      expect(tester.getTopLeft(bar).dy, AylaSpacing.sp3);
      await tester.pumpAndSettle();
    });

    testWidgets('PostsHubPage：.posts-skeleton 左右 0 / 顶部 0 / 底部 sp4（首卡顶边 = 侧栏顶边）', (
      WidgetTester tester,
    ) async {
      await useViewport(tester, wide);
      await tester.pumpWidget(hostScoped(const PostsHubPage()));
      final Finder bar = find.byType(AylaSkeleton).first;
      expect(tester.getTopLeft(bar).dx, 256); // 未接线时是 272（基样式 sp4）
      expect(tester.getTopLeft(bar).dy, AylaSpacing.sp3); // 内容区 sp3 + 骨架 0
      // 骨架内距 = 页面 listPadding（1536 ≥ 1025 ⇒ 底部 sp4：posts.css:664–668）
      expect(
        tester.widget<AylaPostsSkeleton>(find.byType(AylaPostsSkeleton)).padding,
        const EdgeInsets.fromLTRB(0, 0, 0, AylaSpacing.sp4),
      );
      // 修复目标：首卡顶边与侧栏玻璃卡顶边对齐（directory-filters.css:199–208）
      expect(
        tester.getTopLeft(bar).dy,
        tester.getTopLeft(find.byType(AylaDirectoryFilters)).dy,
      );
      await tester.pumpAndSettle();
    });

    testWidgets('PostsHubPage 窄屏：骨架左右 0 / 顶部仍 sp3（顶部归零只在 ≥769）', (
      WidgetTester tester,
    ) async {
      await useViewport(tester, narrow);
      await tester.pumpWidget(
        hostScoped(const PostsHubPage(), viewport: narrow),
      );
      final Finder bar = find.byType(AylaSkeleton).first;
      final double contentTop =
          tester.getRect(find.byType(AylaDirectoryContent)).top;
      expect(tester.getTopLeft(bar).dx, AylaSpacing.sp4); // 窄屏内容区 padding sp4
      // 内容区 sp2(8) + 骨架 sp3(12)：顶部未归零
      expect(
        tester.getTopLeft(bar).dy - contentTop,
        AylaSpacing.sp2 + AylaSpacing.sp3,
      );
      expect(
        tester.widget<AylaPostsSkeleton>(find.byType(AylaPostsSkeleton)).padding,
        const EdgeInsets.fromLTRB(0, AylaSpacing.sp3, 0, AylaSpacing.sp3),
      );
      await tester.pumpAndSettle();
    });

    testWidgets('MyPostsPage（非目录页）：骨架不被组规则归零（左右仍 sp6 + 1200 居中）', (
      WidgetTester tester,
    ) async {
      await useViewport(tester, wide);
      await tester.pumpWidget(hostScoped(const MyPostsPage()));
      final Rect bar = tester.getRect(find.byType(AylaSkeleton).first);
      // 1536 − 1200 = 336 ⇒ 居中左沿 168；+ 基样式 sp6(24) = 192
      // （若误接目录页 helper 会是 256 = 内容带左沿）
      expect(bar.left, 192);
      expect(bar.left, isNot(256));
      await tester.pumpAndSettle();
    });
  });

  group('帖子列表（posts.css 607–612 / 628–635 + 组规则 171–180 / 199–208）', () {
    /// 与 `posts_hub_page.dart` 的 `listPadding`**逐字相同**的表达式
    /// （页面里骨架与真实列表**共用该变量**）——与骨架用例合起来锁定
    /// 「骨架与真实列表同口径」。
    EdgeInsets listPadding(BuildContext context) => aylaDirectoryListPadding(
          context,
          bottom: MediaQuery.sizeOf(context).width >= AylaBreakpoints.lg
              ? AylaSpacing.sp4
              : AylaSpacing.sp3,
        );

    Widget feed() => Builder(
          builder: (BuildContext context) => AylaMasonryGrid<int>(
            items: const <int>[0, 1, 2],
            itemKey: (int v) => v,
            memoryKey: 'test-posts-feed',
            gap: AylaSpacing.sp3, // .posts-feed gap: sp3
            padding: listPadding(context),
            itemBuilder: (BuildContext context, int v, int index) =>
                SizedBox(height: 40, child: Text('post-$v')),
          ),
        );

    testWidgets('≥769：左右 0 / 顶部 0 ⇒ 首卡顶边 = 侧栏玻璃卡顶边', (
      WidgetTester tester,
    ) async {
      await useViewport(tester, wide);
      await tester.pumpWidget(
        host(shell(child: feed()), disableAnimations: true),
      );
      await settle(tester);

      final Finder grid = find.byType(AylaMasonryGrid<int>);
      final Rect list = tester.getRect(grid);
      expect(list.left, 256);
      expect(list.width, 1260);
      final Rect card = tester.getRect(find.text('post-0'));
      expect(card.left, list.left); // 左右 0
      expect(card.top, list.top); // 顶部 0
      expect(list.top, tester.getTopLeft(find.byType(AylaDirectoryFilters)).dy);
      expect(
        tester.widget<AylaMasonryGrid<int>>(grid).padding,
        const EdgeInsets.fromLTRB(0, 0, 0, AylaSpacing.sp4),
      );
    });

    testWidgets('769–1024：左右 0 / 顶部 0 / 底部仍 sp3（≥1025 才升 sp4）', (
      WidgetTester tester,
    ) async {
      const Size mid = Size(900, 824);
      await useViewport(tester, mid);
      await tester.pumpWidget(
        host(
          shell(child: feed()),
          viewport: mid,
          disableAnimations: true,
        ),
      );
      await settle(tester);

      final Finder grid = find.byType(AylaMasonryGrid<int>);
      expect(tester.getRect(grid).left, 256);
      expect(
        tester.widget<AylaMasonryGrid<int>>(grid).padding,
        const EdgeInsets.fromLTRB(0, 0, 0, AylaSpacing.sp3),
      );
    });

    testWidgets('≤768：左右仍 0（171–180 无媒体查询）/ 顶部回 sp3', (
      WidgetTester tester,
    ) async {
      await useViewport(tester, narrow);
      await tester.pumpWidget(
        host(
          shell(narrowHost: true, child: feed()),
          viewport: narrow,
          disableAnimations: true,
        ),
      );
      await settle(tester);

      final Finder grid = find.byType(AylaMasonryGrid<int>);
      final Rect list = tester.getRect(grid);
      expect(list.left, AylaSpacing.sp4); // 内容区自身 padding sp4，列表不再叠加
      final Rect card = tester.getRect(find.text('post-0'));
      expect(card.left, list.left);
      expect(card.top - list.top, AylaSpacing.sp3); // 顶部不归零
      expect(
        tester.widget<AylaMasonryGrid<int>>(grid).padding,
        const EdgeInsets.fromLTRB(0, AylaSpacing.sp3, 0, AylaSpacing.sp3),
      );
    });

    testWidgets('非目录上下文：件不传 padding ⇒ 基样式分档不变（未被组规则归零）', (
      WidgetTester tester,
    ) async {
      await useViewport(tester, wide);
      await tester.pumpWidget(
        host(
          const Scaffold(body: AylaPostsSkeleton(centered: false)),
          disableAnimations: true,
        ),
      );
      await settle(tester);

      // 1536 ≥ 1025 ⇒ posts.css:664–668 的 sp4 sp6（.posts-skeleton 基样式 628–635 的
      // 顶部 sp3 被 ≥1025 的分档覆写）——组规则只作用于 .directory-page 后代
      final Rect bar = tester.getRect(find.byType(AylaSkeleton).first);
      expect(bar.left, AylaSpacing.sp6);
      expect(bar.top, AylaSpacing.sp4);
    });
  });
}
