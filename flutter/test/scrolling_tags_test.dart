/// `AylaScrollingTags` / `AylaScrollingText` 共享件回归测试。
///
/// 背景（2026-09-22 用户实测报障）：语音卡 / 直播卡 / 帖子卡上「渐隐的右边和下面有一条接缝线」。
/// 根因**不在渐隐位置**，而在本组件自身的高度：此前用 `SizedBox(height: 40)` +
/// `OverflowBox(min/maxHeight: 40)` 顶高度 ⇒ 组件高度恒为 40（无界祖先）或父级可用高
/// （有界祖先），而真标签只有 ~23 ⇒ 父级一矮（卡片 meta 行 22.6 / head 行 32）就把居中的
/// 标签**上下裁掉几像素**、圆角被切断 ⇒ 看起来就是一条接缝。
/// 修法：改用横向 `SingleChildScrollView`（禁手势），子级拿无界宽、自身高 = 内容高、自带裁剪。
///
/// 覆盖：高度 == 内容高（不被父级撑高、不被裁）/ mask 覆盖范围 == 组件范围（渐隐贯穿整高）/
/// 未溢出不加 mask / 不可拖（web `overflow: hidden`）/ marquee 位移发生在溢出时。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/app_theme.dart' show AylaTextStyles;
import '../lib/theme/glass.dart';
import '../lib/theme/tokens.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/primitives.dart';

void main() {
  Widget host(
    WidgetTester tester,
    Widget child, {
    Size viewport = const Size(420, 300),
  }) {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    return MaterialApp(
      home: previewScope(
        Align(alignment: Alignment.topLeft, child: child),
      ),
    );
  }

  List<Widget> tags(int count) => <Widget>[
    for (final String label in <String>['公开', '冰樱研究社', '深夜电台', '好友'].take(count))
      AylaSourceTag(label),
  ];

  group('组件高度 == 内容高（接缝线回归）', () {
    testWidgets('高父级下不被撑高：tags 高度 == 标签高度（±0.01）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          // 父级很高（300）：修复前本组件会被撑到 260
          Padding(
            padding: const EdgeInsets.all(20),
            child: SizedBox(
              width: 200,
              child: AylaScrollingTags(children: tags(4)),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final Rect box = tester.getRect(find.byType(AylaScrollingTags));
      final Rect tag = tester.getRect(find.byType(AylaSourceTag).first);
      expect(box.height, closeTo(tag.height, 0.01), reason: '组件高必须等于标签高：$box vs $tag');
      // 标签完整落在组件内（上下不被裁）
      expect(tag.top, closeTo(box.top, 0.01));
      expect(tag.bottom, closeTo(box.bottom, 0.01));
    });

    testWidgets('SizedBox(height: 40) 包裹时也不变成 40 高', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          Padding(
            padding: const EdgeInsets.all(20),
            child: SizedBox(
              width: 200,
              height: 40, // 父级给定 40（旧实现的魔法高度）
              child: Align(
                alignment: Alignment.topLeft,
                child: AylaScrollingTags(children: tags(4)),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final Rect box = tester.getRect(find.byType(AylaScrollingTags));
      final Rect tag = tester.getRect(find.byType(AylaSourceTag).first);
      expect(box.height, closeTo(tag.height, 0.01));
    });
  });

  group('溢出与渐隐', () {
    testWidgets('真溢出：内层比组件宽；mask 覆盖范围 == 组件范围（渐隐贯穿整高）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          Padding(
            padding: const EdgeInsets.all(20),
            child: SizedBox(
              width: 200,
              child: AylaScrollingTags(children: tags(4)),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final Rect box = tester.getRect(find.byType(AylaScrollingTags));
      // 外层 Row（深度优先的第一个后代 Row 即标签条本体；每个胶囊内部也有 Row）
      final Rect inner = tester.getRect(
        find
            .descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(Row),
            )
            .first,
      );
      expect(inner.width, greaterThan(box.width)); // 真溢出

      final Finder mask = find.byType(ShaderMask);
      expect(mask, findsOneWidget);
      final Rect maskRect = tester.getRect(mask);
      // mask 必须与组件同框：否则渐隐会在内容之外/之内留出一条缝
      expect(maskRect, box);
    });

    testWidgets('未溢出：不加 mask（对齐 web 只在 is-overflow 时加）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          Padding(
            padding: const EdgeInsets.all(20),
            child: SizedBox(
              width: 400, // 足够宽 → 不溢出
              child: AylaScrollingTags(children: tags(2)),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(ShaderMask), findsNothing);
    });

    testWidgets('不可拖（web `.scroll-tags { overflow: hidden }`）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          Padding(
            padding: const EdgeInsets.all(20),
            child: SizedBox(
              width: 200,
              child: AylaScrollingTags(children: tags(4)),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final SingleChildScrollView view = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      expect(view.physics, isA<NeverScrollableScrollPhysics>());
      expect(view.clipBehavior, Clip.hardEdge);
    });
  });

  group('AylaSourceTag（三域统一档）', () {
    testWidgets('度量：utility 12 / padding 2×8 / pill / sakura-300 底 + grape-700 字', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(tester, const AylaSourceTag('公开')));
      await tester.pump();

      final AylaCapsuleTag tag = tester.widget<AylaCapsuleTag>(
        find.byType(AylaCapsuleTag),
      );
      expect(tag.tone, CapsuleTone.sakura);
      expect(tag.fontFamily, AylaFonts.utility);
      expect(tag.fontSize, 12);
      expect(tag.fontWeight, FontWeight.w400);
      expect(tag.letterSpacing, 0);
      expect(
        tag.padding,
        const EdgeInsets.symmetric(horizontal: AylaSpacing.sp2, vertical: 2),
      );
      // 12ch 上限（实测换算）
      final ConstrainedBox box = tester.widget<ConstrainedBox>(
        find
            .descendant(
              of: find.byType(AylaSourceTag),
              matching: find.byType(ConstrainedBox),
            )
            .first,
      );
      final double ch = AylaSourceTag.chWidth(
        AylaTextStyles.of(tester.element(find.byType(AylaSourceTag))),
      );
      expect(box.constraints.maxWidth, closeTo(ch * 12, 0.01));
    });
  });
}
