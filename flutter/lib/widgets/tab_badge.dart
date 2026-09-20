/// TabBadge —— 未读/计数徽标（四档真实规格，一处实现）。
///
/// 事实源（**web 是四个不同类，规格并不完全一致**；2026-09-20 组件库审查 R8 之前，
/// 库内是 3 份各自实现：`TabBadge` / `_UnreadBadge` / `_TabBadgeInline`）：
///
/// | metrics | web 类 | 盒模型 | 字体 | 定位 |
/// |---|---|---|---|---|
/// | [TabBadgeMetrics.tab] | shell.css 579–593 `.tab-badge` | min 16×16 / padding 0 4 / pill | Fredoka 11 w500 | 绝对 `top -4 right -12`（宿主须为 Stack） |
/// | [TabBadgeMetrics.groupBadge] | home.css 302–317 `.group-badge(-unread)` | min 16×16 / padding 0 4 / pill | Fredoka 11（未声明 font-weight） | 行内（Row 里排在文案后） |
/// | [TabBadgeMetrics.messages] | messages.css 43–55 `.messages-tab-badge` | min 18×18 / padding 0 5 / pill + `--glow-shadow` | Space Grotesk 11 | 行内 |
/// | [TabBadgeMetrics.shareUnread] | share.css 130–143 `.share-sheet-unread` | min 18×18 / padding 0 5 / pill，**无辉光** | Space Grotesk 11 | 行内（分享目标行） |
///
/// 数字 > [max] 显示 `max+`（消息中心红点语义，d:§12.14）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../theme/preview_theme.dart';
import '../theme/tokens.dart';

/// 徽标度量档位（对应 web 四个类；**不是「统一规格」**，见文件头表格）。
enum TabBadgeMetrics {
  /// `.tab-badge`（shell.css 579–593）：16×16 / padding 0 4 / Fredoka 11 w500。
  tab(
    minSize: 16,
    horizontalPadding: 4,
    fontFamily: AylaFonts.display,
    fontWeight: FontWeight.w500,
    glow: false,
  ),

  /// `.group-badge(-unread)`（home.css 302–317）：16×16 / padding 0 4 / Fredoka 11，
  /// web 未声明 font-weight（继承祖先）→ 取正文常规字重。
  groupBadge(
    minSize: 16,
    horizontalPadding: 4,
    fontFamily: AylaFonts.display,
    fontWeight: FontWeight.w400,
    glow: false,
  ),

  /// `.messages-tab-badge`（messages.css 43–55）：18×18 / padding 0 5 /
  /// Space Grotesk 11 + `--glow-shadow`。
  messages(
    minSize: 18,
    horizontalPadding: 5,
    fontFamily: AylaFonts.utility,
    fontWeight: FontWeight.w400,
    glow: true,
  ),

  /// `.share-sheet-unread`（share.css 130–143）：18×18 / padding 0 5 /
  /// Space Grotesk 11（web 未声明 font-weight → 继承正文常规字重）/ **无辉光**。
  /// 文字色是 `#fff` 纯白（配 [TabBadge.foregroundColor]），非 `--surface`。
  shareUnread(
    minSize: 18,
    horizontalPadding: 5,
    fontFamily: AylaFonts.utility,
    fontWeight: FontWeight.w400,
    glow: false,
  );

  const TabBadgeMetrics({
    required this.minSize,
    required this.horizontalPadding,
    required this.fontFamily,
    required this.fontWeight,
    required this.glow,
  });

  /// 最小边长（`min-width` / `height`，px）。
  final double minSize;

  /// 水平内边距（`padding: 0 4px` / `0 5px`）。
  final double horizontalPadding;

  /// 字体族（Fredoka / Space Grotesk）。
  final String fontFamily;

  /// 字重（web 未声明的按继承值取常规字重）。
  final FontWeight fontWeight;

  /// 是否带 `--glow-shadow` 辉光。
  final bool glow;
}

/// 徽标定位方式。
enum TabBadgePlacement {
  /// 绝对定位在宿主右上角（`.tab-badge`；宿主须是 Stack 且 `clipBehavior: Clip.none`）。
  positioned,

  /// 行内排布（`.group-badge` / `.messages-tab-badge`）。
  inline,
}

/// 未读/计数徽标。
class TabBadge extends StatelessWidget {
  const TabBadge({
    super.key,
    required this.count,
    this.max = 99,
    this.metrics = TabBadgeMetrics.tab,
    this.placement = TabBadgePlacement.positioned,
    this.foregroundColor,
  });

  /// 未读数（>0 才渲染；≤0 返回空）。
  final int count;

  /// 封顶显示（>max → `max+`，如 99+）。
  final int max;

  /// 度量档位。
  final TabBadgeMetrics metrics;

  /// 定位方式。
  final TabBadgePlacement placement;

  /// 文字色覆写（默认 `--surface` #fffafb）。
  ///
  /// `.share-sheet-unread`（share.css 141）用 **`#fff` 纯白**，与其余档位的
  /// `#fffafb` 不同，故按处覆写而不改基类默认值。
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final String text = count > max ? '$max+' : '$count';
    // ⚠️ 用 ConstrainedBox + Center(widthFactor:1) 收缩到内容尺寸：
    // Container(alignment:) 在**有界宽度**的父级里会撑满整行（实测预览里
    // 内联档被拉成一条长条）；web 的徽标是 inline 元素，永远贴合内容。
    final Widget badge = ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: metrics.minSize, // min-width: 16px / 18px
        minHeight: metrics.minSize, // height: 16px / 18px
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AylaColors.pink500, // background: var(--pink-500)
          borderRadius: AylaRadii.pill,
          // 徽标底是不透明 pink-500 实底 → 辉光即便画进形状内部也被面层覆盖，
          // 与 CSS 观感一致（无需 AylaGlassShadow.ring 挖空内部）。
          boxShadow: metrics.glow ? AylaShadows.glow : null,
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: metrics.horizontalPadding),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Text(
              text,
              maxLines: 1,
              style: TextStyle(
                fontFamily: metrics.fontFamily,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 11, // font-size: 11px
                height: 1, // line-height: 1（16px 与 18px 两档的等比表达）
                fontWeight: metrics.fontWeight,
                color: foregroundColor ?? AylaColors.surface, // #fffafb（share 档 #fff）
              ),
            ),
          ),
        ),
      ),
    );
    return switch (placement) {
      TabBadgePlacement.inline => badge,
      TabBadgePlacement.positioned => Positioned(
        top: -4, // shell.css .tab-badge top
        right: -12, // shell.css .tab-badge right
        child: badge,
      ),
    };
  }
}

// ======================= 预览 =======================

/// TabBadge 1 / 12 / 150→99+。
@Preview(
  group: 'Widgets',
  name: 'TabBadge 1/12/99+',
  size: Size(420, 140),
  wrapper: previewTheme,
)
Widget tabBadgePreview() {
  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp6),
    child: Wrap(
      spacing: AylaSpacing.sp8,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        // 40px 玻璃方模拟图标钮宿主（`.tab-badge` 绝对定位档）
        _BadgeHost(count: 1),
        _BadgeHost(count: 12),
        _BadgeHost(count: 150),
        // `.group-badge`（行内档）
        const TabBadge(
          count: 8,
          metrics: TabBadgeMetrics.groupBadge,
          placement: TabBadgePlacement.inline,
        ),
        // `.messages-tab-badge`（行内 + 辉光档）
        const TabBadge(
          count: 120,
          metrics: TabBadgeMetrics.messages,
          placement: TabBadgePlacement.inline,
        ),
      ],
    ),
  );
}

class _BadgeHost extends StatelessWidget {
  const _BadgeHost({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AylaColors.glassBg,
                borderRadius: BorderRadius.circular(AylaRadii.rInput),
                border: Border.all(color: AylaColors.glassBorder),
              ),
            ),
          ),
          TabBadge(count: count),
        ],
      ),
    );
  }
}
