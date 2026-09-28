/// 注册页回归（`web/src/pages/RegisterPage.tsx` 220 行 + `auth.css` + `app.css:272–276`）。
///
/// 只覆盖**纯 UI / 本地校验**（不发请求）：本地校验不通过时 `_submit` 直接 return，
/// 因此无需 mock `DioClient`；发码/注册的网络路径由后端契约测试覆盖。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/pages/register_page.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';

void main() {
  /// ⚠️ **必须同时钉真实表面尺寸**：只覆写 `MediaQuery` 只改断点判定，
  /// 默认 800×600 表面仍会把 1440 宽的分栏挤到溢出（实测 Row 溢出 160px）。
  Future<void> useViewport(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  /// 真实宿主（MediaQuery 覆写视口 —— 断点判定读的是它，不是测试表面）。
  Widget host(Widget child, {Size viewport = const Size(1440, 900)}) {
    return MaterialApp(
      home: Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: viewport),
          child: previewScope(child),
        ),
      ),
    );
  }

  testWidgets('宽屏（>768）：左右分栏 —— 品牌介绍区与表单卡同屏', (WidgetTester tester) async {
    await useViewport(tester, const Size(1440, 900));
    await tester.pumpWidget(host(const RegisterPage()));
    await tester.pump();

    // `.auth-intro`（LoginPage.tsx:38–51 与 RegisterPage.tsx:92–105 **逐字相同**）
    expect(find.text('Ayla'), findsOneWidget);
    expect(find.text('~ ~ ~ ~'), findsWidgets);
    // 卡内标题是「创建账号」而非 Ayla（tsx 108）
    expect(find.text('创建账号'), findsOneWidget);
    expect(find.text('加入 Ayla'), findsOneWidget);
  });

  testWidgets('窄屏（≤768）：退回居中单卡，品牌介绍区不渲染', (WidgetTester tester) async {
    await useViewport(tester, const Size(375, 812));
    await tester.pumpWidget(
      host(const RegisterPage(), viewport: const Size(375, 812)),
    );
    await tester.pump();

    expect(find.text('Ayla'), findsNothing); // 卡内标题不是 Ayla
    expect(find.text('创建账号'), findsOneWidget);
  });

  testWidgets('字段与文案逐字（tsx 117–216）', (WidgetTester tester) async {
    await useViewport(tester, const Size(1440, 1200));
    await tester.pumpWidget(host(const RegisterPage()));
    await tester.pump();

    for (final String label in <String>[
      '用户名',
      '邮箱',
      '邮箱验证码',
      '昵称（可选）',
      '密码（至少 8 位）',
      '确认密码',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('用于接收注册验证码'), findsOneWidget); // placeholder
    expect(find.text('6 位验证码'), findsOneWidget);
    expect(find.text('留空则使用用户名'), findsOneWidget);
    expect(find.text('发送验证码'), findsOneWidget); // 未发码档
    expect(find.text('已有账号？'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
  });

  testWidgets('本地校验：未发码 + 密码过短 ⇒ 两处字段错误紧贴字段下方，且不提交', (
    WidgetTester tester,
  ) async {
    await useViewport(tester, const Size(1440, 1200));
    await tester.pumpWidget(host(const RegisterPage()));
    await tester.pump();

    await tester.tap(find.widgetWithText(AylaGlassButton, '注册'));
    await tester.pump();

    expect(find.text('密码至少 8 位'), findsOneWidget); // tsx 67
    expect(find.text('请先发送验证码'), findsOneWidget); // tsx 69
    // 密码与确认都为空 ⇒ 两者相等 ⇒ 不出「不一致」（tsx 68 的严格相等语义）
    expect(find.text('两次输入的密码不一致'), findsNothing);
  });

  testWidgets('.field-error 规格：13 / 400 / --destructive（app.css:272–276）', (
    WidgetTester tester,
  ) async {
    await useViewport(tester, const Size(1440, 1200));
    await tester.pumpWidget(host(const RegisterPage()));
    await tester.pump();
    await tester.tap(find.widgetWithText(AylaGlassButton, '注册'));
    await tester.pump();

    final Text error = tester.widget<Text>(find.text('密码至少 8 位'));
    expect(error.style!.fontSize, 13);
    expect(error.style!.fontWeight, FontWeight.w400);
    expect(error.style!.color, AylaColors.destructive);
  });

  testWidgets('.auth-code-btn：min-width 104 / min-height 44（auth.css:98–103）', (
    WidgetTester tester,
  ) async {
    await useViewport(tester, const Size(1440, 1200));
    await tester.pumpWidget(host(const RegisterPage()));
    await tester.pump();

    final AylaGlassButton btn = tester.widget<AylaGlassButton>(
      find.widgetWithText(AylaGlassButton, '发送验证码'),
    );
    expect(btn.minWidth, 104);
    expect(btn.minHeight, 44);
    expect(btn.variant, AylaGlassButtonVariant.ghost); // `.btn.btn-ghost`
    expect(
      btn.padding,
      const EdgeInsets.symmetric(horizontal: AylaSpacing.sp3),
    );
  });

  testWidgets('验证码字段：未发码时 disabled（tsx 152）+ 仅数字 6 位（tsx 147/149）', (
    WidgetTester tester,
  ) async {
    await useViewport(tester, const Size(1440, 1200));
    await tester.pumpWidget(host(const RegisterPage()));
    await tester.pump();

    final AylaGlassInput input = tester.widget<AylaGlassInput>(
      find.byType(AylaGlassInput).at(2), // 顺序：用户名 / 邮箱 / 验证码 / 昵称 / 密码 / 确认
    );
    expect(input.enabled, isFalse);
    expect(input.maxLength, 6);
    expect(input.inputFormatters, isNotNull);
  });
}