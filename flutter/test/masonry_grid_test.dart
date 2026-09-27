/// `AylaMasonryGrid` 定向测试 —— 逐条对照 `hooks/useMasonryColumns.ts`（146 行）+
/// `posts.css 607–694` / `profile.css 458–545`。
///
/// 覆盖：单列/双列断点 · 「最矮列 + 320 预估」交错分配 · **分配锁定**（追加新项不改已分配）·
/// 跨挂载恢复（同一 memoryKey）· **断点切换按列数隔离**（web 2026-08-26 修过的 col=[20,0] 坑）·
/// favorites 档的 gap/padding 差异 · footer 横跨列。
///
/// ⚠️ 纪律（库内既有结论，本文件已按它组织）：**同一用例里二次 `pumpWidget` 换 props / 换视口不生效**
/// ⇒ ① 每个静态档位各写一个用例；② 需要「同一用例内切参数」的（追加项、断点切换）用
/// `StatefulBuilder` 宿主驱动，而不是再 `pumpWidget` 一次。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/posts/masonry_grid.dart';

void main() {
  setUp(aylaClearMasonryMemory);
  tearDown(aylaClearMasonryMemory);

  /// 定宽宿主（决定单/双列）+ 可滚动高度（列表无界高）。
  Widget host(Widget child, {required double width}) => MaterialApp(
    home: previewScope(
      Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: Size(width, 900)),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: 900,
              child: SingleChildScrollView(child: child),
            ),
          ),
        ),
      ),
    ),
  );

  Widget grid({
    required List<int> items,
    String memoryKey = 'k',
    double gap = AylaSpacing.sp3,
    double? masonryGap,
    EdgeInsetsGeometry padding = const EdgeInsets.fromLTRB(16, 12, 16, 12),
    EdgeInsetsGeometry? masonryPadding,
    Widget? footer,
  }) => AylaMasonryGrid<int>(
    items: items,
    memoryKey: memoryKey,
    gap: gap,
    masonryGap: masonryGap,
    padding: padding,
    masonryPadding: masonryPadding,
    footer: footer,
    itemKey: (int i) => i,
    itemBuilder: (BuildContext context, int item, int index) =>
        SizedBox(height: 100, child: Text('item-$item')),
  );

  double leftOf(WidgetTester tester, int i) =>
      tester.getRect(find.text('item-$i')).left;

  testWidgets('窄屏（<1025）⇒ 单列：所有项同左缘', (WidgetTester tester) async {
    await tester.pumpWidget(host(grid(items: <int>[0, 1, 2, 3]), width: 800));
    await tester.pump();
    final double l0 = leftOf(tester, 0);
    for (final int i in <int>[1, 2, 3]) {
      expect(leftOf(tester, i), l0);
    }
  });

  testWidgets('宽屏（≥1025）⇒ 双列，按「最矮列 + 320 预估」交错（0,2 | 1,3）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(grid(items: <int>[0, 1, 2, 3]), width: 1200));
    await tester.pump();

    final double colA = leftOf(tester, 0);
    final double colB = leftOf(tester, 1);
    expect(colB, greaterThan(colA)); // 第二列在右
    expect(leftOf(tester, 2), colA); // 交错
    expect(leftOf(tester, 3), colB);
  });

  testWidgets('分配锁定：追加新项时已分配项不动，新项进某一列末尾', (WidgetTester tester) async {
    final ValueNotifier<int> count = ValueNotifier<int>(4);
    addTearDown(count.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: previewScope(
          ValueListenableBuilder<int>(
            valueListenable: count,
            builder: (BuildContext context, int n, Widget? _) {
              final List<int> items = List<int>.generate(n, (int i) => i);
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(size: const Size(1200, 900)),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 1200,
                    height: 900,
                    child: SingleChildScrollView(
                      child: AylaMasonryGrid<int>(
                        items: items,
                        itemKey: (int i) => i,
                        itemBuilder:
                            (BuildContext context, int item, int index) =>
                                SizedBox(height: 100, child: Text('item-$item')),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    final double colA = leftOf(tester, 0);
    final double colB = leftOf(tester, 1);

    count.value = 5; // 追加一项
    await tester.pump();
    await tester.pump(); // 帧后测量 → 再一帧生效
    expect(leftOf(tester, 0), colA); // 锁定
    expect(leftOf(tester, 2), colA);
    expect(leftOf(tester, 1), colB);
    expect(leftOf(tester, 3), colB);
    expect(leftOf(tester, 4) == colA || leftOf(tester, 4) == colB, isTrue);
  });

  testWidgets('跨挂载恢复：同一 memoryKey 重建后列布局一致', (WidgetTester tester) async {
    await tester.pumpWidget(host(grid(items: <int>[0, 1, 2, 3]), width: 1200));
    await tester.pump();
    final double colA = leftOf(tester, 0);
    final double colB = leftOf(tester, 1);

    // 卸载（换成别的 widget 类型）再重建
    await tester.pumpWidget(host(const SizedBox.shrink(), width: 1200));
    await tester.pump();
    await tester.pumpWidget(host(grid(items: <int>[0, 1, 2, 3]), width: 1200));
    await tester.pump();
    expect(leftOf(tester, 0), colA);
    expect(leftOf(tester, 2), colA);
    expect(leftOf(tester, 1), colB);
    expect(leftOf(tester, 3), colB);
  });

  testWidgets('断点切换按列数隔离：单列→双列不会全挤进第一列（web col=[20,0] 坑）', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<double> width = ValueNotifier<double>(800);
    addTearDown(width.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: previewScope(
          ValueListenableBuilder<double>(
            valueListenable: width,
            builder: (BuildContext context, double w, Widget? _) => MediaQuery(
              data: MediaQuery.of(context).copyWith(size: Size(w, 900)),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: w,
                  height: 900,
                  child: SingleChildScrollView(
                    child: AylaMasonryGrid<int>(
                      items: const <int>[0, 1, 2, 3],
                      itemKey: (int i) => i,
                      itemBuilder: (BuildContext context, int item, int index) =>
                          SizedBox(height: 100, child: Text('item-$item')),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(); // 单列
    expect(leftOf(tester, 1), leftOf(tester, 0));

    width.value = 1200; // 切到双列
    await tester.pump();
    final double colA = leftOf(tester, 0);
    final double colB = leftOf(tester, 1);
    expect(colB, greaterThan(colA));
    expect(leftOf(tester, 2), colA); // 关键：第二列必须有人（继承单列记忆 ⇒ 全在 col0）
    expect(leftOf(tester, 3), colB);
  });

  testWidgets('favorites 单列档：gap sp2', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        grid(items: <int>[0, 1], memoryKey: 'fav', gap: AylaSpacing.sp2),
        width: 800,
      ),
    );
    await tester.pump();
    final Rect f0 = tester.getRect(find.text('item-0'));
    final Rect f1 = tester.getRect(find.text('item-1'));
    expect(f1.top - f0.bottom, AylaSpacing.sp2);
  });

  testWidgets('posts 双列档：列间距 = masonryGap（sp3）', (WidgetTester tester) async {
    await tester.pumpWidget(host(grid(items: <int>[0, 1]), width: 1200));
    await tester.pump();
    expect(
      leftOf(tester, 1) - tester.getRect(find.text('item-0')).right,
      AylaSpacing.sp3,
    );
  });

  testWidgets('favorites 双列档：masonryGap sp3 + masonryPadding 上下 sp4', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        grid(
          items: <int>[0, 1],
          memoryKey: 'fav2',
          gap: AylaSpacing.sp2,
          masonryGap: AylaSpacing.sp3,
          masonryPadding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        ),
        width: 1200,
      ),
    );
    await tester.pump();
    final Rect m0 = tester.getRect(find.text('item-0'));
    expect(m0.left, 16); // 左内距
    expect(m0.top, 16); // 双列上下 sp4
    expect(
      leftOf(tester, 1) - m0.right,
      AylaSpacing.sp3, // 双列 gap sp3（≠ 单列 sp2）
    );
  });

  testWidgets('footer 横跨列（在列内容下方、宽度跨两列）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        grid(
          items: <int>[0, 1, 2],
          footer: const SizedBox(
            key: ValueKey<String>('footer'),
            height: 40,
            child: Text('加载更多'),
          ),
        ),
        width: 1200,
      ),
    );
    await tester.pump();
    final Rect footer = tester.getRect(find.text('加载更多'));
    final Rect last = tester.getRect(find.text('item-2'));
    expect(footer.top, greaterThan(last.bottom)); // 在列内容下方
    expect(
      tester.getRect(find.byKey(const ValueKey<String>('footer'))).width,
      greaterThan(600),
    ); // 跨两列
  });
}
