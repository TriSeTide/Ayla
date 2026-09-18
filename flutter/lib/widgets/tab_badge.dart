/// TabBadge —— 未读/红点徽标（shell.css .tab-badge 579–593 行 / d:§12.1/12.14）。
///
/// 事实源：
/// - `top: -4px; right: -12px`（相对宿主右上角偏移，见 [TabBadge] 用法）
/// - `min-width: 16px; height: 16px; padding: 0 4px` → 单字符 16×16，
///   多字符按内容加宽（胶囊形，radius 999）
/// - `background: var(--pink-500)` + `color: #fffafb`
/// - `font-family: var(--font-display)`（Fredoka）`font-size: 11px; line-height: 16px`
/// - 数字 >99 显示 99+（消息中心红点语义，d:§12.14）
library;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../theme/preview_theme.dart';
import '../theme/tokens.dart';

/// 未读徽标（放在宿主 Stack 右上角即可，本组件自带 top -4 / right -12 定位）。
class TabBadge extends StatelessWidget {
  const TabBadge({super.key, required this.count, this.max = 99});

  /// 未读数（>0 才渲染；0 返回空）。
  final int count;

  /// 封顶显示（>max → `max+`，如 99+）。
  final int max;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final String text = count > max ? '$max+' : '$count';
    return Positioned(
      top: -4, // shell.css .tab-badge top
      right: -12, // shell.css .tab-badge right
      child: Container(
        constraints: const BoxConstraints(
          minWidth: 16, // min-width: 16px
          minHeight: 16, // height: 16px
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4), // padding: 0 4px
        decoration: const BoxDecoration(
          color: AylaColors.pink500,
          borderRadius: AylaRadii.pill,
        ),
        alignment: Alignment.center,
        child: Text(
          text,
          maxLines: 1,
          style: const TextStyle(
            fontFamily: AylaFonts.display,
            fontFamilyFallback: AylaFonts.cjkFallback,
            fontSize: 11, // font-size: 11px
            height: 1, // line-height 16px ÷ 16px
            fontWeight: FontWeight.w500,
            color: AylaColors.surface,
          ),
        ),
      ),
    );
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
        // 40px 玻璃方模拟图标钮宿主
        _BadgeHost(count: 1),
        _BadgeHost(count: 12),
        _BadgeHost(count: 150),
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
