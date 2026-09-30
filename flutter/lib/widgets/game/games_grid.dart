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
/// ## 目录页上下文（调用点口径）
/// 一级桌游页（`GamesHubPage`）的调用点传 `aylaDirectoryListPadding(context)`
/// —— web 的组规则 `directory-filters.css:171–180`（左右恒 0）与 `199–208`
/// （≥769 顶部归零）作用在 `.games-grid` / `.games-grid.games-grid-loading`
/// 两个容器上；**群内（`GroupGames`）与画布样张不传**，保持基样式 `sp3 sp4`。
///
/// ⚠️ **群内口径核对结果（2026-09-29，只登记未改）**：web 的群内留白由**外层容器**给
/// —— `.group-page .group-games { padding: var(--sp-4) }`（`group.css:411–415`，
/// 0-2-0 压过 `boardgame.css:247–252` 的 `sp3 sp4`），内层 `.group-games-grid` 自身
/// `padding: 0`（`boardgame.css:254–258`）。Flutter 群内页有等价外层
/// （`group_games_page.dart:218` 的 `EdgeInsets.all(sp4)`），本件默认 `sp4/sp3` 再叠一次
/// ⇒ 群内左右各多 **16**、上下各多 **12**。另：web 群内**恒 2 列**（`boardgame.css:256`），
/// 而群内调用点未传 `columns` ⇒ 宽屏走 4 列。两条均属群内页面口径，未在本轮改动。
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

/// `.games-grid` / `.games-grid-loading` 的基样式内距（`boardgame.css:232–237`：
/// `padding: var(--sp-3) var(--sp-4)`）—— 两件共用同一默认值。
const EdgeInsets _kGamesGridBasePadding = EdgeInsets.fromLTRB(
  AylaSpacing.sp4,
  AylaSpacing.sp3,
  AylaSpacing.sp4,
  AylaSpacing.sp3,
);

/// 桌游网格：等宽 N 列（窄屏 2 / 宽屏 4，可用 [columns] 覆写）。
class AylaGamesGrid extends StatelessWidget {
  const AylaGamesGrid({
    super.key,
    required this.children,
    this.columns,
    this.padding = _kGamesGridBasePadding,
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
    this.padding = _kGamesGridBasePadding,
  });

  /// 跨列文案（web `.games-skel-text`）。
  final String label;

  /// 列数（与网格保持一致；null ⇒ 跟随断点）。
  final int? columns;

  /// 网格内距（web 骨架的容器同时带 `.games-grid`（GamesHubPage.tsx:185）⇒ 与
  /// [AylaGamesGrid.padding] 同一基样式；目录页调用点传
  /// `aylaDirectoryListPadding(context)` 归零左右与顶部）。
  final EdgeInsetsGeometry padding;

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
            padding: padding,
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
