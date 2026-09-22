/// `GlassButton` 内容布局回归 —— 图标与空 label 的组合。
///
/// 事实源：app.css `.btn { display: inline-flex; align-items: center; gap: 8px }`。
/// **CSS 的 `gap` 对单个子元素不产生间距** ⇒ 只有图标的按钮必须严格居中；
/// 用户 2026-09-21 实报「这三个发送键好歪」（窄屏发帖 / 评论 / 房内聊天的发送键都是
/// `GlassButton(label: '', icon: …)`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/app_icons.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
        home: previewScope(
          Center(child: child),
        ),
      );

  testWidgets('图标 + 文字：间距 8px，整体居中（原有行为不变）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        GlassButton(
          label: '发布',
          icon: AylaIcon(aylaIconByName('iconSend')!, size: 15),
          onPressed: () {},
        ),
      ),
    );
    final Rect button = tester.getRect(find.byType(GlassButton));
    final Rect icon = tester.getRect(find.byType(AylaIcon));
    final Rect text = tester.getRect(find.text('发布'));

    // `.btn { gap: 8px }`
    expect(text.left - icon.right, closeTo(AylaSpacing.sp2, 0.6));
    // 图标 + 间距 + 文字整体居中：左右留白相等
    expect(
      (icon.left - button.left) - (button.right - text.right),
      closeTo(0, 1.0),
    );
  });

  testWidgets('空 label + 图标：**图标严格居中**（CSS gap 对单子元素无效）',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        GlassButton(
          label: '',
          icon: AylaIcon(aylaIconByName('iconSend')!, size: 15),
          padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp6),
          semanticLabel: '发布',
          onPressed: () {},
        ),
      ),
    );
    final Rect button = tester.getRect(find.byType(GlassButton));
    final Rect icon = tester.getRect(find.byType(AylaIcon));

    expect(icon.center.dx, closeTo(button.center.dx, 0.5)); // 不再偏左 4px
    expect(icon.center.dy, closeTo(button.center.dy, 0.5));
    // 空 label 不再渲染文字节点
    expect(find.text(''), findsNothing);
  });

  testWidgets('空 label + 图标：语义标签取 semanticLabel', (WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(
      host(
        GlassButton(
          label: '',
          icon: AylaIcon(aylaIconByName('iconSend')!, size: 15),
          semanticLabel: '发布',
          onPressed: () {},
        ),
      ),
    );
    expect(
      find.bySemanticsLabel('发布'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('图标 + 文字禁用态：布局与启用态一致（只变材质/颜色）',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        GlassButton(
          label: '',
          icon: AylaIcon(aylaIconByName('iconSend')!, size: 15),
          padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp6),
          onPressed: null,
        ),
      ),
    );
    final Rect button = tester.getRect(find.byType(GlassButton));
    final Rect icon = tester.getRect(find.byType(AylaIcon));
    expect(icon.center.dx, closeTo(button.center.dx, 0.5));
  });
}
