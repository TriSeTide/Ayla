/// 收藏页 / 搜索页**内容区入场动画**回归锁（2026-10-09，用户实报）。
///
/// ## 被锁住的缺陷
/// 「收藏、搜索页内容区没有入场动画（web 有）」。
///
/// ## web 事实源（逐条）
/// - **收藏页**：`FavoritesPage.tsx:82` 的
///   `useListEntryMotion(listRef, ".favorite-item", suppressEntry, replayNonce)`
///   + `useListEntryMotion.ts:68–80`：每个**新入场**的 `.favorite-item` 播
///   `opacity 0→1` + `translateY(20px→0)`、`300ms ease-out`、
///   `delay = staggerDelay(index) = min(index*50, 300)`（`useRevealOnEnter.ts`）。
///   `suppressEntry = restoring && !resumeEntry`（tsx 277）：滚动恢复命中时**不播**。
///   刷新（`replayNonce` 递增，tsx 200）⇒ 已入场项整批重播（`useListEntryMotion.ts:34–55`）。
/// - **搜索页**：`SearchPage.tsx:119` 的 selector 是三段
///   `".search-row, .typed-result-card, .search-group .stable-pagination-footer .btn"`
///   ⇒ 用户行、六类结果卡（GroupResultCard/PostCard/GameRoomCard/VoiceChannelCard/
///   LiveChannelCard 的 typed 外包层）、**各组页脚按钮**都在内
///   （`.search-chip` / `.search-clear` **不在**，历史 chips 不播）。
/// - **内容区整块**：两页都是目录页族 ⇒ `directory-filters.css:145–167` 的
///   `directory-content-in`（`opacity 0→1` + `translateY(12px→0)`、300ms
///   `--auroraqua-ease` = **ease**），由 `AylaDirectoryContent` 的 `AylaRevealItem` 承担
///   （已有 `directory_page_pieces_test.dart` 锁定，本文件不重复）。
///
/// ## 为什么这条锁必须存在
/// `AylaDirectoryContent` 的整块入场只盖住**内容区**；列表**逐条**的浮入是另一条
/// owner（web 的 `useListEntryMotion`）。此前 Flutter 侧只做了前者、漏了后者
/// ⇒ 用户看到的「内容区没有入场动画」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/favorite_item.dart';
import '../lib/widgets/base/reveal.dart';
import '../lib/widgets/search/search_result_group.dart';

void main() {
  Widget host(Widget child, {Size viewport = const Size(420, 900)}) => MaterialApp(
    home: previewScope(
      Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: viewport),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: viewport.width, child: child),
          ),
        ),
      ),
    ),
  );

  group('AylaRevealItem 的 stagger 语义（收藏/搜索两页共用同一件）', () {
    testWidgets('index → min(index*50, 300) 的 delay（useRevealOnEnter.ts）', (
      WidgetTester tester,
    ) async {
      // 直接对纯函数断言：三档边界（0 / 3 / 7+）
      expect(AylaRevealMotion.staggerDelay(0), Duration.zero);
      expect(AylaRevealMotion.staggerDelay(3), const Duration(milliseconds: 150));
      expect(AylaRevealMotion.staggerDelay(6), const Duration(milliseconds: 300));
      expect(
        AylaRevealMotion.staggerDelay(20),
        const Duration(milliseconds: 300),
        reason: 'cap 300ms（staggerDelay 的 Math.min）',
      );
    });

    testWidgets('首帧 opacity ≈ 0 + 位移未开始（进入动画在播）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaRevealItem(
            fadeGlass: false,
            child: SizedBox(width: 100, height: 40, child: Text('卡片')),
          ),
        ),
      );
      await tester.pump(); // 首帧（t=0）
      final Finder opacity = find.descendant(
        of: find.byType(AylaRevealItem),
        matching: find.byType(Opacity),
      );
      // ⚠️ 玻璃档（`fadeGlass: false`）在 t=0 时用 `kAylaInvisibleButPainted`
      //（0.001 = 0.4/255，肉眼与全透明等价）让快照**提前捕获**，见 reveal.dart 的
      // 常量注释；非玻璃档才是严格的 0.0。这里两档一并放行（断言「不可见」而非「等于 0」）。
      final double first = tester.widget<Opacity>(opacity.first).opacity;
      expect(first <= kAylaInvisibleButPainted, isTrue,
          reason: 'web `.reveal-item { opacity: 0 }` + `fill: backwards`（实得 $first）');
      await tester.pump(const Duration(milliseconds: 400)); // 走完 300ms
      expect(
        tester.widget<Opacity>(opacity.first).opacity,
        1.0,
        reason: '300ms 后到终值（forwards）',
      );
    });

    testWidgets('reduced-motion ⇒ 不挂动画（MediaQuery.disableAnimations）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: previewScope(
            MediaQuery(
              data: const MediaQueryData(
                size: Size(420, 900),
                disableAnimations: true,
              ),
              child: const AylaRevealItem(
                fadeGlass: false,
                child: SizedBox(width: 100, height: 40, child: Text('卡片')),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(AylaRevealItem),
          matching: find.byType(Opacity),
        ),
        findsNothing,
        reason: 'base.css:501–506 / directory-filters.css:249–254 ⇒ animation: none',
      );
    });
  });

  group('搜索页结果分组：页脚按钮的逐条浮入（SearchPage.tsx:119 第三段 selector）', () {
    // ⚠️ 一态一用例（同用例二次 pumpWidget 换 props 不生效）
    testWidgets('footerRevealIndex 传入 ⇒ 页脚按钮挂 AylaRevealItem', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaSearchResultGroup(
            title: '用户',
            count: 1,
            hasMore: true,
            onMore: () {},
            footerRevealIndex: 2,
            children: const <Widget>[Text('行')],
          ),
        ),
      );
      await tester.pump();
      // 组内：结果项由调用方包（本用例只放裸 Text ⇒ 无），页脚按钮由本件包
      final List<AylaRevealItem> reveals = tester
          .widgetList<AylaRevealItem>(find.byType(AylaRevealItem))
          .toList();
      expect(reveals.length, 1, reason: '页脚按钮一个 reveal 槽');
      expect(reveals.single.index, 2, reason: '下标 = 全局 DOM 位次（跨组连续）');
      expect(reveals.single.fadeGlass, isFalse, reason: 'AylaGlassButton 含玻璃');
    });

    testWidgets('footerRevealIndex 不传 ⇒ 不挂（无页面上下文，如画布样张）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaSearchResultGroup(
            title: '用户',
            count: 1,
            hasMore: true,
            onMore: () {},
            children: const <Widget>[Text('行')],
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(AylaRevealItem), findsNothing);
      expect(find.text('查看更多'), findsOneWidget, reason: '按钮本体照常渲染');
    });

    testWidgets('无页脚（hasMore=false 且无 error）⇒ 无 reveal 槽', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaSearchResultGroup(
            title: '用户',
            count: 1,
            footerRevealIndex: 0,
            children: const <Widget>[Text('行')],
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(AylaRevealItem), findsNothing);
    });
  });

  group('收藏项容器：逐条浮入挂在 AylaFavoriteItem 外侧（不破坏玻璃安全）', () {
    testWidgets('AylaRevealItem(index) 包 AylaFavoriteItem ⇒ 玻璃链上无 Opacity 祖先', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaRevealItem(
            fadeGlass: false,
            index: 1,
            child: const AylaFavoriteItem(child: Text('收藏内容')),
          ),
        ),
      );
      await tester.pump();
      // 收藏页的调用点（favorites_page.dart 的 itemBuilder）就是这个形状。
      // `fadeGlass: false` ⇒ 不推 OpacityLayer ⇒ Impeller 不会拒绝玻璃后代。
      // ⚠️ 解除冻结（`snapshot` 传 null）后仍会渲染一个 alpha=255 的 Opacity，
      //    但 `OpacityLayer.addToScene` 在 alpha==255 时走 `pushOffset`（不推 opacity）
      //    —— 这里断言的是「**入场期内**不叠加不透明度」，故在首帧断言。
      final Iterable<Opacity> opacities = tester.widgetList<Opacity>(
        find.descendant(
          of: find.byType(AylaRevealItem),
          matching: find.byType(Opacity),
        ),
      );
      expect(
        opacities.where((Opacity o) => o.opacity < 1.0 && o.opacity > 0.0),
        isEmpty,
        reason: 'fadeGlass:false 档在 t∈(0,1) 内不产生「部分不透明」的层',
      );
    });
  });
}
