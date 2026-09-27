/// 搜索结果分组（web `pages/SearchPage.tsx:494–521` 的 `ResultGroup` + `styles/search.css` 68–105）。
///
/// ## 事实源
/// ```
/// SearchPage.tsx 500  `if (count === 0) return null` ⇒ **空组整组不渲染**（不是渲染空态）
/// search.css 68       .search-group { min-width: 0 }
/// search.css 71       单类视图隐藏标题：`.search-content:not([data-search-filter="all"]) .search-group-head
///                     { display: none }` ⇒ 暴露 [showTitle]
/// search.css 75–78    组内分页 footer 紧凑化：`min-height: 0; padding: sp2 0 0`（只作用于组内）
/// search.css 80–85    .search-group-head：flex · space-between · margin-bottom sp2
/// search.css 87–93    .search-group-title：Display 13 · letter-spacing .8 · uppercase · --text-secondary
/// search.css 101–105  .search-group-body：column · gap sp2
/// tsx 507–518         页脚：error 文案 + ghost 按钮（loading ⇒「加载中…」/ error ⇒「重试」/
///                     否则 ⇒「查看更多」；loading 时 disabled；aria-label = 重试加载{标题} / 加载更多{标题}）
/// ```
/// ⚠️ `.search-more`（search.css 95–99）在 tsx **零使用 ⇒ 死声明，不复刻**。
///
/// ## 公开面
/// `AylaSearchResultGroup`
library;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import '../base/pagination_footer.dart';

/// 搜索结果分组：标题（可隐藏）+ 子项 + 三态页脚。
class AylaSearchResultGroup extends StatelessWidget {
  const AylaSearchResultGroup({
    super.key,
    required this.title,
    required this.count,
    required this.children,
    this.hasMore = false,
    this.loading = false,
    this.error,
    this.onMore,
    this.showTitle = true,
    this.moreLabel = '查看更多',
    this.retryLabel = '重试',
    this.loadingLabel = '加载中…',
  });

  /// 分组名（用于标题与页脚 aria-label）。
  final String title;

  /// 总数（**为 0 ⇒ 整组不渲染**）。
  final int count;

  /// 组内子项。
  final List<Widget> children;

  /// 还有更多可加载。
  final bool hasMore;

  /// 加载中（页脚按钮禁用 + 文案）。
  final bool loading;

  /// 加载失败文案（非空即显示 error 态页脚）。
  final String? error;

  /// 点「查看更多 / 重试」。
  final VoidCallback? onMore;

  /// 是否显示组标题（web：非「全部」视图隐藏）。
  final bool showTitle;

  /// 页脚按钮文案三档（web 内硬编码；**开放给调用方**）。
  final String moreLabel;
  final String retryLabel;
  final String loadingLabel;

  @override
  Widget build(BuildContext context) {
    if (count == 0) return const SizedBox.shrink();
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool hasFooter = hasMore || error != null;
    final String? message = error;
    final String label = loading
        ? loadingLabel
        : (message != null ? retryLabel : moreLabel);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (showTitle) ...<Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(
                title.toUpperCase(), // text-transform: uppercase
                style: t.timestamp.copyWith(
                  fontSize: 13,
                  letterSpacing: 0.8,
                  color: AylaColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: AylaSpacing.sp2), // margin-bottom: var(--sp-2)
        ],
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          spacing: AylaSpacing.sp2, // gap: var(--sp-2)
          children: children,
        ),
        if (hasFooter)
          AylaStablePaginationFooter(
            // `.search-group .stable-pagination-footer { min-height: 0; padding: sp2 0 0 }`
            minHeight: 0,
            padding: const EdgeInsets.only(top: AylaSpacing.sp2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: AylaSpacing.sp2,
              children: <Widget>[
                if (message != null)
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: t.caption.copyWith(color: AylaColors.destructive),
                  ),
                AylaGlassButton(
                  label: label,
                  variant: AylaGlassButtonVariant.ghost,
                  onPressed: loading ? null : onMore,
                  semanticLabel: message != null
                      ? '重试加载$title'
                      : '加载更多$title',
                ),
              ],
            ),
          ),
      ],
    );
  }
}
