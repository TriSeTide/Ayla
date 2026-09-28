/// `AylaAuthCodeRow`（`.auth-code-row`，`auth.css:89–103`）回归。
///
/// 2026-09-28 由「注册页页面内组装 + `privacy_sheet.dart` 私有 `_CodeRow`」合并为公共件。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/auth_code_row.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
        home: previewScope(
          Center(child: SizedBox(width: 360, child: child)),
        ),
      );

  testWidgets('默认档（隐私弹层规格）：字段 flex 1 / 按钮内容宽 + sp6 内沿', (
    WidgetTester tester,
  ) async {
    final TextEditingController code = TextEditingController();
    addTearDown(code.dispose);
    int sends = 0;
    await tester.pumpWidget(
      host(
        AylaAuthCodeRow(
          controller: code,
          placeholder: '6 位验证码',
          buttonLabel: '发送验证码',
          onSend: () => sends++,
        ),
      ),
    );
    await tester.pump();

    final AylaGlassButton btn = tester.widget<AylaGlassButton>(
      find.byType(AylaGlassButton),
    );
    expect(btn.minWidth, isNull);
    expect(
      btn.padding,
      const EdgeInsets.symmetric(horizontal: AylaSpacing.sp6),
    );
    expect(btn.variant, AylaGlassButtonVariant.ghost); // `.btn.btn-ghost`
    expect(btn.minHeight, 44);

    await tester.tap(find.text('发送验证码'));
    await tester.pump();
    expect(sends, 1);
  });

  testWidgets('注册页档：`.auth-code-btn` 的 min-width 104 + padding-inline sp3', (
    WidgetTester tester,
  ) async {
    final TextEditingController code = TextEditingController();
    addTearDown(code.dispose);
    await tester.pumpWidget(
      host(
        AylaAuthCodeRow(
          controller: code,
          placeholder: '6 位验证码',
          buttonLabel: '重新发送（59s）',
          onSend: () {},
          buttonMinWidth: 104,
          buttonPadding: const EdgeInsets.symmetric(
            horizontal: AylaSpacing.sp3,
          ),
        ),
      ),
    );
    await tester.pump();

    final AylaGlassButton btn = tester.widget<AylaGlassButton>(
      find.byType(AylaGlassButton),
    );
    expect(btn.minWidth, 104);
    expect(
      btn.padding,
      const EdgeInsets.symmetric(horizontal: AylaSpacing.sp3),
    );
    // nowrap ⇒ 长文案不被截断：按钮实际宽度 ≥ min-width（内容把它撑开）
    expect(tester.getSize(find.byType(AylaGlassButton)).width, greaterThanOrEqualTo(104));
  });

  testWidgets('字段规格：数字键盘 / maxLength 6 / 仅数字 / 认证描边 / 44 高', (
    WidgetTester tester,
  ) async {
    final TextEditingController code = TextEditingController();
    addTearDown(code.dispose);
    await tester.pumpWidget(
      host(
        AylaAuthCodeRow(
          controller: code,
          placeholder: '6 位验证码',
          buttonLabel: '发送验证码',
          onSend: () {},
        ),
      ),
    );
    await tester.pump();

    final AylaGlassInput input = tester.widget<AylaGlassInput>(
      find.byType(AylaGlassInput),
    );
    expect(input.maxLength, 6);
    expect(input.minHeight, 44);
    expect(input.onGlassBorder, isTrue);
    expect(input.keyboardType, TextInputType.number);
    expect(input.inputFormatters, isNotNull);

    // 过滤非数字：输入 'a1b2' 只剩 '12'（tsx `replace(/\D/g, "")`）
    await tester.enterText(find.byType(TextField), 'a1b2c3');
    await tester.pump();
    expect(code.text, '123');
  });

  testWidgets('禁用 / 校验失败两档：enabled=false 与 invalid=true 落到字段上', (
    WidgetTester tester,
  ) async {
    final TextEditingController code = TextEditingController();
    addTearDown(code.dispose);
    await tester.pumpWidget(
      host(
        AylaAuthCodeRow(
          controller: code,
          placeholder: '6 位验证码',
          buttonLabel: '发送验证码',
          enabled: false,
          invalid: true,
          buttonEnabled: false,
          onSend: () {},
        ),
      ),
    );
    await tester.pump();

    final AylaGlassInput input = tester.widget<AylaGlassInput>(
      find.byType(AylaGlassInput),
    );
    expect(input.enabled, isFalse); // 注册页未发码档
    expect(input.invalid, isTrue); // aria-invalid
    expect(
      tester.widget<AylaGlassButton>(find.byType(AylaGlassButton)).onPressed,
      isNull,
    );
  });

  testWidgets('onChanged 回传：输入后调用方能重建（隐私弹层「下一步」依赖它）', (
    WidgetTester tester,
  ) async {
    final TextEditingController code = TextEditingController();
    addTearDown(code.dispose);
    int changes = 0;
    await tester.pumpWidget(
      host(
        AylaAuthCodeRow(
          controller: code,
          placeholder: '6 位验证码',
          buttonLabel: '发送验证码',
          onSend: () {},
          onChanged: () => changes++,
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();
    expect(changes, greaterThan(0));
  });
}