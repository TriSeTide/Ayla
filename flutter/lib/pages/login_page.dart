/// 登录页 —— 宽屏左右分栏（左品牌介绍 + 右玻璃表单卡）/ 窄屏居中单卡。
///
/// 事实源（逐条对应，禁自由发挥）：
/// - `web/src/styles/auth.css`（222 行，全文）：
///   `.auth-page` height 100%/min-h 100dvh、align-items safe center、justify
///   center、padding sp8 sp6、overflow-y auto；宽屏(>768) flex-row +
///   gap clamp(48px,6vw,96px)；`.auth-intro` flex 0 1 420px / ≥1024 460px、
///   max-width 同值、gap sp3、sticky top 50dvh + translate -50%；
///   `.auth-intro-brand` Fredoka 56/600/lh1.25/ls -0.5 + 120deg 渐变字；
///   `.auth-intro-slogan` Fredoka 22/500 text-primary；
///   `.auth-intro-desc` margin sp2 0 0 / max-width 380 / 15px lh1.55 secondary；
///   `.auth-intro-features` ≥1024 显示、wrap gap sp2；`.auth-intro-feature`
///   padding 6/14 + radius-pill + sakura-300 底 + grape-700 字 + Fredoka
///   12/500/ls .4；
///   `.auth-card` width min(440px,100%)、padding sp8、gap sp6、glass-bg、
///   1px glass-border、radius-panel 20、glass-shadow-modal、glass-filter；
///   `.auth-heading` 居中 gap sp2；`.auth-brand` Fredoka 40/600/ls -.5/lh1.25
///   渐变字（宽屏卡内降为 26px）；`.auth-subtitle` 14px secondary；
///   `.auth-form` gap sp4；`.auth-field` gap sp2 + 14/700/ls .2；字段 44 高、
///   认证上下文描边 rgba(70,91,146,.3)、focus 辉光；
///   `.auth-error` padding sp2 sp3 + radius-input + rgba(214,77,110,.1/.35) +
///   destructive + 13px；`.auth-submit` 满宽 44 高 + margin-top sp1；
///   `.auth-switch` 14px secondary 居中 + gap sp3 + padding-top sp4 +
///   上边框 glass-border；`.auth-switch-link` min-w 72 / 44 高 / padding-inline 16；
///   ≤480 或高 ≤700：page padding sp4、card padding sp6、brand 32px。
/// - `web/src/pages/LoginPage.tsx`：DOM 顺序与**文案逐字一致**（含其中以
///   `~ ~ ~ ~` / `------还没想好写什么---…` 形式存在的占位文案——照抄原文，
///   不自行创作）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../theme/app_theme.dart';
import '../theme/css_gradient.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';

/// 登录页（视觉 + 本地表单状态；提交回调由外部注入，未接网络）。
class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    this.onSubmit,
    this.errorText,
    this.submitting = false,
    this.onGoRegister,
    this.initialUsername = '',
    this.initialPassword = '',
  });

  /// 提交回调（外部接 auth：M0 第 4 步接线点）。
  final void Function(String username, String password)? onSubmit;

  /// 外部错误文案（null = 无错误）。
  final String? errorText;

  /// 提交中（按钮转「登录中…」+ disabled）。
  final bool submitting;

  /// 「注册」跳转回调。
  final VoidCallback? onGoRegister;

  /// 预览/测试用初始值。
  final String initialUsername;
  final String initialPassword;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final TextEditingController _username =
      TextEditingController(text: widget.initialUsername);
  late final TextEditingController _password =
      TextEditingController(text: widget.initialPassword);

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    widget.onSubmit?.call(_username.text.trim(), _password.text);
  }

  @override
  Widget build(BuildContext context) {
    final Size viewport = MediaQuery.sizeOf(context);
    final bool wide = viewport.width > Breakpoint.sm; // >768 宽屏分栏
    final bool compact =
        viewport.width <= 480 || viewport.height <= 700; // 窄/短屏收紧

    final EdgeInsets pagePadding = EdgeInsets.symmetric(
      horizontal: compact ? AylaSpacing.sp4 : AylaSpacing.sp6,
      vertical: compact ? AylaSpacing.sp4 : AylaSpacing.sp8,
    );

    // .auth-page：垂直居中且内容高于视口时可滚动（safe center 语义）
    return SingleChildScrollView(
      padding: pagePadding,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: viewport.height - pagePadding.vertical,
        ),
        child: Center(
          child: wide
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    // .auth-intro（≥1024 flex-basis 460；gap clamp(48,6vw,96)）
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: viewport.width >= Breakpoint.md ? 460 : 420,
                      ),
                      child: const _AuthIntro(),
                    ),
                    SizedBox(
                      width: (viewport.width * 0.06)
                          .clamp(48.0, 96.0), // gap: clamp(48px, 6vw, 96px)
                    ),
                    _AuthCard(
                      compact: compact,
                      wide: wide,
                      username: _username,
                      password: _password,
                      submitting: widget.submitting,
                      errorText: widget.errorText,
                      onSubmit: _submit,
                      onGoRegister: widget.onGoRegister,
                    ),
                  ],
                )
              : _AuthCard(
                  compact: compact,
                  wide: wide,
                  username: _username,
                  password: _password,
                  submitting: widget.submitting,
                  errorText: widget.errorText,
                  onSubmit: _submit,
                  onGoRegister: widget.onGoRegister,
                ),
        ),
      ),
    );
  }
}

/// 左栏品牌介绍区（仅宽屏显示；内容照抄 web 原文含占位文案）。
class _AuthIntro extends StatelessWidget {
  const _AuthIntro();

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool showFeatures =
        MediaQuery.sizeOf(context).width >= Breakpoint.md; // ≥1024 才显示
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // .auth-intro-brand：Fredoka 56/600/lh1.25/ls -.5 + 120deg 渐变字
        _GradientText(
          'Ayla',
          style: TextStyle(
            fontFamily: AylaFonts.display,
            fontFamilyFallback: AylaFonts.cjkFallback,
            fontSize: 56,
            fontWeight: FontWeight.w600,
            height: 1.25,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: AylaSpacing.sp3), // gap: var(--sp-3)
        // .auth-intro-slogan：Fredoka 22/500 text-primary（原文占位）
        Text(
          '~ ~ ~ ~',
          style: TextStyle(
            fontFamily: AylaFonts.display,
            fontFamilyFallback: AylaFonts.cjkFallback,
            fontSize: 22,
            fontWeight: FontWeight.w500,
            color: AylaColors.textPrimary,
          ),
        ),
        // .auth-intro-desc：margin sp2 0 0 / max-width 380 / 15 / lh1.55（原文占位）
        Padding(
          padding: const EdgeInsets.only(top: AylaSpacing.sp2),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Text(
              '--------------还没想好写什么---------------------------------------------------------------------------',
              style: t.body.copyWith(color: AylaColors.textSecondary),
            ),
          ),
        ),
        if (showFeatures)
          Padding(
            padding: const EdgeInsets.only(top: AylaSpacing.sp3),
            child: Wrap(
              spacing: AylaSpacing.sp2,
              runSpacing: AylaSpacing.sp2,
              children: const <Widget>[
                _IntroFeature('~ ~ ~ ~'),
                _IntroFeature('~ ~ ~ ~'),
                _IntroFeature('~ ~ ~ ~ ~'),
              ],
            ),
          ),
      ],
    );
  }
}

/// `.auth-intro-feature`：padding 6/14 + radius 999 + sakura-300 底 + grape 字。
class _IntroFeature extends StatelessWidget {
  const _IntroFeature(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: const BoxDecoration(
        color: AylaColors.sakura300,
        borderRadius: AylaRadii.pill,
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: AylaFonts.display,
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 12,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.4,
          color: AylaColors.grape700,
        ),
      ),
    );
  }
}

/// 120deg indigo→grape 渐变字（`background-clip: text` 的 Flutter 等价）。
class _GradientText extends StatelessWidget {
  const _GradientText(this.text, {required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (Rect bounds) => cssLinearGradient(
        angleDeg: 120, // linear-gradient(120deg, indigo-700, grape-700)
        colors: AylaGradients.brand,
      ).createShader(bounds),
      child: Text(text, style: style),
    );
  }
}

/// 表单卡（.auth-card，唯一材料 owner）。
class _AuthCard extends StatelessWidget {
  const _AuthCard({
    required this.compact,
    required this.wide,
    required this.username,
    required this.password,
    required this.submitting,
    required this.errorText,
    required this.onSubmit,
    required this.onGoRegister,
  });

  final bool compact;
  final bool wide;
  final TextEditingController username;
  final TextEditingController password;
  final bool submitting;
  final String? errorText;
  final VoidCallback onSubmit;
  final VoidCallback? onGoRegister;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440), // width: min(440px,100%)
      child: GlassCard(
        radius: AylaRadii.rPanel, // --radius-panel 20
        shadow: AylaShadows.modal, // --glass-shadow-modal
        blur: AylaGlass.blurCard, // --glass-filter blur(24)
        padding: EdgeInsets.all(
          compact ? AylaSpacing.sp6 : AylaSpacing.sp8, // sp8→sp6（窄/短屏）
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // .auth-heading：居中 gap sp2
            Column(
              children: <Widget>[
                _GradientText(
                  'Ayla',
                  style: TextStyle(
                    fontFamily: AylaFonts.display,
                    fontFamilyFallback: AylaFonts.cjkFallback,
                    // .auth-brand 40px；宽屏卡内降为 26px；窄/短屏 32px
                    fontSize: wide ? 26 : (compact ? 32 : 40),
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: AylaSpacing.sp2),
                Text(
                  '登录，回到Ayla',
                  style: t.label.copyWith(
                    fontWeight: FontWeight.w400,
                    color: AylaColors.textSecondary,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AylaSpacing.sp6), // gap: var(--sp-6)
            // .auth-form：gap sp4
            if (errorText != null) ...<Widget>[
              _AuthError(errorText!),
              const SizedBox(height: AylaSpacing.sp4),
            ],
            _AuthField(
              label: '用户名',
              controller: username,
              autofillHints: const <String>['username'],
              autofocus: true,
            ),
            const SizedBox(height: AylaSpacing.sp4),
            _AuthField(
              label: '密码',
              controller: password,
              obscure: true,
              autofillHints: const <String>['password'],
              onSubmitted: (_) => onSubmit(),
            ),
            const SizedBox(height: AylaSpacing.sp4),
            // .auth-submit：满宽 44 高 + margin-top sp1
            Padding(
              padding: const EdgeInsets.only(top: AylaSpacing.sp1),
              child: GlassButton(
                label: submitting ? '登录中…' : '登录',
                variant: GlassButtonVariant.glow,
                minHeight: 44,
                expand: true,
                onPressed: submitting ? null : onSubmit,
              ),
            ),
            const SizedBox(height: AylaSpacing.sp6), // gap: var(--sp-6)
            // .auth-switch：padding-top sp4 + 上边框，居中 gap sp3
            Container(
              padding: const EdgeInsets.only(top: AylaSpacing.sp4),
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: AylaColors.glassBorder),
                ),
              ),
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: AylaSpacing.sp3,
                children: <Widget>[
                  Text(
                    '还没有账号？',
                    style: t.label.copyWith(
                      fontWeight: FontWeight.w400,
                      color: AylaColors.textSecondary,
                      letterSpacing: 0,
                    ),
                  ),
                  GlassButton(
                    label: '注册',
                    variant: GlassButtonVariant.ghost,
                    minHeight: 44,
                    minWidth: 72,
                    padding:
                        const EdgeInsets.symmetric(horizontal: AylaSpacing.sp4),
                    onPressed: onGoRegister ?? () {},
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `.auth-field`：label（14/700/ls .2）+ 字段（44 高，认证上下文描边）。
class _AuthField extends StatelessWidget {
  const _AuthField({
    required this.label,
    required this.controller,
    this.obscure = false,
    this.autofillHints,
    this.autofocus = false,
    this.onSubmitted,
  });

  final String label;
  final TextEditingController controller;
  final bool obscure;
  final Iterable<String>? autofillHints;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: t.label.copyWith(
            fontWeight: FontWeight.w700,
            color: AylaColors.textPrimary,
          ),
        ),
        const SizedBox(height: AylaSpacing.sp2), // gap: var(--sp-2)
        GlassInput(
          controller: controller,
          obscureText: obscure,
          autofillHints: autofillHints,
          autofocus: autofocus,
          minHeight: 44, // .auth-field .field { min-height: 44px }
          onGlassBorder: true, // rgba(70,91,146,.3) 认证上下文描边
          onSubmitted: onSubmitted,
          semanticLabel: label,
        ),
      ],
    );
  }
}

/// `.auth-error`：sp2 sp3 内沿 + radius-input + 玫红半透明底/边 + 13px。
class _AuthError extends StatelessWidget {
  const _AuthError(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp3,
        vertical: AylaSpacing.sp2,
      ),
      decoration: BoxDecoration(
        color: const Color(0x1AD64D6E), // rgba(214,77,110,.1)
        border: Border.all(color: const Color(0x59D64D6E)), // rgba(214,77,110,.35)
        borderRadius: BorderRadius.circular(AylaRadii.rInput),
      ),
      child: Text(
        message,
        style: AylaTextStyles.of(context).caption.copyWith(
              color: AylaColors.destructive,
            ),
      ),
    );
  }
}

// ======================= 预览 =======================

/// 窄屏单卡（375×812）。
@Preview(
  group: 'Pages',
  name: 'LoginPage 窄屏 375×812',
  size: Size(375, 812),
  wrapper: previewTheme,
)
Widget loginNarrowPreview() => const LoginPage();

/// 窄屏 · 错误态。
@Preview(
  group: 'Pages',
  name: 'LoginPage 窄屏 · 错误态',
  size: Size(375, 812),
  wrapper: previewTheme,
)
Widget loginNarrowErrorPreview() => const LoginPage(
      initialUsername: '123',
      initialPassword: 'wrongpass',
      errorText: '用户名或密码错误',
    );

/// 窄屏 · 登录中。
@Preview(
  group: 'Pages',
  name: 'LoginPage 窄屏 · 登录中',
  size: Size(375, 812),
  wrapper: previewTheme,
)
Widget loginNarrowPendingPreview() => const LoginPage(
      initialUsername: '123',
      initialPassword: '12345678',
      submitting: true,
    );

/// 宽屏左右分栏（1440×900）。
@Preview(
  group: 'Pages',
  name: 'LoginPage 宽屏 1440×900',
  size: Size(1440, 900),
  wrapper: previewTheme,
)
Widget loginWidePreview() => const LoginPage();

/// 宽屏 · 分栏 + 错误态。
@Preview(
  group: 'Pages',
  name: 'LoginPage 宽屏 · 错误态',
  size: Size(1440, 900),
  wrapper: previewTheme,
)
Widget loginWideErrorPreview() => const LoginPage(
      initialUsername: '123',
      errorText: '网络异常，登录失败，请稍后重试',
    );

/// 短屏 1024×680（≤700 高触发 compact：page/card 收紧、brand 32px）。
@Preview(
  group: 'Pages',
  name: 'LoginPage 短屏 1024×680（compact）',
  size: Size(1024, 680),
  wrapper: previewTheme,
)
Widget loginCompactPreview() => const LoginPage();

/// 断点边界 768×900（= 窄屏上限，仍单卡）。
@Preview(
  group: 'Pages',
  name: 'LoginPage 768×900（窄屏上限）',
  size: Size(768, 900),
  wrapper: previewTheme,
)
Widget loginBreakpointPreview() => const LoginPage();
