/// 玻璃基类：GlassSurface / GlassCard / GlassButton / GlassInput（全站单材料 owner）。
///
/// 事实源（逐条对应 web CSS，禁自由发挥）：
/// - 材料：`tokens.css` `--glass-bg`(.55) / `--glass-bg-strong`(.78) /
///   `--glass-border`(白 .65) / `--glass-filter`(blur 24px saturate 1.4) /
///   `--glass-shadow`(0 8px 32px .2) / `--glass-inset`(顶沿内高光 .5)
/// - 卡：`app.css .glass-card` + auroraqua.css 卡片族
///   （hover 上浮 2px + 阴影 12/40、active scale .99，300ms/200ms）
/// - 按钮：`app.css .btn/.btn-primary/.btn-glow/.btn-ghost`
///   + auroraqua.css（.btn-ghost 覆写、hover 1.02 / press .98、600ms 扫光）
/// - 输入：`app.css .field` + auroraqua.css 统一 owner
///   （`--glass-inset` 内阴影 + `--glass-filter`）与 focus 辉光边
///
/// 纪律（05 §4）：
/// - **单材料 owner**：一张卡只保留一个材料层，内部布局块不再叠玻璃/blur；
/// - **禁裸色值**：一切颜色走 [AylaColors]；
/// - **reduced-motion**（`MediaQuery.disableAnimations`）：关闭上浮/缩放/扫光，
///   保留焦点与状态反馈；手势路径不依赖动画。
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import 'app_theme.dart';
import 'css_gradient.dart';
import 'preview_theme.dart';
import 'tokens.dart';

/// 毛玻璃运行期配置（性能降级链，05 坑 1 / d:§9）。
///
/// web 端降级条件是「浏览器不支持 `backdrop-filter`」（app.css @supports →
/// `rgba(255,250,251,0.92)` 实底），Flutter 侧对应「平台/设备不适合逐帧
/// 离屏模糊」——统一用 .92 不透明实底兜底，保住可读性且不再付模糊代价。
abstract final class GlassConfig {
  /// 为 true 时全站玻璃卡改用不透明实底（低端设备/性能告警时手动开启）。
  static bool useOpaqueFallback = false;

  /// 依据当前环境解析材料底色（默认 .55 / strong .78；降级 .92）。
  static Color resolveBackground({required bool strong}) {
    if (useOpaqueFallback) return AylaColors.glassOpaqueFallback;
    return strong ? AylaColors.glassBgStrong : AylaColors.glassBg;
  }
}

/// 玻璃材料的通用绘制（底色 + 模糊 + 亮边 + 宽软阴影 + 顶沿内高光）。
///
/// 只做一层离屏模糊（每处 `BackdropFilter` = 一次离屏模糊，全站用量必须
/// 收敛到本基类；d:§4 单材料 owner）。
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.radius = AylaRadii.rCard,
    this.blur = AylaGlass.blurCard,
    this.strong = false,
    this.shadow = AylaShadows.glass,
    this.border = true,
    this.padding,
  });

  /// 内容。
  final Widget child;

  /// 圆角。
  final double radius;

  /// 模糊半径（卡片 24 / 导航 18 / 按钮 8）。
  final double blur;

  /// 是否使用强玻璃底（.78，弹层）。
  final bool strong;

  /// 外阴影。
  final List<BoxShadow> shadow;

  /// 是否绘制 1px 亮边。
  final bool border;

  /// 内边距。
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final bool opaque = GlassConfig.useOpaqueFallback;

    // 卡面（底色 + 亮边 + 顶沿内高光）。**不含外阴影**——阴影必须在裁剪
    // 之外绘制，否则会被 ClipRRect 连同圆角裁掉（web box-shadow 在元素外侧）。
    final BorderRadius radiusValue = BorderRadius.circular(radius);
    final Widget face = DecoratedBox(
      decoration: BoxDecoration(
        color: GlassConfig.resolveBackground(strong: strong),
        borderRadius: radiusValue,
        border: border ? Border.all(color: AylaColors.glassBorder) : null,
      ),
      child: Stack(
        children: <Widget>[
          // 顶沿内高光（--glass-inset：inset 0 1px 0 rgba(255,255,255,.5)）
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radiusValue,
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      AylaColors.glassInsetHighlight,
                      const Color(0x00FFFFFF),
                    ],
                    stops: const <double>[0, 0.25],
                  ),
                ),
              ),
            ),
          ),
          Padding(padding: padding ?? EdgeInsets.zero, child: child),
        ],
      ),
    );

    // 外阴影：先于卡面绘制（在下层），不参与裁剪。
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radiusValue,
        boxShadow: shadow,
      ),
      child: opaque
          ? face
          : ClipRRect(
              borderRadius: radiusValue,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                child: face,
              ),
            ),
    );
  }
}

/// 模糊半径归一（--glass-filter blur(24px)；导航 18 / 按钮 8 有各自覆写）。
abstract final class AylaGlass {
  /// blur(24px) saturate(1.4)（t:--glass-filter）——卡片/侧栏/弹层
  static const double blurCard = 24;
  /// blur(18px)——底栏/顶栏/搜索面板/FAB
  static const double blurNav = 18;
  /// blur(8px)——ghost 按钮/工具钮
  static const double blurButton = 8;
}

/// GlassCard —— 全站卡面材料（app.css .glass-card / d:§4 Cards）。
///
/// [interactive] 为 true 时启用「可交互卡」行为：hover 上浮 2px + 阴影升
/// 12/40（300ms ease，auroraqua.css 卡片族），按下 scale .99；reduced-motion
/// 下不位移不缩放。非交互卡保持稳定位置（d:§4「仅可交互列表卡抬升」）。
class GlassCard extends StatefulWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding,
    this.radius = AylaRadii.rCard,
    this.blur = AylaGlass.blurCard,
    this.strong = false,
    this.shadow,
    this.interactive = false,
    this.onTap,
    this.semanticLabel,
  });

  /// 内容。
  final Widget child;

  /// 内边距（默认 16px，d:§12.8 帖子卡 padding 16；调用方可覆盖）。
  final EdgeInsetsGeometry? padding;

  /// 圆角（.glass-card = --radius-card 16）。
  final double radius;

  /// 模糊半径。
  final double blur;

  /// 强玻璃（弹层用 .78，d:§4 Panels）。
  final bool strong;

  /// 覆盖阴影（默认 [AylaShadows.glass]）。
  final List<BoxShadow>? shadow;

  /// 可交互（hover 抬升 + 按下缩放）。
  final bool interactive;

  /// 点击回调（传入即渲染为可点击卡）。
  final VoidCallback? onTap;

  /// 可访问性标签。
  final String? semanticLabel;

  @override
  State<GlassCard> createState() => _GlassCardState();
}

class _GlassCardState extends State<GlassCard> {
  bool _hovered = false;
  bool _pressed = false;

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  @override
  Widget build(BuildContext context) {
    final bool lifted = widget.interactive && _hovered && !_reduceMotion;
    final List<BoxShadow> shadow = lifted
        ? (widget.shadow ?? AylaShadows.glassHover)
        : (widget.shadow ?? AylaShadows.glass);
    final double scale = widget.interactive && _pressed && !_reduceMotion
        ? 0.99
        : 1.0;

    // 位移用独立 transform（auroraqua.css 卡片族：translate 300ms + scale 200ms）
    Widget card = AnimatedContainer(
      duration: _reduceMotion
          ? Duration.zero
          : (lifted ? AylaDurations.auroraqua : Duration.zero),
      curve: AylaCurves.auroraqua,
      transform: Matrix4.identity()
        ..translateByDouble(0, lifted ? -2 : 0, 0, 1)
        ..scaleByDouble(scale, scale, scale, 1),
      transformAlignment: Alignment.center,
      child: GlassSurface(
        radius: widget.radius,
        blur: widget.blur,
        strong: widget.strong,
        shadow: shadow,
        padding: widget.padding ?? const EdgeInsets.all(AylaSpacing.sp4),
        child: widget.child,
      ),
    );

    if (widget.onTap != null) {
      card = Semantics(
        button: true,
        label: widget.semanticLabel,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapCancel: () => setState(() => _pressed = false),
          onTapUp: (_) => setState(() => _pressed = false),
          child: card,
        ),
      );
    }

    if (!widget.interactive) return card;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: card,
    );
  }
}

/// 按钮类型（.btn-primary / .btn-glow / .btn-ghost）。
enum GlassButtonVariant {
  /// .btn-primary：indigo 实底 + 白字 + compact 阴影；hover 换 glow 阴影
  primary,

  /// .btn-glow：sakura→glow 135deg 渐变 + grape 字 + 常驻辉光；hover brightness(1.06)
  glow,

  /// .btn-ghost：玻璃底 + 亮边 + blur(8px) + button 阴影；hover 换 ice 蓝底
  ghost,
}

/// GlassButton —— 严格照 web CSS 实现的三类按钮。
///
/// **事实源（app.css + auroraqua.css，逐条对应，无自由发挥）**：
///
/// `.btn`（盒模型）：inline-flex / gap 8 / min-height 40 / padding 0 24
///   / radius 12 / 14px / 700 / ls .2
/// `.btn-primary`：background --indigo-700 / #fffafb / box-shadow compact；
///   :hover → box-shadow glow-shadow
/// `.btn-glow`：background 135deg #f9b0ff→#f796ff / color grape-700 /
///   box-shadow glow-shadow（常驻）；:hover → filter brightness(1.06)
/// `.btn-ghost`（base）：transparent / 1px rgba(70,91,146,.35) / indigo-700；
///   :hover → rgba(157,191,230,.18)。auroraqua.css 覆写：glass-bg /
///   glass-border / glass-shadow-button / blur(8px)；:hover → button-hover
///
/// auroraqua.css 交互：200ms transition 组；hover scale 1.02、active
///   scale .98（独立 scale 属性）；600ms 扫光（::after：90deg transparent→
///   glass-border→transparent，opacity .5，translateX(-120%→120%)）。
/// base.css button:disabled：opacity .55。
/// 窄屏（≤768）：辉光降 30%（0 0 11px rgba(247,150,255,.32)）。
class GlassButton extends StatefulWidget {
  const GlassButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = GlassButtonVariant.primary,
    this.icon,
    this.minHeight = 40,
    this.minWidth,
    this.padding = const EdgeInsets.symmetric(horizontal: AylaSpacing.sp6),
    this.expand = false,
    this.semanticLabel,
  });

  /// 文案。
  final String label;

  /// 点击回调；null = disabled（对应 :disabled，opacity .55）。
  final VoidCallback? onPressed;

  /// 变体。
  final GlassButtonVariant variant;

  /// 前置图标（.btn 的 gap 8 作用在图标与文字之间）。
  final Widget? icon;

  /// `.btn { min-height: 40px }`；认证页传 44（auth.css .auth-submit）。
  final double minHeight;

  /// `min-width`（.auth-switch-link 72 / .auth-code-btn 104）；null = 内容决定。
  final double? minWidth;

  /// `.btn { padding: 0 24px }`；认证页可传 padding-inline 16。
  final EdgeInsetsGeometry padding;

  /// `.auth-submit { width: 100% }`。
  final bool expand;

  /// 可访问性标签（默认 [label]）。
  final String? semanticLabel;

  @override
  State<GlassButton> createState() => _GlassButtonState();
}

class _GlassButtonState extends State<GlassButton>
    with SingleTickerProviderStateMixin {
  /// 扫光位置：0 = translateX(-120%)，1 = translateX(+120%)（::after）。
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: AylaDurations.sweep, // 600ms
  );

  bool _hovered = false;
  bool _pressed = false;

  bool get _enabled => widget.onPressed != null;

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles text = AylaTextStyles.of(context);
    final bool narrow = Breakpoint.isNarrow(MediaQuery.sizeOf(context).width);
    final bool animate = _enabled && !_reduceMotion;
    final bool hovered = _hovered && animate;

    // ---- 三类材质 ----
    late final Color background;
    late final Color foreground;
    late final Color? borderColor;
    final List<BoxShadow> shadow;
    late final LinearGradient? gradient;

    switch (widget.variant) {
      case GlassButtonVariant.primary:
        background = AylaColors.indigo700;
        foreground = AylaColors.surface;
        borderColor = null;
        gradient = null;
        shadow = hovered ? AylaShadows.glow : AylaShadows.compact;
      case GlassButtonVariant.glow:
        background = AylaColors.sakura300; // 渐变盖其上，底色兜底
        foreground = AylaColors.grape700;
        borderColor = null;
        // 135deg #f9b0ff → #f796ff（app.css .btn-glow）
        gradient = cssLinearGradient(
          angleDeg: 135,
          colors: AylaGradients.btnGlow,
        );
        // 常驻辉光；窄屏（≤768）强度降 30%
        shadow = narrow ? AylaShadows.glowNarrow : AylaShadows.glow;
      case GlassButtonVariant.ghost:
        // auroraqua 覆写：glass-bg + glass-border + button 阴影 + blur(8px)
        background = hovered
            ? AylaColors.ice500.withValues(alpha: 0.18) // :hover rgba(157,191,230,.18)
            : GlassConfig.resolveBackground(strong: false);
        foreground = AylaColors.indigo700;
        borderColor = AylaColors.glassBorder; // auroraqua 覆写 --glass-border
        gradient = null;
        shadow = hovered ? AylaShadows.buttonHover : AylaShadows.button;
    }

    final BorderRadius rInput =
        BorderRadius.all(Radius.circular(AylaRadii.rInput));

    // ---- 卡面：底色/渐变 + 描边 + 圆角裁剪（.btn 盒模型与材质）----
    // 注意：padding 必须放在 Stack **内部**（内容 Row 外包 Padding）——
    // CSS `.btn::after { inset: 0 }` 的扫光是相对 padding box（含左右
    // 24px），若 padding 留在外层面板，Positioned.fill 扫光层只能覆盖
    // 内容区，光条会比按钮窄、扫不过按钮两端。
    final Widget face = AnimatedContainer(
      duration: _reduceMotion ? Duration.zero : AylaDurations.fast,
      curve: AylaCurves.easeOut,
      constraints: BoxConstraints(
        minHeight: widget.minHeight,
        minWidth: widget.minWidth ?? 0,
      ),
      decoration: BoxDecoration(
        color: background,
        gradient: gradient,
        borderRadius: rInput,
        border: borderColor == null ? null : Border.all(color: borderColor),
      ),
      // ::after 在圆角内裁剪（.btn { overflow: hidden; isolation: isolate }）
      child: ClipRRect(
        borderRadius: rInput,
        clipBehavior: Clip.hardEdge,
        child: Stack(
          fit: StackFit.passthrough,
          alignment: Alignment.center,
          children: <Widget>[
            // .btn::after 扫光：覆盖整个 padding box；opacity .5，
            // -120% → +120%（600ms）
            if (animate)
              Positioned.fill(
                child: IgnorePointer(
                  child: Opacity(
                    opacity: 0.5,
                    child: AnimatedBuilder(
                      animation: _sweep,
                      builder: (BuildContext context, Widget? child) {
                        return FractionalTranslation(
                          translation: Offset(-1.2 + _sweep.value * 2.4, 0),
                          child: child,
                        );
                      },
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: cssLinearGradient(
                            angleDeg: 90, // linear-gradient(90deg, …)
                            colors: AylaGradients.sweep,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            // 内容：gap 8px；14px/700/ls .2（padding 在 Stack 内部）
            Padding(
              padding: widget.padding,
              child: Row(
                mainAxisSize:
                    widget.expand ? MainAxisSize.max : MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  if (widget.icon != null) ...<Widget>[
                    IconTheme(
                      data: IconThemeData(color: foreground, size: 18),
                      child: widget.icon!,
                    ),
                    const SizedBox(width: AylaSpacing.sp2), // gap: var(--sp-2)
                  ],
                  Flexible(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.label.copyWith(
                        color: foreground,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    // ---- 外阴影：不参与裁剪（box-shadow 在元素外侧）----
    Widget decorated = Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: rInput,
              boxShadow: shadow,
            ),
          ),
        ),
        face,
      ],
    );

    // .btn-glow:hover:not(:disabled) { filter: brightness(1.06) }
    // CSS filter 是通道乘法（×1.06 后钳位）→ ColorFilter.matrix 等价。
    if (widget.variant == GlassButtonVariant.glow && hovered) {
      decorated = ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          1.06, 0, 0, 0, 0, //
          0, 1.06, 0, 0, 0, //
          0, 0, 1.06, 0, 0, //
          0, 0, 0, 1, 0,
        ]),
        child: decorated,
      );
    }

    // .btn-ghost { backdrop-filter: blur(8px) }（auroraqua.css）
    if (widget.variant == GlassButtonVariant.ghost &&
        !GlassConfig.useOpaqueFallback) {
      decorated = Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: ClipRRect(
              borderRadius: rInput,
              child: BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: AylaGlass.blurButton,
                  sigmaY: AylaGlass.blurButton,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          decorated,
        ],
      );
    }

    // :hover { scale: 1.02 } / :active { scale: .98 }（独立 scale，200ms）
    final double pressScale =
        _enabled && _pressed && !_reduceMotion ? 0.98 : 1.0;
    final Widget body = AnimatedScale(
      scale: hovered ? 1.02 : pressScale,
      duration: _reduceMotion ? Duration.zero : AylaDurations.fast,
      curve: AylaCurves.auroraqua,
      child: decorated,
    );

    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.semanticLabel ?? widget.label,
      child: MouseRegion(
        cursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) {
          setState(() => _hovered = true);
          if (animate) _sweep.forward(); // ::after → translateX(120%)
        },
        onExit: (_) {
          setState(() {
            _hovered = false;
            _pressed = false;
          });
          if (animate) _sweep.reverse(); // 移出时 600ms 扫回
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
          onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
          onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
          // base.css button:disabled { opacity: .55 }
          child: Opacity(opacity: _enabled ? 1 : 0.55, child: body),
        ),
      ),
    );
  }
}

/// GlassInput —— 文本输入基类（.field + auroraqua 统一 owner）。
///
/// 材料（app.css .field + auroraqua.css 统一 owner）：
/// 底 `--glass-bg`(.55) + 1px `--glass-border` + 12px 圆角 +
/// `--glass-inset` 内阴影 + `--glass-filter`(blur 24px)；内边距 12×16。
/// focus：边框转 `--glow-500` + `--glow-shadow`（180ms）。
/// placeholder：`--slate-500`。
///
/// 认证上下文（d:§5）：字段描边覆写为 rgba(70,91,146,.3)
/// （白边在浅玻璃上不可见）、min-height 44px。[onGlassBorder] 控制前者。
class GlassInput extends StatefulWidget {
  const GlassInput({
    super.key,
    required this.controller,
    this.hintText,
    this.obscureText = false,
    this.onSubmitted,
    this.autofocus = false,
    this.enabled = true,
    this.minHeight = 44,
    this.textInputAction,
    this.autofillHints,
    this.onGlassBorder = false,
    this.textStyle,
    this.semanticLabel,
    this.focusNode,
  });

  /// 文本控制器。
  final TextEditingController controller;

  /// 占位文案（--slate-500）。
  final String? hintText;

  /// 密码输入。
  final bool obscureText;

  /// 回车提交。
  final ValueChanged<String>? onSubmitted;

  /// 自动聚焦（web 登录页 userName 字段 autoFocus）。
  final bool autofocus;

  /// 是否可编辑。
  final bool enabled;

  /// 最小高度（认证字段 44px）。
  final double minHeight;

  /// 键盘动作。
  final TextInputAction? textInputAction;

  /// 自动填充提示（web autoComplete="username"）。
  final Iterable<String>? autofillHints;

  /// 是否使用认证卡内描边 rgba(70,91,146,.3)。
  final bool onGlassBorder;

  /// 覆盖文字样式（认证字段继承 .auth-field 的 14px）。
  final TextStyle? textStyle;

  /// 可访问性标签。
  final String? semanticLabel;

  /// 焦点节点。
  final FocusNode? focusNode;

  @override
  State<GlassInput> createState() => _GlassInputState();
}

class _GlassInputState extends State<GlassInput> {
  FocusNode? _ownedFocus;
  bool _focused = false;

  FocusNode get _focus => widget.focusNode ?? (_ownedFocus ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (!mounted) return;
    setState(() => _focused = _focus.hasFocus);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _ownedFocus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles text = AylaTextStyles.of(context);
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final Color border = _focused
        ? AylaColors.glow500
        : (widget.onGlassBorder
            ? AylaColors.fieldBorderOnGlass
            : AylaColors.glassBorder);

    final Widget field = AnimatedContainer(
      duration: reduceMotion ? Duration.zero : AylaDurations.fast,
      curve: AylaCurves.easeOut,
      constraints: BoxConstraints(minHeight: widget.minHeight),
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp4,
        vertical: AylaSpacing.sp3,
      ),
      decoration: BoxDecoration(
        color: GlassConfig.resolveBackground(strong: false),
        borderRadius: BorderRadius.all(Radius.circular(AylaRadii.rInput)),
        border: Border.all(color: border),
        boxShadow: _focused ? AylaShadows.glow : null,
        gradient: _focused
            ? null
            : LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  AylaColors.glassInsetHighlight,
                  const Color(0x00FFFFFF),
                ],
                stops: const <double>[0, 0.25],
              ),
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: _focus,
        enabled: widget.enabled,
        obscureText: widget.obscureText,
        autofocus: widget.autofocus,
        textInputAction: widget.textInputAction,
        autofillHints: widget.autofillHints,
        onSubmitted: widget.onSubmitted,
        cursorColor: AylaColors.indigo700,
        style: widget.textStyle ??
            text.body.copyWith(color: AylaColors.textPrimary),
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          contentPadding: EdgeInsets.zero,
          hintText: widget.hintText,
          hintStyle: text.body.copyWith(color: AylaColors.textSecondary),
        ),
      ),
    );

    return Semantics(
      textField: true,
      label: widget.semanticLabel ?? widget.hintText,
      child: field,
    );
  }
}

// ======================= 预览 =======================

/// GlassCard 静态 + 可交互。
@Preview(
  group: 'Glass',
  name: 'GlassCard 静态 + 可交互',
  size: Size(420, 240),
  wrapper: previewTheme,
)
Widget glassCardPreview() {
  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp6),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        GlassCard(
          child: Text('静态玻璃卡', style: AylaTextStyles.light.cardTitle),
        ),
        const SizedBox(height: AylaSpacing.sp4),
        GlassCard(
          interactive: true,
          onTap: () {},
          child: Text('可交互（hover 上浮 2px）', style: AylaTextStyles.light.body),
        ),
      ],
    ),
  );
}

/// GlassButton 三类 + disabled。
@Preview(
  group: 'Glass',
  name: 'GlassButton primary/glow/ghost/disabled',
  size: Size(420, 300),
  wrapper: previewTheme,
)
Widget glassButtonPreview() {
  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp6),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        GlassButton(label: '登录', onPressed: () {}),
        const SizedBox(height: AylaSpacing.sp3),
        GlassButton(
          label: '登录',
          variant: GlassButtonVariant.glow,
          onPressed: () {},
        ),
        const SizedBox(height: AylaSpacing.sp3),
        GlassButton(
          label: '注册',
          variant: GlassButtonVariant.ghost,
          minHeight: 44,
          onPressed: () {},
        ),
        const SizedBox(height: AylaSpacing.sp3),
        GlassButton(label: '登录中…', onPressed: null),
      ],
    ),
  );
}

/// GlassInput 常态 / focus。
@Preview(
  group: 'Glass',
  name: 'GlassInput 常态 + focus',
  size: Size(420, 260),
  wrapper: previewTheme,
)
Widget glassInputPreview() => const _GlassInputSample();

class _GlassInputSample extends StatefulWidget {
  const _GlassInputSample();

  @override
  State<_GlassInputSample> createState() => _GlassInputSampleState();
}

class _GlassInputSampleState extends State<_GlassInputSample> {
  final TextEditingController _a = TextEditingController();
  final TextEditingController _b = TextEditingController(text: '123');

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AylaSpacing.sp6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          GlassInput(controller: _a, hintText: 'hint = slate-500'),
          const SizedBox(height: AylaSpacing.sp4),
          GlassInput(controller: _b, autofocus: true),
        ],
      ),
    );
  }
}
