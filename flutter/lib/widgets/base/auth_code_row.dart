/// 邮箱验证码行（`.auth-code-row`）—— 验证码输入框 + 发码键的并排组合。
///
/// ## 事实源
/// `web/src/styles/auth.css:89–103`：
/// ```
/// .auth-code-row { display: flex; align-items: center; gap: var(--sp-2); }
/// .auth-code-row .field { flex: 1; min-width: 0; }
/// .auth-code-btn { min-width: 104px; min-height: 44px; padding-inline: var(--sp-3); white-space: nowrap; }
/// ```
/// 字段本体规格（`inputMode="numeric"` + `maxLength={6}` + 过滤非数字）来自各调用点的 tsx：
/// · `RegisterPage.tsx:143–155`（未发码时 `disabled`、`aria-invalid`、`autoComplete="one-time-code"`）；
/// · `PrivacySheet.tsx`（改密 / 换绑三步，共 3 处 `_CodeRow`）。
///
/// ## 来历
/// 2026-09-28 用户裁决：把注册页的页面内组装与 `privacy_sheet.dart` 的私有 `_CodeRow`
/// **合并为公共件**（同一规格的两份实现，正是库内禁止的重复模式）。
/// 默认值取两处**共同**的那一支：`buttonMinWidth` / `buttonPadding` 默认 null ⇒ 沿用
/// [AylaGlassButton] 自己的默认（内容宽 + `padding: 0 var(--sp-6)`）；注册页要
/// `.auth-code-btn` 的 104 / `sp3` 就显式传。
///
/// ## 公开面
/// `AylaAuthCodeRow` · 样张 `aylaAuthCodeRowSamples()`
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, TextInputFormatter;

import '../../theme/app_theme.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';

class AylaAuthCodeRow extends StatelessWidget {
  const AylaAuthCodeRow({
    super.key,
    required this.controller,
    required this.placeholder,
    required this.buttonLabel,
    required this.onSend,
    this.buttonEnabled = true,
    this.enabled = true,
    this.invalid = false,
    this.onChanged,
    this.autofillHints,
    this.semanticLabel,
    this.buttonMinWidth,
    this.buttonPadding,
  });

  /// 验证码输入控制器。
  final TextEditingController controller;

  /// 输入框占位（注册页「6 位验证码」/ 隐私弹层「新邮箱 6 位验证码」）。
  final String placeholder;

  /// 发码键文案（调用方按倒计时 / 发送态算好，如「发送验证码」/「重新发送（59s）」）。
  final String buttonLabel;

  /// 发码回调。
  final VoidCallback onSend;

  /// 发码键可用（false ⇒ disabled）。
  final bool buttonEnabled;

  /// 输入框可用（注册页未发码时 `disabled={!codeSent}`）。
  final bool enabled;

  /// 输入框校验失败态（`aria-invalid` → `--destructive` 描边）。
  final bool invalid;

  /// 文本变化（调用方常需重建以刷新「下一步」等按钮的可用性）。
  final VoidCallback? onChanged;

  /// 自动填充提示（注册页传 `one-time-code`）。
  final Iterable<String>? autofillHints;

  /// 可访问名（默认取 [placeholder]）。
  final String? semanticLabel;

  /// 发码键最小宽（注册页 `.auth-code-btn` 传 104；null = [AylaGlassButton] 默认）。
  final double? buttonMinWidth;

  /// 发码键内沿（注册页 `.auth-code-btn` 传 `sp3`；null = [AylaGlassButton] 默认 `sp6`）。
  final EdgeInsetsGeometry? buttonPadding;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles style = AylaTextStyles.of(context);
    return Row(
      spacing: AylaSpacing.sp2, // gap: var(--sp-2)
      children: <Widget>[
        Expanded(
          // `.auth-code-row .field { flex: 1; min-width: 0 }`
          child: AylaGlassInput(
            controller: controller,
            hintText: placeholder,
            enabled: enabled,
            invalid: invalid,
            minHeight: 44,
            onGlassBorder: true, // 认证上下文：描边 rgba(70,91,146,.3)
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
            ],
            autofillHints: autofillHints,
            semanticLabel: semanticLabel ?? placeholder,
            onChanged: (_) => onChanged?.call(),
            textStyle: style.body.copyWith(color: AylaColors.textPrimary),
          ),
        ),
        AylaGlassButton(
          label: buttonLabel,
          variant: AylaGlassButtonVariant.ghost, // `.btn.btn-ghost`
          minHeight: 44,
          minWidth: buttonMinWidth,
          // `.auth-code-btn { white-space: nowrap }`：按钮按内容宽伸展（min-width 只兜底），
          // 故长文案不会被截断——Flutter 侧同理（按钮自身无 maxWidth 约束）。
          padding: buttonPadding ??
              const EdgeInsets.symmetric(horizontal: AylaSpacing.sp6),
          onPressed: buttonEnabled ? onSend : null,
        ),
      ],
    );
  }
}

// ======================= 样张 =======================

class _AuthCodeRowSample extends StatefulWidget {
  const _AuthCodeRowSample({
    required this.placeholder,
    required this.buttonLabel,
    this.enabled = true,
    this.invalid = false,
    this.buttonEnabled = true,
    this.buttonMinWidth,
    this.buttonPadding,
  });

  final String placeholder;
  final String buttonLabel;
  final bool enabled;
  final bool invalid;
  final bool buttonEnabled;
  final double? buttonMinWidth;
  final EdgeInsetsGeometry? buttonPadding;

  @override
  State<_AuthCodeRowSample> createState() => _AuthCodeRowSampleState();
}

class _AuthCodeRowSampleState extends State<_AuthCodeRowSample> {
  final TextEditingController _code = TextEditingController();
  bool _sent = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AylaSpacing.sp2,
      children: <Widget>[
        SizedBox(
          width: 360,
          child: AylaAuthCodeRow(
            controller: _code,
            placeholder: widget.placeholder,
            buttonLabel: widget.buttonLabel,
            enabled: widget.enabled,
            invalid: widget.invalid,
            buttonEnabled: widget.buttonEnabled,
            buttonMinWidth: widget.buttonMinWidth,
            buttonPadding: widget.buttonPadding,
            onSend: () => setState(() => _sent = true),
            onChanged: () => setState(() {}),
          ),
        ),
        Text(
          _sent ? '已触发发码' : '点发码键看反馈',
          style: AylaTextStyles.of(context).timestamp.copyWith(
                color: AylaColors.textSecondary,
              ),
        ),
      ],
    );
  }
}

/// 画布样张：默认档（内容宽）/ 注册页档（`.auth-code-btn` 104 + sp3）/ 禁用档 / 校验失败档。
Widget aylaAuthCodeRowSamples() {
  return Wrap(
    spacing: AylaSpacing.sp6,
    runSpacing: AylaSpacing.sp4,
    crossAxisAlignment: WrapCrossAlignment.start,
    children: const <Widget>[
      _AuthCodeRowSample(placeholder: '6 位验证码', buttonLabel: '发送验证码'),
      _AuthCodeRowSample(
        placeholder: '6 位验证码',
        buttonLabel: '重新发送（59s）',
        buttonMinWidth: 104,
        buttonPadding: EdgeInsets.symmetric(horizontal: AylaSpacing.sp3),
        enabled: false,
      ),
      _AuthCodeRowSample(
        placeholder: '新邮箱 6 位验证码',
        buttonLabel: '发送验证码',
        invalid: true,
      ),
      _AuthCodeRowSample(
        placeholder: '6 位验证码',
        buttonLabel: '发送中…',
        buttonEnabled: false,
      ),
    ],
  );
}