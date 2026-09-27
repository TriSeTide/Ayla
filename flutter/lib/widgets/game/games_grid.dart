/// 桌游网格 + 加载骨架（web `pages/GamesHubPage.tsx:184–216` + `styles/boardgame.css 232–275`）。
///
/// ## 事实源
/// ```
/// boardgame.css 232–237  .games-grid：grid · repeat(2, 1fr) · gap sp3 · padding sp3 sp4
/// boardgame.css 240–243  （≥769）.games-grid：repeat(4, 1fr)
/// boardgame.css 254–259  .group-games-grid：**恒 2 列**（群内），gap sp3
/// tsx 185–193            骨架：`.games-grid.games-grid-loading[aria-busy=true]` = 2 张
///                        `.games-skeleton-card`（内含 `.skeleton` 高 120 / 圆角 12）+ 跨列文案
///                        `.home-load-text.games-skel-text`「正在加载桌游室…」
/// boardgame.css 265–275  .games-grid-loading { align-content: start } · .games-skeleton-card
///                        { display block · height 120 · margin-bottom sp3 } · .games-skel-text { grid-column: 1/-1 }
/// ```
///
/// ## 机制差异（登记）
/// Flutter 没有 CSS grid ⇒ 用 `LayoutBuilder` 算出等宽列宽（`(可用宽 − 左右内距 − 列间距×(n−1)) / n`）
/// 再 `Wrap` 换行 —— 与 `repeat(n, 1fr)` 等价；列数由断点 <769 ⇒ 2 / ≥769 ⇒ 4 决定（可用 [columns] 覆写，
/// 群内场景恒传 2）。
///
/// ## 公开面
/// `AylaGamesGrid` · `AylaGamesGridSkeleton`
library;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../base/loading.dart';

/// 桌游网格：等宽 N 列（窄屏 2 / 宽屏 4，可用 [columns] 覆写）。
class AylaGamesGrid extends StatelessWidget {
  const AylaGamesGrid({
    super.key,
    required this.children,
    this.columns,
    this.padding = const EdgeInsets.fromLTRB(
      AylaSpacing.sp4,
      AylaSpacing.sp3,
      AylaSpacing.sp4,
      AylaSpacing.sp3,
    ),
    this.gap = AylaSpacing.sp3,
  });

  /// 卡片（`AylaGameRoomCard`）。
  final List<Widget> children;

  /// 列数（null ⇒ 跟随断点：<769 两列 / ≥769 四列）。
  final int? columns;

  /// 网格内距（`padding: sp3 sp4`）。
  final EdgeInsetsGeometry padding;

  /// 行/列间距（`gap: sp3`）。
  final double gap;

  @override
  Widget build(BuildContext context) {
    final int count =
        columns ??
        (MediaQuery.sizeOf(context).width >= 769 ? 4 : 2); // ≥769 → 4 列
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final EdgeInsets inset = padding.resolve(Directionality.of(context));
        final double available =
            constraints.maxWidth - inset.horizontal - gap * (count - 1);
        final double colW = available <= 0 ? 0 : available / count;
        return Padding(
          padding: padding,
          child: Wrap(
            spacing: gap,
            runSpacing: gap,
            children: <Widget>[
              for (final Widget child in children)
                SizedBox(width: colW, child: child),
            ],
          ),
        );
      },
    );
  }
}

/// 跨列文案的 key（测试用它量「跨列」这一事实 —— `find.text` 量的只是文本自身宽）。
const Key gamesSkeletonTextKey = ValueKey<String>('games-skel-text');

/// 桌游网格加载骨架：两张 120 高骨架卡 + 跨列文案。
class AylaGamesGridSkeleton extends StatelessWidget {
  const AylaGamesGridSkeleton({
    super.key,
    this.label = '正在加载桌游室…',
    this.columns,
  });

  /// 跨列文案（web `.games-skel-text`）。
  final String label;

  /// 列数（与网格保持一致；null ⇒ 跟随断点）。
  final int? columns;

  /// 骨架卡高度（web `.games-skeleton-card { height: 120 }`）。
  static const double cardHeight = 120;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Semantics(
      liveRegion: true, // 等价 aria-busy / status
      label: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 两张骨架卡走网格列（web：两个 `.games-skeleton-card` 是 grid 子项）
          AylaGamesGrid(
            columns: columns,
            children: const <Widget>[
              AylaSkeleton(height: cardHeight, radius: AylaRadii.rInput),
              AylaSkeleton(height: cardHeight, radius: AylaRadii.rInput),
            ],
          ),
          // 跨列文案：web 是 `grid-column: 1 / -1`（占满一行的 grid 子项）——
          // ⚠️ 若当成普通网格子项传入，会被按**单列宽**包住（实测 183px）⇒ 必须放在网格之外通栏。
          Padding(
            key: gamesSkeletonTextKey,
            padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp4),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: t.timestamp.copyWith(color: AylaColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
