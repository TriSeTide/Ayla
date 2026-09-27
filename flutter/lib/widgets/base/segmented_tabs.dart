/// segmented tabs（自 `primitives.dart` 拆出：一文件一件）。
///
/// 事实源与逐条对照见 `docs/flutter/17-组件文件头归档（整理前原文）.md` 的 `primitives.dart` 一节
/// 与各件的 `///` 头注。
///
/// ## 公开面
/// `AylaSegmentedTabsVariant` · `AylaSegmentedTabs` · `AylaSegmentedTab`

library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../../theme/app_theme.dart';
import '../../theme/css_gradient.dart';
import '../../theme/buttons.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import 'tab_badge.dart';
import 'nav_highlight.dart';

/// 选项卡族两个真实规格（web 是两个**独立类**，样式并不一致）。
///
/// | 维度 | [AylaSegmentedTabsVariant.messages] | [AylaSegmentedTabsVariant.shareSheet] |
/// |---|---|---|
/// | 事实源 | `messages.css` 17–33 + `auroraqua.css` 272–278 | `share.css` 63–91 |
/// | 容器 margin | `sp2`（覆写 messages.css 的 `sp3 sp4`） | `12px 16px 8px` |
/// | 容器 padding | `sp1` | `4px`（= sp1） |
/// | 容器圆角 | `--radius-card` 16 | `--radius-input` 12 |
/// | 容器底 | 无（透明） | `--glass-bg` |
/// | 容器内高光 | `--glass-inset` | **无** |
/// | 选中态 | 共享滑动胶囊（`AylaNavHighlight`：nav 阴影 + 1px 边框 + 700ms 扫光，
/// 300ms 迁移） | 项自带**静态**底（`--nav-active-bg` + `--glass-shadow-compact`，
/// **无边框、无扫光、无迁移**） |
/// | 项圆角 | `--radius-input` 12 | `10px` |
/// | 项按下缩放 | `:active scale .98`（auroraqua 236–249） | **无**（不在任何 `:is()` 组） |
/// | 文字过渡 | 180ms `--ease-out` | 200ms `ease` |
enum AylaSegmentedTabsVariant {
  /// `.messages-tabs` / `.messages-tab`（消息中心双 tab）。
  messages,

  /// `.share-sheet-tabs` / `.share-sheet-tab`（分享弹窗「群聊 / 私信」）。
  shareSheet,
}

/// 分段选项卡容器 —— 选中态随 [AylaSegmentedTabsVariant] 切换。
///
/// **messages 档 1:1 对照 `messages.css` 17–37 + `MessagesPage.tsx` 209–241**
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
    this.variant = AylaSegmentedTabsVariant.messages,
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

  /// 规格档（默认消息中心档；分享弹窗传 [AylaSegmentedTabsVariant.shareSheet]）。
  final AylaSegmentedTabsVariant variant;

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
    final bool shareSheet =
        widget.variant == AylaSegmentedTabsVariant.shareSheet;
    // messages 档 16（auroraqua 275 覆写）；shareSheet 档 12（share.css 70）
    final BorderRadius containerRadius = BorderRadius.circular(
      shareSheet ? AylaRadii.rInput : AylaRadii.rCard,
    );

    return MouseRegion(
      onHover: (PointerHoverEvent e) => _pointerPos = e.position,
      child: Semantics(
        container: true,
        label: widget.semanticLabel,
        child: Container(
          // messages：`.messages-tabs { margin: sp2 }`（auroraqua 272–278）
          // shareSheet：`.share-sheet-tabs { margin: 12px 16px 8px }`（share.css 67）
          margin: shareSheet
              ? const EdgeInsets.fromLTRB(16, 12, 16, 8)
              : const EdgeInsets.all(AylaSpacing.sp2),
          decoration: BoxDecoration(
            // shareSheet：`background: var(--glass-bg)`（share.css 71）
            // messages：web 无 background（透明），选中底由内层胶囊提供
            color: shareSheet
                ? AylaGlassConfig.resolveBackground(strong: false)
                : null,
            borderRadius: containerRadius, // rCard 16 / rInput 12
            border: Border.all(color: AylaColors.glassBorder),
            // messages：box-shadow: var(--glass-inset)（内高光见下，无外阴影）
            // shareSheet：share.css 无 box-shadow → 不叠内高光
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
                    // box-shadow: var(--glass-inset) 的等价层（顶沿 1px 高光）；
                    // shareSheet 档无 box-shadow → 不叠（share.css 63–74）
                    if (!shareSheet)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: AylaInset.topHighlight(40),
                            ),
                          ),
                        ),
                      ),
                    // shareSheet 档**没有共享滑动胶囊**（tsx 未渲染
                    // AuroraquaNavHighlight；share.css 也无迁移规则）
                    if (!shareSheet && w > 0 && tabW > 0)
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
                              variant: widget.variant,
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

/// 选项卡按钮本体（高 40 / 14-700）—— 规格随 [AylaSegmentedTabsVariant] 切换。
///
/// **messages 档**（`messages.css` 24–37）：`flex: 1`、`height: 40px`、
/// `border-radius: var(--radius-input)` 12、14px/700、`text-secondary`；
/// `.is-active` → `text-primary`（选中底由容器共享胶囊提供，对齐 auroraqua.css
/// 194–197 的 `background: transparent`）；`:active scale .98`。
///
/// **shareSheet 档**（`share.css` 74–91）：`height: 40px`、`border-radius: 10px`、
/// `transition: color 200ms ease`；`.is-active` → `text-primary` +
/// `background: var(--nav-active-bg)` + `box-shadow: var(--glass-shadow-compact)`
/// （**项自带静态底：无边框、无扫光、无迁移**）；**无 `:active` 缩放**。
/// 可选右侧徽标。
class AylaSegmentedTab extends StatefulWidget {
  const AylaSegmentedTab({
    super.key,
    required this.label,
    required this.active,
    this.onTap,
    this.badgeCount = 0,
    this.onHoverChanged,
    this.onPressChanged,
    this.variant = AylaSegmentedTabsVariant.messages,
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

  /// 规格档（与容器 [AylaSegmentedTabs.variant] 保持一致）。
  final AylaSegmentedTabsVariant variant;

  @override
  State<AylaSegmentedTab> createState() => _AylaSegmentedTabState();
}

class _AylaSegmentedTabState extends State<AylaSegmentedTab> {
  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final bool shareSheet =
        widget.variant == AylaSegmentedTabsVariant.shareSheet;
    final BorderRadius radius = BorderRadius.circular(
      shareSheet ? 10 : AylaRadii.rInput, // share.css 77 / messages.css 28
    );

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
              // messages：`transition: … color var(--dur-fast) --ease-out`
              // shareSheet：`transition: color 200ms ease`（share.css 81）
              duration: reduceMotion
                  ? Duration.zero
                  : (shareSheet
                      ? const Duration(milliseconds: 200)
                      : AylaDurations.fast),
              curve: shareSheet ? AylaCurves.auroraqua : AylaCurves.easeOut,
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
            // 2026-09-20 审查 R8：合并到组件库 AylaTabBadge（.messages-tab-badge 档）
            AylaTabBadge(
              count: widget.badgeCount,
              metrics: AylaTabBadgeMetrics.messages,
              placement: AylaTabBadgePlacement.inline,
            ),
          ],
        ],
      ),
    );

    // shareSheet：`.share-sheet-tab.is-active` 的静态底 ——
    // `background: var(--nav-active-bg)`（135deg ice .35 → .18）
    // + `box-shadow: var(--glass-shadow-compact)`（含顶沿内高光），**无边框**。
    // 它属于项自身（不是容器共享胶囊），因此不随索引迁移。
    // ⚠️ 用 `SizedBox(height: 40)` + `Positioned.fill` 固定几何：
    // 选项卡 Row 在 Column（mainAxisSize.min）里高度**无界**，
    // `StackFit.expand` 会强推 `h=Infinity` 断言失败（2026-09-20 实测）。
    if (shareSheet && widget.active) {
      button = SizedBox(
        height: 40, // `.share-sheet-tab { height: 40px }`
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: IgnorePointer(
                child: AylaGlassShadow.ring(
                  radius: radius,
                  shadows: AylaShadows.compact,
                ),
              ),
            ),
            Positioned.fill(
              child: AylaGlassInset.over(
                radius: radius,
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints c) {
                    return DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: radius,
                        gradient: cssLinearGradient(
                          angleDeg: 135,
                          colors: const <Color>[
                            Color(0x599DBFE6), // rgba(157,191,230,.35)
                            Color(0x2E9DBFE6), // rgba(157,191,230,.18)
                          ],
                          aspectRatio: c.maxWidth.isFinite
                              ? c.maxWidth / 40
                              : 1,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            Positioned.fill(child: button),
          ],
        ),
      );
    }

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
        // `.share-sheet-tab` 不在任何一组 `:is()` 里，web 无 `:active` 规则
        // （share.css 74–85 只有 color 过渡）→ 不做按压缩放。
        pressScale: !shareSheet,
        onPressChanged: widget.onPressChanged,
        child: button,
      ),
    );
  }
}
