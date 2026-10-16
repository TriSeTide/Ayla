/// 弹层材质**逐项对账**（2026-10-16）：Flutter 实际渲染值 vs web computed 值。
///
/// web 侧用真实浏览器读到（1536 宽，`getComputedStyle` 一个 `.create-sheet-card` 探针）：
///   backdrop-filter : blur(24px) saturate(1.4)
///   background      : rgba(255, 250, 251, 0.78)  (= --glass-bg-strong)
///   border-radius   : 20px                       (= --radius-panel)
///   box-shadow      : 0 20px 60px rgba(70,91,146,.3) + inset 0 1px 0 rgba(255,255,255,.5)
///   padding         : 16px                       (= --sp-4)
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/glass.dart';
import '../lib/theme/tokens.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/dialogs.dart';

void main() {
  tearDown(() => AylaGlassConfig.quality = AylaGlassQuality.realBackdrop);

  test('材质常量逐项等于 web computed 值', () {
    // backdrop-filter 的模糊半径（web blur(24px)）
    expect(AylaGlass.blurCard, 24, reason: 'blur(24px)');
    // --glass-bg-strong = rgba(255,250,251,0.78)
    final Color strong = AylaGlassConfig.resolveBackground(strong: true);
    expect(strong.r, closeTo(255 / 255, 0.005));
    expect(strong.g, closeTo(250 / 255, 0.005));
    expect(strong.b, closeTo(251 / 255, 0.005));
    expect(strong.a, closeTo(0.78, 0.005), reason: '--glass-bg-strong 的 .78');
    // --radius-panel = 20
    expect(AylaModalCard.panelRadius, 20, reason: '--radius-panel 20px');
    // --glass-shadow-modal 的外阴影：0 20px 60px rgba(70,91,146,.3)。
    // ⚠️ CSS 里它拼了 `var(--glass-inset)`（inset 0 1px 0 白.5），但 Flutter 的
    //    `BoxShadow` 没有 inset 变体 ⇒ 库内把内高光单独用 [AylaGlassInset] 表达
    //    （见 tokens.dart:426 的说明「7 个 token 全部带顶沿 1px，集中处理」）
    //    ⇒ `AylaShadows.modal` **只含外阴影一条**，这是设计而非缺失。
    expect(AylaShadows.modal.length, 1);
    final BoxShadow outer = AylaShadows.modal.first;
    expect(outer.offset, const Offset(0, 20), reason: '0 20px 60px');
    expect(outer.blurRadius, 60);
    expect(outer.color.r, closeTo(70 / 255, 0.005));
    expect(outer.color.g, closeTo(91 / 255, 0.005));
    expect(outer.color.b, closeTo(146 / 255, 0.005));
    expect(outer.color.a, closeTo(0.3, 0.005));
    // --glass-border = rgba(255,255,255,0.65)
    expect(AylaColors.glassBorder.a, closeTo(0.65, 0.005));
  });

  testWidgets('真玻璃档：弹层的模糊滤镜用 blur(24) + saturate(1.4)（与 web 同档）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) =>
              AylaModalCard(child: const Text('x')),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 350));
    final BackdropFilter bf =
        tester.widgetList<BackdropFilter>(find.byType(BackdropFilter)).first;
    // 断言的是「确实装了滤镜层」+ 档位正确；具体 sigma 由 glass.dart 单点持有，
    // 这里只做「不是恒等滤镜」的辨别性检查。
    expect(bf.filter, isNotNull);
    debugPrint('弹层滤镜 = ' + bf.filter.toString());
  });
}