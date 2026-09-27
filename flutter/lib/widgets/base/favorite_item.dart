/// 收藏列表项容器（web `pages/FavoritesPage.tsx:95` + `styles/profile.css 474–487 / 539–541`）。
///
/// ## 事实源
/// ```
/// FavoritesPage.tsx 95  <div className="favorite-item typed-result-card" data-favorite-id data-result-type>
///                       └─ <FavoriteResultCard … action=<button className="msg-action-btn typed-card-remove">取消收藏</button> />
/// profile.css 474–487  .favorite-item：display flex · align-items center · gap sp3 · padding sp3 ·
///                      border-radius --radius-input · background --glass-bg · 1px --glass-border ·
///                      backdrop-filter --glass-filter · box-shadow **--glass-shadow-compact** ·
///                      transition box-shadow / border-color / translate（--auroraqua-duration + ease）
/// profile.css 539      （≥769）.favorite-item { padding: sp4 }
/// ```
/// ⚠️ **登记**：`.favorite-item-title` / `-type` / `-body`（profile.css 498–524）在 tsx **零使用 ⇒ 死声明**，
/// 不复刻；`.favorite-item-main` 只在 `DirectoryResultCards.tsx:47` 的「内容不可用」按钮上（gap 2px，
/// ≥769 ⇒ sp2），该处由 `AylaFavoriteResultCard._unavailable` 自身承担。
///
/// ## 公开面
/// `AylaFavoriteItem`
library;

import 'package:flutter/material.dart';

import '../../theme/glass.dart';
import '../../theme/tokens.dart';

/// 收藏项容器：玻璃 + 紧凑阴影 + 内距 sp3（≥769 ⇒ sp4），内部放对应的结果卡。
class AylaFavoriteItem extends StatelessWidget {
  const AylaFavoriteItem({super.key, required this.child});

  /// 对应的结果卡（`AylaFavoriteResultCard` / 四个 typed 卡）。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // `@media (min-width: 769px)` ⇒ padding sp4（窄屏 sp3）
    final bool wide = MediaQuery.sizeOf(context).width >= 769;
    return AylaGlassSurface(
      radius: AylaRadii.rInput, // border-radius: --radius-input（AylaGlassSurface 收 double）
      padding: EdgeInsets.all(wide ? AylaSpacing.sp4 : AylaSpacing.sp3),
      shadow: AylaShadows.compact, // box-shadow: --glass-shadow-compact
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center, // align-items: center
        children: <Widget>[
          Expanded(child: child), // flex 子项（卡片自身撑满）
        ],
      ),
    );
  }
}
