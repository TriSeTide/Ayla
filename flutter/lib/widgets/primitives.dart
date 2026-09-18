/// 展示型基元（Batch 2）：LayoutSwitch / SegmentedTabs / CapsuleTag /
/// StatusPill / ScrollingText。
///
/// 事实源（逐条对应 web CSS，禁自由发挥）：
/// - `.layout-switch` / `.layout-switch-btn`（home.css 182–206）：
///   inline-flex + gap sp2 + padding sp1 + radius-pill + glass-bg + 1px
///   glass-border；按钮 36×36 pill、text-secondary、180ms background/color；
///   `is-active` → 底 `rgba(157,191,230,.35)` + text-primary。
/// - `.messages-tabs` / `.messages-tab`（messages.css 17–37）：flex gap sp2 +
///   padding sp3 sp4；tab 高 40、radius-input 12、14px/700、text-secondary；
///   `is-active` → 同款 ice .35 底 + text-primary。
/// - `.tab-badge` 语义的徽标见 tab_badge.dart（本文件的胶囊不是它）。
/// - design.md §4 Tags/Badges：胶囊形、`--sakura-300` 底 + `--grape-700` 字、
///   11px Fredoka（Micro Tag 等级见 d:§3）。
/// - `.scroll-text` / `.scroll-text-inner` + `scroll-text-marquee`
///   （base.css 724–758）：单行 nowrap + overflow hidden；溢出时内层
///   marquee 来回滚动（0–20% 停开头、50–70% 停结尾、100% 回开头，
///   linear 匀速），距离/时长由组件测量（d/speed，夹 4~16s）；
///   未溢出静态显示；`prefers-reduced-motion` 关闭滚动。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widget_previews.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/css_gradient.dart';
import '../theme/buttons.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';

/// `.layout-switch` —— 主页布局切换（卡片 / 列表），**共享胶囊 300ms 迁移**。
///
/// 事实源：
/// - `home.css .layout-switch` 182–189：inline-flex、gap sp2、padding sp1、
///   radius-pill、`--glass-bg` 底 + 1px `--glass-border`；
/// - `home.css .layout-switch-btn` 191–206：36×36、radius-pill、
///   text-secondary、180ms background/color；`is-active` → ice .35 底 +
///   text-primary；
/// - `LayoutSwitch.tsx`：两个按钮各自渲染 `<AuroraquaNavHighlight id={同一个
///   useId()} />` —— **同一个 layoutId ⇒ Framer 共享布局动画**，切换时胶囊
///   从一个按钮滑到另一个（300ms、easeOut `[0,0,0.58,1]`）；
/// - `auroraqua.css` 190–192：`.layout-switch-btn.has-auroraqua-highlight`
///   的胶囊圆角覆写为 `--radius-pill`。
///
/// Flutter 等价：容器内**一个共享胶囊**用 [AnimatedAlign] 在左右两个槽位间
/// 迁移（300ms easeOut），两枚按钮不再各自画选中底。
class AylaLayoutSwitch extends StatefulWidget {
  const AylaLayoutSwitch({
    super.key,
    required this.isCard,
    required this.onChanged,
    this.semanticLabel = '主页布局',
  });

  /// true = 卡片布局选中，false = 列表布局选中。
  final bool isCard;

  /// 切换回调（true = 选卡片）。
  final ValueChanged<bool> onChanged;

  /// 组语义标签。
  final String semanticLabel;

  /// 按钮边长（web 36×36）。
  static const double _btnSize = 36;

  @override
  State<AylaLayoutSwitch> createState() => _AylaLayoutSwitchState();
}

class _AylaLayoutSwitchState extends State<AylaLayoutSwitch> {
  /// 选中按钮是否被 hover（驱动共享胶囊扫光）。
  bool _activeHovered = false;

  /// 指针位置（胶囊滑到静止鼠标下时的复检用；web 是纯 CSS :hover，
  /// 浏览器在元素移入指针时会重新判定,Flutter 需手动补）。
  Offset? _pointerPos;

  void _recheckHover() {
    final Offset? p = _pointerPos;
    if (p == null || !mounted) return;
    final RenderBox? self = context.findRenderObject() as RenderBox?;
    if (self == null) return;
    final HitTestResult result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, p, View.of(context).viewId);
    if (!mounted) return;
    final bool overSelf =
        result.path.any((HitTestEntry e) => e.target == self);
    if (overSelf != _activeHovered) {
      setState(() => _activeHovered = overSelf);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 共享胶囊：**300ms easeOut 迁移**（LayoutSwitch.tsx 里两个按钮共用同一个
    // useId 的 AuroraquaNavHighlight ⇒ Framer 共享布局动画，胶囊滑过去）。
    //
    // 几何纯算术（实测验证）：两枚 36px 钮 + gap sp2(8) ⇒
    //   卡片槽 left = 0，列表槽 left = 36 + 8 = 44，宽均 = 36。
    // （此前用 FractionallySizedBox(0.5) 按内容宽 80 算成 40 宽 → 与 36px 钮
    // 不重合,肉眼可见错位。）
    const double btn = AylaLayoutSwitch._btnSize; // 36
    const double gap = AylaSpacing.sp2; // 8
    final double left = widget.isCard ? 0 : btn + gap;

    return MouseRegion(
      onHover: (PointerHoverEvent e) => _pointerPos = e.position,
      child: Semantics(
      container: true,
      label: widget.semanticLabel,
      child: Container(
        padding: const EdgeInsets.all(AylaSpacing.sp1), // padding: var(--sp-1)
        decoration: BoxDecoration(
          color: GlassConfig.resolveBackground(strong: false),
          borderRadius: AylaRadii.pill, // border-radius: var(--radius-pill)
          border: Border.all(color: AylaColors.glassBorder),
        ),
        child: SizedBox(
          height: btn,
          child: Stack(
            children: <Widget>[
              AnimatedPositioned(
                duration: const Duration(milliseconds: 300), // 300ms
                curve: AylaCurves.auroraquaEaseOut, // [0,0,0.58,1]
                onEnd: _recheckHover, // 迁移结束复检指针是否被盖住
                left: left,
                top: 0,
                width: btn,
                height: btn,
                child: AylaNavHighlight(
                  pill: true, // auroraqua.css 190–192 覆写为 radius-pill
                  sweep: true,
                  sweepActive: _activeHovered,
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _LayoutSwitchButton(
                    icon: aylaIconByName('iconGrid')!,
                    active: widget.isCard,
                    label: '卡片布局',
                    size: btn,
                    onHoverChanged: (bool h) {
                      if (widget.isCard && h != _activeHovered) {
                        setState(() => _activeHovered = h);
                      }
                    },
                    onTap: () => widget.onChanged(true),
                  ),
                  const SizedBox(width: gap), // gap: var(--sp-2)
                  _LayoutSwitchButton(
                    icon: aylaIconByName('iconList')!,
                    active: !widget.isCard,
                    label: '列表布局',
                    size: btn,
                    onHoverChanged: (bool h) {
                      if (!widget.isCard && h != _activeHovered) {
                        setState(() => _activeHovered = h);
                      }
                    },
                    onTap: () => widget.onChanged(false),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
    );
  }
}

class _LayoutSwitchButton extends StatelessWidget {
  const _LayoutSwitchButton({
    required this.icon,
    required this.active,
    required this.label,
    required this.size,
    required this.onTap,
    this.onHoverChanged,
  });

  final AylaIconData icon;
  final bool active;
  final String label;
  final double size;
  final VoidCallback onTap;
  final ValueChanged<bool>? onHoverChanged;

  @override
  Widget build(BuildContext context) {
    // 选中底由**容器级共享胶囊**绘制（单一实例,可 300ms 迁移）；
    // 本按钮只负责图标与颜色（180ms，home.css 199–206），
    // hover 状态上报给容器驱动胶囊扫光。
    return Semantics(
      button: true,
      selected: active,
      label: label,
      child: AylaPressScale(
        onTap: onTap,
        semanticLabel: label,
        child: MouseRegion(
          opaque: true,
          onEnter: (_) => onHoverChanged?.call(true),
          onExit: (_) => onHoverChanged?.call(false),
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: AylaIcon(
                icon,
                size: 18,
                color:
                    active ? AylaColors.textPrimary : AylaColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 分段选项卡容器（`.messages-tabs`）——**共享选中胶囊 + 300ms 迁移**。
///
/// 事实源：
/// - `messages.css .messages-tabs` 17–22：flex + gap sp2 + padding sp3 sp4；
/// - `AuroraquaNavHighlight.tsx` + `auroraquaMotion.ts`：选中胶囊用 Framer
///   的 **共享布局动画**（`layoutId`）在 tab 间迁移，300ms、
///   `easeOut = cubic-bezier(0,0,0.58,1)`；胶囊几何/颜色见
///   `auroraqua.css .auroraqua-nav-highlight`（`--nav-active-bg` +
///   `--glass-shadow-nav` + 1px glass-border，`inset:0`、`z-index:-1`）。
///
/// Flutter 等价：**所有 tab 共享同一个胶囊实例**，用 [AnimatedAlign] 从上一
/// 个 tab 的位置迁移到当前 tab（300ms easeOut）；胶囊画在内容之下。
/// 这样切换时看到的是"胶囊滑过去"，而不是两个 tab 各自淡入淡出——与 web 的
/// layoutId 行为一致。
class AylaSegmentedTabs extends StatefulWidget {
  const AylaSegmentedTabs({
    super.key,
    required this.labels,
    required this.index,
    required this.onChanged,
    this.badges = const <int>[],
    this.semanticLabel,
  });

  /// 各 tab 文案。
  final List<String> labels;

  /// 当前选中索引。
  final int index;

  /// 切换回调。
  final ValueChanged<int> onChanged;

  /// 各 tab 徽标数（可为空；长度不足处视为 0）。
  final List<int> badges;

  /// 组语义标签。
  final String? semanticLabel;

  @override
  State<AylaSegmentedTabs> createState() => _AylaSegmentedTabsState();
}

class _AylaSegmentedTabsState extends State<AylaSegmentedTabs> {
  /// 选中 tab 是否被 hover（驱动共享胶囊扫光）。
  bool _activeHovered = false;

  /// 上一次已知的指针位置（用于"胶囊滑到鼠标下"的复检）。
  Offset? _pointerPos;

  /// **胶囊迁移到位后复检指针是否落在选中 tab 上**。
  ///
  /// web 是纯 CSS `:hover`，浏览器在元素移动进指针位置时会重新判定 hover；
  /// Flutter 的 MouseRegion 只在指针自身移动时更新 —— 因此「切换后胶囊滑到
  /// 静止的鼠标下方」不会触发扫光（用户实测反馈）。
  /// 这里在迁移动画结束后主动用 hitTest 复检一次，等价补齐 web 行为。
  void _recheckHoverAfterMigration() {
    final Offset? p = _pointerPos;
    if (p == null || !mounted) return;
    final RenderBox? self = context.findRenderObject() as RenderBox?;
    if (self == null) return;
    // 命中测试：指针点是否落在本组件内（选中 tab 由 build 时的几何决定）
    final HitTestResult result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, p, View.of(context).viewId);
    if (!mounted) return;
    final bool overSelf = result.path.any(
      (HitTestEntry e) => e.target == self,
    );
    if (overSelf != _activeHovered) {
      setState(() => _activeHovered = overSelf);
    }
  }

  @override
  Widget build(BuildContext context) {
    // tab 布局是确定的算术：n 个 Expanded 等分，间隙 gap = sp2 ×(n−1)。
    //   tabW = (W − gap×(n−1)) / n ；第 i 个 left = i × (tabW + gap)
    // 实测验证：容器 420 / n=3 → tab[1] L=142.7 R=277.3，胶囊同值重合。
    const double gap = AylaSpacing.sp2;
    final int n = widget.labels.length;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double w = c.maxWidth.isFinite ? c.maxWidth : 0;
        final double tabW = n > 0 ? (w - gap * (n - 1)) / n : 0;
        final double left = widget.index * (tabW + gap);

        return MouseRegion(
          // 记录指针位置：用于"胶囊滑到静止鼠标下"的迁移后复检
          onHover: (PointerHoverEvent e) => _pointerPos = e.position,
          child: Semantics(
          container: true,
          label: widget.semanticLabel,
          child: Stack(
            children: <Widget>[
              // 共享胶囊：单实例，**300ms easeOut 迁移**（web 的 layoutId 语义）
              if (w > 0 && tabW > 0)
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 300),
                  curve: AylaCurves.auroraquaEaseOut, // [0,0,0.58,1]
                  left: left,
                  top: 0,
                  width: tabW,
                  height: 40,
                  // 迁移结束 → 复检指针是否被"滑过来"的胶囊盖住
                  onEnd: _recheckHoverAfterMigration,
                  child: AylaNavHighlight(
                    sweep: true,
                    sweepActive: _activeHovered, // hover 选中 tab → 700ms 扫光
                  ),
                ),
              Row(
                children: <Widget>[
                  for (int i = 0; i < n; i++) ...<Widget>[
                    if (i > 0) const SizedBox(width: gap),
                    Expanded(
                      child: AylaSegmentedTab(
                        label: widget.labels[i],
                        active: i == widget.index,
                        badgeCount:
                            i < widget.badges.length ? widget.badges[i] : 0,
                        showOwnHighlight: false, // 胶囊由容器统一画（单一实例）
                        onHoverChanged: (bool h) {
                          if (i == widget.index && h != _activeHovered) {
                            setState(() => _activeHovered = h);
                          }
                        },
                        onTap: () => widget.onChanged(i),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        );
      },
    );
  }
}

/// 共享选中胶囊（web `AuroraquaNavHighlight` 的 Flutter 等价物）。
///
/// `auroraqua.css .auroraqua-nav-highlight` 175–191：
/// `inset: 0`、`z-index: -1`（内容之下）、`border-radius: inherit`、
/// `background: var(--nav-active-bg)`（135deg ice .35 → ice .18）、
/// `box-shadow: var(--glass-shadow-nav)`、`border: 1px solid --glass-border`。
class AylaNavHighlight extends StatefulWidget {
  const AylaNavHighlight({
    super.key,
    this.pill = false,
    this.sweep = false,
    this.sweepActive = false,
    this.radiusValue,
  });

  /// 外部（父级 tab/按钮）的 hover 状态——web 的选择器是
  /// `.has-auroraqua-highlight:hover > .auroraqua-nav-highlight::after`：
  /// **hover 判定在父元素上，作用于子级胶囊的伪元素**。
  /// 胶囊自身不接收指针（`pointer-events: none`），因此必须由父级驱动。
  final bool sweepActive;

  /// 覆盖圆角（不传则按 [pill] 推导）。
  final BorderRadius? radiusValue;

  /// 圆角是否为 pill（`.layout-switch-btn` / `.favorites-filter` /
  /// `.group-chat-subgroup-tab` 覆写为 radius-pill，auroraqua.css 190–192）。
  final bool pill;

  /// 是否启用选中项 hover 扫光。
  ///
  /// 事实源 auroraqua.css 149–166 + 187：`.auroraqua-nav-highlight::after`
  /// 是一条 `linear-gradient(90deg, transparent, --glass-border, transparent)`
  /// 光带，`opacity .5`、`translateX(-120%)`、**700ms**
  /// （`.auroraqua-nav-highlight::after { transition-duration: 700ms }`）；
  /// 父级 `.has-auroraqua-highlight:hover` 时 → `translateX(120%)`。
  final bool sweep;

  @override
  State<AylaNavHighlight> createState() => _AylaNavHighlightState();
}

class _AylaNavHighlightState extends State<AylaNavHighlight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700), // 700ms（导航选中项）
  );
  late final Animation<double> _sweepEased = CurvedAnimation(
    parent: _sweep,
    curve: AylaCurves.auroraqua, // var(--auroraqua-ease)
  );

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius = widget.radiusValue ??
        (widget.pill ? AylaRadii.pill : BorderRadius.circular(AylaRadii.rInput));
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);

    // 扫光由**父级 hover**驱动（web: `.has-auroraqua-highlight:hover >
    // .auroraqua-nav-highlight::after`）。胶囊自身不接收指针事件
    // （web 的 `pointer-events: none`），所以这里不挂 MouseRegion。
    final bool shouldSweep = widget.sweep && !reduceMotion;
    if (shouldSweep) {
      if (widget.sweepActive) {
        if (!_sweep.isAnimating) _sweep.forward();
      } else if (_sweep.value > 0) {
        _sweep.reverse();
      }
    }

    return IgnorePointer(
        child: ClipRRect(
          borderRadius: radius, // .auroraqua-nav-highlight { overflow: hidden }
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: cssLinearGradient(
                angleDeg: 135, // --nav-active-bg: linear-gradient(135deg, …)
                colors: AylaGradients.navActive,
              ),
              // border 由内层 DecoratedBox 画在裁剪内（圆角内可见）
              border: Border.all(color: AylaColors.glassBorder),
              boxShadow: AylaShadows.nav, // --glass-shadow-nav
            ),
            child: widget.sweep && !reduceMotion
                ? Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      AnimatedBuilder(
                        animation: _sweepEased,
                        builder: (BuildContext context, Widget? child) {
                          return FractionalTranslation(
                            translation:
                                Offset(-1.2 + _sweepEased.value * 2.4, 0),
                            child: child,
                          );
                        },
                        child: const Opacity(
                          opacity: 0.5, // ::after { opacity: .5 }
                          child: _SweepBand(),
                        ),
                      ),
                    ],
                  )
                : null,
          ),
        ),
    );
  }
}

/// 扫光带（`linear-gradient(90deg, transparent, --glass-border, transparent)`）。
class _SweepBand extends StatelessWidget {
  const _SweepBand();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: cssLinearGradient(
          angleDeg: 90,
          colors: AylaGradients.sweep,
        ),
      ),
    );
  }
}

/// `.messages-tab` 单枚（分段选项卡，`.messages-tabs` 容器由调用方排布）。
///
/// 高度 40、radius 12、14px/700；选中 → `rgba(157,191,230,.35)` + 主色字
/// （messages.css 24–37）。可选右侧徽标（`.messages-tab-badge`）。
class AylaSegmentedTab extends StatefulWidget {
  const AylaSegmentedTab({
    super.key,
    required this.label,
    required this.active,
    this.onTap,
    this.badgeCount = 0,
    this.expand = true,
    this.showOwnHighlight = true,
    this.onHoverChanged,
  });

  /// 文案。
  final String label;

  /// 是否选中。
  final bool active;

  /// 点击回调。
  final VoidCallback? onTap;

  /// 徽标数字（>0 显示；`.messages-tab-badge`）。
  final int badgeCount;

  /// 是否让内层 Row 撑满可用宽度（`.messages-tab { flex: 1 }`）。
  final bool expand;

  /// 是否自绘选中胶囊（单枚使用时 true；容器共享胶囊时 false）。
  final bool showOwnHighlight;

  /// hover 状态变化回调（供容器驱动共享胶囊的扫光）。
  final ValueChanged<bool>? onHoverChanged;

  @override
  State<AylaSegmentedTab> createState() => _AylaSegmentedTabState();
}

class _AylaSegmentedTabState extends State<AylaSegmentedTab> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);

    // 胶囊（`.auroraqua-nav-highlight`：position absolute; inset 0; z-index -1）
    // 扫光由本 tab 的 hover 驱动（web：`.has-auroraqua-highlight:hover >
    // .auroraqua-nav-highlight::after`）。
    final Widget capsule = AylaNavHighlight(
      radiusValue: BorderRadius.circular(AylaRadii.rInput),
      sweep: true,
      sweepActive: _hovered,
    );

    final Widget body = Stack(
      fit: StackFit.expand, // 内容层撑满整枚 tab（否则 Stack 收缩、内容靠左）
      children: <Widget>[
        if (widget.active && widget.showOwnHighlight)
          Positioned.fill(child: capsule),
        Padding(
          padding: widget.badgeCount > 0
              ? const EdgeInsets.symmetric(horizontal: AylaSpacing.sp2)
              : EdgeInsets.zero,
          child: Row(
            // 居中：撑满可用宽 + 主轴居中（`.messages-tab` 是 flex 容器，
            // 文字默认水平居中；web 用 flex:1 + 内容居中）
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Flexible(
                fit: FlexFit.loose,
                child: Center(
                  widthFactor: 1,
                  child: AnimatedDefaultTextStyle(
                    duration:
                        reduceMotion ? Duration.zero : AylaDurations.fast,
                    style: t.label.copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: widget.active
                          ? AylaColors.textPrimary
                          : AylaColors.textSecondary,
                    ),
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              if (widget.badgeCount > 0) ...<Widget>[
                const SizedBox(width: AylaSpacing.sp1), // margin-left sp1
                _TabBadgeInline(count: widget.badgeCount),
              ],
            ],
          ),
        ),
      ],
    );

    Widget result = Container(
      height: 40, // height: 40px
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AylaRadii.rInput), // radius 12
      ),
      child: body,
    );

    // hover 监听放在**按钮本体**（父级），驱动子级胶囊扫光
    result = MouseRegion(
      opaque: true,
      onEnter: (_) {
        setState(() => _hovered = true);
        widget.onHoverChanged?.call(true);
      },
      onExit: (_) {
        setState(() => _hovered = false);
        widget.onHoverChanged?.call(false);
      },
      child: result,
    );

    if (widget.onTap == null) {
      return Semantics(
        selected: widget.active,
        label: widget.label,
        child: result,
      );
    }
    return Semantics(
      button: true,
      selected: widget.active,
      label: widget.label,
      child: AylaPressScale(
        onTap: widget.onTap,
        semanticLabel: widget.label,
        child: result,
      ),
    );
  }
}

/// `.messages-tab-badge`（messages.css 43–57）：
/// `display:inline-grid`、**min-width 18 / height 18**、`padding 0 5`、
/// `margin-left: var(--sp-1)`、`border-radius: var(--radius-pill)`、
/// 底 `--pink-500`、字 `--surface`、**`font-family: var(--font-utility)`**
/// （Space Grotesk，不是 Fredoka）、`font-size: 11px`、`line-height: 1`、
/// `box-shadow: var(--glow-shadow)`。
///
/// 注意：它是**固定 18px 高的小圆**（内容更长时按 padding 撑成胶囊），
/// 绝不能跟随父容器高度拉伸——此前用 Row 内默认 stretch 导致被拉成大胶囊。
class _TabBadgeInline extends StatelessWidget {
  const _TabBadgeInline({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 18, maxHeight: 18),
      child: Container(
        height: 18, // height: 18px（固定,不随父拉伸）
        padding: const EdgeInsets.symmetric(horizontal: 5), // padding: 0 5px
        decoration: const BoxDecoration(
          color: AylaColors.pink500, // background: var(--pink-500)
          borderRadius: AylaRadii.pill,
          boxShadow: AylaShadows.glow, // box-shadow: var(--glow-shadow)
        ),
        alignment: Alignment.center,
        child: Text(
          count > 99 ? '99+' : '$count',
          maxLines: 1,
          style: const TextStyle(
            // font-family: var(--font-utility) → Space Grotesk
            fontFamily: AylaFonts.utility,
            fontFamilyFallback: AylaFonts.cjkFallback,
            fontSize: 11,
            height: 1, // line-height: 1
            fontWeight: FontWeight.w400,
            color: AylaColors.surface,
          ),
        ),
      ),
    );
  }
}

/// 胶囊标签（design.md §4 Tags/Badges + §12.9.1 Micro Tag）。
///
/// 默认（Micro Tag）：`--sakura-300` 底 + `--grape-700` 字 + Fredoka 11/500
/// + ls .8 + padding 6/14 + radius-pill（d:§3 Micro Tag / auth.css 203–212
/// 的特性胶囊同规格）。[tone] 提供其余语义色板（ice / glow / pink / surface）。
enum CapsuleTone {
  /// sakura-300 底 + grape-700 字（默认，Micro Tag）
  sakura,

  /// ice-100 底 + text-primary 字（历史搜索 chips）
  ice,

  /// glass-bg 底 + text-primary 字（玻璃胶囊）
  glass,

  /// pink-500 底 + surface 字（LIVE 徽标）
  pink,

  /// indigo-700 底 + surface 字（实底强调）
  indigo,
}

/// 胶囊标签（尺寸/圆角/字级按 [CapsuleTone] 与调用方给定）。
class AylaCapsuleTag extends StatelessWidget {
  const AylaCapsuleTag(
    this.label, {
    super.key,
    this.tone = CapsuleTone.sakura,
    this.icon,
    this.semanticLabel,
  });

  /// 文案。
  final String label;

  /// 色板。
  final CapsuleTone tone;

  /// 可选前置图标（12–14px 线性图标）。
  final Widget? icon;

  /// 可访问性标签。
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    late final Color bg;
    late final Color fg;
    late final Border? border;
    switch (tone) {
      case CapsuleTone.sakura:
        bg = AylaColors.sakura300;
        fg = AylaColors.grape700;
        border = null;
      case CapsuleTone.ice:
        bg = AylaColors.ice100; // 历史搜索 chips
        fg = AylaColors.textPrimary;
        border = null;
      case CapsuleTone.glass:
        bg = GlassConfig.resolveBackground(strong: false);
        fg = AylaColors.textPrimary;
        border = Border.all(color: AylaColors.glassBorder);
      case CapsuleTone.pink:
        bg = AylaColors.pink500; // LIVE 徽标
        fg = AylaColors.surface;
        border = null;
      case CapsuleTone.indigo:
        bg = AylaColors.indigo700;
        fg = AylaColors.surface;
        border = null;
    }

    return Semantics(
      label: semanticLabel ?? label,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: AylaRadii.pill,
          border: border,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              IconTheme(data: IconThemeData(color: fg, size: 12), child: icon!),
              const SizedBox(width: AylaSpacing.sp1),
            ],
            Text(
              label,
              maxLines: 1,
              style: TextStyle(
                fontFamily: AylaFonts.display,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.4,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `.scroll-text` —— 长文本单行 marquee（溢出才滚，未溢出静态）。
///
/// 事实源 base.css 724–758：容器 `white-space: nowrap` + overflow hidden；
/// 溢出时内层按 `scroll-text-marquee` 来回滚动——0–20% 停开头、
/// 50–70% 停结尾、100% 回到开头，linear 匀速；时长由距离/速度得出并夹在
/// 4~16s。`prefers-reduced-motion` 关闭滚动只裁剪。
class AylaScrollingText extends StatefulWidget {
  const AylaScrollingText({
    super.key,
    required this.text,
    this.style,
    this.speed = 24,
  });

  /// 文本。
  final String text;

  /// 文字样式（默认 body）。
  final TextStyle? style;

  /// 每秒滚动像素（默认 24；越大越快）。
  final double speed;

  @override
  State<AylaScrollingText> createState() => _AylaScrollingTextState();
}

class _AylaScrollingTextState extends State<AylaScrollingText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _marquee = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
  );

  /// 溢出距离（>0 才滚动）。用 TextPainter 同步测量，避免依赖"先渲染再回读"
  /// 造成的死锁：未溢出分支不带测量用的 key，就永远测不出溢出（此前实测
  /// 「长文本不滚」的根因）。
  double _overflow = 0;
  double _lastWidth = -1;

  /// marquee 时间轴（对齐 base.css keyframes 百分比）：
  /// 0–20% 停开头 → 20–50% 滚到尾 → 50–70% 停结尾 → 70–100% 滚回开头。
  double _offsetFor(double t) {
    if (t <= 0.2) return 0;
    if (t <= 0.5) return -(t - 0.2) / 0.3 * _overflow;
    if (t <= 0.7) return -_overflow;
    return -(1 - (t - 0.7) / 0.3) * _overflow;
  }

  TextStyle _resolveStyle(BuildContext context) =>
      widget.style ??
      AylaTextStyles.of(context)
          .body
          .copyWith(color: AylaColors.textPrimary);

  /// 测量文本自然宽度与容器可用宽度的差（正数=溢出）。
  void _measure(double available, TextStyle style, double scale) {
    if ((available - _lastWidth).abs() < 0.5) return; // 宽度没变不必重测
    _lastWidth = available;
    final TextPainter tp = TextPainter(
      text: TextSpan(text: widget.text, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.linear(scale),
    )..layout();
    final double overflow = tp.size.width - available;
    tp.dispose();

    final double next = overflow > 1 ? overflow : 0;
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (next > 0 && !reduceMotion) {
      // duration = clamp(distance / speed, 4, 16) 秒（web ScrollingText 同式）
      final double secs = (next / widget.speed).clamp(4.0, 16.0);
      _marquee.duration = Duration(milliseconds: (secs * 1000).round());
      if (!_marquee.isAnimating) _marquee.repeat();
    } else {
      _marquee.stop();
    }
    if ((next - _overflow).abs() > 0.5) {
      // 布局阶段更新测量结果：用 post-frame 避免 build 期间 setState
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _overflow = next);
      });
      _overflow = next; // 本帧即用新值（避免闪一帧静态）
    }
  }

  @override
  void dispose() {
    _marquee.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle style = _resolveStyle(context);
    final double scale = MediaQuery.textScalerOf(context).scale(1);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double available = constraints.maxWidth;
        if (available.isFinite && available > 0) {
          _measure(available, style, scale);
        }

        final Widget label = Text(
          widget.text,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.visible, // 溢出交给外层 ClipRect 裁
          style: style,
        );

        if (_overflow <= 0) {
          // 未溢出：静态单行（超出即省略，语义同 web 未溢出分支）
          return ClipRect(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.text,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
          );
        }

        return ClipRect(
          child: AnimatedBuilder(
            animation: _marquee,
            builder: (BuildContext context, Widget? child) {
              return Transform.translate(
                offset: Offset(_offsetFor(_marquee.value), 0),
                child: child,
              );
            },
            child: label,
          ),
        );
      },
    );
  }
}
/// `.scroll-tags` —— 标签横向 marquee（溢出时滚 + **左右 14px 渐隐**）。
///
/// 事实源 `base.css` 760–806：
/// - `.scroll-tags`：`display:block`、`min-width:0`、overflow hidden、nowrap；
/// - `.scroll-tags-inner`：inline-flex、`gap: var(--sp-1)`、nowrap；
/// - 溢出时 `.scroll-tags-inner` 复用 `scroll-text-marquee` 关键帧（与
///   ScrollingText 同一时序：0–20% 停开头 / 50–70% 停结尾 / 100% 回开头，
///   linear，时长由组件测量夹 4~16s）；
/// - **溢出时左右边缘渐隐**（`mask-image: linear-gradient(to right,
///   transparent 0, #000 14px, #000 calc(100% - 14px), transparent 100%)`）
///   ——替代硬裁剪的生硬截断；未溢出时不加 mask。
/// - `prefers-reduced-motion`：停止滚动（仅裁剪）。
class AylaScrollingTags extends StatefulWidget {
  const AylaScrollingTags({
    super.key,
    required this.children,
    this.speed = 24,
    this.fadeWidth = 14, // mask 渐隐 14px（base.css）
  });

  /// 标签（横向排列，间距 sp1）。
  final List<Widget> children;

  /// 每秒滚动像素（默认 24）。
  final double speed;

  /// 左右渐隐宽度（px，web 为 14px）。
  final double fadeWidth;

  @override
  State<AylaScrollingTags> createState() => _AylaScrollingTagsState();
}

class _AylaScrollingTagsState extends State<AylaScrollingTags>
    with SingleTickerProviderStateMixin {
  late final AnimationController _marquee = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
  );

  final GlobalKey _innerKey = GlobalKey();
  double _overflow = 0;

  double _offsetFor(double t) {
    if (t <= 0.2) return 0;
    if (t <= 0.5) return -(t - 0.2) / 0.3 * _overflow;
    if (t <= 0.7) return -_overflow;
    return -(1 - (t - 0.7) / 0.3) * _overflow;
  }

  void _measure(double available) {
    final RenderBox? inner =
        _innerKey.currentContext?.findRenderObject() as RenderBox?;
    if (inner == null || !available.isFinite || available <= 0) return;
    final double d = inner.size.width - available;
    final double next = d > 1 ? d : 0;
    if ((next - _overflow).abs() < 0.5) return;
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    setState(() => _overflow = next);
    if (next > 0 && !reduceMotion) {
      final double secs = (next / widget.speed).clamp(4.0, 16.0);
      _marquee.duration = Duration(milliseconds: (secs * 1000).round());
      if (!_marquee.isAnimating) _marquee.repeat();
    } else {
      _marquee.stop();
    }
  }

  @override
  void dispose() {
    _marquee.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool overflowing = _overflow > 0;

    Widget content = Row(
      key: _innerKey,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < widget.children.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: AylaSpacing.sp1), // gap: sp1
          widget.children[i],
        ],
      ],
    );

    if (overflowing) {
      content = AnimatedBuilder(
        animation: _marquee,
        builder: (BuildContext context, Widget? child) => Transform.translate(
          offset: Offset(_offsetFor(_marquee.value), 0),
          child: child,
        ),
        child: content,
      );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _measure(c.maxWidth);
        });

        // 内层 Row 按内容自然宽度排布，溢出由 ClipRect 裁剪（对齐 web 的
        // `overflow: hidden` + `white-space: nowrap`）。
        // SizedBox(height: 40) 给有限高度：否则 OverflowBox 在无界高度祖先
        // 下会抛 "given an infinite size during layout"（实测）。
        Widget clipped = ClipRect(
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              height: 40,
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                maxWidth: double.infinity,
                minHeight: 40,
                maxHeight: 40,
                child: content,
              ),
            ),
          ),
        );

        // 溢出时套 mask 渐隐（未溢出不加，对齐 web）
        if (overflowing) {
          clipped = ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (Rect bounds) => LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: const <Color>[Color(0x00000000), Color(0xFF000000),
                  Color(0xFF000000), Color(0x00000000)],
              stops: <double>[
                0,
                widget.fadeWidth / (bounds.width == 0 ? 1 : bounds.width),
                1 - widget.fadeWidth / (bounds.width == 0 ? 1 : bounds.width),
                1,
              ],
            ).createShader(bounds),
            child: clipped,
          );
        }

        return clipped;
      },
    );
  }
}

// ======================= 预览 =======================

/// B2 批全量（LayoutSwitch / SegmentedTab / CapsuleTag / ScrollingText）。
@Preview(
  group: 'Batch2',
  name: 'B2 展示型基元全量',
  size: Size(760, 560),
  wrapper: previewTheme,
)
Widget batch2Preview() {
  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        const Text('LayoutSwitch（选中卡片 / 列表）'),
        const SizedBox(height: AylaSpacing.sp3),
        Row(
          children: <Widget>[
            AylaLayoutSwitch(isCard: true, onChanged: (_) {}),
            const SizedBox(width: AylaSpacing.sp4),
            AylaLayoutSwitch(isCard: false, onChanged: (_) {}),
          ],
        ),
        const SizedBox(height: AylaSpacing.sp6),
        const Text('SegmentedTab（选中 / 带徽标 / 未选中）'),
        const SizedBox(height: AylaSpacing.sp3),
        SizedBox(
          width: 420,
          child: Row(
            children: <Widget>[
              AylaSegmentedTab(label: '私信', active: true, onTap: () {}),
              const SizedBox(width: AylaSpacing.sp2),
              AylaSegmentedTab(
                label: '认证消息',
                active: false,
                badgeCount: 5,
                onTap: () {},
              ),
            ],
          ),
        ),
        const SizedBox(height: AylaSpacing.sp6),
        const Text('CapsuleTag（五种色板）'),
        const SizedBox(height: AylaSpacing.sp3),
        const Wrap(
          spacing: AylaSpacing.sp2,
          runSpacing: AylaSpacing.sp2,
          children: <Widget>[
            AylaCapsuleTag('数字生命'),
            AylaCapsuleTag('持续记忆'),
            AylaCapsuleTag('历史搜索', tone: CapsuleTone.ice),
            AylaCapsuleTag('玻璃胶囊', tone: CapsuleTone.glass),
            AylaCapsuleTag('LIVE', tone: CapsuleTone.pink),
            AylaCapsuleTag('实底', tone: CapsuleTone.indigo),
          ],
        ),
        const SizedBox(height: AylaSpacing.sp6),
        const Text('ScrollingText（溢出滚动 / 未溢出静态）'),
        const SizedBox(height: AylaSpacing.sp3),
        const SizedBox(
          width: 260,
          child: AylaScrollingText(
            text: '这是一段很长的、超出容器宽度的文本，用来验证 marquee 来回滚动的效果是否与 web 一致',
          ),
        ),
        const SizedBox(height: AylaSpacing.sp2),
        const SizedBox(
          width: 260,
          child: AylaScrollingText(text: '短文本静态显示'),
        ),
      ],
    ),
  );
}
