/// 全局图标色回归（`--text-primary` 兜底）—— 防止 `Theme` 注入的黑色 `iconTheme` 复活。
///
/// 背景（2026-09-20 用户实测「分享图标都是纯黑，违反 design」）：
/// SDK 的 `ThemeData` 在缺省时 `iconTheme ??= IconThemeData(color: kDefaultIconDarkColor)`
/// （= `Color(0xDD000000)`，theme_data.dart:526），`Theme` 再把它注入整棵树（theme.dart:147）；
/// `AylaIcon` 的解析顺序是「显式 color → 祖先 IconTheme → textPrimary」（app_icons.dart:77–79），
/// 于是未显式传色的图标全部取到黑色，`textPrimary` 永远轮不到。
/// 修法 = `buildAylaTheme()` 显式设置 `iconTheme`（web：SVG 用 currentColor 继承 --text-primary）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/app_icons.dart';
import '../lib/theme/app_theme.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/share.dart';

void main() {
  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  testWidgets('主题必须显式设置 iconTheme（不能是 SDK 的黑色兜底）',
      (WidgetTester tester) async {
    final ThemeData theme = buildAylaTheme();
    expect(
      theme.iconTheme.color,
      AylaColors.textPrimary,
      reason: '缺省时 SDK 会注入 Color(0xDD000000)，未传色的 AylaIcon 会全部变黑',
    );
    // 顺带守住：绝不能是黑色系（任何 alpha）
    expect(theme.iconTheme.color!.a, greaterThan(0.99), reason: '不能是半透明黑');
    expect(
      theme.iconTheme.color,
      isNot(equals(Colors.black)),
      reason: 'kDefaultIconDarkColor 的观感即纯黑',
    );
  });

  testWidgets('分享面板：未显式传色的图标继承 indigo，而非黑色',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        // 分享样张内容较长 → 包滚动视图避免 RenderFlex overflow（与图标色断言无关）
        SizedBox(
          width: 375,
          child: SingleChildScrollView(child: aylaShareSamples()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 面板内每个 AylaIcon 实际解析到的颜色（走 build 里的解析顺序）
    final IconThemeData resolved = IconTheme.of(
      tester.element(find.byType(AylaIcon).first),
    );
    // ignore: avoid_print
    print('SHARE iconColor=${resolved.color}');
    expect(
      resolved.color,
      AylaColors.textPrimary,
      reason: 'web `.share-sheet-row { color: var(--text-primary) }` 的 currentColor 继承',
    );
  });
}
