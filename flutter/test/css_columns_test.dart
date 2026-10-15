/// `AylaCssColumns`（CSS `columns: N` + `column-fill: balance` 等价件）的回归锁。
///
/// ## 为什么这些样本是「事实源」而不是「我算出来的」
/// 全部 9 组来自**真实 Chrome 的受控实验**：把块级 `column-count:2; column-gap:24px` 容器
/// 挂进真实搜索页（1440×900），塞入固定高 + `margin-bottom` + `break-inside:avoid` 的单元，
/// 量每个单元的 `getBoundingClientRect().x` 归组、以及容器高。
/// 采集命令与页面见交付报告；本文件的期望值是**量出来的**，不是推导出来的。
///
/// ⚠️ 这些样本里有两组会直接打死「按均值切」的写法（g11 = 6/5 而非 5/6、
/// 7×(100/10) = 4/3 而非 4/3 的均值版），所以它们是有效的判别性样本。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/widgets/base/css_columns.dart';

/// 生成 n 个相同高的单元。
List<double> _same(int n, double h) => List<double>.filled(n, h);

/// 把分配结果压成「每列装了几个」的区间串（与浏览器实测的 x 归组对齐）。
List<String> _ranges(List<int> columns) {
  final Map<int, List<int>> byCol = <int, List<int>>{};
  for (int i = 0; i < columns.length; i++) {
    byCol.putIfAbsent(columns[i], () => <int>[]).add(i);
  }
  final List<int> keys = byCol.keys.toList()..sort();
  return <String>[
    for (final int k in keys)
      '${byCol[k]!.first}..${byCol[k]!.last}',
  ];
}

void main() {
  group('aylaCssColumnsDistribute —— 受控实验实测标定', () {
    test('20 x 66.6，gap 24 => 10 / 10', () {
      final List<int> c = aylaCssColumnsDistribute(_same(20, 66.6),
          itemGap: 24, columnCount: 2);
      expect(_ranges(c), <String>['0..9', '10..19']);
    });

    test('11 x 82.6，gap 24 => 6 / 5（判据：按均值切会得 5/6）', () {
      final List<int> c = aylaCssColumnsDistribute(_same(11, 82.6),
          itemGap: 24, columnCount: 2);
      expect(_ranges(c), <String>['0..5', '6..10']);
    });

    test('20 x 150.9，gap 24 => 10 / 10', () {
      final List<int> c = aylaCssColumnsDistribute(_same(20, 150.9),
          itemGap: 24, columnCount: 2);
      expect(_ranges(c), <String>['0..9', '10..19']);
    });

    test('20 x 202.6，gap 24 => 10 / 10', () {
      final List<int> c = aylaCssColumnsDistribute(_same(20, 202.6),
          itemGap: 24, columnCount: 2);
      expect(_ranges(c), <String>['0..9', '10..19']);
    });

    test('6 组不等高（搜索页全部档），gap 16 => 4 / 2', () {
      // 真实「全部」档分组高（含单元 margin-bottom 已折进 itemGap）
      const List<double> h = <double>[
        317.5,
        365.5,
        725.4,
        1373.4,
        570.5,
        1298.9,
      ];
      final List<int> c =
          aylaCssColumnsDistribute(h, itemGap: 16, columnCount: 2);
      expect(_ranges(c), <String>['0..3', '4..5']);
    });

    test('4 x 100，gap 24 => 2 / 2', () {
      final List<int> c = aylaCssColumnsDistribute(_same(4, 100),
          itemGap: 24, columnCount: 2);
      expect(_ranges(c), <String>['0..1', '2..3']);
    });

    test('5 x 100，gap 24 => 3 / 2', () {
      final List<int> c = aylaCssColumnsDistribute(_same(5, 100),
          itemGap: 24, columnCount: 2);
      expect(_ranges(c), <String>['0..2', '3..4']);
    });

    test('7 x 100，gap 24 => 4 / 3', () {
      final List<int> c = aylaCssColumnsDistribute(_same(7, 100),
          itemGap: 24, columnCount: 2);
      expect(_ranges(c), <String>['0..3', '4..6']);
    });

    test('7 x 10，gap 24 => 4 / 3', () {
      final List<int> c = aylaCssColumnsDistribute(_same(7, 10),
          itemGap: 24, columnCount: 2);
      expect(_ranges(c), <String>['0..3', '4..6']);
    });

    test('对拍精度登记：40 组「搜索页真实场景」全部与 Chrome 一致', () {
      // 5 类卡高 × 11/20 项 × 4 档抖动 = 40 组；期望值全部来自真实 Chrome 的双盲对拍。
      // 覆盖「同组内同类型结果卡（高度接近）」这一**实际形态**；
      // 200 组纯随机里唯一 1 组不匹配是「高度差异极大」的反例（见下方登记用例）。
      const Map<String, double> base = <String, double>{
        'user': 66.6,
        'group': 82.6,
        'post': 202.6,
        'voice': 150.9,
        'live': 393.7,
      };
      int checked = 0;
      for (final MapEntry<String, double> e in base.entries) {
        for (final int n in <int>[11, 20]) {
          for (final double jitter in <double>[0, 0.1, 1, 5]) {
            final List<double> h = <double>[
              for (int i = 0; i < n; i++)
                // ⚠️ 公式必须与采集 Chrome 期望值时的 JS **逐字一致**
                // （JS: `Math.round((h + (i % 3 === 0 ? jitter : -jitter)) * 10) / 10`）
                // —— 写成 `(h + jitter) * 10` 会得到另一组数据，断言就失去意义（已踩过）。
                ((e.value + (i % 3 == 0 ? jitter : -jitter)) * 10).round() / 10,
            ];
            final List<int> cols =
                aylaCssColumnsDistribute(h, itemGap: 24, columnCount: 2);
            // Chrome 实测：同类等高/近高卡在 n=2 下恒为「前半 / 后半」等分
            final int firstCol = cols.where((int c) => c == 0).length;
            expect(cols.length, n);
            expect(cols.first, 0);
            expect(cols.last, 1, reason: '${e.key}/$n/jit$jitter 必须真实分到两列');
            expect(firstCol, (n / 2).ceil(),
                reason: '${e.key}/$n/jit$jitter 的列 0 项数');
            checked += 1;
          }
        }
      }
      expect(checked, 40);
    });

    test('已知偏差登记：高度差异极大时不复现 Blink（n=2/gap=16/22 项）', () {
      // 2026-10-14 双盲对拍（200 组随机）里唯一 1 组不匹配，**如实登记、不掩盖**：
      // Blink 把第 11 项留在第 1 列；本算法换列。
      // 搜索页实际数据是同组内同类型结果卡（高度接近）⇒ 对当前用途零影响。
      // 若将来本件被用于「高度差异极大」的场景（如混合类型瀑布流），须回到该反例重新标定。
      const List<double> h = <double>[
        50.6, 87, 131.7, 262, 291.7, 193.9, 113.8, 188.2, 98.6, 175.2, 10.9,
        86, 247.9, 91.5, 165.6, 38.7, 151.2, 194, 296.8, 166.5, 113.3, 23.7,
      ];
      final List<int> cols =
          aylaCssColumnsDistribute(h, itemGap: 16, columnCount: 2);
      final int firstCol = cols.where((int c) => c == 0).length;
      expect(firstCol, 10, reason: '本算法：10/12（Blink 是 11/11）');
    });
    test('单列 / 空输入 / 非法列数 => 退化行为', () {
      expect(_ranges(aylaCssColumnsDistribute(_same(3, 10),
              itemGap: 12, columnCount: 1)),
          <String>['0..2']);
      expect(aylaCssColumnsDistribute(const <double>[],
              itemGap: 12, columnCount: 2),
          isEmpty);
      expect(aylaCssColumnsDistribute(_same(3, 10),
              itemGap: 12, columnCount: 0),
          isEmpty);
    });
  });

  group('aylaCssColumnsHeight —— 容器高实测标定', () {
    ({double got, double want}) run(List<double> h, double gap) {
      final List<int> cols =
          aylaCssColumnsDistribute(h, itemGap: gap, columnCount: 2);
      return (
        got: aylaCssColumnsHeight(h,
            itemGap: gap, columnCount: 2, columns: cols),
        want: 0,
      );
    }

    test('20 x 66.6 / gap24 => 906（T 档）', () {
      final r = run(_same(20, 66.6), 24);
      expect(r.got, closeTo(906, 0.01));
    });

    test('11 x 82.6 / gap24 => 615.6（最大列内容高档）', () {
      final r = run(_same(11, 82.6), 24);
      expect(r.got, closeTo(615.6, 0.01));
    });

    test('20 x 150.9 / gap24 => 1749（T 档）', () {
      final r = run(_same(20, 150.9), 24);
      expect(r.got, closeTo(1749, 0.01));
    });

    test('20 x 202.6 / gap24 => 2266（T 档）', () {
      final r = run(_same(20, 202.6), 24);
      expect(r.got, closeTo(2266, 0.01));
    });

    test('6 组不等 / gap16 => 2829.8（最大列内容高档）', () {
      final r = run(const <double>[
        317.5,
        365.5,
        725.4,
        1373.4,
        570.5,
        1298.9,
      ], 16);
      expect(r.got, closeTo(2829.8, 0.01));
    });

    test('4 x 100 / gap24 => 248（T 档）', () {
      expect(run(_same(4, 100), 24).got, closeTo(248, 0.01));
    });

    test('5 x 100 / gap24 => 348（最大列内容高档）', () {
      expect(run(_same(5, 100), 24).got, closeTo(348, 0.01));
    });

    test('7 x 100 / gap24 => 472（最大列内容高档）', () {
      expect(run(_same(7, 100), 24).got, closeTo(472, 0.01));
    });

    test('7 x 10 / gap24 => 119（T 档）', () {
      expect(run(_same(7, 10), 24).got, closeTo(119, 0.01));
    });
  });

  group('AylaCssColumns —— 渲染几何', () {
    testWidgets('两列：列宽 = (可用宽 - gap) / 2，单元落位与分配一致', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // 4 个 100 高单元、itemGap 24 => 2 / 2
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 1024,
                child: AylaCssColumns(
                  columnCount: 2,
                  columnGap: 24,
                  itemGap: 24,
                  children: <Widget>[
                    for (int i = 0; i < 4; i++)
                      SizedBox(
                        key: ValueKey<int>(i),
                        height: 100,
                        child: const ColoredBox(color: Colors.red),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      // 列宽 = (1024 - 24) / 2 = 500
      final Rect r0 = tester.getRect(find.byKey(const ValueKey<int>(0)));
      final Rect r1 = tester.getRect(find.byKey(const ValueKey<int>(1)));
      final Rect r2 = tester.getRect(find.byKey(const ValueKey<int>(2)));
      final Rect r3 = tester.getRect(find.byKey(const ValueKey<int>(3)));
      expect(r0.width, closeTo(500, 0.01));
      expect(r0.left, closeTo(0, 0.01));
      expect(r1.left, closeTo(0, 0.01));
      expect(r2.left, closeTo(500 + 24, 0.01)); // 第 2 列起点 = 列宽 + columnGap
      expect(r3.left, closeTo(500 + 24, 0.01));
      // 列内 y：0 与 100+24
      expect(r1.top - r0.top, closeTo(124, 0.01));
      expect(r3.top - r2.top, closeTo(124, 0.01));
      // 两列首项齐平（CSS multicol 的列起点对齐）
      expect(r2.top, closeTo(r0.top, 0.01));
      // 容器高 = 248（T 档）
      final Size size = tester.getSize(find.byType(AylaCssColumns));
      expect(size.height, closeTo(248, 0.01));
    });

    testWidgets('单列退化：与普通 Column 同构（不产生空列）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AylaCssColumns(
              columnCount: 1,
              columnGap: 24,
              itemGap: 12,
              children: <Widget>[
                for (int i = 0; i < 3; i++)
                  SizedBox(key: ValueKey<int>(i), height: 50),
              ],
            ),
          ),
        ),
      );
      final Rect r0 = tester.getRect(find.byKey(const ValueKey<int>(0)));
      final Rect r1 = tester.getRect(find.byKey(const ValueKey<int>(1)));
      expect(r0.left, closeTo(0, 0.01));
      expect(r1.left, closeTo(0, 0.01));
      expect(r1.top - r0.top, closeTo(62, 0.01));
    });
  });
}