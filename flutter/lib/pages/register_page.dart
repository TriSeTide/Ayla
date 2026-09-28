/// 注册页 —— 与登录页同构（宽屏左右分栏 / 窄屏居中单卡）。
///
/// ## 事实源（逐条）
/// - `web/src/pages/RegisterPage.tsx`（220 行全文）：DOM 顺序、字段、**文案逐字**、
///   校验时机（提交时校验，错误紧贴字段下方、不放顶部汇总，tsx 63–72）、发码 60s 倒计时；
/// - `web/src/styles/auth.css`：`.auth-page` / `.auth-intro*` / `.auth-card` / `.auth-heading` /
///   `.auth-brand`（宽屏卡内 26 / 窄短屏 32 / 否则 40）/ `.auth-subtitle` / `.auth-form`（gap sp4）/
///   `.auth-field`（column + gap sp2）/ `.auth-error` / `.auth-submit`（满宽 44 + margin-top sp1）/
///   `.auth-switch`（padding-top sp4 + 上边框 + gap sp3 + link min-w 72 / 44 高）；
///   **本页新增三块**：`.auth-code-row`（89–93：flex + center + gap sp2）·
///   `.auth-code-row .field`（94–97：`flex: 1` + `min-width: 0`）·
///   `.auth-code-btn`（98–103：`min-width: 104px` + `min-height: 44px` + `padding-inline: sp3` + `nowrap`）；
/// - `web/src/styles/app.css:272–276` `.field-error`（13 / 400 / `--destructive`）。
///
/// ## 复用与登记
/// - 左栏品牌介绍区复用 [AylaAuthIntro]（与登录页同一份 DOM，2026-09-28 提升）；
/// - ✅ **`.auth-code-row` 已提升为公共件 [AylaAuthCodeRow]**（2026-09-28 用户裁决）：
///   本页与 `privacy_sheet.dart` 原有的私有 `_CodeRow` 合并，注册页档显式传
///   `.auth-code-btn` 的 `minWidth: 104` + `padding-inline: sp3`。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/auth_api.dart';
import '../widgets/base/auth_code_row.dart';
import '../core/app_init.dart';
import '../core/net/dio_client.dart';
import '../core/ws/ws_manager.dart';
import '../state/auth_state.dart';
import '../theme/app_theme.dart';
import '../theme/css_gradient.dart';
import '../theme/glass.dart';
import '../theme/tokens.dart';
import 'login_page.dart' show AylaAuthIntro;

/// 发码冷却秒数（tsx 13 `const CODE_COOLDOWN = 60`）。
const int kRegisterCodeCooldown = 60;

class RegisterPage extends ConsumerStatefulWidget {
  const RegisterPage({super.key});

  @override
  ConsumerState<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends ConsumerState<RegisterPage> {
  final TextEditingController _username = TextEditingController();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _nickname = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  final TextEditingController _code = TextEditingController();

  bool _codeSent = false;
  bool _sendingCode = false;
  int _countdown = 0;
  Timer? _timer;
  String? _passwordError;
  String? _confirmError;
  String? _codeError;
  String? _error;
  bool _submitting = false;

  @override
  void dispose() {
    _timer?.cancel();
    _username.dispose();
    _email.dispose();
    _nickname.dispose();
    _password.dispose();
    _confirm.dispose();
    _code.dispose();
    super.dispose();
  }

  /// 发码倒计时（tsx 38–42：每秒递减，到 0 允许重发）。
  void _startCountdown() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _countdown -= 1;
        if (_countdown <= 0) {
          _countdown = 0;
          t.cancel();
        }
      });
    });
  }

  /// `handleSendCode`（tsx 44–61）：空邮箱先贴字段提示，不请求。
  Future<void> _sendCode() async {
    setState(() => _error = null);
    if (_email.text.trim().isEmpty) {
      setState(() => _codeError = '请先填写邮箱');
      return;
    }
    setState(() => _sendingCode = true);
    try {
      await AuthApi.sendEmailCode(_email.text.trim());
      if (!mounted) return;
      setState(() {
        _codeSent = true;
        _countdown = kRegisterCodeCooldown;
        _codeError = null;
      });
      _startCountdown();
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = err is ApiException ? err.message : '验证码发送失败，请稍后重试';
      });
    } finally {
      if (mounted) setState(() => _sendingCode = false);
    }
  }

  /// 提交（tsx 63–88）：先本地校验三处，任一不过即 return（不发请求）。
  Future<void> _submit() async {
    setState(() => _error = null);
    final String? passwordError =
        _password.text.length < 8 ? '密码至少 8 位' : null;
    final String? confirmError =
        _password.text != _confirm.text ? '两次输入的密码不一致' : null;
    String? codeError;
    if (!_codeSent) {
      codeError = '请先发送验证码';
    } else if (!RegExp(r'^\d{6}$').hasMatch(_code.text.trim())) {
      codeError = '请输入 6 位数字验证码';
    }
    setState(() {
      _passwordError = passwordError;
      _confirmError = confirmError;
      _codeError = codeError;
    });
    if (passwordError != null || confirmError != null || codeError != null) {
      return;
    }
    setState(() => _submitting = true);
    try {
      final RegisterResult result = await AuthApi.register(
        username: _username.text.trim(),
        email: _email.text.trim(),
        password: _password.text,
        nickname: _nickname.text.trim(),
        code: _code.text.trim(),
      );
      final AuthNotifier auth = ref.read(authNotifierProvider.notifier);
      auth.setTokens(result.access, result.refresh);
      auth.setUser(result.user);
      // web `useAuth.register`：connect 两条 WS + 跑预加载门。
      wsManager?.connectAll();
      unawaited(AppInit.instance.run());
      if (!mounted) return;
      context.go('/group');
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = err is ApiException ? err.message : '注册失败，请稍后重试';
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Size viewport = MediaQuery.sizeOf(context);
    final bool wide = viewport.width > AylaBreakpoints.sm;
    final bool compact = viewport.width <= 480 || viewport.height <= 700;
    final EdgeInsets pagePadding = EdgeInsets.symmetric(
      horizontal: compact ? AylaSpacing.sp4 : AylaSpacing.sp6,
      vertical: compact ? AylaSpacing.sp4 : AylaSpacing.sp8,
    );
    final Widget card = _card(wide: wide, compact: compact);

    if (wide) {
      // ⚠️ 宽屏：**左栏不参与滚动**（与 `LoginPage` 同口径，2026-09-28 用户指出）。
      // web `auth.css:126–148`：`.auth-page` 整页 `overflow-y:auto`，`.auth-intro` 是
      // `align-self: flex-start`（高度 = 内容高）+ `position: sticky; top: 50dvh; translate: 0 -50%`
      // ⇒ **钉在视口垂直中点、随滚动不动**。Flutter 侧等价形态：左栏移出滚动流固定居中，
      // **只有右侧表单卡区独立滚动**。
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: pagePadding.horizontal),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: viewport.width >= AylaBreakpoints.md ? 460 : 420,
                ),
                child: const AylaAuthIntro(),
              ),
              SizedBox(width: (viewport.width * 0.06).clamp(48.0, 96.0)),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: viewport.height),
                // ⚠️ `clipBehavior: Clip.none` **必须给**（2026-09-28 用户实报「卡片阴影裁断」）：
                // `.auth-card` 的 `--glass-shadow-modal`（`0 20px 60px`，tokens）**画在形状之外**，
                // 默认 `Clip.hardEdge` 会把它裁成一条硬边（截图可见）。
                // 滚动区的高度 = 视口高（外层 Center 居中），故不裁也不会溢出视口。
                child: SingleChildScrollView(
                  clipBehavior: Clip.none,
                  padding: EdgeInsets.symmetric(vertical: pagePadding.vertical),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: viewport.height - pagePadding.vertical,
                    ),
                    child: Center(child: card),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 窄屏（≤768）：`.auth-intro { display: none }` + 整页可滚的居中单卡
    return SingleChildScrollView(
      padding: pagePadding,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(minHeight: viewport.height - pagePadding.vertical),
        child: Center(child: card),
      ),
    );
  }

  Widget _card({required bool wide, required bool compact}) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final TextStyle labelStyle = t.label.copyWith(
      fontWeight: FontWeight.w700,
      color: AylaColors.textPrimary,
    );
    final TextStyle secondaryStyle = t.label.copyWith(
      fontWeight: FontWeight.w400,
      color: AylaColors.textSecondary,
      letterSpacing: 0,
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440), // width: min(440px,100%)
      child: AylaGlassCard(
        radius: AylaRadii.rPanel,
        shadow: AylaShadows.modal,
        blur: AylaGlass.blurCard,
        padding: EdgeInsets.all(compact ? AylaSpacing.sp6 : AylaSpacing.sp8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // `.auth-heading`：居中 gap sp2
            Column(
              children: <Widget>[
                ShaderMask(
                  blendMode: BlendMode.srcIn,
                  shaderCallback: (Rect bounds) => cssLinearGradient(
                    angleDeg: 120,
                    colors: AylaGradients.brand,
                  ).createShader(bounds),
                  child: Text(
                    '创建账号', // tsx 108（**不是** Ayla 二字）
                    style: TextStyle(
                      fontFamily: AylaFonts.display,
                      fontFamilyFallback: AylaFonts.cjkFallback,
                      fontSize: wide ? 26 : (compact ? 32 : 40),
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                const SizedBox(height: AylaSpacing.sp2),
                Text('加入 Ayla', style: secondaryStyle), // tsx 109
              ],
            ),
            const SizedBox(height: AylaSpacing.sp6),
            if (_error != null) ...<Widget>[
              _AuthErrorBox(_error!),
              const SizedBox(height: AylaSpacing.sp4),
            ],
            _field(
              label: '用户名', // tsx 118
              labelStyle: labelStyle,
              controller: _username,
              autofillHints: const <String>['username'],
              autofocus: true,
            ),
            const SizedBox(height: AylaSpacing.sp4),
            _field(
              label: '邮箱', // tsx 129
              labelStyle: labelStyle,
              controller: _email,
              hint: '用于接收注册验证码', // tsx 136
              keyboardType: TextInputType.emailAddress,
              autofillHints: const <String>['email'],
            ),
            const SizedBox(height: AylaSpacing.sp4),
            // `.auth-field`（div 档）：独立 label + `.auth-code-row`（tsx 140–172）
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('邮箱验证码', style: labelStyle), // tsx 141
                const SizedBox(height: AylaSpacing.sp2),
                // 公共件 `AylaAuthCodeRow`（2026-09-28 用户裁决：与 privacy_sheet 的
                // 私有 `_CodeRow` 合并；注册页档传 `.auth-code-btn` 的 104 / sp3）
                AylaAuthCodeRow(
                  controller: _code,
                  placeholder: '6 位验证码', // tsx 150
                  buttonLabel: _codeButtonLabel, // tsx 162–168
                  buttonEnabled: !(_sendingCode || _countdown > 0),
                  enabled: _codeSent, // tsx 152 `disabled={!codeSent}`
                  invalid: _codeError != null, // tsx 153 aria-invalid
                  autofillHints: const <String>['one-time-code'],
                  semanticLabel: '邮箱验证码',
                  buttonMinWidth: 104, // .auth-code-btn
                  buttonPadding: const EdgeInsets.symmetric(
                    horizontal: AylaSpacing.sp3,
                  ),
                  onSend: () => unawaited(_sendCode()),
                  // 输入变化需重建：错误提示与提交流程读的是 controller 内容
                  onChanged: () => setState(() {}),
                ),
                if (_codeError != null) ...<Widget>[
                  const SizedBox(height: AylaSpacing.sp2),
                  _FieldError(_codeError!),
                ],
              ],
            ),
            const SizedBox(height: AylaSpacing.sp4),
            _field(
              label: '昵称（可选）', // tsx 174
              labelStyle: labelStyle,
              controller: _nickname,
              hint: '留空则使用用户名', // tsx 179
            ),
            const SizedBox(height: AylaSpacing.sp4),
            _field(
              label: '密码（至少 8 位）', // tsx 183
              labelStyle: labelStyle,
              controller: _password,
              obscure: true,
              autofillHints: const <String>['new-password'],
              errorText: _passwordError,
            ),
            const SizedBox(height: AylaSpacing.sp4),
            _field(
              label: '确认密码', // tsx 197
              labelStyle: labelStyle,
              controller: _confirm,
              obscure: true,
              autofillHints: const <String>['new-password'],
              errorText: _confirmError,
              onSubmitted: (_) => unawaited(_submit()),
            ),
            const SizedBox(height: AylaSpacing.sp4),
            Padding(
              padding: const EdgeInsets.only(top: AylaSpacing.sp1), // .auth-submit margin-top
              child: AylaGlassButton(
                label: _submitting ? '注册中…' : '注册', // tsx 211
                variant: AylaGlassButtonVariant.glow,
                minHeight: 44,
                expand: true,
                onPressed: _submitting ? null : () => unawaited(_submit()),
              ),
            ),
            const SizedBox(height: AylaSpacing.sp6),
            Container(
              padding: const EdgeInsets.only(top: AylaSpacing.sp4),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: AylaColors.glassBorder)),
              ),
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: AylaSpacing.sp3,
                children: <Widget>[
                  Text('已有账号？', style: secondaryStyle), // tsx 215
                  AylaGlassButton(
                    label: '登录',
                    variant: AylaGlassButtonVariant.ghost,
                    minHeight: 44,
                    minWidth: 72,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AylaSpacing.sp4,
                    ),
                    onPressed: () => context.go('/login'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// `.auth-code-btn` 的三态文案（tsx 162–168）。
  String get _codeButtonLabel {
    if (_sendingCode) return '发送中…';
    if (_countdown > 0) return '重新发送（$_countdown}s）';
    return _codeSent ? '重新发送' : '发送验证码';
  }

  /// `.auth-field`：label（14/700）+ gap sp2 + 44 高字段（认证描边）+ 可选 `.field-error`。
  Widget _field({
    required String label,
    required TextStyle labelStyle,
    required TextEditingController controller,
    String? hint,
    bool obscure = false,
    bool autofocus = false,
    String? errorText,
    TextInputType? keyboardType,
    Iterable<String>? autofillHints,
    ValueChanged<String>? onSubmitted,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: labelStyle),
        const SizedBox(height: AylaSpacing.sp2),
        AylaGlassInput(
          controller: controller,
          hintText: hint,
          obscureText: obscure,
          autofocus: autofocus,
          invalid: errorText != null,
          minHeight: 44,
          onGlassBorder: true,
          keyboardType: keyboardType,
          autofillHints: autofillHints,
          onSubmitted: onSubmitted,
          semanticLabel: label,
        ),
        if (errorText != null) ...<Widget>[
          const SizedBox(height: AylaSpacing.sp2),
          _FieldError(errorText),
        ],
      ],
    );
  }
}

/// `.field-error`（`app.css:272–276`：13 / 400 / `--destructive`）——**紧贴字段下方**。
class _FieldError extends StatelessWidget {
  const _FieldError(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Text(
      message,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: AylaColors.destructive,
      ),
    );
  }
}

/// `.auth-error`（`auth.css`：sp2 sp3 内沿 + radius-input + 玫红半透明底/边 + 13px + `role=alert`）。
class _AuthErrorBox extends StatelessWidget {
  const _AuthErrorBox(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true, // tsx 113 `role="alert"`
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: AylaSpacing.sp3,
          vertical: AylaSpacing.sp2,
        ),
        decoration: BoxDecoration(
          color: const Color(0x1AD64D6E), // rgba(214,77,110,.1)
          border: Border.all(color: const Color(0x59D64D6E)),
          borderRadius: BorderRadius.circular(AylaRadii.rInput),
        ),
        child: Text(
          message,
          style: AylaTextStyles.of(context).caption.copyWith(
                color: AylaColors.destructive,
              ),
        ),
      ),
    );
  }
}