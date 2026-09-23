/// 按钮族「禁用态 = 按颜色降透明」回归（2026-09-22 用户裁决）。
///
/// 背景：`base.css button:disabled { opacity: .55 }` 原先实现为**整层 `Opacity(.55)`**，
/// 而 `GlassButton(ghost)` / `AylaIconButton` / `AylaCornerFab` / `AylaToolButton` 的盒子里含
/// `BackdropFilter` ⇒ Opacity 叠在 BackdropFilter 上被 Impeller 拒绝并刷屏
/// （`SetInheritedOpacity … CanAcceptOpacity returns false`），且禁用态变暗并不生效。
/// ⇒ 改为把 .55 落到颜色上（底/边/阴影 ×.55），内容层单独 Opacity。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/app_icons.dart';
import '../lib/theme/buttons.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
    home: previewScope(
      Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: const Size(400, 300),
          ),
          child: Center(child: child),
        ),
      ),
    ),
  );

  /// 面层（AnimatedContainer 的 BoxDecoration）底色。
  Color faceColor(WidgetTester tester, Finder root) {
    final AnimatedContainer face = tester.widget<AnimatedContainer>(
      find.descendant(of: root, matching: find.byType(AnimatedContainer)).first,
    );
    return (face.decoration! as BoxDecoration).color!;
  }

  testWidgets('GlassButton（ghost）禁用 → 底色 ×.55；BackdropFilter 不被 Opacity 包住', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        const GlassButton(
          label: '开播',
          variant: GlassButtonVariant.ghost, // hover 才用 Opacity? 不：禁用态才是
        ),
      ),
    );
    await tester.pump();

    final Finder button = find.byType(GlassButton);
    final Color dimmed = faceColor(tester, button);
    expect(
      dimmed.a,
      closeTo(AylaColors.glassBg.a * 0.55, 0.01),
      reason: '禁用态 = base.css `opacity: .55` 落到颜色上',
    );
    // 回归点：BackdropFilter 的祖先里**不能**有 Opacity（Impeller 校验拒绝该组合）
    expect(
      find.ancestor(
        of: find.byType(BackdropFilter),
        matching: find.byType(Opacity),
      ),
      findsNothing,
    );
  });

  testWidgets('GlassButton（ghost）可用 → 底色为原值（不受降透明影响）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        GlassButton(
          label: '开播',
          variant: GlassButtonVariant.ghost,
          onPressed: () {},
        ),
      ),
    );
    await tester.pump();
    expect(faceColor(tester, find.byType(GlassButton)).a, AylaColors.glassBg.a);
  });

  testWidgets('AylaIconButton 禁用 → 底色/边 ×.55 且 BackdropFilter 不被 Opacity 包住', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        AylaIconButton(
          icon: AylaIcon(aylaIconByName('iconClose')!, size: 18),
          size: 40,
          semanticLabel: '关闭',
        ),
      ),
    );
    await tester.pump();

    final Finder button = find.byType(AylaIconButton);
    final AnimatedContainer face = tester.widget<AnimatedContainer>(
      find.descendant(of: button, matching: find.byType(AnimatedContainer)).first,
    );
    final BoxDecoration deco = face.decoration! as BoxDecoration;
    expect(deco.color!.a, closeTo(AylaColors.glassBg.a * 0.55, 0.01));
    expect(
      deco.border!.top.color.a,
      closeTo(AylaColors.glassBorder.a * 0.55, 0.01),
    );
    expect(
      find.ancestor(
        of: find.byType(BackdropFilter),
        matching: find.byType(Opacity),
      ),
      findsNothing,
    );
  });

  testWidgets('AylaIconButton 可用 → 底色/边为原值', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        AylaIconButton(
          icon: AylaIcon(aylaIconByName('iconClose')!, size: 18),
          size: 40,
          semanticLabel: '关闭',
          onPressed: () {},
        ),
      ),
    );
    await tester.pump();
    final AnimatedContainer face = tester.widget<AnimatedContainer>(
      find
          .descendant(
            of: find.byType(AylaIconButton),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    final BoxDecoration deco = face.decoration! as BoxDecoration;
    expect(deco.color!.a, AylaColors.glassBg.a);
    expect(deco.border!.top.color.a, AylaColors.glassBorder.a);
  });
}
