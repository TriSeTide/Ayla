/// 收藏列表加载骨架（web `pages/FavoritesPage.tsx:268–271` + `profile.css 452–456`）。
///
/// ## 事实源
/// ```
/// FavoritesPage.tsx 268  `<div className="favorites-skeleton" role="status" aria-label="正在加载收藏">`
/// tsx 269–270            两条骨架条：第一条 `height: 64; marginBottom: 8`、第二条 `height: 64`
/// profile.css 452–456    .favorites-skeleton { padding: sp4; display: flex; flex-direction: column }
/// directory-filters.css 171–180  组规则：该容器的 `padding-left/right` 归零（全断点）
/// 199–208                组规则：≥769 `padding-top: 0`（`.favorites-skeleton` 在名单内）
/// ```
///
/// ⚠️ **已登记未改**（不在本次 padding 口径内）：≥1025 时 web 把该容器变成两列 grid
/// （`directory-filters.css:210–217`：`repeat(2, minmax(0,1fr))` + gap sp3），
/// 本件恒为纵排两条 —— 两列排布属结构改动，未在本轮动。
///
/// ## 公开面
/// `AylaFavoritesSkeleton` · `kAylaFavoritesSkeletonPadding`
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../base/loading.dart';

/// `.favorites-skeleton` 基样式内距（`profile.css:452–456`：`padding: var(--sp-4)`）。
const EdgeInsets kAylaFavoritesSkeletonPadding = EdgeInsets.all(AylaSpacing.sp4);

/// 收藏列表骨架：两条 64 高的骨架条（首条下方留 8）。
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
  /// —— 左右恒 0 + ≥769 顶部归零）。
  final EdgeInsetsGeometry padding;

  /// 单条骨架高度（web `height: 64`）。
  static const double barHeight = 64;

  /// 首条下方留白（web `marginBottom: 8`）。
  static const double barGap = AylaSpacing.sp2;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true, // 等价 role=status
      label: label,
      child: Padding(
        padding: padding,
        child: Column(
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
