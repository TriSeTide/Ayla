/// `AylaMsgActionButton` 的 hover 扫光（auroraqua 扫光组：`.msg-action-btn` 明文在列）。
///
/// 事实源：
/// - `styles/auroraqua.css:142–146` —— 扫光组 `:is(.btn, .msg-action-btn,
///   .narrow-topbar-more > .icon-btn-40, .top-nav-more > .top-nav-icon-btn)` 声明
///   `position: relative; overflow: hidden; isolation: isolate`（`::after` 裁在圆角内）；
/// - `auroraqua.css:148–159` —— `::after`：`inset: 0` / `border-radius: inherit` /
///   色带 `linear-gradient(90deg, transparent, var(--glass-border), transparent)` /
///   `opacity: .5` / `transform: translateX(-120%)` / `transition: transform 600ms`；
/// - `auroraqua.css:161–166` —— `@media (hover: hover) and (pointer: fine)` 下
///   `:not(:disabled):hover::after { transform: translateX(120%) }`；
/// - `auroraqua.css:675–677` —— `@media (prefers-reduced-motion: reduce)` 时
///   `::after { display: none }`（**不渲染**）。
///
/// ⚠️ 每个用例**只 pumpWidget 一次**：`previewScope` 内部是 `Overlay` + 持久
/// `OverlayEntry`，换根 widget 不会重建 entry 子树（实测第二次 pumpWidget 仍拿到旧按钮）。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/buttons.dart' show AylaMsgActionButton;
import '../lib/theme/preview_theme.dart';

void main() {
  /// 扫光带位置：`-1.2`（起点，translateX(-120%)）→ `+1.2`（终点，translateX(120%)）。
  ///
  /// `AylaMsgActionButton` 子树里只有扫光用 `FractionalTranslation`
  /// （`AylaPressScale` 走 `AnimatedScale`）⇒ 该 Finder 唯一。
  double? sweepDx(WidgetTester tester) {
    final Finder f = find.descendant(
      of: find.byType(AylaMsgActionButton),
      matching: find.byType(FractionalTranslation),
    );
    if (f.evaluate().isEmpty) return null;
    return tester.widget<FractionalTranslation>(f).translation.dx;
  }

  Widget host(Widget child, {bool reduceMotion = false}) => MaterialApp(
        home: previewScope(
          MediaQuery(
            data: MediaQueryData(
              size: const Size(420, 320),
              disableAnimations: reduceMotion,
            ),
            child: Center(child: child),
          ),
        ),
      );

  testWidgets('默认带扫光：hover → 600ms 走到 translateX(120%)，移出反向扫回', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(AylaMsgActionButton(label: '引用', onPressed: () {})),
    );
    await tester.pumpAndSettle();

    expect(sweepDx(tester), isNotNull, reason: '默认 sweep = true ⇒ 扫光层存在');
    expect(sweepDx(tester), closeTo(-1.2, 0.001), reason: '静止在 translateX(-120%)');

    final TestGesture gesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(5, 5));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(AylaMsgActionButton)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final double mid = sweepDx(tester)!;
    expect(mid, greaterThan(-1.2));
    expect(mid, lessThan(1.2), reason: '600ms 过渡的中间帧（不是瞬跳）');
    await tester.pump(const Duration(milliseconds: 400));
    expect(sweepDx(tester), closeTo(1.2, 0.001), reason: 'hover 终态 translateX(120%)');

    // 移出：`onExit` → `_sweep.reverse()`（web 的 transition 双向）
    await gesture.removePointer();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(sweepDx(tester), closeTo(-1.2, 0.001), reason: '移出反向扫回起点');
  });

  testWidgets('sweep: false → 不渲染扫光层', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(AylaMsgActionButton(label: '引用', sweep: false, onPressed: () {})),
    );
    await tester.pumpAndSettle();
    expect(sweepDx(tester), isNull);
  });

  testWidgets('禁用态（onPressed == null）：扫光不推进（auroraqua.css:162 的 :not(:disabled)）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(const AylaMsgActionButton(label: '引用')));
    await tester.pumpAndSettle();
    expect(sweepDx(tester), closeTo(-1.2, 0.001));
    final TestGesture gesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(5, 5));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(AylaMsgActionButton)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(sweepDx(tester), closeTo(-1.2, 0.001));
    await gesture.removePointer();
  });

  testWidgets('reduced-motion：扫光层不渲染（auroraqua.css:675–677 display:none）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        AylaMsgActionButton(label: '引用', onPressed: () {}),
        reduceMotion: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      sweepDx(tester),
      isNull,
      reason: 'prefers-reduced-motion 下 .msg-action-btn::after 直接 display:none',
    );
  });
}
