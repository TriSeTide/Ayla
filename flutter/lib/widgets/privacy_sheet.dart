/// 隐私设置弹窗（`PrivacySheet.tsx` + profile.css 626–752）。
///
/// ## 事实源
/// ```
/// .privacy-sheet-overlay { fixed; inset:0; z-index:120; --overlay-dim;
///   flex center; padding: 24px }
/// .privacy-sheet-card { flex column; width: min(480px,100%);
///   max-height: min(80vh, 720px); overflow:hidden;
///   --glass-bg-strong; blur(24px) saturate(1.4); 1px --glass-border;
///   radius-panel 20; --glass-shadow-modal }
/// .is-narrow（≤768）{ absolute bottom:0; width:100%; height:60dvh;
///   max-height:60dvh; radius 20 20 0 0; 去左右下边框; padding-bottom safe-area }
/// .privacy-sheet-head { flex between; gap sp3; padding sp4; 下边框 glass-border }
/// .privacy-sheet-title { font-display 16/700 }
/// .privacy-sheet-body { flex column; gap sp3; padding sp4; overflow-y:auto }
/// .privacy-sheet-hint { 13px --text-secondary }  strong → --indigo-700 700
/// .privacy-menu-item { 左对齐列; gap 2px; padding sp3 sp2; radius-input;
///   透明底; transition background 180ms }  :hover → rgba(157,191,230,.2)
/// .privacy-menu-item-title { 15/700 --indigo-700 }
/// .privacy-menu-item-desc { 12px --text-secondary }
/// .privacy-sheet-submit { width:100%; min-height:44px; margin-top: sp1 }
/// .privacy-done { align-items:center; text-align:center; padding-block: sp8 }
/// .privacy-done-icon { 32px --success }  .privacy-done-text { 15/700 }
/// ```
///
/// ## 视图流（tsx，全部在弹窗内完成）
/// - `menu`：邮箱换绑 / 更改密码 两个入口
/// - `password`：验证码（发至绑定邮箱，**60s 倒计时**）+ 新密码两次确认
/// - `email`：**两步** —— step1 当前邮箱验证码（**未绑定邮箱则跳过** → 直接 step2）
///   → step2 新邮箱 + 发至新邮箱的验证码
/// - `done`：✓ + 结果文案 + 「完成」
///
/// ## 校验（tsx，前端先校验再提交）
/// - 改密：`code` 必须 **6 位数字**；`password.length >= 8`；两次一致
/// - 换绑：`newCode` 6 位数字；`newEmail` 匹配邮箱正则；
///   `current_code` 仅在已绑定邮箱时提交（否则空串）
///
/// ## 行为
/// - **ESC 关闭**；遮罩点击关闭；`closedRef` 防重复关闭
/// - 动画：遮罩 opacity 180ms；卡片窄屏从底部 100% 上滑、宽屏 -12px 下落，
///   250ms `--ease-out`；**reduced-motion 关闭位移**
/// - 发码按钮禁用条件：`sending || countdown>0`（换绑 step2 另加 `newEmail` 为空）
/// - 错误显示在 `.auth-error`（`role=alert`）
/// - 验证码输入 `inputMode=numeric` + **过滤非数字** + `maxLength 6`
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, KeyDownEvent, LogicalKeyboardKey,
        TextInputFormatter;
import 'package:flutter/widget_previews.dart';

import '../core/net/dio_client.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';

/// 验证码冷却秒数（tsx `CODE_COOLDOWN = 60`）。
const int kPrivacyCodeCooldown = 60;

/// 弹窗视图（tsx `View`）。
enum PrivacyView { menu, password, email, done }

/// 隐私设置弹窗。
///
/// API 通过回调注入（与 `SignedVideo` 同样的处理方式：核心链路属账号批次，
/// 这里给出完整状态机与校验，调用方接 `DioClient` 即可）。
class PrivacySheet extends StatefulWidget {
  const PrivacySheet({
    super.key,
    required this.onClose,
    this.boundEmail = '',
    this.sendEmailCode,
    this.changePassword,
    this.changeEmail,
  });

  /// 关闭回调。
  final VoidCallback onClose;

  /// 当前绑定邮箱（空 = 未绑定 → 换绑直接进 step2）。
  final String boundEmail;

  /// 发送邮箱验证码。
  final Future<void> Function(String email)? sendEmailCode;

  /// 修改密码（`code` + `new_password`）。
  final Future<void> Function({required String code, required String newPassword})?
      changePassword;

  /// 换绑邮箱（`current_code` / `new_email` / `new_code`）。
  final Future<void> Function({
    required String currentCode,
    required String newEmail,
    required String newCode,
  })? changeEmail;

  @override
  State<PrivacySheet> createState() => _PrivacySheetState();
}

class _PrivacySheetState extends State<PrivacySheet> {
  PrivacyView _view = PrivacyView.menu;

  /// 换绑步骤（1 = 验证当前邮箱；2 = 新邮箱）。
  int _emailStep = 1;

  // 改密字段
  final TextEditingController _code = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirm = TextEditingController();

  // 换绑字段
  final TextEditingController _curCode = TextEditingController();
  final TextEditingController _newEmail = TextEditingController();
  final TextEditingController _newCode = TextEditingController();

  // 状态
  bool _sending = false;
  int _countdown = 0;
  bool _submitting = false;
  String? _error;
  String _doneMsg = '';
  Timer? _timer;

  /// 防重复关闭（tsx `closedRef`）。
  bool _closed = false;

  bool get _isNarrow => MediaQuery.of(context).size.width <= 768;

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    _curCode.dispose();
    _newEmail.dispose();
    _newCode.dispose();
    super.dispose();
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    widget.onClose();
  }

  /// 发码 + 启动倒计时（tsx `sendCodeTo`）。
  Future<void> _sendCodeTo(String target) async {
    setState(() => _error = null);
    if (target.trim().isEmpty) {
      setState(() => _error = '请先填写邮箱');
      return;
    }
    setState(() => _sending = true);
    try {
      await widget.sendEmailCode?.call(target.trim());
      setState(() => _countdown = kPrivacyCodeCooldown);
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        setState(() {
          _countdown--;
          if (_countdown <= 0) t.cancel();
        });
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = _msgOf(e, '验证码发送失败，请稍后重试'));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 错误文案（tsx `err instanceof ApiError ? err.message : fallback`）。
  String _msgOf(Object e, String fallback) =>
      e is ApiException ? e.message : fallback;

  /// 提交改密（tsx `submitPassword` 的三条校验顺序一致）。
  Future<void> _submitPassword() async {
    setState(() => _error = null);
    if (!RegExp(r'^\d{6}$').hasMatch(_code.text.trim())) {
      setState(() => _error = '请输入 6 位数字验证码');
      return;
    }
    if (_password.text.length < 8) {
      setState(() => _error = '新密码至少 8 位');
      return;
    }
    if (_password.text != _confirm.text) {
      setState(() => _error = '两次输入的密码不一致');
      return;
    }
    setState(() => _submitting = true);
    try {
      await widget.changePassword?.call(
        code: _code.text.trim(),
        newPassword: _password.text,
      );
      if (!mounted) return;
      setState(() {
        _doneMsg = '密码已更新';
        _view = PrivacyView.done;
      });
    } catch (e) {
      if (mounted) setState(() => _error = _msgOf(e, '修改失败，请稍后重试'));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 提交换绑（tsx `submitEmail`）。
  Future<void> _submitEmail() async {
    setState(() => _error = null);
    if (!RegExp(r'^\d{6}$').hasMatch(_newCode.text.trim())) {
      setState(() => _error = '请输入新邮箱的 6 位数字验证码');
      return;
    }
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(_newEmail.text.trim())) {
      setState(() => _error = '请输入有效的新邮箱地址');
      return;
    }
    setState(() => _submitting = true);
    try {
      await widget.changeEmail?.call(
        // current_code 仅在已绑定邮箱时提交（否则空串）
        currentCode: widget.boundEmail.isNotEmpty ? _curCode.text.trim() : '',
        newEmail: _newEmail.text.trim(),
        newCode: _newCode.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _doneMsg = '邮箱已更新';
        _view = PrivacyView.done;
      });
    } catch (e) {
      if (mounted) setState(() => _error = _msgOf(e, '换绑失败，请稍后重试'));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _openPassword() => setState(() {
        _error = null;
        _view = PrivacyView.password;
      });

  void _openEmail() => setState(() {
        _error = null;
        // 未绑定邮箱则跳过 step1（tsx `setEmailStep(boundEmail ? 1 : 2)`）
        _emailStep = widget.boundEmail.isNotEmpty ? 1 : 2;
        _view = PrivacyView.email;
      });

  @override
  Widget build(BuildContext context) {
    final bool narrow = _isNarrow;

    // ESC 关闭。tsx 用**全局 window keydown**（不依赖焦点）；Flutter 的
    // Shortcuts/Actions 只在**焦点位于本子树内**时命中，故必须 autofocus ——
    // 否则弹窗刚打开时按 ESC 无反应（实测）。
    return Focus(
      autofocus: true,
      onKeyEvent: (FocusNode node, KeyEvent event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          _close();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape): _CloseIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _CloseIntent: CallbackAction<_CloseIntent>(
            onInvoke: (_) {
              _close();
              return null;
            },
          ),
        },
        child: Semantics(
          scopesRoute: true,
          explicitChildNodes: true,
          label: '隐私设置',
          child: Stack(
            children: <Widget>[
              // `.privacy-sheet-overlay`（--overlay-dim + 居中 + padding 24）
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _close,
                  child: const ColoredBox(color: Color(0x40465B92)),
                ),
              ),
              // 卡片定位：窄屏贴底 60dvh；宽屏居中
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.all(narrow ? 0 : 24),
                  child: Align(
                    alignment: narrow ? Alignment.bottomCenter : Alignment.center,
                    child: GestureDetector(
                      onTap: () {}, // 卡内点击不冒泡到遮罩
                      child: _buildCard(narrow),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildCard(bool narrow) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    // 窄屏 20 20 0 0；宽屏 20
    final BorderRadius r = narrow
        ? const BorderRadius.vertical(top: Radius.circular(AylaRadii.rPanel))
        : BorderRadius.circular(AylaRadii.rPanel);
    final bool opaque = GlassConfig.useOpaqueFallback;

    final Widget inner = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _buildHead(t),
        Flexible(
          child: SingleChildScrollView(
            child: _buildBody(t),
          ),
        ),
      ],
    );

    Widget face = DecoratedBox(
      decoration: BoxDecoration(
        color: GlassConfig.resolveBackground(strong: true), // --glass-bg-strong
        borderRadius: r,
        border: narrow
            ? const Border(top: BorderSide(color: AylaColors.glassBorder))
            : Border.all(color: AylaColors.glassBorder),
      ),
      child: ClipRRect(borderRadius: r, child: inner),
    );
    if (!opaque) {
      face = Stack(
        children: <Widget>[
          Positioned.fill(
            child: ClipRRect(
              borderRadius: r,
              child: BackdropFilter(
                filter: GlassConfig.backdropFilter(sigma: AylaGlass.blurCard),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          face,
        ],
      );
    }

    // width: min(480px,100%)；max-height: min(80vh,720px)；窄屏 height 60dvh
    final Size vp = MediaQuery.of(context).size;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: narrow ? double.infinity : 480,
        maxHeight: narrow ? vp.height * 0.6 : (vp.height * 0.8).clamp(0, 720),
        minHeight: narrow ? vp.height * 0.6 : 0, // 窄屏固定 60dvh
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          // --glass-shadow-modal（20/60 + --glass-inset）
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: r,
                boxShadow: AylaShadows.modal,
              ),
            ),
          ),
          face,
        ],
      ),
    );
  }

  /// `.privacy-sheet-head`（标题 + 关闭 icon-btn-40 + 下边框）。
  Widget _buildHead(AylaTextStyles t) {
    return Container(
      padding: const EdgeInsets.all(AylaSpacing.sp4), // padding: var(--sp-4)
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AylaColors.glassBorder), // border-bottom
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '隐私设置',
              style: TextStyle(
                fontFamily: AylaFonts.display, // --font-display
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 16, // font-size: 16px
                fontWeight: FontWeight.w700, // font-weight: 700
                color: AylaColors.textPrimary,
              ),
            ),
          ),
          Semantics(
            button: true,
            label: '关闭',
            child: GestureDetector(
              onTap: _close,
              child: const SizedBox(
                width: 40, // .icon-btn-40
                height: 40,
                child: Icon(Icons.close, size: 18, color: AylaColors.textSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// `.privacy-sheet-body`（flex column gap sp3 padding sp4）。
  Widget _buildBody(AylaTextStyles t) {
    final Widget content = switch (_view) {
      PrivacyView.menu => _buildMenu(t),
      PrivacyView.password => _buildPassword(t),
      PrivacyView.email => _emailStep == 1 ? _buildEmailStep1(t) : _buildEmailStep2(t),
      PrivacyView.done => _buildDone(t),
    };
    return Padding(
      padding: const EdgeInsets.all(AylaSpacing.sp4), // padding: var(--sp-4)
      child: content,
    );
  }

  /// 视图 menu。
  Widget _buildMenu(AylaTextStyles t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: AylaSpacing.sp3, // gap: var(--sp-3)
      children: <Widget>[
        Text(
          '变更需要通过绑定邮箱验证',
          style: t.caption.copyWith(
            fontSize: 13, // font-size: 13px
            color: AylaColors.textSecondary,
          ),
        ),
        _MenuItem(
          title: '邮箱换绑',
          desc: widget.boundEmail.isNotEmpty
              ? '当前：${widget.boundEmail}'
              : '当前未绑定邮箱',
          onTap: _openEmail,
          style: t,
        ),
        _MenuItem(
          title: '更改密码',
          desc: '通过邮箱验证码修改登录密码',
          onTap: _openPassword,
          style: t,
        ),
      ],
    );
  }

  /// 视图 password。
  Widget _buildPassword(AylaTextStyles t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: AylaSpacing.sp3,
      children: <Widget>[
        _hint(
          t,
          '验证码将发送至',
          suffix: widget.boundEmail.isNotEmpty
              ? ' ${widget.boundEmail}'
              : '你当前绑定的邮箱',
        ),
        if (_error != null) _errorBox(t, _error!),
        _CodeRow(
          controller: _code,
          placeholder: '6 位验证码',
          buttonLabel: _sendLabel,
          buttonEnabled: !_sending &&
              _countdown == 0 &&
              widget.boundEmail.isNotEmpty, // !boundEmail 时禁用
          onSend: () => _sendCodeTo(widget.boundEmail),
          onChanged: () => setState(() {}),
          style: t,
        ),
        _LabeledField(
          label: '新密码（至少 8 位）',
          controller: _password,
          obscure: true,
          autofill: 'new-password',
          style: t,
        ),
        _LabeledField(
          label: '确认新密码',
          controller: _confirm,
          obscure: true,
          autofill: 'new-password',
          style: t,
        ),
        _SubmitButton(
          label: _submitting ? '提交中…' : '确认修改',
          enabled: !_submitting,
          onTap: _submitPassword,
        ),
      ],
    );
  }

  /// 换绑 step1（验证当前邮箱）。
  Widget _buildEmailStep1(AylaTextStyles t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: AylaSpacing.sp3,
      children: <Widget>[
        _hint(t, '第一步：验证当前邮箱 ', strong: widget.boundEmail),
        if (_error != null) _errorBox(t, _error!),
        _CodeRow(
          controller: _curCode,
          placeholder: '6 位验证码',
          buttonLabel: _sendLabel,
          buttonEnabled: !_sending && _countdown == 0,
          onSend: () => _sendCodeTo(widget.boundEmail),
          // 必须回传：`下一步` 的 enabled 依赖 `_curCode.text`，
          // 不重建则输入后按钮仍禁用（实测）
          onChanged: () => setState(() {}),
          style: t,
        ),
        _SubmitButton(
          label: '下一步',
          // disabled={!/^\d{6}$/.test(curCode.trim())}
          enabled: RegExp(r'^\d{6}$').hasMatch(_curCode.text.trim()),
          onTap: () async {
            setState(() {
              _error = null;
              _emailStep = 2;
            });
          },
        ),
      ],
    );
  }

  /// 换绑 step2（新邮箱 + 验证码）。
  Widget _buildEmailStep2(AylaTextStyles t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: AylaSpacing.sp3,
      children: <Widget>[
        _hint(t, '第二步：验证新邮箱'),
        if (_error != null) _errorBox(t, _error!),
        _LabeledField(
          label: '新邮箱',
          controller: _newEmail,
          placeholder: '用于接收验证码的新邮箱',
          autofill: 'email',
          // 输入变化需重建：发码按钮的禁用条件含 `!newEmail.trim()`
          onChanged: () => setState(() {}),
          style: t,
        ),
        _CodeRow(
          controller: _newCode,
          placeholder: '新邮箱 6 位验证码',
          buttonLabel: _sendLabel,
          // 另加 `!newEmail.trim()` 禁用条件
          buttonEnabled:
              !_sending && _countdown == 0 && _newEmail.text.trim().isNotEmpty,
          onSend: () => _sendCodeTo(_newEmail.text),
          onChanged: () => setState(() {}),
          style: t,
        ),
        _SubmitButton(
          label: _submitting ? '提交中…' : '确认换绑',
          enabled: !_submitting,
          onTap: _submitEmail,
        ),
      ],
    );
  }

  /// 视图 done。
  Widget _buildDone(AylaTextStyles t) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AylaSpacing.sp8), // sp8
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        spacing: AylaSpacing.sp3,
        children: <Widget>[
          const Text(
            '✓',
            style: TextStyle(fontSize: 32, color: AylaColors.success), // 32px success
          ),
          Text(
            _doneMsg,
            textAlign: TextAlign.center,
            style: t.label.copyWith(
              fontSize: 15, // font-size: 15px
              fontWeight: FontWeight.w700,
              color: AylaColors.textPrimary,
            ),
          ),
          _SubmitButton(label: '完成', enabled: true, onTap: () async => _close()),
        ],
      ),
    );
  }

  /// 发码按钮文案（tsx：sending → 发送中…；countdown>0 → 重新发送（Ns）；else 发送验证码）。
  String get _sendLabel {
    if (_sending) return '发送中…';
    if (_countdown > 0) return '重新发送（${_countdown}s）';
    return '发送验证码';
  }

  /// `.privacy-sheet-hint`（13px secondary；strong → indigo-700 700）。
  Widget _hint(AylaTextStyles t, String text, {String? strong, String? suffix}) {
    return Text.rich(
      TextSpan(
        style: t.caption.copyWith(
          fontSize: 13,
          color: AylaColors.textSecondary,
        ),
        children: <InlineSpan>[
          TextSpan(text: text),
          if (strong != null)
            TextSpan(
              text: strong,
              style: const TextStyle(
                color: AylaColors.indigo700, // --indigo-700
                fontWeight: FontWeight.w700,
              ),
            ),
          if (suffix != null) TextSpan(text: suffix),
        ],
      ),
    );
  }

  /// `.auth-error`（role=alert）。
  Widget _errorBox(AylaTextStyles t, String msg) {
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AylaSpacing.sp3, // padding: sp2 sp3
          vertical: AylaSpacing.sp2,
        ),
        decoration: BoxDecoration(
          color: const Color(0x1AD64D6E), // rgba(214,77,110,.1)
          border: Border.all(color: const Color(0x59D64D6E)), // rgba(...,.35)
          borderRadius: BorderRadius.circular(AylaRadii.rInput),
        ),
        child: Text(
          msg,
          style: t.caption.copyWith(fontSize: 13, color: AylaColors.destructive),
        ),
      ),
    );
  }
}

/// ESC 关闭意图。
class _CloseIntent extends Intent {
  const _CloseIntent();
}

/// `.privacy-menu-item` —— 菜单项（标题 15/700 indigo + 描述 12 secondary）。
class _MenuItem extends StatefulWidget {
  const _MenuItem({
    required this.title,
    required this.desc,
    required this.onTap,
    required this.style,
  });

  final String title;
  final String desc;
  final VoidCallback onTap;
  final AylaTextStyles style;

  @override
  State<_MenuItem> createState() => _MenuItemState();
}

class _MenuItemState extends State<_MenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AylaDurations.fast, // transition background 180ms
          curve: AylaCurves.easeOut,
          width: double.infinity, // width: 100%
          padding: const EdgeInsets.symmetric(
            horizontal: AylaSpacing.sp2, // padding: sp3 sp2
            vertical: AylaSpacing.sp3,
          ),
          decoration: BoxDecoration(
            // :hover → rgba(157,191,230,.2)
            // 零透明用**同色相**（`Colors.transparent` 是透明黑，插值中途会闪灰）
            color: _hovered
                ? AylaColors.ice500.withValues(alpha: 0.2)
                : AylaColors.ice500.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(AylaRadii.rInput),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2, // gap: 2px
            children: <Widget>[
              Text(
                widget.title,
                style: widget.style.label.copyWith(
                  fontSize: 15, // font-size: 15px
                  fontWeight: FontWeight.w700,
                  color: AylaColors.indigo700, // --indigo-700
                ),
              ),
              Text(
                widget.desc,
                style: widget.style.caption.copyWith(
                  fontSize: 12, // font-size: 12px
                  color: AylaColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `.auth-code-row` —— 验证码输入 + 发码按钮并排。
///
/// **复用组件库**：[GlassInput]（`.field` 输入框）+ [GlassButton]（`.btn-ghost`）。
/// 本类只负责「并排 + 数值输入约束」的编排，不重复实现输入框/按钮样式。
class _CodeRow extends StatelessWidget {
  const _CodeRow({
    required this.controller,
    required this.placeholder,
    required this.buttonLabel,
    required this.buttonEnabled,
    required this.onSend,
    required this.style,
    this.onChanged,
  });

  final TextEditingController controller;
  final String placeholder;
  final String buttonLabel;
  final bool buttonEnabled;
  final VoidCallback onSend;
  final AylaTextStyles style;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      spacing: AylaSpacing.sp2, // `.auth-code-row` 并排
      children: <Widget>[
        Expanded(
          child: GlassInput(
            controller: controller,
            hintText: placeholder,
            minHeight: 44,
            onGlassBorder: true, // `.auth-card .field` 在卡内用 indigo 描边
            // `inputMode="numeric"` + `maxLength={6}` + 过滤非数字
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
            ],
            onChanged: (_) => onChanged?.call(),
            textStyle: style.body.copyWith(color: AylaColors.textPrimary),
          ),
        ),
        GlassButton(
          label: buttonLabel,
          variant: GlassButtonVariant.ghost,
          minHeight: 44,
          onPressed: buttonEnabled ? onSend : null,
        ),
      ],
    );
  }
}

/// `.auth-field` 标签 + [GlassInput] 的组合（label 在上、输入框在下）。
///
/// **复用组件库**：输入框本体用 [GlassInput]；本类只加 `.auth-field` 的
/// label 排版（`flex column; gap: sp2; 14/700; ls .2`）。
class _LabeledField extends StatelessWidget {
  const _LabeledField({
    required this.label,
    required this.controller,
    required this.style,
    this.placeholder,
    this.obscure = false,
    this.autofill,
    this.onChanged,
  });

  final String label;
  final TextEditingController controller;
  final AylaTextStyles style;
  final String? placeholder;
  final bool obscure;
  final String? autofill;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AylaSpacing.sp2, // gap: var(--sp-2)
      children: <Widget>[
        Text(
          label,
          style: style.label.copyWith(
            fontSize: 14, // font-size: 14px
            fontWeight: FontWeight.w700, // font-weight: 700
            letterSpacing: 0.2, // letter-spacing: 0.2px
            color: AylaColors.textPrimary,
          ),
        ),
        GlassInput(
          controller: controller,
          hintText: placeholder,
          obscureText: obscure,
          minHeight: 44, // `.auth-field .field { min-height: 44px }`
          onGlassBorder: true, // 认证上下文描边
          autofillHints: autofill == null ? null : <String>[autofill!],
          onChanged: (_) => onChanged?.call(),
          textStyle: style.body.copyWith(color: AylaColors.textPrimary),
        ),
      ],
    );
  }
}

/// `.btn.btn-primary.privacy-sheet-submit`（满宽 + margin-top sp1）。
///
/// **复用组件库**：[GlassButton]（primary）；本类只补 `.privacy-sheet-submit`
/// 的 `width:100%` 与 `margin-top: var(--sp-1)`。
class _SubmitButton extends StatelessWidget {
  const _SubmitButton({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool enabled;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AylaSpacing.sp1), // margin-top: sp1
      child: GlassButton(
        label: label,
        variant: GlassButtonVariant.primary,
        minHeight: 44, // min-height: 44px
        expand: true, // width: 100%
        onPressed: enabled ? () => onTap() : null,
      ),
    );
  }
}

// ======================= 预览 =======================

/// 隐私设置弹窗四视图（menu / password / email step1 / email step2 / done）。
@Preview(
  group: 'Widgets',
  name: 'PrivacySheet（menu/改密/换绑两步/done）',
  size: Size(1040, 560),
  wrapper: previewTheme,
)
Widget previewPrivacySheet() {
  Widget frame(String label, Widget child) => SizedBox(
        width: 320,
        height: 500,
        child: Stack(
          children: <Widget>[
            child,
            Positioned(
              left: 0,
              bottom: 0,
              child: Text(label, style: const TextStyle(fontSize: 11)),
            ),
          ],
        ),
      );

  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp4),
    child: Row(
      children: <Widget>[
        frame('menu（已绑定邮箱）', PrivacySheet(
          onClose: () {}, boundEmail: 'ayla@example.com')),
        const SizedBox(width: AylaSpacing.sp3),
        frame('menu（未绑定 → 跳过 step1）', PrivacySheet(
          onClose: () {}, boundEmail: '')),
        const SizedBox(width: AylaSpacing.sp3),
        frame('done 视图（需交互进入；此预览为 menu）', PrivacySheet(
          onClose: () {}, boundEmail: 'ayla@example.com')),
      ],
    ),
  );
}
