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
///
/// ## 「记住密码 / 自动登录」两个开关（**新增功能，web 端没有** —— 2026-10-01）
/// `LoginPage.tsx` 全 95 行已核：web 侧无这两个控件 ⇒ 本件是**新增**而非复刻。
/// 但视觉/交互一律沿用本项目既有规范，**不新造颜色与尺寸**，复刻源 = 既有组件在 web 里的原始规格：
/// - 复选框本体 = `AylaCheckbox`（16×16 + `accent-color`；规格源
///   `web/src/styles/app.css:161–167` 的 `.visibility-selector-options input[type="checkbox"]`）
///   —— **两者根同名同规格同语义**（同为 label 内复选框，`app.css:117–133` 同规格）⇒ 复用即成；
/// - 选项 = 复选框 + label，label 走 [AylaTextStyles.label]（14 / w700 / ls .2 / --text-primary，
///   等价 `web/src/styles/auth.css:64–72` 的 `.auth-field` 那两行）；
/// - 选项 `min-height: 40px`（`app.css:117–133` 的 label 可达性规格）、行内 gap `sp2`
///   （同 .auth-field 的 `gap: var(--sp-2)`）；
/// - **两个选项排在同一行**（2026-10-01 用户要求），选项间 `gap: var(--sp-2)` ——
///   依据 = web 里「一排可勾选项」的既有规格 `app.css:111–115` 的
///   `.visibility-selector-options { display: flex; flex-wrap: wrap; gap: var(--sp-2) }`
///   （该容器装的正是与这里同规格的 label 内复选框）；整体与表单同拍，
///   上下仍各留 `.auth-form { gap: var(--sp-4) }`（`auth.css:63`）。
///   `flex-wrap` ⇒ Flutter 等价物是 [Wrap]（**内容宽 + 放不下折行**，不是 `Expanded` 等分）。
/// 交互：整行挂**一次**手势（web 是 `<label>` 包住控件 ⇒ 点整行与点控件是同一次切换；
/// Flutter 双侧挂手势会各触发一次）；键盘可达（Focus + Enter/Space）；
/// focus 环 = `base.css:365–370` 的 `:focus-visible { outline: var(--focus-ring); outline-offset: 2px }`
/// （等价写法照抄 `widgets/base/switch.dart`）。
/// 联动：勾「自动登录」⇒ 同时勾上「记住密码」；取消「记住密码」⇒ 自动登录一并取消
/// （见 [AylaAuthOptions]，**只写这一处**；本页只持受控 state 并回调）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../widgets/base/checkbox.dart';
import '../theme/css_gradient.dart';
import '../theme/glass.dart';
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
    this.rememberPassword = false,
    this.autoLogin = false,
    this.onRememberChanged,
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

  /// 「记住密码」初始勾选态（受控：本地 state 初值取它）。
  final bool rememberPassword;

  /// 「自动登录」初始勾选态（受控：本地 state 初值取它）。
  final bool autoLogin;

  /// 每次勾选变化即回调（remember, auto）。
  ///
  /// ⚠️ 勾选态**不走** [onSubmit] —— 那里只有 username/password，签名与语义保持不变，
  /// 既有调用方/测试零破坏。
  final void Function(bool remember, bool auto)? onRememberChanged;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final TextEditingController _username =
      TextEditingController(text: widget.initialUsername);
  late final TextEditingController _password =
      TextEditingController(text: widget.initialPassword);

  /// 用户是否已改动过对应输入框（`true` ⇒ 外部后到的初值**不覆盖**用户输入）。
  bool _usernameEdited = false;
  bool _passwordEdited = false;

  /// 程序上一次写入控制器的文本 —— 用来把「外部回填」与「用户输入」区分开。
  late String _usernameWritten = widget.initialUsername;
  late String _passwordWritten = widget.initialPassword;

  /// 「记住密码 / 自动登录」受控态（初值取 widget 传参；联动由 [AylaAuthOptions] 唯一负责）。
  late bool _remember = widget.rememberPassword;
  late bool _auto = widget.autoLogin;

  /// 用户是否手动点过这两个开关（点过则以用户为准，不被外部回填撤销）。
  bool _authOptionsTouched = false;

  @override
  void initState() {
    super.initState();
    _username.addListener(_onUsernameChanged);
    _password.addListener(_onPasswordChanged);
  }

  /// 控制器内容变了：与「程序上次写入的值」不同 ⇒ 判定为用户输入。
  void _onUsernameChanged() {
    if (_username.text == _usernameWritten) return;
    _usernameWritten = _username.text;
    _usernameEdited = true;
  }

  void _onPasswordChanged() {
    if (_password.text == _passwordWritten) return;
    _passwordWritten = _password.text;
    _passwordEdited = true;
  }

  /// 把外部后到的初值写进输入框（仅在用户未改动过该框、且值确实不同时），光标移到末尾。
  ///
  /// 存在的原因：勾了「记住密码」后凭据来自安全存储（**异步读盘**），
  /// `initialUsername` / `initialPassword` 会在本页挂载**之后**才从空串变成真实值 ——
  /// 只初始化一次的 `late final` 控制器收不到，用户就得重新输一遍。
  void _adoptUsername() {
    final String value = widget.initialUsername;
    if (_usernameEdited || _username.text == value) return;
    _username.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _usernameWritten = value;
  }

  void _adoptPassword() {
    final String value = widget.initialPassword;
    if (_passwordEdited || _password.text == value) return;
    _password.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _passwordWritten = value;
  }

  @override
  void didUpdateWidget(covariant LoginPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // ① 凭据回填（异步读盘完成后到达）。只在用户尚未改动过该框时同步 —— 绝不覆盖用户输入。
    if (oldWidget.initialUsername != widget.initialUsername) _adoptUsername();
    if (oldWidget.initialPassword != widget.initialPassword) _adoptPassword();
    // ② 勾选态同步：外部只在首帧附近更新一次（读盘完成）；用户已手动点过则以用户为准。
    if (!_authOptionsTouched) {
      final bool remember = widget.rememberPassword;
      final bool auto = widget.autoLogin && remember; // 「两个一定同时开」不变量
      if (remember != _remember || auto != _auto) {
        // didUpdateWidget 之后框架必然重建 ⇒ 直接赋值即可，无需 setState。
        _remember = remember;
        _auto = auto;
      }
    }
  }

  @override
  void dispose() {
    _username.removeListener(_onUsernameChanged);
    _password.removeListener(_onPasswordChanged);
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  /// 勾选变化落地（联动已由 [AylaAuthOptions] 算好，本页只持态 + 对外回调）。
  void _onAuthOptionsChanged(bool remember, bool auto) {
    if (remember == _remember && auto == _auto) return;
    _authOptionsTouched = true;
    setState(() {
      _remember = remember;
      _auto = auto;
    });
    widget.onRememberChanged?.call(remember, auto);
  }

  void _submit() {
    widget.onSubmit?.call(_username.text.trim(), _password.text);
  }

  @override
  Widget build(BuildContext context) {
    final Size viewport = MediaQuery.sizeOf(context);
    final bool wide = viewport.width > AylaBreakpoints.sm; // >768 宽屏分栏
    final bool compact =
        viewport.width <= 480 || viewport.height <= 700; // 窄/短屏收紧

    final EdgeInsets pagePadding = EdgeInsets.symmetric(
      horizontal: compact ? AylaSpacing.sp4 : AylaSpacing.sp6,
      vertical: compact ? AylaSpacing.sp4 : AylaSpacing.sp8,
    );

    final Widget card = _AuthCard(
      compact: compact,
      wide: wide,
      username: _username,
      password: _password,
      submitting: widget.submitting,
      errorText: widget.errorText,
      onSubmit: _submit,
      onGoRegister: widget.onGoRegister,
      remember: _remember,
      auto: _auto,
      onAuthOptionsChanged: _onAuthOptionsChanged,
    );

    if (wide) {
      // ⚠️ 宽屏布局 = web `auth.css:126–148` 的**逐条等价**（2026-09-28 两轮用户反馈后定稿）：
      //
      // · `.auth-page { flex-direction: row; justify-content: center; align-items: safe center;
      //   padding: sp8 sp6; overflow-y: auto }` ⇒ **整页**是滚动容器
      //   （覆盖层细滚动条因此落在**视口右缘**，而不是卡片右侧 —— 用户截图点名的那条）；
      // · `.auth-intro { flex: 0 1 420px / ≥1024 460px; align-self: flex-start;
      //   position: sticky; top: 50dvh; translate: 0 -50% }` ⇒ 左栏**钉在视口垂直中点**、不随滚动；
      // · `.auth-card { width: min(440px, 100%); margin-block: auto }`；gap `clamp(48px, 6vw, 96px)`。
      //
      // Flutter 无 sticky ⇒ 用**两层**表达（视觉等价，且滚动容器仍是整页）：
      //   ① 滚动层：左栏只留**同宽占位**，真身不在这里；
      //   ② 固定层：左栏钉在视口垂直中点（`Positioned(top:0,bottom:0)` + `Center`）。
      final double gap = (viewport.width * 0.06).clamp(48.0, 96.0); // gap: clamp(48px, 6vw, 96px)
      final double introWidth = viewport.width >= AylaBreakpoints.md ? 460 : 420;
      return LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          final double available = c.maxWidth - pagePadding.horizontal;
          final double cardWidth =
              math.min(440.0, math.max(0.0, available - introWidth - gap));
          final double contentWidth = introWidth + gap + cardWidth;
          final double contentLeft =
              pagePadding.left + (available - contentWidth) / 2;
          return Stack(
            children: <Widget>[
              // ① 整页滚动（`.auth-page { overflow-y: auto }`）
              SingleChildScrollView(
                padding: pagePadding,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: viewport.height - pagePadding.vertical,
                  ),
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      // `.auth-intro { align-self: flex-start }` 的交叉轴语义
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SizedBox(width: introWidth), // 左栏占位（真身在 ②）
                        SizedBox(width: gap),
                        SizedBox(width: cardWidth, child: card),
                      ],
                    ),
                  ),
                ),
              ),
              // ② 左栏固定层（sticky `top: 50dvh` + `translate: 0 -50%` 的视觉等价）
              Positioned(
                left: contentLeft,
                top: 0,
                bottom: 0,
                width: introWidth,
                child: const Center(child: AylaAuthIntro()),
              ),
            ],
          );
        },
      );
    }

    // 窄屏（≤768）：`.auth-intro { display: none }` + 整页可滚的居中单卡
    // （`.auth-page { overflow-y: auto; align-items: safe center; justify-content: center }`）
    return SingleChildScrollView(
      padding: pagePadding,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: viewport.height - pagePadding.vertical,
        ),
        child: Center(child: card),
      ),
    );
  }
}

/// 左栏品牌介绍区（仅宽屏显示；内容照抄 web 原文含占位文案）。
///
/// **2026-09-28 提升为可复用件**：`RegisterPage.tsx:92–105` 与 `LoginPage.tsx:38–51`
/// 是**逐字相同**的一份 DOM（web 两页各写一遍）⇒ Flutter 侧不再复制第二份。
/// 内部仍用同文件的私有 `_GradientText` / `_IntroFeature`。
class AylaAuthIntro extends StatelessWidget {
  const AylaAuthIntro({super.key});

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool showFeatures =
        MediaQuery.sizeOf(context).width >= AylaBreakpoints.md; // ≥1024 才显示
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
    required this.remember,
    required this.auto,
    required this.onAuthOptionsChanged,
  });

  final bool compact;
  final bool wide;
  final TextEditingController username;
  final TextEditingController password;
  final bool submitting;
  final String? errorText;
  final VoidCallback onSubmit;
  final VoidCallback? onGoRegister;

  /// 「记住密码」当前勾选态。
  final bool remember;

  /// 「自动登录」当前勾选态。
  final bool auto;

  /// 勾选变化（已由 [AylaAuthOptions] 完成联动计算）。
  final void Function(bool remember, bool auto) onAuthOptionsChanged;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440), // width: min(440px,100%)
      child: AylaGlassCard(
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
            // 「记住密码 / 自动登录」（**新增功能，web 无对应**）：**同一行**的两个选项。
            // 上下间距沿用 `.auth-form { gap: var(--sp-4) }`（auth.css:63）——
            // 与表单里其它行同拍：字段本身已含 label 的 sp2 内距，故本块前仍是 sp4。
            AylaAuthOptions(
              remember: remember,
              auto: auto,
              onChanged: onAuthOptionsChanged,
            ),
            const SizedBox(height: AylaSpacing.sp4),
            // .auth-submit：满宽 44 高 + margin-top sp1
            Padding(
              padding: const EdgeInsets.only(top: AylaSpacing.sp1),
              child: AylaGlassButton(
                label: submitting ? '登录中…' : '登录',
                variant: AylaGlassButtonVariant.glow,
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
                  AylaGlassButton(
                    label: '注册',
                    variant: AylaGlassButtonVariant.ghost,
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
        AylaGlassInput(
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

/// 「记住密码」整行锚点（测试用；与 web 的 `<label>` 转发语义同构）。
const Key kAylaAuthRememberRowKey = Key('aylaAuthRememberRow');

/// 「自动登录」整行锚点。
const Key kAylaAuthAutoRowKey = Key('aylaAuthAutoRow');

/// 「记住密码」focus 环锚点（仅聚焦时存在）。
const Key kAylaAuthRememberFocusRingKey = Key('aylaAuthRememberFocusRing');

/// 「自动登录」focus 环锚点（仅聚焦时存在）。
const Key kAylaAuthAutoFocusRingKey = Key('aylaAuthAutoFocusRing');

/// 「记住密码 / 自动登录」开关（**同一行**两个选项；**新增功能：web `LoginPage.tsx` 全 95 行无对应控件**，2026-10-01）。
///
/// ## 规格来源（全部取自既有件与既有 web 规格，**不新造颜色/尺寸**）
/// - 复选框本体 = [AylaCheckbox]（16×16 + 选中 `--glow-500` 实底白勾）；规格源
///   `web/src/styles/app.css:161–167` 的 `.visibility-selector-options input[type="checkbox"]`
///   —— **两者根同名同规格同语义**（同为 `<label>` 内复选框，且共用 `app.css:117–133` 的行规格）
///   ⇒ 复用即成件，不新造第二份；
/// - 选项 = 复选框 + label（gap `--sp-2`，同 `.auth-field { gap: var(--sp-2) }`），
///   label 走 [AylaTextStyles.label]（14 / w700 / ls .2 / `--text-primary`，
///   等价 `web/src/styles/auth.css:64–72` 的 `.auth-field` 那两行）；
/// - 选项 `min-height: 40px`（`app.css:117–133` 的 label 可达性规格）；
/// - **两个选项排在同一行**（2026-10-01 用户要求），选项间 `gap: var(--sp-2)` ——
///   依据 = web 里「一排可勾选项」的既有规格 `app.css:111–115` 的
///   `.visibility-selector-options { display:flex; flex-wrap:wrap; gap: var(--sp-2) }`
///   （该容器装的正是与这里同规格的 label 内复选框）；整体与表单同拍，
///   上下仍各留 `--sp-4`（`.auth-form { gap: var(--sp-4) }`，`auth.css:63`）；
///   `flex-wrap` ⇒ Flutter 等价物是 [Wrap]（**内容宽 + 放不下折行**，不是 `Expanded` 等分）。
/// - `:focus-visible` ⇒ `base.css:365–370` 的 `outline: var(--focus-ring); outline-offset: 2px`
///   （等价写法照抄 `widgets/base/switch.dart`：环外扩 4、不吃指针、不参与布局）。
///
/// ## 联动（**只写这一处**：[AylaAuthOptions.resolve]）
/// - 勾「自动登录」⇒ 同时把「记住密码」勾上（**自动登录必然同时记住密码**），auto 取反；
/// - 取消「记住密码」⇒ 自动登录一并取消（**两个一定同时开**）；
/// - 只勾「记住密码」⇒ 只影响自己。
///
/// ## 禁用视觉（「记住密码」未勾时的自动登录行）
/// 不变量是 `auto ⇒ remember`：auto 为真时 remember 必为真 ⇒ **从不写入** `auto=true, remember=false`
/// 这种组合，视觉上就近表达为 `AylaCheckbox(checked: false)` + 文案转 [AylaColors.textSecondary]。
/// ⚠️ **这一档仍可点**：点了会按联动规则把「记住密码」一并打开（最终两个都勾）——
/// 所以行语义的 `enabled` **不置 false**（置 false 等于对无障碍宣称「不可激活」，与真实行为不符）。
/// **已勾选时不禁用** —— 用户可以单独取消自动登录（结果 = remember 仍勾、auto 取消）。
///
/// ## 交互（label 转发语义）
/// web 的 `<label>` 包住控件 ⇒ 点整行与点控件是**同一次**切换。Flutter 两侧都挂手势会各触发一次
/// ⇒ 本件**整行只挂一次手势**，复选框本体不挂手势（键盘 Enter/Space 留在行上）。
class AylaAuthOptions extends StatelessWidget {
  const AylaAuthOptions({
    super.key,
    required this.remember,
    required this.auto,
    required this.onChanged,
  });

  /// 「记住密码」勾选态。
  final bool remember;

  /// 「自动登录」勾选态。
  final bool auto;

  /// 勾选变化：参数是**联动计算后**的最终值 `(remember, auto)`；null ⇒ 两行都走禁用档。
  final void Function(bool remember, bool auto)? onChanged;

  /// 联动规则的**唯一实现**（两个入口都调它，规则不复制）。
  ///
  /// [tapAuto] `true` = 点的「自动登录」，`false` = 点的「记住密码」。
  static (bool, bool) resolve({
    required bool remember,
    required bool auto,
    required bool tapAuto,
  }) {
    if (tapAuto) return (true, !auto); // 自动登录 ⇒ 记住密码同时开，auto 取反
    if (remember) return (false, false); // 取消记住密码 ⇒ 自动登录一并取消
    return (true, auto); // 勾上记住密码 ⇒ 只影响自己
  }

  /// 点某一行的最终值（按 [resolve] 计算，供调用方/测试复用同一处规则）。
  (bool, bool) onRowTap({required bool tapAuto}) => resolve(
    remember: remember,
    auto: auto,
    tapAuto: tapAuto,
  );

  /// 两个选项之间的间距（同时是横向 gap 与折行后的行距）—— `app.css:111–115` 的
  /// `.visibility-selector-options { gap: var(--sp-2) }`（CSS 的 `gap` 在两个方向都生效）。
  static const double optionGap = AylaSpacing.sp2;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onChanged != null;

    // ⚠️ 用 [Wrap] 而不是 Row/Expanded：web 的 `.visibility-selector-options` 是
    // `display:flex; flex-wrap:wrap` + 子项 `display:inline-flex`（**内容宽**）
    // ⇒ 等价物是「内容宽 + 放不下折行」的 Wrap；用 `Expanded` 会强行等分、
    // 与 web 语义不符，窄卡上还会把文案压成省略号（库级踩坑：flex:1 1 0 ≠ Expanded）。
    return Wrap(
      spacing: optionGap,
      runSpacing: optionGap,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        _AylaAuthOptionRow(
          key: kAylaAuthRememberRowKey,
          label: '记住密码',
          checked: remember,
          focusRingKey: kAylaAuthRememberFocusRingKey,
          onTap: enabled
              ? () {
                  final (bool r, bool a) = onRowTap(tapAuto: false);
                  onChanged!(r, a);
                }
              : null,
        ),
        _AylaAuthOptionRow(
          key: kAylaAuthAutoRowKey,
          label: '自动登录',
          checked: remember && auto,
          // 记住密码未勾 ⇒ 禁用视觉（灰色文案 + 未勾复选框），但**仍可点**：
          // 点了会按 [resolve] 把「记住密码」一并打开（最终两个都勾）。
          dimmed: !remember,
          focusRingKey: kAylaAuthAutoFocusRingKey,
          onTap: enabled
              ? () {
                  final (bool r, bool a) = onRowTap(tapAuto: true);
                  onChanged!(r, a);
                }
              : null,
        ),
      ],
    );
  }
}

/// 单行（复选框 + 文案）：整行一次手势 + 键盘 Enter/Space + focus 环。
class _AylaAuthOptionRow extends StatefulWidget {
  const _AylaAuthOptionRow({
    super.key,
    required this.label,
    required this.checked,
    required this.onTap,
    required this.focusRingKey,
    this.dimmed = false,
  });

  /// 文案（「记住密码」/「自动登录」；同时就是该行的无障碍名称）。
  final String label;

  /// 勾选态。
  final bool checked;

  /// 整行点击；null ⇒ 两行都走禁用档（`onChanged == null` 时）。
  final VoidCallback? onTap;

  /// **禁用视觉**（「记住密码」未勾时的自动登录行）：文案转次要色。
  ///
  /// ⚠️ 只是视觉 —— 该行**仍可点**（点了会按联动规则把「记住密码」一并打开），
  /// 因此不改变语义里的 `enabled`。
  final bool dimmed;

  /// focus 环锚点（仅聚焦时存在）。
  final Key focusRingKey;

  @override
  State<_AylaAuthOptionRow> createState() => _AylaAuthOptionRowState();
}

class _AylaAuthOptionRowState extends State<_AylaAuthOptionRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool enabled = widget.onTap != null;
    final bool disabledLook = !enabled || widget.dimmed; // 视觉降档（不等同于不可点）

    Widget body = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 40), // app.css:117–133
      // ⚠️ `mainAxisSize: min` + 不用 `Expanded`：本件现在由 [Wrap] 排布，
      // Wrap 给的是**松约束**，`Expanded` 在这里拿不到有界宽度（会直接报错）。
      // 内容宽也正是 web 的语义（`.visibility-selector-options label { display:inline-flex }`）。
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // input[type=checkbox]：本体不挂手势（整行只挂一次，见 [AylaAuthOptions] 库头）。
          AylaCheckbox(checked: widget.checked),
          const SizedBox(width: AylaSpacing.sp2), // gap: var(--sp-2)
          Text(
            widget.label,
            style: t.label.copyWith(
              // 禁用视觉 = 文案降为次要色（同 switch.dart 的「按颜色降透」口径，而非整层 Opacity）
              color: disabledLook
                  ? AylaColors.textSecondary
                  : AylaColors.textPrimary,
            ),
          ),
        ],
      ),
    );

    // :focus-visible { outline: var(--focus-ring); outline-offset: 2px }
    // outline 2px + offset 2 ⇒ 外扩 4；环不吃指针、不参与布局（库内约定，同 switch.dart）。
    if (_focused && enabled) {
      body = Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned(
            key: widget.focusRingKey,
            left: -4,
            top: -4,
            right: -4,
            bottom: -4,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: AylaColors.glow500, width: 2),
                  borderRadius: BorderRadius.circular(AylaRadii.rSm + 2),
                ),
              ),
            ),
          ),
          body,
        ],
      );
    }

    // 整行挂**一次**手势；语义（checked/disabled）落在行上，label 由行内文本提供
    //（与 switch.dart 同款：Semantics 不设 container ⇒ 与文本合并为同一节点）。
    return Semantics(
      checked: widget.checked,
      enabled: enabled,
      child: Focus(
        canRequestFocus: enabled,
        onFocusChange: (bool has) => setState(() => _focused = has),
        onKeyEvent: (FocusNode node, KeyEvent event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final bool activate =
              event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.space;
          if (!activate || !enabled) return KeyEventResult.ignored;
          widget.onTap!();
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          cursor: enabled
              ? SystemMouseCursors.click // web label { cursor: pointer }
              : SystemMouseCursors.basic,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: body,
          ),
        ),
      ),
    );
  }
}

// ======================= 样张 =======================

/// [AylaAuthOptions] 的画布样张入口（组件画布 `_Section` 的唯一来源）。
///
/// 四档状态（**在画布里一眼看全**，各档可点，点了看联动是否与规则一致）：
/// ① 都不勾（自动登录选项 = 禁用视觉）② 只勾记住密码 ③ 都勾 ④ 已勾自动登录后取消记住密码
/// ⇒ 自动登录**随之取消**（不变量 `auto ⇒ remember`）。
///
/// ⚠️ 样张只用**纯色/现有件**，不放新的玻璃卡或 `BackdropFilter` ——
/// 画布的离屏层预算（`test/perf_audit_test.dart` 的 `kMaxBackdropPerCategory`）是硬锁。
Widget aylaAuthOptionsSamples() => const _AuthOptionsSamples();

class _AuthOptionsSamples extends StatelessWidget {
  const _AuthOptionsSamples();

  /// `.auth-card` 的卡内宽度：`width: min(440px, 100%)` − 左右 padding `sp8` = **376**
  /// （`auth.css` 的 .auth-card 与 `.auth-field` 实际排布宽度；禁用视觉与行高按此对账）。
  static const double _cardInnerWidth = 376;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('① 都不勾（自动登录行 = 禁用视觉）', style: t.body),
        const SizedBox(height: AylaSpacing.sp3),
        SizedBox(
          width: _cardInnerWidth,
          child: AylaAuthOptions(
            remember: false,
            auto: false,
            onChanged: (bool r, bool a) {},
          ),
        ),
        const SizedBox(height: AylaSpacing.sp6),
        Text('② 只勾记住密码（自动登录未勾 ⇒ 仍是禁用视觉）', style: t.body),
        const SizedBox(height: AylaSpacing.sp3),
        SizedBox(
          width: _cardInnerWidth,
          child: AylaAuthOptions(
            remember: true,
            auto: false,
            onChanged: (bool r, bool a) {},
          ),
        ),
        const SizedBox(height: AylaSpacing.sp6),
        Text('③ 都勾（自动登录可用态）', style: t.body),
        const SizedBox(height: AylaSpacing.sp3),
        SizedBox(
          width: _cardInnerWidth,
          child: AylaAuthOptions(
            remember: true,
            auto: true,
            onChanged: (bool r, bool a) {},
          ),
        ),
        const SizedBox(height: AylaSpacing.sp6),
        Text('④ 点一下看联动（可交互）：勾「自动登录」⇒ 记住密码同时勾；取消「记住密码」⇒ 自动登录一并取消',
            style: t.body),
        const SizedBox(height: AylaSpacing.sp3),
        const SizedBox(width: _cardInnerWidth, child: _AuthOptionsLiveDemo()),
        const SizedBox(height: AylaSpacing.sp6),
        Text('⑤ 禁用档（onChanged: null ⇒ 两行都不可点）', style: t.body),
        const SizedBox(height: AylaSpacing.sp3),
        const SizedBox(
          width: _cardInnerWidth,
          child: AylaAuthOptions(remember: false, auto: false, onChanged: null),
        ),
      ],
    );
  }
}

/// 可交互档：内部持态，直接复用 [AylaAuthOptions] 的联动规则（规则只写一处）。
class _AuthOptionsLiveDemo extends StatefulWidget {
  const _AuthOptionsLiveDemo();

  @override
  State<_AuthOptionsLiveDemo> createState() => _AuthOptionsLiveDemoState();
}

class _AuthOptionsLiveDemoState extends State<_AuthOptionsLiveDemo> {
  bool _remember = false;
  bool _auto = false;

  @override
  Widget build(BuildContext context) {
    return AylaAuthOptions(
      remember: _remember,
      auto: _auto,
      onChanged: (bool remember, bool auto) => setState(() {
        _remember = remember;
        _auto = auto;
      }),
    );
  }
}
