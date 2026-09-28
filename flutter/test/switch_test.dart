/// 通用开关 `AylaSwitch` 定向测试 —— 对照 group.css 1924–1993（compact 群档）+
/// profile.css 400–434（regular 个人档）+ base.css 6–7（`* { box-sizing: border-box }`）。
///
/// 本轮修的是**用户当场点名的 bug**：个人档 knob 没有上下居中在滑轨上。
/// 根因：CSS 绝对定位子级的包含块是 **padding box**（1px 边框内侧）⇒ `top: 3px` 实际距外框 4px；
/// 旧实现把 3 当作外框坐标 ⇒ knob 中心 13 ≠ 轨道中心 14。
/// 本文件用「knob 中心 vs 轨道中心」断言锁死（1px 容差 + 实测差 0）。
///
/// ⚠️ 一态一用例（同用例二次 pumpWidget 换 props 不生效）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/switch.dart';

void main() {
  Widget host(Widget child, {double width = 420}) => MaterialApp(
    home: previewScope(
      Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: Size(width, 1200)),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    ),
  );

  Rect trackRect(WidgetTester tester) =>
      tester.getRect(find.byKey(kAylaSwitchTrackKey));

  Rect knobRect(WidgetTester tester) =>
      tester.getRect(find.byKey(kAylaSwitchKnobKey));

  // ===================== 量纲与居中（本轮核心） =====================

  group('AylaSwitch · 几何', () {
    testWidgets('compact 群档：轨道 44×24 · thumb 18×18 · knob 垂直居中在轨道上', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(AylaSwitch(value: false, onChanged: (bool v) {})),
      );
      final Rect track = trackRect(tester);
      final Rect knob = knobRect(tester);
      expect(track.width, 44);
      expect(track.height, 24);
      expect(knob.width, 18);
      expect(knob.height, 18);

      // 用户要求的口径：量 knob 中心 vs 轨道中心，1px 容差
      final double delta = knob.center.dy - track.center.dy;
      expect(
        delta.abs(),
        lessThanOrEqualTo(1.0),
        reason: 'knob 中心必须落在轨道中线 1px 内（实测差 $delta）',
      );
      expect(delta, 0.0, reason: 'compact 容器无边框 ⇒ 实测差 0（top 3 + 9 = 12 = 24/2）');

      // off 档：左间隙 3（.thumb { left: 3px }），右间隙 = 44 − (3 + 18) = 23
      expect(knob.left - track.left, 3);
      expect(track.right - knob.right, 23);
    });

    testWidgets('compact 群档 on：translateX(20) ⇒ left 3→23 · 右间隙同为 3（对称）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(AylaSwitch(value: true, onChanged: (bool v) {})),
      );
      await tester.pump(const Duration(milliseconds: 200)); // 180ms 位移动画走完
      final Rect track = trackRect(tester);
      final Rect knob = knobRect(tester);
      expect(knob.left - track.left, 23);
      expect(track.right - knob.right, 3);
      expect(knob.center.dy - track.center.dy, 0.0);
    });

    testWidgets('regular 个人档：轨道 48×28 · knob 20×20 · **knob 垂直居中**（1px 边框补偿）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaSwitch(
            value: false,
            variant: AylaSwitchVariant.regular,
            onChanged: (bool v) {},
          ),
        ),
      );
      final Rect track = trackRect(tester);
      final Rect knob = knobRect(tester);
      expect(track.width, 48);
      expect(track.height, 28);
      expect(knob.width, 20);
      expect(knob.height, 20);

      final double delta = knob.center.dy - track.center.dy;
      expect(
        delta.abs(),
        lessThanOrEqualTo(1.0),
        reason: 'knob 中心必须落在轨道中线 1px 内（实测差 $delta）',
      );
      expect(
        delta,
        0.0,
        reason:
            '实测差 0：CSS top 3 相对 padding box ⇒ 距外框 4，中心 4+10 = 14 = 28/2；'
            '旧实现按外框 3 ⇒ 中心 13（偏上 1px，本轮修）',
      );

      // off 档：左间隙 4（CSS left 3 + 1px 边框 ⇒ 距外框 4），右间隙 = 48 − (4 + 20) = 24
      expect(knob.left - track.left, 4);
      expect(track.right - knob.right, 24);
    });

    testWidgets('regular 个人档 on：left 3 + translateX(20) + 1px ⇒ 24 · 右间隙 4', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaSwitch(
            value: true,
            variant: AylaSwitchVariant.regular,
            onChanged: (bool v) {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      final Rect track = trackRect(tester);
      final Rect knob = knobRect(tester);
      expect(knob.left - track.left, 24);
      expect(track.right - knob.right, 4);
      expect(knob.center.dy - track.center.dy, 0.0);

      // 选中辉光：**不降 30%**（宿主宽 420 ⇒ 窄屏档）。web 的 ≤768 降档只在
      // app.css 3195–3199（.btn-glow / .avatar-halo.is-elysia / .elysia-entry:hover），
      // .profile-switch.is-on 恒为 tokens.css:73 的 --glow-shadow = 16px/.45。
      final BoxDecoration decor =
          tester
                  .widget<AnimatedContainer>(
                    find.descendant(
                      of: find.byType(AylaSwitch),
                      matching: find.byType(AnimatedContainer),
                    ).first,
                  )
                  .decoration!
              as BoxDecoration;
      expect(decor.boxShadow, AylaShadows.glow);
    });

    test('两档度量常量与 web 对照（含 1px 边框补偿）', () {
      // compact：group.css 1933–1993
      expect(AylaSwitchMetrics.compact.trackWidth, 44);
      expect(AylaSwitchMetrics.compact.trackHeight, 24);
      expect(AylaSwitchMetrics.compact.thumbSize, 18);
      expect(AylaSwitchMetrics.compact.knobTop, 3); // 无边框 ⇒ 不补偿
      expect(AylaSwitchMetrics.compact.knobLeft, 3);
      expect(AylaSwitchMetrics.compact.knobOnLeft, 23); // 3 + 20
      expect(AylaSwitchMetrics.compact.disabledOpacity, 0.6);
      expect(AylaSwitchMetrics.compact.borderWidth, 0);
      expect(AylaSwitchMetrics.compact.usesInsetHighlight, isTrue); // --glass-inset
      expect(AylaSwitchMetrics.compact.usesGlow, isFalse);

      // regular：profile.css 400–434（CSS 3 + 1px 边框 = 4）
      expect(AylaSwitchMetrics.regular.trackWidth, 48);
      expect(AylaSwitchMetrics.regular.trackHeight, 28);
      expect(AylaSwitchMetrics.regular.thumbSize, 20);
      expect(AylaSwitchMetrics.regular.knobTop, 4);
      expect(AylaSwitchMetrics.regular.knobLeft, 4);
      expect(AylaSwitchMetrics.regular.knobOnLeft, 24); // 4 + 20
      expect(AylaSwitchMetrics.regular.disabledOpacity, 0.55);
      expect(AylaSwitchMetrics.regular.borderWidth, 1);
      expect(AylaSwitchMetrics.regular.usesInsetHighlight, isFalse);
      expect(AylaSwitchMetrics.regular.usesGlow, isTrue); // --glow-shadow
    });
  });

  // ===================== 点击语义 =====================

  group('AylaSwitch · 点击语义', () {
    testWidgets('ownTap: true ⇒ 点控件切换一次', (WidgetTester tester) async {
      int calls = 0;
      bool value = false;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) => AylaSwitch(
              value: value,
              onChanged: (bool v) => setState(() {
                calls++;
                value = v;
              }),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(kAylaSwitchTrackKey));
      await tester.pump();
      expect(calls, 1);
    });

    testWidgets('ownTap: false ⇒ 本体不挂手势，行手势点控件只触发一次（不双触发）', (
      WidgetTester tester,
    ) async {
      int calls = 0;
      bool value = true;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() {
                calls++;
                value = !value;
              }),
              child: Row(
                children: <Widget>[
                  const Expanded(child: Text('成员可上传表情包')),
                  AylaSwitch(
                    value: value,
                    ownTap: false,
                    onChanged: (bool v) => setState(() {
                      calls++;
                      value = v;
                    }),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      // 点控件本体：只有行手势接得住 ⇒ 恰好一次（旧实现会行 + 控件各一次 ⇒ 净效果翻回原位）
      await tester.tap(find.byKey(kAylaSwitchTrackKey));
      await tester.pump();
      expect(calls, 1);
      expect(value, isFalse);
    });
  });

  // ===================== 禁用 / focus / 键盘 / 语义 =====================

  group('AylaSwitch · 状态档', () {
    testWidgets('compact 禁用：整轨 opacity .6 + 点击无回调', (WidgetTester tester) async {
      int calls = 0;
      await tester.pumpWidget(
        host(AylaSwitch(value: false, onChanged: null)),
      );
      final Opacity dim = tester.widget<Opacity>(
        find.descendant(
          of: find.byType(AylaSwitch),
          matching: find.byType(Opacity),
        ),
      );
      expect(dim.opacity, 0.6); // :disabled opacity .6
      await tester.tap(find.byKey(kAylaSwitchTrackKey));
      await tester.pump();
      expect(calls, 0);
    });

    testWidgets('regular 禁用：整轨 opacity .55', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaSwitch(
            value: true,
            variant: AylaSwitchVariant.regular,
            onChanged: null,
          ),
        ),
      );
      final Opacity dim = tester.widget<Opacity>(
        find.descendant(
          of: find.byType(AylaSwitch),
          matching: find.byType(Opacity),
        ),
      );
      expect(dim.opacity, 0.55); // base.css button:disabled 兜底
    });

    testWidgets('focus 环：聚焦后出现环锚点且不吃指针（IgnorePointer）', (
      WidgetTester tester,
    ) async {
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        host(
          AylaSwitch(
            value: false,
            focusNode: node,
            onChanged: (bool v) {},
          ),
        ),
      );
      expect(find.byKey(kAylaSwitchFocusRingKey), findsNothing);
      node.requestFocus();
      await tester.pump();
      expect(find.byKey(kAylaSwitchFocusRingKey), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(kAylaSwitchFocusRingKey),
          matching: find.byType(IgnorePointer),
        ),
        findsOneWidget,
      );
    });

    testWidgets('键盘 Enter / Space 各切换一次', (WidgetTester tester) async {
      int calls = 0;
      bool value = false;
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) => AylaSwitch(
              value: value,
              focusNode: node,
              onChanged: (bool v) => setState(() {
                calls++;
                value = v;
              }),
            ),
          ),
        ),
      );
      node.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(calls, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(calls, 2);
    });

    testWidgets('语义：toggled 随值变化 + label 可读', (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(
          AylaSwitch(
            value: true,
            semanticLabel: '成员可上传表情包',
            onChanged: (bool v) {},
          ),
        ),
      );
      final SemanticsNode node = tester.getSemantics(
        find.byKey(kAylaSwitchTrackKey),
      );
      expect(node.flagsCollection.isToggled.toBoolOrNull(), isTrue);
      expect(node.label, '成员可上传表情包');
      handle.dispose();
    });
  });
}
