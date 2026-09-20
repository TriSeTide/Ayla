/// 按钮族（GlassButton 之外的 web 按钮样式全量）——
/// IconButton40 / CornerFab / CreateFab / MessageFab / ComposerToolButton /
/// MsgActionButton。
///
/// 事实源（逐条对应 web CSS，禁自由发挥）：
/// - **统一交互**（auroraqua.css 54–94 行，作用于 `.btn`/`.icon-btn-40`/
///   `.top-nav-icon-btn`/`.live-player-btn`/`.composer-send`/
///   `.composer-tool-btn`/`.msg-action-btn`/`.favorite-toggle`/
///   `.server-create-btn`/`.create-fab`/`.message-fab`/`.corner-fab` 等全族）：
///   `transition: scale/box-shadow/background/color/filter/opacity/transform
///   200ms var(--auroraqua-ease)`；`:hover` → `scale: 1.02`；
///   `:active` → `scale: .98`（**:active 规则在后，按下时覆盖 hover**）。
/// - `.icon-btn-40`（home.css 121–134）：40×40、border-radius pill、
///   color text-primary、`transition: background 180ms --ease-out`；
///   `:hover` → `rgba(157,191,230,.18)`。auroraqua.css 125–132 追加：
///   glass-bg + 1px glass-border + `--glass-shadow-button` + blur(8px)；
///   hover → `--glass-shadow-button-hover`（134–139）。窄屏顶栏「更多」入口
///   还带 12px 圆角（119–122：`.narrow-topbar-more > .icon-btn-40`）。
/// - `.corner-fab`（shell.css 697–719）：44px 圆、glass-bg + blur(18px)
///   saturate(1.4) + 1px glass-border + text-primary + `--card-shadow`；
///   hover → glass-bg-strong + `0 2px 12px rgba(70,91,146,.18)`。
/// - `.create-fab`（shell.css 406–421）：56px 圆、indigo-700 实底 + #fffafb、
///   `0 2px 12px rgba(70,91,146,.18)`，hover → `--glow-shadow`（d:§12.5）。
/// - `.message-fab`（shell.css 423–439）：56px 圆、glass-bg + blur(18px)
///   saturate(1.4) + 1px glass-border + text-primary（未读徽标由调用方挂）。
/// - `.composer-tool-btn`（app.css 2105–2119 + auroraqua.css 105–112）：
///   40×40、pill、1px ice-300；auroraqua 覆写为 glass-bg + glass-border +
///   `--glass-shadow-compact` + blur(8px)；hover/focus-within → glow 边 +
///   `--glow-shadow`。录音停止态（auroraqua 114–117）：destructive 边与底。
/// - `.msg-action-btn`（app.css 1324–1366 + auroraqua.css 125–132）：
///   padding sp1 sp2、radius 8、12px、text-secondary、glass-bg-strong 底 +
///   glass-border；hover → indigo 字 + `--glow-shadow`；auroraqua 追加
///   button 阴影与 blur(8px)，hover → button-hover（134–139）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import 'app_theme.dart';
import 'glass.dart';
import 'preview_theme.dart';
import 'tokens.dart';

/// 统一按钮交互壳（auroraqua.css 全族共用：200ms + hover 1.02 + active .98）。
///
/// 按下时 **必须** 覆盖 hover（CSS 中 :active 规则在后）——否则鼠标按住时
/// 只能看到 1.02、没有按压反馈。
class AylaPressScale extends StatefulWidget {
  const AylaPressScale({
    super.key,
    required this.child,
    this.onTap,
    this.enabled = true,
    this.semanticLabel,
    this.isButton = true,
    this.hoverScale = true,
    this.onPressChanged,
  });

  /// 内容。
  final Widget child;

  /// 点击回调。
  final VoidCallback? onTap;

  /// 是否可用（false → 无交互，opacity .55 由调用方处理）。
  final bool enabled;

  /// 可访问性标签。
  final String? semanticLabel;

  /// 是否暴露为按钮语义。
  final bool isButton;

  /// 是否启用 hover 放大 1.02。
  ///
  /// **两组不同的 web 规则**（auroraqua.css）：
  /// - **按钮组**（54–94，`.btn`/`.icon-btn-40`/…/`.layout-switch-btn`）：
  ///   `:hover { scale: 1.02 }` + `:active { scale: .98 }` → `hoverScale: true`
  /// - **导航/选项卡组**（236–249，`.messages-tab`/`.channel-scene`/
  ///   `.top-nav-module`/`.bottom-tab-link` 等）：**只有 `:active { scale: .98 }`，
  ///   hover 不放大** → `hoverScale: false`
  final bool hoverScale;

  /// 按压状态回调（按下 true / 松开 false）。
  ///
  /// 用途：web 里高亮胶囊是按钮的**子元素**，父按钮 `:active { scale: .98 }`
  /// 会连带胶囊一起缩放；Flutter 侧胶囊与按钮平级（容器级单实例），
  /// 必须由容器监听该回调让胶囊同步缩放。
  final ValueChanged<bool>? onPressChanged;

  @override
  State<AylaPressScale> createState() => _AylaPressScaleState();
}

class _AylaPressScaleState extends State<AylaPressScale> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  @override
  Widget build(BuildContext context) {
    final double scale = _reduceMotion || !widget.enabled
        ? 1.0
        : (_pressed
            ? 0.98
            : (_hovered && widget.hoverScale ? 1.02 : 1.0));
    final BorderRadius ringRadius =
        BorderRadius.circular(AylaRadii.rPill + 2 + 2);

    Widget content = AnimatedScale(
      scale: scale,
      duration: _reduceMotion ? Duration.zero : AylaDurations.button,
      curve: AylaCurves.auroraqua,
      child: widget.child,
    );

    if (_focused && widget.enabled) {
      // base.css :focus-visible { outline: 2px #F796FF; outline-offset: 2px }
      content = Container(
        decoration: BoxDecoration(
          borderRadius: ringRadius,
          border: Border.all(color: AylaColors.glow500, width: 2),
        ),
        padding: const EdgeInsets.all(2),
        child: content,
      );
    }

    return Semantics(
      button: widget.isButton,
      enabled: widget.enabled,
      label: widget.semanticLabel,
      child: Focus(
        onFocusChange: (bool has) => setState(() => _focused = has),
        child: MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() {
            _hovered = false;
            _pressed = false;
          }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            onTapDown: widget.enabled
                ? (_) {
                    setState(() => _pressed = true);
                    widget.onPressChanged?.call(true);
                  }
                : null,
            onTapCancel: widget.enabled
                ? () {
                    setState(() => _pressed = false);
                    widget.onPressChanged?.call(false);
                  }
                : null,
            onTapUp: widget.enabled
                ? (_) {
                    setState(() => _pressed = false);
                    widget.onPressChanged?.call(false);
                  }
                : null,
            child: content,
          ),
        ),
      ),
    );
  }
}

/// `.icon-btn-40` —— 40px 圆形玻璃图标钮（auroraqua 覆写为玻璃材料）。
///
/// [square] = true 时圆角 12px（窄屏顶栏「更多」入口 `.narrow-topbar-more >
/// .icon-btn-40`，auroraqua.css 119–122）。
class AylaIconButton extends StatefulWidget {
  const AylaIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.square = false,
    this.size = 40,
    this.semanticLabel,
  });

  /// 图标（AylaIcon）。
  final Widget icon;

  /// 点击回调（null = disabled）。
  final VoidCallback? onPressed;

  /// 圆角 12px 方形（否则 pill）。
  final bool square;

  /// 边长（默认 40）。
  final double size;

  /// 可访问性标签。
  final String? semanticLabel;

  @override
  State<AylaIconButton> createState() => _AylaIconButtonState();
}

class _AylaIconButtonState extends State<AylaIconButton> {
  bool _hovered = false;

  bool get _enabled => widget.onPressed != null;

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius = widget.square
        ? BorderRadius.circular(AylaRadii.rInput)
        : AylaRadii.pill;
    // .icon-btn-40 { transition: background 180ms --ease-out }；hover 浅冰蓝底
    final Color background = _hovered && _enabled
        ? AylaColors.ice500.withValues(alpha: 0.18)
        : GlassConfig.resolveBackground(strong: false);

    Widget box = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: AylaCurves.easeOut,
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: background,
        borderRadius: radius,
        border: Border.all(color: AylaColors.glassBorder),
      ),
      child: Center(child: widget.icon),
    );
    // auroraqua.css 124–132：`box-shadow: var(--glass-shadow-button)` → hover 换
    // `-hover`；`--glass-inset`（顶沿 1px 内高光）由下面的 AylaGlassInset.over 叠层实现。
    // ⚠️ 2026-09-20 审查 R2：外阴影必须**只画形状之外**——原裸用 boxShadow 会把
    // `.1` indigo 铺进 `.55` 玻璃面内部（按钮内部发灰，hover 升到 .15 更明显）。
    box = AylaGlassShadow.animatedRing(
      radius: radius,
      shadows: _hovered && _enabled
          ? AylaShadows.buttonHover
          : AylaShadows.button,
      duration: AylaDurations.button, // auroraqua transition 组 200ms
      child: box,
    );
    // --glass-inset（顶沿 1px 内高光）
    box = AylaGlassInset.over(child: box, radius: radius);

    // auroraqua.css 125–132：backdrop-filter blur(8px)
    if (!GlassConfig.useOpaqueFallback) {
      box = Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: ClipRRect(
              borderRadius: radius,
              child: BackdropFilter(
                // auroraqua.css 124–132（`.icon-btn-40` 等 surface 按钮）：
                // `backdrop-filter: blur(8px)` —— **只有 blur，没有 saturate**
                // （与 18px 档的 `.corner-fab`/`.message-fab`
                //  `blur(18px) saturate(1.4)` 不同，不能统一按 1.4 处理）。
                filter: GlassConfig.blurOnly(sigma: AylaGlass.blurButton),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          box,
        ],
      );
    }

    return AylaPressScale(
      onTap: widget.onPressed,
      enabled: _enabled,
      semanticLabel: widget.semanticLabel,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Opacity(opacity: _enabled ? 1 : 0.55, child: box),
      ),
    );
  }
}

/// `.corner-fab` —— 44px 玻璃圆钮（次级 FAB：刷新 / 回顶）。
class AylaCornerFab extends StatefulWidget {
  const AylaCornerFab({
    super.key,
    required this.icon,
    this.onPressed,
    this.semanticLabel,
  });

  final Widget icon;
  final VoidCallback? onPressed;
  final String? semanticLabel;

  @override
  State<AylaCornerFab> createState() => _AylaCornerFabState();
}

class _AylaCornerFabState extends State<AylaCornerFab> {
  bool _hovered = false;

  bool get _enabled => widget.onPressed != null;

  @override
  Widget build(BuildContext context) {
    Widget box = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: AylaCurves.easeOut,
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        // hover → glass-bg-strong + 0 2px 12px rgba(70,91,146,.18)
        color: _hovered && _enabled
            ? AylaColors.glassBgStrong
            : GlassConfig.resolveBackground(strong: false),
        borderRadius: AylaRadii.pill,
        border: Border.all(color: AylaColors.glassBorder),
      ),
      child: Center(child: widget.icon),
    );
    // 外阴影只画形状之外（2026-09-20 审查 R2；原裸 boxShadow 会染进 .55 玻璃内部）
    box = AylaGlassShadow.animatedRing(
      radius: AylaRadii.pill,
      shadows: _hovered && _enabled ? AylaShadows.fab : AylaShadows.card,
      duration: AylaDurations.button,
      child: box,
    );

    if (!GlassConfig.useOpaqueFallback) {
      box = Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: ClipRRect(
              borderRadius: AylaRadii.pill,
              child: BackdropFilter(
                // CSS 里 blur 与 saturate(1.4) 成对出现（shell.css 432
                // `.message-fab` / 704 `.corner-fab`：`blur(18px) saturate(1.4)`）。
                // 只做 blur 会丢失玻璃的通透鲜艳感——必须两个都做。
                filter: GlassConfig.backdropFilter(sigma: AylaGlass.blurNav),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          box,
        ],
      );
    }

    return AylaPressScale(
      onTap: widget.onPressed,
      enabled: _enabled,
      semanticLabel: widget.semanticLabel,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Opacity(opacity: _enabled ? 1 : 0.55, child: box),
      ),
    );
  }
}

/// `.create-fab` —— 56px indigo 实底主 FAB（hover 附辉光，d:§12.5）。
class AylaCreateFab extends StatelessWidget {
  const AylaCreateFab({
    super.key,
    required this.icon,
    this.onPressed,
    this.semanticLabel,
  });

  final Widget icon;
  final VoidCallback? onPressed;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onPressed != null;
    return _FabHover(
      // 实底 indigo（不透明）——外观与裸 boxShadow 等价；此处统一走 ring
      // 只为消灭「同一件事两种写法」（2026-09-20 审查 R2）。
      builder: (bool hovered) => AylaGlassShadow.animatedRing(
        radius: AylaRadii.pill,
        // 常驻 0 2px 12px rgba(70,91,146,.18)；hover → --glow-shadow
        shadows: hovered && enabled ? AylaShadows.glow : AylaShadows.fab,
        duration: AylaDurations.button,
        child: Container(
          width: 56,
          height: 56,
          decoration: const BoxDecoration(
            color: AylaColors.indigo700,
            borderRadius: AylaRadii.pill,
          ),
          child: Center(
            child: IconTheme(
              data: const IconThemeData(color: AylaColors.surface),
              child: icon,
            ),
          ),
        ),
      ),
      onTap: onPressed,
      enabled: enabled,
      semanticLabel: semanticLabel,
    );
  }
}

/// `.message-fab` —— 56px 玻璃圆钮（左下私信入口，未读徽标由调用方挂）。
class AylaMessageFab extends StatelessWidget {
  const AylaMessageFab({
    super.key,
    required this.icon,
    this.onPressed,
    this.badge,
    this.semanticLabel,
  });

  final Widget icon;
  final VoidCallback? onPressed;

  /// 未读徽标（右上角；null = 无）。
  final Widget? badge;

  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onPressed != null;
    Widget box = Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: GlassConfig.resolveBackground(strong: false),
        borderRadius: AylaRadii.pill,
        border: Border.all(color: AylaColors.glassBorder),
      ),
      child: Center(child: icon),
    );

    if (!GlassConfig.useOpaqueFallback) {
      box = Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: ClipRRect(
              borderRadius: AylaRadii.pill,
              child: BackdropFilter(
                // CSS 里 blur 与 saturate(1.4) 成对出现（shell.css 432
                // `.message-fab` / 704 `.corner-fab`：`blur(18px) saturate(1.4)`）。
                // 只做 blur 会丢失玻璃的通透鲜艳感——必须两个都做。
                filter: GlassConfig.backdropFilter(sigma: AylaGlass.blurNav),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          box,
        ],
      );
    }

    if (badge != null) {
      box = Stack(
        clipBehavior: Clip.none,
        children: <Widget>[box, badge!],
      );
    }

    return _FabHover(
      builder: (bool hovered) =>
          Opacity(opacity: enabled ? 1 : 0.55, child: box),
      onTap: onPressed,
      enabled: enabled,
      semanticLabel: semanticLabel,
    );
  }
}

/// FAB 共用交互壳（AylaPressScale + 供 builder 读 hover 态）。
class _FabHover extends StatefulWidget {
  const _FabHover({
    required this.builder,
    required this.onTap,
    required this.enabled,
    required this.semanticLabel,
  });

  final Widget Function(bool hovered) builder;
  final VoidCallback? onTap;
  final bool enabled;
  final String? semanticLabel;

  @override
  State<_FabHover> createState() => _FabHoverState();
}

class _FabHoverState extends State<_FabHover> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return AylaPressScale(
      onTap: widget.onTap,
      enabled: widget.enabled,
      semanticLabel: widget.semanticLabel,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: widget.builder(_hovered),
      ),
    );
  }
}

/// `.composer-tool-btn` —— 40px 圆形工具钮（玻璃材质 + hover 辉光边）。
class AylaToolButton extends StatefulWidget {
  const AylaToolButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.danger = false,
    this.semanticLabel,
  });

  final Widget icon;
  final VoidCallback? onPressed;

  /// 录音停止态（`.composer-voice-stop`：destructive 边与底）。
  final bool danger;

  final String? semanticLabel;

  @override
  State<AylaToolButton> createState() => _AylaToolButtonState();
}

class _AylaToolButtonState extends State<AylaToolButton> {
  bool _hovered = false;

  bool get _enabled => widget.onPressed != null;

  @override
  Widget build(BuildContext context) {
    // app.css：1px ice-300；auroraqua 覆写：glass-bg + glass-border +
    // compact 阴影 + blur(8px)；hover/focus-within → glow 边 + glow 阴影。
    final Color border = widget.danger
        ? AylaColors.destructive
        : (_hovered && _enabled ? AylaColors.glow500 : AylaColors.glassBorder);
    final Color background = widget.danger
        ? AylaColors.destructive
        : GlassConfig.resolveBackground(strong: false);

    Widget box = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: AylaCurves.easeOut,
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: background,
        borderRadius: AylaRadii.pill,
        border: Border.all(color: border),
      ),
      child: Center(child: widget.icon),
    );
    // 外阴影只画形状之外（2026-09-20 审查 R2；原裸 boxShadow 会染进 .55 玻璃内部）
    box = AylaGlassShadow.animatedRing(
      radius: AylaRadii.pill,
      shadows: _hovered && _enabled && !widget.danger
          ? AylaShadows.glow
          : AylaShadows.compact,
      duration: AylaDurations.button,
      child: box,
    );
    // `.composer-tool-btn`（auroraqua.css 105–112）：box-shadow:
    // var(--glass-shadow-compact) —— 该 token 含 `var(--glass-inset)`，
    // 故补顶沿 1px 内高光（danger 态为 destructive 实底、非玻璃材质，不加）。
    if (!widget.danger) {
      box = AylaGlassInset.over(child: box, radius: AylaRadii.pill);
    }

    if (!GlassConfig.useOpaqueFallback && !widget.danger) {
      box = Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: ClipRRect(
              borderRadius: AylaRadii.pill,
              child: BackdropFilter(
                // auroraqua.css 110–111（`.composer-tool-btn`）：`blur(8px)`
                // 无 saturate（见 8px 档三处均为纯 blur）。
                filter: GlassConfig.blurOnly(sigma: AylaGlass.blurButton),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          box,
        ],
      );
    }

    return AylaPressScale(
      onTap: widget.onPressed,
      enabled: _enabled,
      semanticLabel: widget.semanticLabel,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Opacity(opacity: _enabled ? 1 : 0.55, child: box),
      ),
    );
  }
}

/// `.msg-action-btn` —— 气泡操作小按钮（11–12px 图标+文字，hover 辉光）。
class AylaMsgActionButton extends StatefulWidget {
  const AylaMsgActionButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.danger = false,
    this.semanticLabel,
  });

  final String label;
  final Widget? icon;
  final VoidCallback? onPressed;

  /// 失败态等危险操作（destructive 文字色）。
  final bool danger;

  final String? semanticLabel;

  @override
  State<AylaMsgActionButton> createState() => _AylaMsgActionButtonState();
}

class _AylaMsgActionButtonState extends State<AylaMsgActionButton> {
  bool _hovered = false;

  bool get _enabled => widget.onPressed != null;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    // app.css 1324–1336：glass-bg-strong 底 + glass-border + radius 8 +
    // padding sp1 sp2 + 12px；hover → indigo 字 + glow 阴影。
    final Color fg = widget.danger
        ? AylaColors.destructive
        : (_hovered && _enabled
            ? AylaColors.indigo700
            : AylaColors.textSecondary);

    Widget box = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: AylaCurves.easeOut,
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp2,
        vertical: AylaSpacing.sp1,
      ),
      decoration: BoxDecoration(
        color: AylaColors.glassBgStrong,
        borderRadius: BorderRadius.circular(AylaRadii.rSm),
        border: Border.all(color: AylaColors.glassBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (widget.icon != null) ...<Widget>[
            IconTheme(
              data: IconThemeData(color: fg, size: 11),
              child: widget.icon!,
            ),
            const SizedBox(width: AylaSpacing.sp1),
          ],
          Text(
            widget.label,
            style: t.caption.copyWith(
              fontSize: 12,
              color: fg,
              height: 1.2,
            ),
          ),
        ],
      ),
    );

    // auroraqua.css 124–132 覆写：`--glass-shadow-button` / `-hover`（含 inset）→
    // 外阴影只画形状之外（2026-09-20 审查 R2；.78 强玻璃内部会被 .1 indigo 染色）
    box = AylaGlassShadow.animatedRing(
      radius: BorderRadius.circular(AylaRadii.rSm),
      shadows: _hovered && _enabled
          ? AylaShadows.buttonHover
          : AylaShadows.button,
      duration: AylaDurations.button,
      child: box,
    );

    return AylaPressScale(
      onTap: widget.onPressed,
      enabled: _enabled,
      semanticLabel: widget.semanticLabel ?? widget.label,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Opacity(
          opacity: _enabled ? 1 : 0.55,
          // --glass-inset（顶沿 1px 内高光；radius 与卡面一致 = --radius-sm 8）
          child: AylaGlassInset.over(
            child: box,
            radius: BorderRadius.circular(AylaRadii.rSm),
          ),
        ),
      ),
    );
  }
}

// ======================= 预览 =======================

/// 按钮族全量（后台复核用：40 图标钮 / 44 corner / 56 create+message / 工具钮 / 消息操作钮）。
@Preview(
  group: 'Buttons',
  name: '按钮族全量（IconButton/CornerFab/FAB/Tool/MsgAction）',
  size: Size(720, 460),
  wrapper: previewTheme,
)
Widget buttonsFamilyPreview() {
  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Row(
          children: <Widget>[
            AylaIconButton(
              icon: const _Dot(),
              onPressed: () {},
              semanticLabel: 'icon-btn-40',
            ),
            const SizedBox(width: AylaSpacing.sp4),
            AylaIconButton(icon: const _Dot(), square: true, onPressed: () {}),
            const SizedBox(width: AylaSpacing.sp4),
            AylaCornerFab(icon: const _Dot(), onPressed: () {}),
            const SizedBox(width: AylaSpacing.sp4),
            AylaCreateFab(icon: const _Dot(), onPressed: () {}),
            const SizedBox(width: AylaSpacing.sp4),
            AylaMessageFab(icon: const _Dot(), onPressed: () {}),
          ],
        ),
        const SizedBox(height: AylaSpacing.sp6),
        Row(
          children: <Widget>[
            AylaToolButton(icon: const _Dot(), onPressed: () {}),
            const SizedBox(width: AylaSpacing.sp4),
            AylaToolButton(icon: const _Dot(), onPressed: () {}, danger: true),
            const SizedBox(width: AylaSpacing.sp4),
            AylaMsgActionButton(
              label: '重试',
              icon: const _Dot(),
              onPressed: () {},
            ),
            const SizedBox(width: AylaSpacing.sp2),
            AylaMsgActionButton(
              label: '删除',
              icon: const _Dot(),
              onPressed: () {},
              danger: true,
            ),
          ],
        ),
      ],
    ),
  );
}

/// 占位图标点（预览用；真实图标走 AylaIcon）。
class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18,
      height: 18,
      decoration: const BoxDecoration(
        color: AylaColors.indigo700,
        shape: BoxShape.circle,
      ),
    );
  }
}
