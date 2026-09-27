/// 收藏列表加载骨架（web `pages/FavoritesPage.tsx:268–271` + `profile.css 452–456`）。
///
/// ## 事实源
/// ```
/// FavoritesPage.tsx 268  `<div className="favorites-skeleton" role="status" aria-label="正在加载收藏">`
/// tsx 269–270            两条骨架条：第一条 `height: 64; marginBottom: 8`、第二条 `height: 64`
/// profile.css 452–456    .favorites-skeleton { padding: sp4; display: flex; flex-direction: column }
/// ```
///
/// ## 公开面
/// `AylaFavoritesSkeleton`
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../base/loading.dart';

/// 收藏列表骨架：两条 64 高的骨架条（首条下方留 8）。
class AylaFavoritesSkeleton extends StatelessWidget {
  const AylaFavoritesSkeleton({super.key, this.label = '正在加载收藏'});

  /// 无障碍状态文案（web `aria-label`）。
  final String label;

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
        padding: const EdgeInsets.all(AylaSpacing.sp4), // padding: var(--sp-4)
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
