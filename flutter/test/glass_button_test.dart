/// `AylaGlassButton` 内容布局回归 —— 图标与空 label 的组合。
///
/// 事实源：app.css `.btn { display: inline-flex; align-items: center; gap: 8px }`。
/// **CSS 的 `gap` 对单个子元素不产生间距** ⇒ 只有图标的按钮必须严格居中；
/// 用户 2026-09-21 实报「这三个发送键好歪」（窄屏发帖 / 评论 / 房内聊天的发送键都是
/// `AylaGlassButton(label: '', icon: …)`）。
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
        AylaGlassButton(
          label: '发布',
          icon: AylaIcon(aylaIconByName('iconSend')!, size: 15),
          onPressed: () {},
        ),
      ),
    );
    final Rect button = tester.getRect(find.byType(AylaGlassButton));
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
        AylaGlassButton(
          label: '',
          icon: AylaIcon(aylaIconByName('iconSend')!, size: 15),
          padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp6),
          semanticLabel: '发布',
          onPressed: () {},
        ),
      ),
    );
    final Rect button = tester.getRect(find.byType(AylaGlassButton));
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
        AylaGlassButton(
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
        AylaGlassButton(
          label: '',
          icon: AylaIcon(aylaIconByName('iconSend')!, size: 15),
          padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp6),
          onPressed: null,
        ),
      ),
    );
    final Rect button = tester.getRect(find.byType(AylaGlassButton));
    final Rect icon = tester.getRect(find.byType(AylaIcon));
    expect(icon.center.dx, closeTo(button.center.dx, 0.5));
  });

  // ---- 有界松高宿主（2026-09-28 修） ----
  //
  // 事实源：app.css `.btn { min-height: 40px; padding: 0 24px }` —— `.btn` 的高
  // 恒为「内容高 + min-height」，web 里没有任何拉伸语义（`.btn` 不在任何
  // `align-items: stretch` 的 flex 项清单里）。
  // 反证（修复前）：`Center(widthFactor: 1)` 缺 `heightFactor` ⇒ Center 在交叉轴
  // **取满 maxHeight** ⇒ 800×600 测试表面里按钮高就是 600（实测 600×106.8）。
  testWidgets('有界松高宿主：按钮保持内容高 40（不撑满宿主）',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      host(AylaGlassButton(label: '登录', onPressed: () {})),
    );
    // host 的 Center 给按钮 loose 约束 (0..800, 0..600)：修复前高度读到 600
    expect(
      tester.getSize(find.byType(AylaGlassButton)).height,
      closeTo(40, 0.5),
    );
  });

  testWidgets('紧高宿主（flex stretch 等价）：仍按宿主高拉伸',
      (WidgetTester tester) async {
    // 保证修复没有把「父级紧约束高度 ⇒ 按钮跟着拉伸」这条语义一起改掉：
    // 渐变宽高比的高度基准只在**非紧约束**时才回落 minHeight。
    await tester.pumpWidget(
      host(
        SizedBox(
          height: 120,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              AylaGlassButton(label: '拉伸', onPressed: () {}),
            ],
          ),
        ),
      ),
    );
    expect(
      tester.getSize(find.byType(AylaGlassButton)).height,
      closeTo(120, 0.5),
    );
  });
}
