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
            color: GlassConfig.resolveBackground(strong: false), // --glass-bg
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

/// 分段选项卡容器（`.messages-tabs`）—— 选中胶囊 300ms 迁移。
///
/// **1:1 对照 `messages.css` 17–37 + `MessagesPage.tsx` 209–241**
/// （`.messages-tabs { gap: sp2 }`；`.messages-tab { flex:1; height:40px;
/// border-radius: --radius-input }`；选中项内含 `AuroraquaNavHighlight`）。
///
/// Flutter 等价：单个胶囊 + `AnimatedPositioned`；几何纯算术
/// （n 个等分槽 + gap×(n−1) 间隙）：
///   `tabW = (W − gap×(n−1)) / n`，`left(i) = i × (tabW + gap)`
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
  bool _activeHovered = false;
  bool _activePressed = false;
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
    const double gap = AylaSpacing.sp2; // `.messages-tabs { gap: var(--sp-2) }`
    final int n = widget.labels.length;
    // `.messages-tabs`（messages.css 17–22）+ **auroraqua.css 272–278 覆写**：
    //   :is(.messages-tabs, .layout-switch) {
    //     border: 1px solid --glass-border;
    //     border-radius: var(--radius-card);   ← 16 圆角矩形（覆写默认）
    //     box-shadow: var(--glass-inset);      ← 只有顶沿 1px 内高光
    //   }
    //   .messages-tabs { margin: var(--sp-2); padding: var(--sp-1); }
    //     ← 覆写 messages.css 的 padding: sp3 sp4
    final BorderRadius containerRadius =
        BorderRadius.circular(AylaRadii.rCard);

    return MouseRegion(
      onHover: (PointerHoverEvent e) => _pointerPos = e.position,
      child: Semantics(
        container: true,
        label: widget.semanticLabel,
        child: Container(
          margin: const EdgeInsets.all(AylaSpacing.sp2), // margin: sp2
          decoration: BoxDecoration(
            borderRadius: containerRadius, // --radius-card 16
            border: Border.all(color: AylaColors.glassBorder),
            // box-shadow: var(--glass-inset)：内高光见下（无外阴影）
          ),
          // 关键：LayoutBuilder 放在 **padding 内部**，它的 maxWidth 即
          // Stack 的真实可用宽——几何才不会因 border/padding 产生累积误差
          // （此前 LayoutBuilder 在外层、又手工减 padding 却漏了 border，
          //  导致胶囊与 tab 错位，实测滑到下一个 tab）。
          child: Padding(
            padding: const EdgeInsets.all(AylaSpacing.sp1), // padding: sp1
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) {
                final double w = c.maxWidth.isFinite ? c.maxWidth : 0;
                final double tabW = n > 0 ? (w - gap * (n - 1)) / n : 0;
                final double left = widget.index * (tabW + gap);

                return Stack(
                  children: <Widget>[
                    // box-shadow: var(--glass-inset) 的等价层（顶沿 1px 高光）
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: AylaInset.topHighlight(40),
                          ),
                        ),
                      ),
                    ),
                    if (w > 0 && tabW > 0)
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 300),
                        curve: AylaCurves.auroraquaEaseOut,
                        onEnd: _recheckHover,
                        left: left,
                        top: 0,
                        width: tabW,
                        height: 40,
                        // 胶囊随选中 tab 一起按压缩放（web：胶囊是按钮子元素）
                        child: AnimatedScale(
                          scale: _activePressed ? 0.98 : 1.0,
                          duration: const Duration(milliseconds: 200),
                          curve: AylaCurves.auroraqua,
                          child: AylaNavHighlight(
                            // 不传 pill → 继承 `.messages-tab` 的
                            // `--radius-input`(12) ⇒ **圆角矩形**
                            sweep: true,
                            sweepActive: _activeHovered,
                          ),
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
                              badgeCount: i < widget.badges.length
                                  ? widget.badges[i]
                                  : 0,
                              onHoverChanged: (bool h) {
                                if (i == widget.index &&
                                    h != _activeHovered) {
                                  setState(() => _activeHovered = h);
                                }
                              },
                              onPressChanged: (bool p) {
                                if (i == widget.index &&
                                    p != _activePressed) {
                                  setState(() => _activePressed = p);
                                }
                              },
                              onTap: () => widget.onChanged(i),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

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
    this.showBorder = true,
  });

  /// 外部（父级 tab/按钮）的 hover 状态——web 的选择器是
  /// `.has-auroraqua-highlight:hover > .auroraqua-nav-highlight::after`：
  /// **hover 判定在父元素上，作用于子级胶囊的伪元素**。
  /// 胶囊自身不接收指针（`pointer-events: none`），因此必须由父级驱动。
  final bool sweepActive;

  /// 覆盖圆角（不传则按 [pill] 推导）。
  final BorderRadius? radiusValue;

  /// 是否绘制 1px 亮边（`--glass-border`）。
  ///
  /// **默认 true**（对齐 `.auroraqua-nav-highlight { border: 1px solid ... }`）。
  /// 当**宿主按钮自己也画了同色 1px 边框**时（如 `.directory-filter.is-active {
  /// border-color: var(--glass-border) }`），两层 border 会**精确重叠**成
  /// 「双线」（实测：按钮层 (230,236,248) + 胶囊层 (248,251,253) 各 1px）。
  /// web 靠 `z-index: -1` 让胶囊退到按钮之下、视觉合一；Flutter 侧显式
  /// 只保留按钮那一层更稳定 → 此场景传 `false`。
  final bool showBorder;

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
  State<AylaNavHighlight> createState() => AylaNavHighlightState();
}

class AylaNavHighlightState extends State<AylaNavHighlight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700), // 700ms（导航选中项）
  );
  late final Animation<double> _sweepEased = CurvedAnimation(
    parent: _sweep,
    curve: AylaCurves.auroraqua, // var(--auroraqua-ease)
  );

  /// **直接驱动扫光**（供宿主在指针进入时立即调用）。
  ///
  /// 为什么要这个入口：web 的 `:hover` 由浏览器合成器**原生响应（0 帧）**；
  /// 而「子级通知父级 → 父级 setState → rebuild → 子级才 forward()」需要
  /// **2 帧**（实测 32ms 才见位移），手感明显滞后于 web。
  /// 让命中指针的那个 tab 直达这里启动动画，可省掉 1 帧。
  void setSweep(bool active, {bool jump = false}) {
    if (!widget.sweep || MediaQuery.disableAnimationsOf(context)) return;
    if (active) {
      if (jump) {
        // **挂载即命中**：web 上胶囊被挂载到「鼠标已在上面」的 tab 时，
        // 元素首次绘制的 computed style 就已经是 `translateX(120%)`
        // （`:hover` 从第一帧就匹配）→ **没有 transition**（无"前值"可过渡）。
        // 之后鼠标移走 → `120% → -120%` → transition 跑出**完整的一次
        // 从右往左扫**。这正是用户看到的效果。
        // 反之若此处启动 forward()，行程会被提前消耗（16ms 只走 3%），
        // 移走时的回程几乎为零 → 看不到扫光（实测 dx 恒 ≈ -1.17）。
        _sweep.value = 1.0;
      } else if (!_sweep.isAnimating && _sweep.value < 1.0) {
        // 普通 hover 进入已挂载的胶囊：-120% → 120%，从左往右扫
        _sweep.forward();
      }
    } else {
      // `:hover` 消失 → 目标变回 -120%；从**当前值**过渡（CSS transition 语义）
      if (_sweep.isAnimating || _sweep.value > 0) _sweep.reverse();
    }
  }

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
        if (!_sweep.isAnimating && _sweep.value < 1.0) _sweep.forward();
      } else if (_sweep.isAnimating || _sweep.value > 0) {
        // 同 setSweep：单用 `value > 0` 会在「刚 forward 未 tick」时失效
        // （value 还是 0 → 不 reverse → 扫光卡在起点）
        _sweep.reverse();
      }
    }

    // ── 严格照抄 auroraqua.css 175–185 ──
    //   position: absolute; inset: 0;      → 尺寸 = 调用方给定
    //   border-radius: inherit;            → radius（继承父元素圆角）
    //   overflow: hidden;                  → **只裁内部扫光**
    //   background: var(--nav-active-bg);  → 135deg 冰蓝渐变
    //   box-shadow: var(--glass-shadow-nav);→ 0 0 8px rgba(157,191,230,.3)
    //   border: 1px solid var(--glass-border);
    //
    // **分层纪律**（此前三处做错）：
    //  ① **边框必须与渐变分层**：Flutter 的 `BoxDecoration` 同时设 `gradient` 与
    //     `border` 时，**渐变填充会盖住 1px 边框**（实测：胶囊单独渲染时
    //     y=18 起直接进渐变底色，白边完全不可见）。web 的 `background` 与
    //     `border` 是分离绘制、两者都可见。故这里拆成
    //     「底色+阴影层」→「边框层」→「扫光层」。
    //  ② 圆角必须在**画边框的那一层**给出（否则边框沿矩形绘制 → 圆被切）；
    //  ③ `overflow: hidden` 只包**扫光层**——若包住含 boxShadow 的整层，
    //     Flutter 的 ClipRRect 会把阴影一起裁掉（CSS 的 overflow 不裁自身阴影）
    //     → 胶囊看起来"上下左右被切"。
    // ⚠️ **阴影不能挂 `BoxDecoration(boxShadow:)`**：CSS 规定 `box-shadow`
    // **不在 border-box 内部绘制**；Flutter 的 `BoxShadow` 会**铺满形状含内部**。
    // `--glass-shadow-nav` = `0 0 8px rgba(157,191,230,.3)` → 把整个胶囊内部
    // 再染一层冰蓝。
    //
    // 实测证据（卡片底 #FFFAFB + ice-500 渐变）：
    //   web 胶囊内部应为 **(229,234,245)**（纯 `--nav-active-bg`）
    //   挂 boxShadow 后是  **(205,220,240)**
    //   ≈ 在 web 值上再叠 `.3` 冰蓝 → **(207,221,240)**（差仅 (2,1,0)）
    //   ⇒ 证实内部被多画一层阴影 → 高亮块偏暗偏蓝。
    //
    // **当前决定：胶囊不画外阴影**（已移除 `boxShadow`，暂不补 ring 层）。
    // 用户 2026-09-20 验收 release 后确认「正常」，故维持现状。
    // 若日后要补齐 `--glass-shadow-nav` 的 8px 冰蓝外发光，请用
    // [AylaGlassShadow.ring]（只画形状之外）—— **不要**改回 `boxShadow`。
    final Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        gradient: cssLinearGradient(
          angleDeg: 135, // --nav-active-bg: linear-gradient(135deg, …)
          colors: AylaGradients.navActive,
        ),
        borderRadius: radius,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // --glass-inset（顶沿 1px 内高光）也在此层内绘制
          if (widget.sweep && !reduceMotion)
            ClipRRect(
              // overflow: hidden 只作用于扫光
              borderRadius: radius,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  AnimatedBuilder(
                    animation: _sweepEased,
                    builder: (BuildContext context, Widget? child) {
                      return FractionalTranslation(
                        translation: Offset(-1.2 + _sweepEased.value * 2.4, 0),
                        child: child,
                      );
                    },
                    child: const Opacity(
                      opacity: 0.5, // ::after { opacity: .5 }
                      child: _SweepBand(),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );

    // --glass-inset 的等价层（形状内顶沿 1px 白高光）+ 1px 亮边，叠在 surface 之上。
    //
    // **为什么边框单独一层**：Flutter 的 `BoxDecoration` 同时设 `gradient` 与
    // `border` 时，**渐变填充会盖住 1px 边框**（实测：胶囊单独渲染时从内容起点
    // 直接进渐变底色，白边完全不可见）。web 的 `background` 与 `border` 分离
    // 绘制、两者都可见 → 这里同样拆层。
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          return Stack(
            children: <Widget>[
              surface,
              // --glass-inset：形状内顶沿 1px 白高光
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      gradient: AylaInset.topHighlight(c.maxHeight),
                    ),
                  ),
                ),
              ),
              // 1px 亮边（`--glass-border`）。宿主按钮已画同色边时传
              // showBorder=false 以避免两层重叠（见 showBorder 文档）。
              if (widget.showBorder)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: radius,
                        border: Border.all(color: AylaColors.glassBorder),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
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
/// `.messages-tab` —— 选项卡按钮本体（高 40 / radius 12 / 14-700）。
///
/// `messages.css` 24–37：`flex: 1`、`height: 40px`、
/// `border-radius: var(--radius-input)`、14px/700、`text-secondary`；
/// `.is-active` → `text-primary`（选中底由容器胶囊提供，对齐 auroraqua.css
/// 194–197 的 `background: transparent`）。可选右侧徽标。
class AylaSegmentedTab extends StatefulWidget {
  const AylaSegmentedTab({
    super.key,
    required this.label,
    required this.active,
    this.onTap,
    this.badgeCount = 0,
    this.onHoverChanged,
    this.onPressChanged,
  });

  /// 文案。
  final String label;

  /// 是否选中。
  final bool active;

  /// 点击回调。
  final VoidCallback? onTap;

  /// 徽标数字（>0 显示；`.messages-tab-badge`）。
  final int badgeCount;

  /// hover 状态回调（供容器驱动共享胶囊扫光）。
  final ValueChanged<bool>? onHoverChanged;

  /// 按压状态回调（供容器让共享胶囊同步 scale .98）。
  final ValueChanged<bool>? onPressChanged;

  @override
  State<AylaSegmentedTab> createState() => _AylaSegmentedTabState();
}

class _AylaSegmentedTabState extends State<AylaSegmentedTab> {
  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);

    Widget button = Container(
      height: 40, // height: 40px
      padding: widget.badgeCount > 0
          ? const EdgeInsets.symmetric(horizontal: AylaSpacing.sp2)
          : EdgeInsets.zero,
      child: Row(
        // 内容居中（`.messages-tab` 是 flex 容器，文字+徽标整体居中）
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Flexible(
            fit: FlexFit.loose,
            child: AnimatedDefaultTextStyle(
              duration: reduceMotion ? Duration.zero : AylaDurations.fast,
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
          if (widget.badgeCount > 0) ...<Widget>[
            const SizedBox(width: AylaSpacing.sp1), // margin-left: var(--sp-1)
            _TabBadgeInline(count: widget.badgeCount),
          ],
        ],
      ),
    );

    button = MouseRegion(
      opaque: true,
      onEnter: (_) => widget.onHoverChanged?.call(true),
      onExit: (_) => widget.onHoverChanged?.call(false),
      child: button,
    );

    if (widget.onTap == null) {
      return Semantics(
        selected: widget.active,
        label: widget.label,
        child: button,
      );
    }
    return Semantics(
      button: true,
      selected: widget.active,
      label: widget.label,
      child: AylaPressScale(
        onTap: widget.onTap,
        semanticLabel: widget.label,
        // auroraqua.css 236–249：`.messages-tab` 属「导航/选项卡组」——
        // **只有 `:active { scale: .98 }`，hover 不放大**（它不在 54–83 的
        // 按钮组里，那组的 hover 1.02 不适用于选项卡）。
        hoverScale: false,
        onPressChanged: widget.onPressChanged,
        child: button,
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
///
/// ⚠️ **事实源边界（2026-09-19 审查）**：web 里**没有统一的胶囊基类**，
/// 各处胶囊是各自独立的类，规格并不一致：
///
/// | tone | web 真实来源 | 底 / 字 | 盒模型 |
/// |---|---|---|---|
/// | [CapsuleTone.sakura] | `auth.css 203–212` `.auth-intro-feature` | sakura-300 / grape-700 | padding 6×14、12px/500、ls .4 |
/// | [CapsuleTone.ice] | `search.css 19–25` `.search-chip` | ice-100 / text-primary | padding **4×12**、**13px** |
/// | [CapsuleTone.pink] | `live.css 811–814` `.live-badge-live` | pink-500 / surface | 随 `.live-badge` 基类 |
/// | [CapsuleTone.glass] | **暂无精确对应**（就近：`--glass-bg` + `--glass-border`） | — | — |
/// | [CapsuleTone.indigo] | **暂无精确对应**（就近：`--indigo-700` 实底） | — | — |
///
/// 本组件**当前实现的是 [CapsuleTone.sakura] 的规格**；其余 tone 仅共享色板，
/// **盒模型与字级需在各组件落地时按各自 CSS 覆写**，不要用本组件的固定值套用
/// （否则 ice chip 偏大、live badge 偏离）。
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
