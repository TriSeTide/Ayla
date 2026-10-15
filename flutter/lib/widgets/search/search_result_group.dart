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
/// **typed-result-cards.css 134**  `.search-content .search-group-body { gap: var(--sp-3) }`
///                     —— 特异性更高、**不在任何媒体查询内** ⇒ **全断点 gap = 12**（不是 sp2=8）。
///                     实测：1440 与 400 两种宽度下 computed gap 恒为 `12px`。
/// search.css 490–524  （@media min-width:769）
///   .search-page .search-row { min-height: 64px; padding: sp3 sp4 }
///   .search-page .search-group-title { font-size: 14px }          ← 窄屏 13px
///   .search-results { display: block; columns: 2; column-gap: sp6 }  ← 见 [columnCount] 的说明
///   .search-content:not([data-search-filter="all"]) .search-group-body {
///       columns: 2; column-gap: sp6 }
///   .search-content:not([data-search-filter="all"]) .search-group-body > * {
///       break-inside: avoid; margin-bottom: sp3 }                 ← 单元间距 = gap12 + margin12 = **24**
/// tsx 507–518         页脚：error 文案 + ghost 按钮（loading ⇒「加载中…」/ error ⇒「重试」/
///                     否则 ⇒「查看更多」；loading 时禁用；aria-label = 重试加载{标题} / 加载更多{标题}）
///
/// ## 多列（宽屏搜索页）
/// 单类视图宽屏时组内结果项分两列 —— 由 [columnCount] 表达（≥769 时调用方传 2）。
/// 列宽/列间距/列分配**完全交给** [AylaCssColumns]（CSS `columns:2` 的等价件），
/// 本件只负责「标题 + 多列体 + 页脚」的垂直装配。
/// ⚠️ **页脚不参与多列**：web 的 `.stable-pagination-footer` 是 `.search-group` 的子级、
/// 在 `.search-group-body` **之外**（tsx 507）⇒ 始终横跨整组宽度、排在内容之下。
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
import '../base/css_columns.dart';
import '../base/pagination_footer.dart';
import '../base/reveal.dart';

/// 搜索结果分组：标题（可隐藏）+ 子项 + 三态页脚。
///
/// ## 逐条浮入（`useListEntryMotion`，`SearchPage.tsx:119`）
///
/// web 的 selector 是
/// `".search-row, .typed-result-card, .search-group .stable-pagination-footer .btn"`：
/// - `.search-row`（用户行）与 `.typed-result-card`（群/帖/桌游/语音/直播卡）
///   ⇒ 由 `search_page.dart` 的六个分组逐项包 [AylaRevealItem] 表达
///   （Flutter 的列表容器在页面层，件本身不知道下标）；
/// - `.search-group .stable-pagination-footer .btn`（**组内页脚按钮**）⇒ 本件自持，
///   下标由调用方经 [footerRevealIndex] 传入（web 的下标是**整棵 root 的 DOM 顺序**，
///   跨组连续；件这一层算不出全局位次）。
///   `null` = 不挂（画布样张等无页面上下文的用法）。
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
    this.footerRevealIndex,
    this.columnCount = 1,
    this.columnGap = AylaSpacing.sp6,
    this.itemGap = AylaSpacing.sp3,
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

  /// 页脚按钮的逐条浮入下标（web 全局 DOM 顺序位次）；null = 不挂。
  final int? footerRevealIndex;

  /// 组内结果项的列数（CSS `columns: N`）。
  ///
  /// - `1`（默认）：单列 `Column`（**全断点的窄屏档**，也是「全部」档宽屏时的组内形态）；
  /// - `2`：宽屏**单类视图**档 —— web 由
  ///   `search.css:508–511` 的 `.search-group-body { columns: 2 }` 表达
  ///   （实测项宽 570 = (1164 − 24) / 2、列间距 24）。
  ///
  /// ⚠️ web 里该声明写在 `display: flex` 的 `.search-group-body` 上（**flex 容器不接受
  /// `columns`**）—— 真实生效的是**父级** `.search-results` 的 `display:block; columns:2`
  /// 把内容切分到两根柱上（受控实验证实：flex 容器自身加 `column-count` 无效，
  /// 而块级 multicol 会切分）。Flutter 侧不需要复刻那个「声明失效但视觉两列」的间接路径，
  /// 直接表达**视觉结果**：项分两列、列宽同上、列间距 24。
  final int columnCount;

  /// 列间距（`column-gap`）。
  final double columnGap;

  /// 单元间距（多列时 = CSS 的 `gap` 与 `margin-bottom` 叠加值；单列时 = `gap`）。
  ///
  /// 实测：单类宽屏档 = 24（`gap: sp3` + `margin-bottom: sp3` 叠加，相邻项 top 差 90.6 = 66.6 + 24）；
  /// 单列档 = 12（只有 `gap: sp3`，窄屏不命中那条 `margin-bottom`）。
  final double itemGap;

  @override
  Widget build(BuildContext context) {
    if (count == 0) return const SizedBox.shrink();
    final AylaTextStyles t = AylaTextStyles.of(context);
    // 组标题字号两档（search.css:499 在 @media min-width:769 内）
    final bool wideTitle = MediaQuery.sizeOf(context).width > 768;
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
                // 字号两档：窄屏 13（search.css:87–93 基样式）；
                // ≥769 ⇒ 14（search.css:499，在 @media min-width:769 内）
                style: t.timestamp.copyWith(
                  fontSize: wideTitle ? 14 : 13,
                  letterSpacing: 0.8,
                  color: AylaColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: AylaSpacing.sp2), // margin-bottom: var(--sp-2)
        ],
        // 组内体：单列时 = Column；多列时 = [AylaCssColumns]（CSS `columns: N` 等价件）。
        // ⚠️ gap 用 [itemGap]（≥769 实测 12；单类宽屏档 24）而不是 search.css:101 的 sp2
        // —— typed-result-cards.css:134 覆写为 sp3 且全断点生效。
        if (columnCount <= 1)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            spacing: itemGap,
            children: children,
          )
        else
          AylaCssColumns(
            columnCount: columnCount,
            columnGap: columnGap,
            itemGap: itemGap,
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
                // web selector 的第三段是 `.search-group .stable-pagination-footer .btn`
                // —— **只有按钮**参与逐条浮入（`SearchPage.tsx:119`），错误文案不在其中。
                // 下标（全局 DOM 顺序位次）由调用方经 [footerRevealIndex] 传入；
                // null ⇒ 不挂（无页面上下文，如画布样张）。
                if (footerRevealIndex == null)
                  AylaGlassButton(
                    label: label,
                    variant: AylaGlassButtonVariant.ghost,
                    onPressed: loading ? null : onMore,
                    semanticLabel: message != null
                        ? '重试加载$title'
                        : '加载更多$title',
                  )
                else
                  AylaRevealItem(
                    fadeGlass: false,
                    index: footerRevealIndex!,
                    child: AylaGlassButton(
                      label: label,
                      variant: AylaGlassButtonVariant.ghost,
                      onPressed: loading ? null : onMore,
                      semanticLabel: message != null
                          ? '重试加载$title'
                          : '加载更多$title',
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
