/// 桌游网格两件定向测试 —— 对照 `GamesHubPage.tsx:184–216` + `boardgame.css 232–275`。
///
/// 覆盖：列数断点（<769 两列 / ≥769 四列）· `columns` 覆写（群内恒 2）· 等宽列与 gap sp3 ·
/// padding sp3 sp4 · 骨架两张 120 高 + 跨列文案 + 语义 label。
/// ⚠️ 一态一用例（同用例二次 pumpWidget 换 props 不生效）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/loading.dart';
import '../lib/widgets/game/games_grid.dart';

void main() {
  Widget host(Widget child, {double width = 900}) => MaterialApp(
    home: previewScope(
      Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: Size(width, 800)),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    ),
  );

  List<Widget> cells(int n) => <Widget>[
    for (int i = 0; i < n; i++)
      SizedBox(key: ValueKey<int>(i), height: 60, child: Text('room-$i')),
  ];

  group('AylaGamesGrid（boardgame.css 232–243）', () {
    testWidgets('窄档（<769）⇒ 两列等宽', (WidgetTester tester) async {
      await tester.pumpWidget(host(AylaGamesGrid(children: cells(4)), width: 700));
      final Rect r0 = tester.getRect(find.text('room-0'));
      final Rect r1 = tester.getRect(find.text('room-1'));
      final Rect r2 = tester.getRect(find.text('room-2'));
      expect(r1.left, greaterThan(r0.left)); // 第二列在右
      expect(r2.top, greaterThan(r0.top)); // 第三张换行
      expect(r2.left, r0.left); // 回到第一列
      // 列间距 = sp3
      expect(r1.left - r0.right, closeTo(AylaSpacing.sp3, 0.01));
    });

    testWidgets('宽档（≥769）⇒ 四列', (WidgetTester tester) async {
      await tester.pumpWidget(host(AylaGamesGrid(children: cells(5)), width: 900));
      final double l0 = tester.getRect(find.text('room-0')).left;
      final double l3 = tester.getRect(find.text('room-3')).left;
      final double l4 = tester.getRect(find.text('room-4')).left;
      expect(l3, greaterThan(l0));
      expect(l4, l0); // 第 5 张换到第二行第一列
      expect(tester.getRect(find.text('room-4')).top,
          greaterThan(tester.getRect(find.text('room-0')).top));
    });

    testWidgets('columns 覆写：群内恒 2 列（boardgame.css 254–259）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(AylaGamesGrid(columns: 2, children: cells(4)), width: 900),
      );
      final double l0 = tester.getRect(find.text('room-0')).left;
      final double l2 = tester.getRect(find.text('room-2')).left;
      expect(l2, l0); // 仍是 2 列 ⇒ 第 3 张回到第一列
      expect(
        tester.getRect(find.text('room-2')).top,
        greaterThan(tester.getRect(find.text('room-0')).top),
      );
    });

    testWidgets('内距 padding sp3 sp4（左 16 / 上 12）', (WidgetTester tester) async {
      await tester.pumpWidget(host(AylaGamesGrid(children: cells(2)), width: 900));
      final Rect r0 = tester.getRect(find.text('room-0'));
      expect(r0.left, 16);
      expect(r0.top, 12);
    });
  });

  group('AylaGamesGridSkeleton（tsx 185–193 + boardgame.css 265–275）', () {
    testWidgets('两张 120 高骨架 + 跨列文案 + 语义 label', (WidgetTester tester) async {
      await tester.pumpWidget(host(const AylaGamesGridSkeleton(), width: 900));
      final Finder bars = find.byType(AylaSkeleton);
      expect(bars, findsNWidgets(2));
      expect(tester.getSize(bars.at(0)).height, AylaGamesGridSkeleton.cardHeight);
      expect(find.text('正在加载桌游室…'), findsOneWidget);
      // 文案跨列（容器宽 > 单列宽；⚠️ 别用 find.text 量——那只是文本自身宽）
      final double colW = tester.getSize(bars.at(0)).width;
      expect(tester.getSize(find.byKey(gamesSkeletonTextKey)).width, greaterThan(colW));
      final Semantics sem = tester.widget<Semantics>(
        find
            .descendant(
              of: find.byType(AylaGamesGridSkeleton),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(sem.properties.label, '正在加载桌游室…');
      expect(sem.properties.liveRegion, isTrue);
    });
  });
}
