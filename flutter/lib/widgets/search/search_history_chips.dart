/// 搜索历史标签 + 清空（web `pages/SearchPage.tsx:362–372` + `styles/search.css` 11–30）。
///
/// ## 事实源
/// ```
/// SearchPage.tsx 362  只在此条件渲染：`!q && history.length > 0`（**有查询词就不显示历史**）
/// search.css 11–17    .search-history：flex-wrap · gap sp2 · padding sp3 sp4 sp3（12 / 16 / 12）
/// directory-filters.css 171–180  组规则：该容器的 padding-left/right 归零（**全断点**）
///                     ⚠️ `.search-history` **不在** 199–208 的顶部归零名单内 ⇒ 顶部保持 sp3
/// search.css 19–25    .search-chip：padding 4×12 · radius pill · background --ice-100 ·
///                     color --text-primary · font-size 13
/// search.css 27–30    .search-clear：font-size 13 · color --slate-500
/// auroraqua 59/77/89/664  **`.search-chip` 在按钮组内** ⇒ 组过渡 200ms + hover scale 1.02 + active .98；
///                     `.search-clear` **不在**组内（无 1.02/.98）
/// ```
/// 行为：点 chip = 用该词再搜（`submitQuery(h)`）；点「清空」= 清历史（`clearHistory`）。
///
/// ## 有意偏离
/// 无。两个按钮的材质与 web 一致（chip 有 ice-100 底、clear 是纯文字）。
///
/// ## 公开面
/// `AylaSearchHistoryChips`
library;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/buttons.dart';
import '../../theme/tokens.dart';

/// 搜索历史标签行（含「清空」）。
class AylaSearchHistoryChips extends StatelessWidget {
  const AylaSearchHistoryChips({
    super.key,
    required this.history,
    this.query = '',
    this.onSelect,
    this.onClear,
    this.clearLabel = '清空',
    this.padding = inset,
  });

  /// 历史词（按 web 顺序展示）。
  final List<String> history;

  /// 当前查询词：**非空时整块不渲染**（web `!q && …`）。
  final String query;

  /// 点某个历史词（web `submitQuery(h)`）。
  final ValueChanged<String>? onSelect;

  /// 点「清空」（web `clearHistory`）。
  final VoidCallback? onClear;

  /// 「清空」文案（web 内硬编码；**开放给调用方**）。
  final String clearLabel;

  /// 容器内距（默认 [inset] = 基样式 `padding: sp3 sp4 sp3`；搜索页调用点传
  /// 目录页档 —— 左右恒 0（`directory-filters.css:171–180`）、顶部保持 sp3）。
  final EdgeInsetsGeometry padding;

  /// 基样式的容器内距（`padding: sp3 sp4 sp3`）—— [padding] 的默认值。
  static const EdgeInsets inset = EdgeInsets.fromLTRB(
    AylaSpacing.sp4,
    AylaSpacing.sp3,
    AylaSpacing.sp4,
    AylaSpacing.sp3,
  );

  /// 标签内距（`padding: 4px 12px`）。
  static const EdgeInsets chipPadding = EdgeInsets.symmetric(
    horizontal: AylaSpacing.sp3,
    vertical: 4,
  );

  @override
  Widget build(BuildContext context) {
    if (query.isNotEmpty || history.isEmpty) return const SizedBox.shrink();
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Padding(
      padding: padding,
      child: Wrap(
        spacing: AylaSpacing.sp2, // gap: var(--sp-2)
        runSpacing: AylaSpacing.sp2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          for (final String word in history)
            AylaPressScale(
              // `.search-chip` 在 auroraqua 按钮组内 ⇒ hover 1.02 / active .98
              semanticLabel: word,
              onTap: onSelect == null ? null : () => onSelect!(word),
              child: Container(
                padding: chipPadding,
                decoration: BoxDecoration(
                  color: AylaColors.ice100, // background: var(--ice-100)
                  borderRadius: AylaRadii.pill,
                ),
                child: Text(
                  word,
                  style: t.label.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    color: AylaColors.textPrimary,
                  ),
                ),
              ),
            ),
          // `.search-clear`：纯文字、不在按钮组内（无 1.02/.98）
          AylaPressScale(
            semanticLabel: clearLabel,
            hoverScale: false,
            pressScale: false,
            onTap: onClear,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp1),
              child: Text(
                clearLabel,
                style: t.label.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: AylaColors.slate500, // color: var(--slate-500)
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
