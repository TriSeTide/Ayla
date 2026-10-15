/// 收藏列表加载骨架（web `pages/FavoritesPage.tsx:268–271` + `profile.css 452–456` +
/// `directory-filters.css 171–180 / 199–208 / 210–217`）。
///
/// ## 事实源（逐条；行号已按 2026-10-14 复核）
/// ```
/// FavoritesPage.tsx 268  `<div className="favorites-skeleton" role="status" aria-label="正在加载收藏">`
/// tsx 269–270            两条骨架条：第一条 `height: 64; marginBottom: 8`、第二条 `height: 64`
/// profile.css 452–456    .favorites-skeleton { padding: sp4; display: flex; flex-direction: column }
/// directory-filters.css 171–180  组规则：该容器的 `padding-left/right` 归零（全断点，无媒体查询）
/// directory-filters.css 199–208  @media (min-width:769) 组规则：`padding-top: 0`
///                                （`.favorites-skeleton` 在 204–205 的名单内）
/// directory-filters.css 210–217  @media (min-width:1025) —— **本件本轮的修复对象**：
///   .directory-page .favorites-skeleton {
///     display: grid;
///     grid-template-columns: repeat(2, minmax(0, 1fr));
///     align-items: start;
///     gap: var(--sp-3);
///   }
///   ⇒ ≥1025 起：两条骨架**并排两列**（原 `flex-direction: column` 被 grid 取代 ⇒ 纵排失效），
///     两列等宽（`minmax(0,1fr)` ⇒ 列宽 = (容器宽 − sp3) / 2，且**允许收缩到 0**）、
///     `align-items: start` ⇒ 两条各自贴列顶（等高，故与 stretch 同值）、
///     行/列间距均为 sp3(12)（`gap` 单值 ⇒ row-gap 与 column-gap 都是 12）。
///     两列两行时：第 1 条 → 第 1 行第 1 列；第 2 条 → 第 1 行第 2 列（grid 自动流按行）。
///     ⚠️ `marginBottom: 8`（tsx 269）在 grid 容器下仍在（骨架条自身的行内样式），
///        但两列并排时不影响可见布局（只把第 1 行撑高 8px）。
/// ```
///
/// ## 与 web 的机制差异（登记）
/// Flutter 无 `display: grid` ⇒ 两列用 `Row` + `Expanded`（等价 `minmax(0,1fr)`：
/// `Expanded` 给紧约束、可收缩到 0）+ `crossAxisAlignment: start`；列距用 `spacing: sp3`。
/// 单列（<1025）保持 `Column`（= web 的 `flex-direction: column`）。
///
/// ## 公开面
/// `AylaFavoritesSkeleton` · `kAylaFavoritesSkeletonPadding` · [kAylaFavoritesSkeletonTwoColumnMinWidth]
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../base/loading.dart';

/// `.favorites-skeleton` 基样式内距（`profile.css:452–456`：`padding: var(--sp-4)`）。
const EdgeInsets kAylaFavoritesSkeletonPadding = EdgeInsets.all(AylaSpacing.sp4);

/// 两列档阈值 —— 逐字取自 web 的 `@media (min-width: 1025px)`
/// （`directory-filters.css:210`）。仓内同口径：`posts_hub_page.dart` 的
/// `kAylaPostsWideMinWidth = 1025`。
const double kAylaFavoritesSkeletonTwoColumnMinWidth = 1025;

/// 收藏列表骨架：两条 64 高的骨架条（首条下方留 8）。
///
/// <1025 = 纵排单列；≥1025 = 两列并排（`directory-filters.css:210–217`）。
class AylaFavoritesSkeleton extends StatelessWidget {
  const AylaFavoritesSkeleton({
    super.key,
    this.label = '正在加载收藏',
    this.padding = kAylaFavoritesSkeletonPadding,
  });

  /// 无障碍状态文案（web `aria-label`）。
  final String label;

  /// 容器内距（基样式 `profile.css:452–456` 的 `padding: var(--sp-4)`；
  /// 收藏页调用点传目录页档 `aylaDirectoryListPadding(context, top: sp4, bottom: sp4)`
  /// —— 左右恒 0（171–180）+ ≥769 顶部归零（199–208））。
  final EdgeInsetsGeometry padding;

  /// 单条骨架高度（web `height: 64`）。
  static const double barHeight = 64;

  /// 首条下方留白（web `marginBottom: 8`；窄屏纵排档生效）。
  static const double barGap = AylaSpacing.sp2;

  /// 两列间距（web `gap: var(--sp-3)`，`directory-filters.css:215`）。
  static const double columnGap = AylaSpacing.sp3;

  @override
  Widget build(BuildContext context) {
    // 断点读 MediaQuery（web 的媒体查询语义；测试与画布用 setSurfaceSize /
    // MediaQuery.copyWith(size:) 钉住 —— 库内既有口径，见 skill「测试表面默认 800x600」条）。
    final bool twoColumn = MediaQuery.sizeOf(context).width >=
        kAylaFavoritesSkeletonTwoColumnMinWidth;

    return Semantics(
      liveRegion: true, // 等价 role=status
      label: label,
      child: Padding(
        padding: padding,
        child: twoColumn
            // ≥1025：grid `repeat(2, minmax(0,1fr))` + `align-items: start` + `gap: sp3`
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: columnGap,
                children: const <Widget>[
                  Expanded(child: AylaSkeleton(height: barHeight)),
                  Expanded(child: AylaSkeleton(height: barHeight)),
                ],
              )
            // <1025：flex column（tsx 269 首条 `marginBottom: 8`）
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: const <Widget>[
                  AylaSkeleton(height: barHeight),
                  SizedBox(height: barGap),
                  AylaSkeleton(height: barHeight),
                ],
              ),
      ),
    );
  }
}
