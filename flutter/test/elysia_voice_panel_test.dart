/// B1-5：爱莉语音面板定向测试 —— 逐条对照 `ElysiaVoicePanel.tsx`(108) 与
/// `app.css:3122–3156 / 1324–1333 / 1362`。
///
/// ⚠️ web 里该组件**没有挂载点**（只有 hook + vitest），故本测试是行为与样式的唯一回归面。
///
/// 覆盖：收起档（单个 btn-glow + `.collapsed` 的 padding/左对齐）/ 展开 head（**center** 而非
/// baseline + 16/700 + `.msg-action-btn`「收起」）/ 未接入两态 / 输入行（placeholder、2000 上限
/// 且无计数器、Enter 提交）/ 行动区两态（结束通话 = outlineDestructive、重新发起 = primary）/
/// busy 三按钮禁用 / 空文本不受理则**不清空** / 受理后清空 / 面板宽 560。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter;
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/buttons.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/elysia_voice_panel.dart';

void main() {
  Widget host(Widget child, {Size viewport = const Size(700, 520)}) {
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: SizedBox.fromSize(
              size: viewport,
              // ⚠️ 宽松宽度：竖向滚动视图会给紧宽约束，`max-width: 560` 无从生效
              child: Align(alignment: Alignment.topLeft, child: child),
            ),
          ),
        ),
      ),
    );
  }

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  GlassSurface shell(WidgetTester tester) =>
      tester.widget<GlassSurface>(find.byType(GlassSurface));

  GlassInput input(WidgetTester tester) => tester.widget<GlassInput>(
        find.byWidgetPredicate(
          (Widget w) => w is GlassInput && w.hintText == AylaElysiaVoicePanel.inputHint,
        ),
      );

  Finder nameField() => find.descendant(
        of: find.byWidgetPredicate(
          (Widget w) => w is GlassInput && w.hintText == AylaElysiaVoicePanel.inputHint,
        ),
        matching: find.byType(TextField),
      );

  GlassButton buttonOf(WidgetTester tester, String label) =>
      tester.widget<GlassButton>(
        find.byWidgetPredicate(
          (Widget w) => w is GlassButton && w.label == label,
        ),
      );

  // ======================= 收起档 =======================

  testWidgets('收起档：只有一个 .btn-glow「爱莉语音」+ `.collapsed` 的 padding sp3 与左对齐',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 520));
    await tester.pumpWidget(host(const AylaElysiaVoicePanel()));

    expect(find.text('爱莉语音'), findsOneWidget);
    expect(find.text('收起'), findsNothing); // 收起态没有 head
    expect(buttonOf(tester, '爱莉语音').variant, GlassButtonVariant.glow);

    // `.collapsed { padding: var(--sp-3) }`（展开是 sp4）
    expect(shell(tester).padding, const EdgeInsets.all(AylaSpacing.sp3));
    // `.collapsed { align-items: flex-start }` ⇒ **按钮**贴左（= 面板 padding 12），
    // 不是居中；按钮内部的 24px 左右内边距属 `.btn` 本身，不影响这条断言。
    final double buttonLeft = tester.getRect(find.byType(GlassButton)).left;
    final double shellLeft = tester.getRect(find.byType(GlassSurface)).left;
    expect(buttonLeft - shellLeft, closeTo(AylaSpacing.sp3, 1.0));
  });

  testWidgets('点「爱莉语音」展开：出现 head + 输入行（padding 变 sp4）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 520));
    await tester.pumpWidget(
      host(const AylaElysiaVoicePanel(connected: true)),
    );
    await tester.tap(find.text('爱莉语音'));
    await settle(tester);

    expect(find.text('收起'), findsOneWidget);
    expect(
      shell(tester).padding,
      const EdgeInsets.all(AylaSpacing.sp4), // 展开档 padding: sp4
    );
    expect(find.byType(GlassInput), findsOneWidget);
  });

  // ======================= 展开 head =======================

  testWidgets('head：16/700 标题 + `.msg-action-btn`「收起」；垂直居中（不是 baseline）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 520));
    await tester.pumpWidget(host(const AylaElysiaVoicePanel(connected: true)));
    await tester.tap(find.text('爱莉语音'));
    await settle(tester);

    final Text title = tester.widget<Text>(find.text('爱莉语音'));
    expect(title.style!.fontSize, 16);
    expect(title.style!.fontWeight, FontWeight.w700);

    // `.elysia-voice-head { align-items: center }` ⇒ 标题与按钮**垂直居中**（不是基线）
    final Rect t1 = tester.getRect(find.text('爱莉语音'));
    final Rect b1 = tester.getRect(find.text('收起'));
    expect((t1.center.dy - b1.center.dy).abs(), lessThan(2.0));

    // 「收起」是 `.msg-action-btn` 档
    expect(find.byType(AylaMsgActionButton), findsOneWidget);
  });

  testWidgets('「收起」回到收起档', (WidgetTester tester) async {
    setViewport(tester, const Size(700, 520));
    await tester.pumpWidget(host(const AylaElysiaVoicePanel(connected: true)));
    await tester.tap(find.text('爱莉语音'));
    await settle(tester);
    await tester.tap(find.text('收起'));
    await settle(tester);
    expect(find.text('收起'), findsNothing);
    expect(find.byType(GlassInput), findsNothing);
  });

  // ======================= 未接入态 =======================

  testWidgets('未接入：busy=false → 「等待接入」；busy=true → 「接入中…」', (WidgetTester tester) async {
    setViewport(tester, const Size(700, 520));
    await tester.pumpWidget(host(const AylaElysiaVoicePanel(connected: false)));
    await tester.tap(find.text('爱莉语音'));
    await settle(tester);
    expect(find.text('等待接入'), findsOneWidget);
    // `.voice-list-empty`：13px + secondary + 居中
    final Text empty = tester.widget<Text>(find.text('等待接入'));
    expect(empty.style!.fontSize, 13);
    expect(empty.style!.color, AylaColors.textSecondary);
    expect(find.byType(GlassInput), findsNothing); // 未接入没有输入行
  });

  testWidgets('未接入 + busy：文案「接入中…」', (WidgetTester tester) async {
    setViewport(tester, const Size(700, 520));
    await tester.pumpWidget(
      host(const AylaElysiaVoicePanel(connected: false, busy: true)),
    );
    await tester.tap(find.text('爱莉语音'));
    await settle(tester);
    expect(find.text('接入中…'), findsOneWidget);
  });

  // ======================= 输入行 =======================

  testWidgets('输入行：placeholder + 2000 上限（无计数器）+ Enter 提交 + 发送钮 primary',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 520));
    final List<String> sent = <String>[];
    await tester.pumpWidget(
      host(
        AylaElysiaVoicePanel(
          connected: true,
          onSubmitText: (String text) async {
            sent.add(text);
            return true;
          },
        ),
      ),
    );
    await tester.tap(find.text('爱莉语音'));
    await settle(tester);

    final GlassInput field = input(tester);
    expect(field.hintText, AylaElysiaVoicePanel.inputHint);
    expect(field.minHeight, 36);
    expect(field.textStyle!.fontSize, 13);
    // tsx 66：`maxLength={2000}` —— formatter 表达（`maxLength` 会带「0/2000」计数器）
    expect(field.maxLength, isNull);
    expect(field.inputFormatters!.first, isA<LengthLimitingTextInputFormatter>());
    expect(buttonOf(tester, '发送').variant, GlassButtonVariant.primary);

    // 真输入 2100 字符 → 截到 2000
    await tester.enterText(nameField(), 'x' * 2100);
    await tester.pump();
    expect(
      tester.widget<TextField>(nameField()).controller!.text.length,
      AylaElysiaVoicePanel.textMaxLength,
    );
    expect(find.textContaining('/2000'), findsNothing); // 无计数器

    // Enter 提交
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(sent.length, 1);
  });

  testWidgets('空文本不受理 ⇒ **不清空**输入（tsx 32–35）', (WidgetTester tester) async {
    setViewport(tester, const Size(700, 520));
    await tester.pumpWidget(
      host(
        AylaElysiaVoicePanel(
          connected: true,
          // web `sendText("")` 不受理 ⇒ 返回 false
          onSubmitText: (String text) async => text.trim().isNotEmpty,
        ),
      ),
    );
    await tester.tap(find.text('爱莉语音'));
    await settle(tester);

    await tester.tap(find.text('发送'));
    await settle(tester);
    expect(tester.widget<TextField>(nameField()).controller!.text, '');

    await tester.enterText(nameField(), '你好呀');
    await tester.pump();
    await tester.tap(find.text('发送'));
    await settle(tester);
    expect(
      tester.widget<TextField>(nameField()).controller!.text,
      '', // 受理后才清空
    );
  });

  testWidgets('发送失败（抛错）⇒ 保留输入', (WidgetTester tester) async {
    setViewport(tester, const Size(700, 520));
    await tester.pumpWidget(
      host(
        AylaElysiaVoicePanel(
          connected: true,
          onSubmitText: (String text) async => throw StateError('boom'),
        ),
      ),
    );
    await tester.tap(find.text('爱莉语音'));
    await settle(tester);
    await tester.enterText(nameField(), '你好呀');
    await tester.pump();
    await tester.tap(find.text('发送'));
    await settle(tester);
    expect(tester.widget<TextField>(nameField()).controller!.text, '你好呀');
  });

  // ======================= 行动区 =======================

  testWidgets('行动区：非终态 → 「结束通话」= outlineDestructive，并回调 onEndCall',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 520));
    int ends = 0;
    await tester.pumpWidget(
      host(
        AylaElysiaVoicePanel(
          connected: true,
          onEndCall: () async => ends++,
        ),
      ),
    );
    await tester.tap(find.text('爱莉语音'));
    await settle(tester);

    expect(find.text('结束通话'), findsOneWidget);
    expect(find.text('重新发起'), findsNothing);
    expect(
      buttonOf(tester, '结束通话').variant,
      GlassButtonVariant.outlineDestructive, // `.btn.voice-leave-btn`
    );
    await tester.tap(find.text('结束通话'));
    await settle(tester);
    expect(ends, 1);
  });

  testWidgets('行动区：终态 → 「重新发起」= primary，并回调 onEnsureCall；无输入行',
      (WidgetTester tester) async {
    setViewport(tester, const Size(700, 520));
    int ensures = 0;
    await tester.pumpWidget(
      host(
        AylaElysiaVoicePanel(
          connected: true,
          isTerminal: true,
          onEnsureCall: () async => ensures++,
        ),
      ),
    );
    await tester.tap(find.text('爱莉语音'));
    await settle(tester);

    expect(find.text('重新发起'), findsOneWidget);
    expect(find.text('结束通话'), findsNothing);
    expect(buttonOf(tester, '重新发起').variant, GlassButtonVariant.primary);
    expect(find.byType(GlassInput), findsNothing); // tsx 60：终态不显示输入行
    await tester.tap(find.text('重新发起'));
    await settle(tester);
    expect(ensures, 1);
  });

  testWidgets('busy：发送 / 结束通话一起禁用（tsx 75/97）', (WidgetTester tester) async {
    setViewport(tester, const Size(700, 520));
    await tester.pumpWidget(
      host(const AylaElysiaVoicePanel(connected: true, busy: true)),
    );
    await tester.tap(find.text('爱莉语音'));
    await settle(tester);
    expect(buttonOf(tester, '发送').onPressed, isNull);
    expect(buttonOf(tester, '结束通话').onPressed, isNull);
  });

  // ⚠️ 多状态一律拆用例：`previewScope` 的 `Overlay(initialEntries:)` 只在首次创建生效
  testWidgets('busy：终态下「重新发起」也禁用（tsx 88）', (WidgetTester tester) async {
    setViewport(tester, const Size(700, 520));
    await tester.pumpWidget(
      host(
        const AylaElysiaVoicePanel(
          connected: true,
          isTerminal: true,
          busy: true,
        ),
      ),
    );
    await tester.tap(find.text('爱莉语音'));
    await settle(tester);
    expect(buttonOf(tester, '重新发起').onPressed, isNull);
  });

  // ======================= 盒模型 =======================

  testWidgets('面板：max-width 560 / radius 16 / blur24 / glass 阴影', (WidgetTester tester) async {
    setViewport(tester, const Size(700, 520));
    await tester.pumpWidget(host(const AylaElysiaVoicePanel()));
    expect(tester.getSize(find.byType(AylaElysiaVoicePanel)).width, 560);

    final GlassSurface s = shell(tester);
    expect(
      s.radiusOverride,
      BorderRadius.all(Radius.circular(AylaRadii.rCard)),
    );
    expect(s.blur, AylaGlass.blurCard);
    expect(s.shadow, AylaShadows.glass);
  });
}
