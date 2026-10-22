/// `AylaFitContent` / `AylaInlineSize` / `AylaInlineNaturalSize` 的语义回归锁
/// （`widgets/base/fit_content.dart`，2026-10-22 二轮）。
///
/// ## 背景
/// 真机实报「语音气泡撑满整行」的根因是：CSS 的 fit-content 分**两趟**算
/// （先 intrinsic 求 max-content，再被祖先 max-width 夹住），而 Flutter 只有一趟
/// —— `Align(widthFactor:1)` 拿到的是**已被夹过的**约束，内部 `Row/Expanded`
/// 会把那个上限当成内容宽。这三个原语把两趟语义显式补上。
///
/// 本文件锁语义本身（不涉及消息气泡的接线，那部分在
/// `bubble_media_width_test.dart`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/widgets/base/fit_content.dart';

/// 在**松约束**的给定宽度里放一个控件，返回它的实际宽。
///
/// ⚠️ 必须走 `SizedBox → Align` —— `Align` 会把 tight 约束 loosen 掉
/// （`RenderPositionedBox` 的 `_constraintsForChild` = `constraints.loosen()`），
/// 这才是真实消息链给 `AylaFitContent` 的形态（`Column → ClipRRect → Padding`
/// 一路都是松约束）。直接用 `SizedBox(width:)` 会下发 **tight** 宽，
/// 被测件永远只能取那个值，测不出 fit-content 语义。
Future<double> _widthOf(
  WidgetTester tester,
  Widget child, {
  required double available,
  double height = 200,
}) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: available,
          height: height,
          child: Align(alignment: Alignment.topLeft, child: child),
        ),
      ),
    ),
  );
  await tester.pump();
  return tester.getSize(find.byType(AylaFitContent).first).width;
}

void main() {
  // ================================================================
  // 一、AylaFitContent = CSS width: fit-content
  // ================================================================

  testWidgets('★ 内容窄于可用宽 ⇒ 取内容宽（不拉伸）', (WidgetTester tester) async {
    final double w = await _widthOf(
      tester,
      const AylaFitContent(child: SizedBox(width: 120, height: 40)),
      available: 600,
    );
    expect(w, 120, reason: '★ fit-content：内容 120 < 可用 600 ⇒ 宽 = 120');
  });

  testWidgets('★ 内容宽于可用宽 ⇒ 夹到可用宽', (WidgetTester tester) async {
    final double w = await _widthOf(
      tester,
      const AylaFitContent(child: SizedBox(width: 900, height: 40)),
      available: 600,
    );
    expect(w, 600, reason: '★ fit-content：内容 900 > 可用 600 ⇒ 宽 = 600');
  });

  testWidgets('★ minWidth 压过可用宽：子级按 minWidth 布局，自身被祖先夹回', (
    WidgetTester tester,
  ) async {
    // 这是 375 档语音卡的**真实情形**：`.voice-card{min-width:240}` 而气泡内容盒
    // 只有 204.31 ⇒ 浏览器让卡片保持 240、溢出被 `.bubble-media` 的
    // `overflow:hidden` 裁掉（web 实测：.bubble 214.31 / .voice-card 240）。
    //
    // Flutter 的 `RenderBox.size` **必须**满足父约束（debug 断言），所以本件
    // 自身宽只能夹回 204 —— 但**子级**必须按 240 布局（与 CSS 一致，溢出的
    // 那部分由祖先 `ClipRRect` 裁掉）。两者一起才是 CSS 的完整语义。
    final double w = await _widthOf(
      tester,
      const AylaFitContent(
        minWidth: 240,
        child: SizedBox(width: 100, height: 40),
      ),
      available: 204,
    );
    expect(w, 204, reason: '★ 自身宽被父约束夹回可用宽（Flutter 尺寸契约）');
    expect(
      tester.getSize(find.byType(SizedBox).last).width,
      240,
      reason: '★ 子级必须按 min-width 240 布局（溢出部分由祖先裁剪，等价 CSS）',
    );
  });

  testWidgets('★ maxWidth 夹住内容（.file-card{max-width:320}）', (
    WidgetTester tester,
  ) async {
    final double w = await _widthOf(
      tester,
      const AylaFitContent(
        minWidth: 240,
        maxWidth: 320,
        child: SizedBox(width: 900, height: 40),
      ),
      available: 900,
    );
    expect(w, 320, reason: '★ max-width 320 是自身盒子约束，与可用宽无关');
  });

  testWidgets('★ 先测 max-content 再夹 —— 内部 Row 不得把上限当内容宽', (
    WidgetTester tester,
  ) async {
    // 关键语义：这个 Row 的自然宽是 100（固定子级），可用宽 600。
    // 若实现是「用已有约束布局一次再收缩」（Align(widthFactor:1) 那种），
    // Row 的 MainAxisSize.max 会先撑到 600 ⇒ 结果 600（错）。
    const Widget child = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[SizedBox(width: 100, height: 40)],
    );
    final double w = await _widthOf(
      tester,
      const AylaFitContent(child: child),
      available: 600,
    );
    expect(w, 100,
        reason: '★ 必须无界主轴先量 max-content（100），不能拿可用 600 当内容宽');
  });

  // ================================================================
  // 二、AylaInlineSize = flex:1 的两档语义
  // ================================================================

  testWidgets('★ AylaInlineSize 有界 ⇒ 占满父级给定宽', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 300,
            height: 60,
            child: Align(
              alignment: Alignment.topLeft,
              // ⚠️ 必须经 `Flexible(fit: loose)`：`Row` 给**非弹性**子级的是
              // **无界主轴**约束（`_constraintsForNonFlexChild`），只有弹性子项才拿到
              // 「剩余空间」的 loose 约束。生产代码同样如此包装（见 media_content.dart）。
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: const <Widget>[
                  Flexible(
                    fit: FlexFit.loose,
                    child: AylaInlineSize(
                      minWidth: 144,
                      child: SizedBox(height: 36),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final double w = tester
        .getSize(find.byType(AylaInlineSize).first)
        .width;
    expect(w, 300, reason: '★ 父级有界 ⇒ 宽 = 父级 maxWidth（等价 flex:1 占满）');
  });

  testWidgets('★ AylaInlineSize 无界 ⇒ 取声明的 max-content', (
    WidgetTester tester,
  ) async {
    // 横向滚动视口 = 真正的主轴无界（这就是 AylaCssFlexRow 的测量环境）。
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const <Widget>[
                AylaInlineSize(
                  minWidth: kTestNaturalWidth,
                  child: SizedBox(height: 36),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final double w = tester
        .getSize(find.byType(AylaInlineSize).first)
        .width;
    expect(w, kTestNaturalWidth,
        reason: '★ 无界主轴 ⇒ 宽 = 声明的 max-content（144）');
  });

  // ================================================================
  // 三、AylaInlineNaturalSize = flex:1，无界档取子级自然宽
  // ================================================================

  testWidgets('★ AylaInlineNaturalSize 无界 ⇒ 取子级自然宽', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const <Widget>[
                AylaInlineNaturalSize(
                  child: SizedBox(width: 173.5, height: 20),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(
      tester
          .getSize(find.byType(AylaInlineNaturalSize).first)
          .width,
      173.5,
      reason: '★ 无界主轴 ⇒ 子级自然宽（动态内容，如文件名）',
    );
  });

  testWidgets('★ AylaInlineNaturalSize 有界 ⇒ 占满父级给定宽', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 60,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const <Widget>[
                Flexible(
                  fit: FlexFit.loose,
                  child: AylaInlineNaturalSize(
                    child: SizedBox(width: 100, height: 20),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(
      tester
          .getSize(find.byType(AylaInlineNaturalSize).first)
          .width,
      400,
      reason: '★ 有界 ⇒ 占满（等价 flex:1）',
    );
  });
}

/// 测试里用的自然宽（与 `.voice-wave` 无关，只为断言语义）。
const double kTestNaturalWidth = 144;
