/// 弹出菜单项（`.conv-menu-item` / `.server-pop-action`）—— 一处实现、两档规格。
///
/// **为什么提为公共件**（2026-09-21，用户点头）：ServerRail 的置顶面板动作行
/// （`group.css 624–643 .server-pop-action`）与「⋯ 更多」菜单项
/// （`app.css 663–693 .conv-menu-item`）是**同一交互、不同规格**：
///
/// | 维度 | [AylaMenuItemMetrics.conversation] | [AylaMenuItemMetrics.rail] |
/// |---|---|---|
/// | 最小高 | `min-height: 40px` | `min-height: 34px` |
/// | 水平内边距 | `padding: 0 var(--sp-3)` = 12 | `padding: 0 8px` |
/// | 圆角 | `border-radius: 10px` | `border-radius: 8px` |
/// | 字号 | `font-size: 14px` | `font-size: 13px` |
/// | 图标 | 16 | 14（`<IconPin width={14} height={14}/>`） |
/// | 图标-文字间距 | `gap: var(--sp-2)` = 8 | `gap: 6px` |
///
/// 两档共用的部分（同值，勿改）：字重 600、`color: var(--text-primary)`、
/// hover 底 `rgba(157,191,230,.22)`、`:disabled { opacity: .5 }`；
/// danger 只在会话菜单出现（`--destructive` + `rgba(224,100,100,.12)`）。
///
/// **零透明用同色相**（`ice500.withValues(alpha: 0)`）：Flutter 的 `Color.lerp`
/// 逐通道直插，从 `Colors.transparent`（透明黑）出发中途会闪中性灰。
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// 菜单项规格档位（web 是两个不同类，见文件头对照表）。
enum AylaMenuItemMetrics {
  /// `.conv-menu-item`（app.css 663–693）——「⋯ 更多」会话菜单。
  conversation(
    minHeight: 40,
    horizontalPadding: 12,
    radius: 10,
    fontSize: 14,
    iconSize: 16,
    gap: 8,
  ),

  /// `.server-pop-action`（group.css 624–643）—— ServerRail 悬停置顶面板。
  rail(
    minHeight: 34,
    horizontalPadding: 8,
    radius: 8,
    fontSize: 13,
    iconSize: 14,
    gap: 6,
  );

  const AylaMenuItemMetrics({
    required this.minHeight,
    required this.horizontalPadding,
    required this.radius,
    required this.fontSize,
    required this.iconSize,
    required this.gap,
  });

  /// `min-height`（px）。
  final double minHeight;

  /// 水平内边距（px）。
  final double horizontalPadding;

  /// 圆角（px）。
  final double radius;

  /// 字号（px）。
  final double fontSize;

  /// 图标尺寸（px；同时作为 `IconTheme.size` 兜底，显式给 size 的图标不受影响）。
  final double iconSize;

  /// 图标与文字的间距（px）。
  final double gap;
}

/// 菜单项（`.conv-menu-item` / `.server-pop-action`）。
class AylaMenuItem extends StatefulWidget {
  const AylaMenuItem({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.metrics = AylaMenuItemMetrics.conversation,
    this.danger = false,
    this.disabled = false,
    this.focusNode,
    this.onKey,
  });

  /// 前置图标（着色走 `IconTheme`，即本项前景色）。
  final Widget icon;

  /// 文案。
  final String label;

  /// 点击回调（[disabled] 为 true 时不触发）。
  final VoidCallback onTap;

  /// 规格档位。
  final AylaMenuItemMetrics metrics;

  /// 危险项（`color: var(--destructive)` + 危险 hover 底）。
  final bool danger;

  /// 禁用（`:disabled` → `opacity: .5`，不响应点击）。
  final bool disabled;

  /// 键盘焦点节点（会话菜单的 ArrowUp/Down 循环用；可空）。
  final FocusNode? focusNode;

  /// 键盘事件（可空）。
  final KeyEventResult Function(FocusNode, KeyEvent)? onKey;

  @override
  State<AylaMenuItem> createState() => _AylaMenuItemState();
}

class _AylaMenuItemState extends State<AylaMenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    // danger → color: var(--destructive)；其余 --text-primary
    final Color fg = widget.danger
        ? AylaColors.destructive
        : AylaColors.textPrimary;

    final Widget row = Container(
      // gap 由父级 Column.spacing 提供（对齐 CSS `.conv-menu { gap: 2px }`
      // 与 `.server-pop { gap: 2px }`）
      constraints: BoxConstraints(minHeight: widget.metrics.minHeight),
      padding: EdgeInsets.symmetric(
        horizontal: widget.metrics.horizontalPadding,
      ),
      decoration: BoxDecoration(
        // :hover → rgba(157,191,230,.22)；danger:hover → rgba(224,100,100,.12)
        // 零透明用**同色相**（透明黑若参与插值会闪灰）
        color: (!_hovered || widget.disabled)
            ? (widget.danger
                  ? const Color(0x00E06464)
                  : AylaColors.ice500.withValues(alpha: 0))
            : (widget.danger
                  ? const Color(0x1FE06464)
                  : AylaColors.ice500.withValues(alpha: 0.22)),
        borderRadius: BorderRadius.circular(widget.metrics.radius),
      ),
      child: Opacity(
        opacity: widget.disabled ? 0.5 : 1.0, // :disabled { opacity: .5 }
        child: Row(
          children: <Widget>[
            IconTheme(
              data: IconThemeData(color: fg, size: widget.metrics.iconSize),
              child: widget.icon,
            ),
            SizedBox(width: widget.metrics.gap),
            Text(
              widget.label,
              style: t.label.copyWith(
                fontSize: widget.metrics.fontSize,
                fontWeight: FontWeight.w600, // font-weight: 600
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );

    Widget clickable = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.disabled ? null : widget.onTap,
        child: row,
      ),
    );

    // Focus 只在给了 focusNode 时挂（键盘导航是会话菜单的语义，rail 面板不需要）
    if (widget.focusNode != null || widget.onKey != null) {
      clickable = Focus(
        focusNode: widget.focusNode,
        onKeyEvent: widget.onKey,
        child: clickable,
      );
    }

    return Semantics(
      button: true,
      enabled: !widget.disabled,
      label: widget.label,
      child: clickable,
    );
  }
}
