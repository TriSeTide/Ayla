/// layout switch（自 `primitives.dart` 拆出：一文件一件）。
///
/// 事实源与逐条对照见 `docs/flutter/17-组件文件头归档（整理前原文）.md` 的 `primitives.dart` 一节
/// 与各件的 `///` 头注。
///
/// ## 公开面
/// `AylaLayoutSwitch`

library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../../theme/app_icons.dart';
import '../../theme/buttons.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import 'nav_highlight.dart';

/// `.layout-switch` —— 主页布局切换（卡片 / 列表）。
///
/// ══ web 事实链（完整，含 CSS 层叠） ══
/// DOM：`div.layout-switch` > 两个 `button.layout-switch-btn.has-auroraqua-highlight`
///      选中项加 `.is-active`，且**选中项内部**渲染 `<span.auroraqua-nav-highlight>`。
/// CSS 加载序：home.css → auroraqua.css（**后者覆盖**）。
///
/// 1. `.layout-switch`（home.css 182–189）
///      `inline-flex` / `gap: sp2` / `padding: sp1` / `radius-pill` /
///      `--glass-bg` / `1px --glass-border`
///    **auroraqua.css 272–277 覆写**：
///      `:is(.messages-tabs, .layout-switch) { border: 1px solid --glass-border;
///        border-radius: var(--radius-card);      ← **16px 圆角矩形**（覆写 pill）
///        box-shadow: var(--glass-inset); }        ← **只有顶沿 1px 内高光**
///    ⇒ 最终：16 圆角 + glass-bg + 1px 亮边 + **无外阴影、有内高光**
/// 2. `.layout-switch-btn`（home.css 191–201）
///      `width/height: 36px` / `border-radius: var(--radius-pill)` /
///      `color: --text-secondary` / `transition: background,color 180ms ease-out`
/// 3. `.layout-switch-btn.is-active`（home.css 203–206）：`background:
///    rgba(157,191,230,.35)` + `text-primary`
///    **auroraqua.css 194–197 覆写**：
///      `.has-auroraqua-highlight:is(.is-active, .active) { background: transparent;
///        box-shadow: none; }`  ← 选中底**不再由按钮画**
/// 4. `.auroraqua-nav-highlight`（auroraqua.css 175–185）：`position:absolute;
///    inset:0`（= 按钮 36×36）/ **`border-radius: inherit`**（继承按钮 pill →
///    36×36 正方形上即 **正圆**）/ `overflow:hidden` / `--nav-active-bg` 渐变 /
///    `--glass-shadow-nav` / `1px --glass-border`
/// 5. 交互动画（auroraqua.css 54–94）：200ms 组过渡 + `:hover { scale: 1.02 }`
///    + `:active { scale: .98 }`
/// 6. 选中胶囊扫光（auroraqua.css 149–166 + 187）：`::after` 700ms
/// 7. 共享布局动画（LayoutSwitch.tsx 两个按钮共用同一 `useId`）：Framer
///    `layoutId` ⇒ **同一胶囊实体**在按钮间迁移，300ms、easeOut `[0,0,0.58,1]`
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

  /// `.layout-switch-btn { width: 36px; height: 36px }`。
  static const double btnSize = 36;

  /// `.layout-switch { gap: var(--sp-2) }`。
  static const double gap = AylaSpacing.sp2; // 8

  /// `.layout-switch { padding: var(--sp-1) }`。
  static const double pad = AylaSpacing.sp1; // 4

  /// 容器总高 = 36 + padding×2 + border×2 = 46（内高光按此高度算 1px）。
  static const double containerHeight = btnSize + pad * 2 + 2;

  @override
  State<AylaLayoutSwitch> createState() => _AylaLayoutSwitchState();
}

class _AylaLayoutSwitchState extends State<AylaLayoutSwitch> {
  /// 选中按钮是否被 hover —— 驱动胶囊扫光（web：`.has-auroraqua-highlight:hover
  /// > .auroraqua-nav-highlight::after`）。
  bool _activeHovered = false;

  /// 选中按钮是否被按下 —— 驱动**胶囊**同步 `scale: .98`
  /// （web 里胶囊是 `<button>` 的子元素，`:active { scale:.98 }` 连带缩放；
  ///  Flutter 侧胶囊与按钮平级，须显式同步）。
  bool _activePressed = false;

  /// 最近指针位置：用于「胶囊滑到静止指针下方」的迁移后复检
  /// （浏览器会在元素移入指针位置时重判 `:hover`，Flutter 不会）。
  Offset? _pointerPos;

  void _recheckHover() {
    final Offset? p = _pointerPos;
    if (p == null || !mounted) return;
    final RenderBox? self = context.findRenderObject() as RenderBox?;
    if (self == null) return;
    final HitTestResult result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, p, View.of(context).viewId);
    if (!mounted) return;
    final bool over = result.path.any((HitTestEntry e) => e.target == self);
    if (over != _activeHovered) setState(() => _activeHovered = over);
  }

  @override
  Widget build(BuildContext context) {
    const double btn = AylaLayoutSwitch.btnSize;
    const double gap = AylaLayoutSwitch.gap;
    final double left = widget.isCard ? 0 : btn + gap;
    // `.layout-switch` 最终圆角 = --radius-card（auroraqua.css 275 覆写 home.css 的 pill）
    final BorderRadius containerRadius =
        BorderRadius.circular(AylaRadii.rCard);

    return MouseRegion(
      onHover: (PointerHoverEvent e) => _pointerPos = e.position,
      child: Semantics(
        container: true,
        label: widget.semanticLabel,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AylaGlassConfig.resolveBackground(strong: false), // --glass-bg
            borderRadius: containerRadius, // --radius-card 16
            border: Border.all(color: AylaColors.glassBorder), // 1px --glass-border
            // box-shadow: var(--glass-inset) —— **无外阴影**，内高光见下
          ),
          child: Stack(
            children: <Widget>[
              // box-shadow: var(--glass-inset) 的等价层（顶沿 1px 白高光）
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: containerRadius,
                      gradient: AylaInset.topHighlight(
                        AylaLayoutSwitch.containerHeight,
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(AylaLayoutSwitch.pad), // padding: sp1
                child: SizedBox(
                  height: btn,
                  child: Stack(
                    children: <Widget>[
                      // `.auroraqua-nav-highlight`：absolute inset:0 +
                      // border-radius: inherit（按钮 pill → 正圆）——
                      // 单实例 + 300ms 迁移（Framer layoutId 的等价）
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 300),
                        curve: AylaCurves.auroraquaEaseOut, // [0,0,0.58,1]
                        onEnd: _recheckHover,
                        left: left,
                        top: 0,
                        width: btn,
                        height: btn,
                    // 胶囊随选中 tab 一起按压缩放（web：胶囊是按钮子元素）
                    child: AnimatedScale(
                      scale: _activePressed ? 0.98 : 1.0,
                      duration: const Duration(milliseconds: 200), // scale 200ms
                      curve: AylaCurves.auroraqua,
                      child: AylaNavHighlight(
                        // `.auroraqua-nav-highlight { border-radius: inherit }`
                        // 父 `.layout-switch-btn` 是 `--radius-pill` 且盒子
                        // 36×36 → **正圆**（不是圆角矩形）
                        pill: true,
                        sweep: true,
                        sweepActive: _activeHovered,
                      ),
                    ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          _LayoutSwitchButton(
                            icon: aylaIconByName('iconGrid')!,
                            active: widget.isCard,
                            label: '卡片布局',
                            onHoverChanged: (bool h) {
                              if (widget.isCard && h != _activeHovered) {
                                setState(() => _activeHovered = h);
                              }
                            },
                            onPressChanged: (bool p) {
                              if (widget.isCard && p != _activePressed) {
                                setState(() => _activePressed = p);
                              }
                            },
                            onTap: () => widget.onChanged(true),
                          ),
                          const SizedBox(width: gap), // gap: sp2
                          _LayoutSwitchButton(
                            icon: aylaIconByName('iconList')!,
                            active: !widget.isCard,
                            label: '列表布局',
                            onHoverChanged: (bool h) {
                              if (!widget.isCard && h != _activeHovered) {
                                setState(() => _activeHovered = h);
                              }
                            },
                            onPressChanged: (bool p) {
                              if (!widget.isCard && p != _activePressed) {
                                setState(() => _activePressed = p);
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
            ],
          ),
        ),
      ),
    );
  }
}

/// `.layout-switch-btn` —— 36×36 图标按钮（选中底由容器胶囊提供）。
class _LayoutSwitchButton extends StatelessWidget {
  const _LayoutSwitchButton({
    required this.icon,
    required this.active,
    required this.label,
    required this.onTap,
    this.onHoverChanged,
    this.onPressChanged,
  });

  final AylaIconData icon;
  final bool active;
  final String label;
  final VoidCallback onTap;
  final ValueChanged<bool>? onHoverChanged;

  /// 按压状态回调（供容器让共享胶囊同步 scale .98）。
  final ValueChanged<bool>? onPressChanged;

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      selected: active,
      label: label,
      child: AylaPressScale(
        onTap: onTap,
        semanticLabel: label,
        onPressChanged: onPressChanged,
        child: MouseRegion(
          opaque: true,
          onEnter: (_) => onHoverChanged?.call(true),
          onExit: (_) => onHoverChanged?.call(false),
          child: SizedBox(
            width: AylaLayoutSwitch.btnSize,
            height: AylaLayoutSwitch.btnSize,
            child: Center(
              // .layout-switch-btn { transition: color 180ms }；选中转 text-primary
              // （选中底由胶囊画，按钮自身 background: transparent）
              child: AnimatedDefaultTextStyle(
                duration:
                    reduceMotion ? Duration.zero : AylaDurations.fast,
                style: const TextStyle(),
                child: AylaIcon(
                  icon,
                  size: 18,
                  color: active
                      ? AylaColors.textPrimary
                      : AylaColors.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
