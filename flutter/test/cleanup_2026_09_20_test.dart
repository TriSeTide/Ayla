/// 2026-09-20 组件库清障：公共件定向测试（R7 入场件 / R8 徽标三档 / R6 卡片交互）。
///
/// 为什么单独建文件：这三件是本轮**从私有实现提升为公共件**的部分，
/// 之前只有页面级冒烟覆盖；这里锁死它们的行为契约（尺寸/时序/重播/静态卡）。
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/reveal.dart';
import '../lib/widgets/tab_badge.dart';

void main() {
  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  group('TabBadge（R8 三档合并）', () {
    testWidgets('行内档贴合内容，不被有界宽度拉满', (WidgetTester tester) async {
      // 关键回归：Container(alignment:) 在有界宽度父级下会撑满整行（曾实测拉伸）
      await tester.pumpWidget(
        host(
          Center(
            child: SizedBox(
              width: 400, // 有界宽度
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const <Widget>[
                  TabBadge(
                    count: 7,
                    metrics: TabBadgeMetrics.groupBadge,
                    placement: TabBadgePlacement.inline,
                  ),
                  TabBadge(
                    count: 7,
                    metrics: TabBadgeMetrics.messages,
                    placement: TabBadgePlacement.inline,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final Size group = tester.getSize(find.byType(TabBadge).first);
      final Size messages = tester.getSize(find.byType(TabBadge).last);
      // 单字符：宽度 = minWidth + 2×padding（16+8 / 18+10），远小于 400
      expect(group.width, lessThan(40));
      expect(group.height, 16);
      expect(messages.width, lessThan(45));
      expect(messages.height, 18);
    });

    testWidgets('count<=0 不渲染；>max 显示 max+', (WidgetTester tester) async {
      // ⚠️ positioned 档内部返回 Positioned → 必须由 Stack 承载（放 Column 会触发
      // ParentData 断言）。
      await tester.pumpWidget(
        host(
          Center(
            child: SizedBox(
              width: 80,
              height: 60,
              child: Stack(
                clipBehavior: Clip.none,
                children: const <Widget>[
                  TabBadge(count: 0),
                  TabBadge(count: 150),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('99+'), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });
  });

  group('AylaRevealItem（R7 公共入场件）', () {
    testWidgets('enabled:false 直接显示（不挂动画）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaRevealItem(
            enabled: false,
            child: Text('静态入场'),
          ),
        ),
      );
      await tester.pump();
      // enabled:false → 完全不挂动画层（没有 Opacity 祖先）
      expect(
        find.ancestor(of: find.text('静态入场'), matching: find.byType(Opacity)),
        findsNothing,
      );
      expect(find.text('静态入场'), findsOneWidget);
    });

    testWidgets('delay 生效：延迟前不可见，延迟+时长后到位', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaRevealItem(
            delay: Duration(milliseconds: 100),
            child: Text('延迟入场'),
          ),
        ),
      );
      await tester.pump(); // 首帧：动画未启动
      double opacityOf() => tester
          .widget<Opacity>(
            find
                .ancestor(of: find.text('延迟入场'), matching: find.byType(Opacity))
                .first,
          )
          .opacity;
      expect(opacityOf(), 0.0);
      // tester.pump() 不带时长不推进动画时间 → 必须给时长（本项目踩过两次）
      await tester.pump(const Duration(milliseconds: 120)); // 触发 forward
      await tester.pump(const Duration(milliseconds: 150)); // 300ms 中段
      final double mid = opacityOf();
      expect(mid, greaterThan(0.0));
      expect(mid, lessThan(1.0));
      await tester.pump(const Duration(milliseconds: 300));
      expect(opacityOf(), 1.0);
    });

    testWidgets('scope 的 replayKey 变化触发已入场项重播', (WidgetTester tester) async {
      // ⚠️ 必须让宿主（MaterialApp）保持不变、只换 scope 的 replayKey：
      // 直接 pumpWidget 新的 MaterialApp.home 时路由缓存 page，子树根本不重建
      // （实测：item.build 只跑一次、重播永不触发）。
      int key = 0;
      late StateSetter rebuildHost;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              rebuildHost = setState;
              return AylaRevealScope(
                replayKey: key,
                child: const AylaRevealItem(child: Text('重播')),
              );
            },
          ),
        ),
      );
      double opacityOf() => tester
          .widget<Opacity>(
            find
                .ancestor(of: find.text('重播'), matching: find.byType(Opacity))
                .first,
          )
          .opacity;
      await tester.pump(const Duration(milliseconds: 400));
      expect(opacityOf(), 1.0);
      rebuildHost(() => key = 1); // 刷新 → replayKey 前进
      await tester.pump();
      expect(opacityOf(), 0.0);
      await tester.pump(const Duration(milliseconds: 400));
      expect(opacityOf(), 1.0);
    });

    testWidgets('suppress（滚动恢复）期新项直接显示', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaRevealScope(
            suppress: true,
            child: AylaRevealItem(child: Text('恢复')),
          ),
        ),
      );
      await tester.pump();
      // suppress 期：当帧即为终态（不排延迟、不播入场）
      expect(
        tester
            .widget<Opacity>(
              find
                  .ancestor(
                    of: find.text('恢复'),
                    matching: find.byType(Opacity),
                  )
                  .first,
            )
            .opacity,
        1.0,
      );
    });

    test('staggerDelay = min(i*gap, cap)', () {
      expect(AylaRevealMotion.staggerDelay(0), Duration.zero);
      expect(AylaRevealMotion.staggerDelay(3), const Duration(milliseconds: 150));
      expect(AylaRevealMotion.staggerDelay(10), const Duration(milliseconds: 300));
    });
  });

  group('AylaCardInteraction（R6 公共交互件）', () {
    testWidgets('interactive:false + 无 onTap → 不挂指针层（静态卡）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaCardInteraction(
            interactive: false,
            builder: (BuildContext context, bool hovered) =>
                const Text('静态卡'),
          ),
        ),
      );
      // 只看本组件子树（MaterialApp/框架自身也带 MouseRegion）
      expect(
        find.descendant(
          of: find.byType(AylaCardInteraction),
          matching: find.byType(MouseRegion),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(AylaCardInteraction),
          matching: find.byType(GestureDetector),
        ),
        findsNothing,
      );
    });

    testWidgets('interactive:true → hover 时 builder 收到 hovered=true', (WidgetTester tester) async {
      bool? seen;
      await tester.pumpWidget(
        host(
          Center(
            child: AylaCardInteraction(
              builder: (BuildContext context, bool hovered) {
                seen = hovered;
                return const SizedBox(width: 100, height: 40);
              },
            ),
          ),
        ),
      );
      expect(seen, isFalse);
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byType(AylaCardInteraction)));
      await tester.pump();
      expect(seen, isTrue);
    });
  });

  group('GlassSurface.shadowTransition（R1/R2 能力）', () {
    testWidgets('动画阴影层只画形状之外：切换不抛错且不改变布局尺寸', (WidgetTester tester) async {
      Widget build(List<BoxShadow> shadows) => host(
            Center(
              child: GlassSurface(
                radiusOverride: BorderRadius.circular(AylaRadii.rCard),
                shadow: shadows,
                shadowTransition: AylaDurations.auroraqua,
                padding: const EdgeInsets.all(AylaSpacing.sp4),
                child: const Text('玻璃卡'),
              ),
            ),
          );
      await tester.pumpWidget(build(AylaShadows.glass));
      final Size before = tester.getSize(find.byType(GlassSurface));
      await tester.pumpWidget(build(AylaShadows.glassHover));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.getSize(find.byType(GlassSurface)), before);
      expect(tester.takeException(), isNull);
    });
  });
}
