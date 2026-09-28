/// 帖子域页面内联件：骨架（`.posts-skeleton`）与「我的帖子」页头（`.my-posts-head`）。
///
/// 依据 19 号 §7.5 range B 的 B 类（「单页内联态 / 骨架 / 页头」）：
/// 这两件在库内**没有对应件**，属页面级装配 ⇒ 先补件（画布节）再装配。
///
/// ## 逐条事实源
/// `.posts-skeleton`：
/// - `posts.css:628–635` `{ width:100%; min-width:0; flex:none; padding: sp3 sp4;
///   display:flex; flex-direction:column }`；
/// - `posts.css:646–651`（@≥769）：`max-width:680px; width:100%; margin:0 auto`；
/// - `posts.css:664–668`（@≥1025）：`max-width:1200px; padding: sp4 sp6`；
/// - `posts.css:670–675`（@≥1025）：`display:grid; grid-template-columns: repeat(2,minmax(0,1fr));
///   align-items:start; column-gap: sp3`；
/// - 骨架单元 `base.css:564–569`（`--radius-sm` + glass-bg + 1px 亮边 + frost-pulse）；
/// - 内联几何（`PostsHubPage.tsx:318–322`：三根 h120、**前两根 marginBottom 12**；
///   `MyPostsPage.tsx:186`：两根 h120 **无间距**；`UserPostsRoute.tsx:49–52` 同）。
/// - ⚠️ **一级帖子页（hub）** 的左右 padding 与 max-width 被目录页组规则
///   （`directory-filters.css:171–180`，特异性 0,3,0 > 0,1,0）**归零**
///   ⇒ hub 传 `centered:false` + 只留纵向 padding（见 [AylaPostsSkeleton.padding]）。
///
/// `.my-posts-head`：
/// - `posts.css:598–605` `{ flex:none; display:flex; align-items:center; gap: sp3;
///   padding: sp2 sp4; border-bottom:1px solid var(--glass-border) }`；
/// - `posts.css:637–642`（@≥769）：`max-width:680px; width:100%; margin:0 auto`；
/// - `posts.css:657–662`（@≥1025）：`max-width:1200px; padding-inline: sp6`；
/// - 结构 `MyPostsPage.tsx:180–185`：返回键（`.icon-btn-40` + IconBack **22**）+ `h1.placeholder-title`。
///
/// ## 公开面
/// `AylaPostsSkeleton` · `AylaMyPostsHead` · 样张 `aylaPostChromeSamples()`
library;

import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../../theme/buttons.dart' show AylaIconButton;
import '../../theme/tokens.dart';
import '../base/loading.dart' show AylaSkeleton;
import '../base/page_state.dart' show AylaPlaceholderTitle;

/// `.posts-skeleton` —— 首屏骨架（hub 3 根 / 我的 2 根）。
class AylaPostsSkeleton extends StatelessWidget {
  const AylaPostsSkeleton({
    super.key,
    this.count = 3,
    this.height = 120,
    this.itemGap = 12,
    this.centered = true,
    this.padding,
  });

  /// 骨架根数（hub 3 / 我的 2）。
  final int count;

  /// 单根高度（内联 `height: 120`）。
  final double height;

  /// 相邻根间距（内联 `marginBottom: 12`；我的帖子页传 0）。
  final double itemGap;

  /// 是否套 ≥769 的 680 / ≥1025 的 1200 居中限宽（hub 页被目录组规则归零 ⇒ false）。
  final bool centered;

  /// 内距覆盖；null = 按 web（base `sp3 sp4` → ≥1025 `sp4 sp6`）。
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final double w = MediaQuery.sizeOf(context).width;
    final bool lg = w >= AylaBreakpoints.lg; // 1025
    final bool sm = w >= 769;
    final EdgeInsetsGeometry resolved = padding ??
        (lg
            ? const EdgeInsets.symmetric(
                horizontal: AylaSpacing.sp6,
                vertical: AylaSpacing.sp4,
              )
            : const EdgeInsets.symmetric(
                horizontal: AylaSpacing.sp4,
                vertical: AylaSpacing.sp3,
              ));
    final List<Widget> bars = <Widget>[
      for (int i = 0; i < count; i += 1)
        Padding(
          padding: EdgeInsets.only(bottom: i == count - 1 ? 0 : itemGap),
          child: SizedBox(height: height, child: const AylaSkeleton()),
        ),
    ];
    Widget content;
    if (lg && centered) {
      // ≥1025：grid 两列（minmax(0,1fr)）+ column-gap sp3
      const double gap = AylaSpacing.sp3;
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int start = 0; start < bars.length; start += 2)
            Padding(
              padding: EdgeInsets.only(bottom: start + 2 < bars.length ? gap : 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: gap,
                children: <Widget>[
                  Expanded(child: bars[start]),
                  if (start + 1 < bars.length)
                    Expanded(child: bars[start + 1]),
                ],
              ),
            ),
        ],
      );
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: bars,
      );
    }
    Widget box = Padding(padding: resolved, child: content);
    if (centered && (sm || lg)) {
      box = Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: lg ? 1200 : 680,
            minWidth: 0,
          ),
          child: SizedBox(width: double.infinity, child: box),
        ),
      );
    }
    return box;
  }
}

/// `.my-posts-head` —— 「我的帖子 / 他人帖子」页头（返回键 + 标题 + 玻璃底边）。
class AylaMyPostsHead extends StatelessWidget {
  const AylaMyPostsHead({
    super.key,
    required this.title,
    this.onBack,
    this.leading,
    this.iconSize = 20,
  });

  /// 标题（我的帖子 / `{昵称}的帖子`）。
  final String title;

  /// 返回键回调（web `navigate(-1)`）。
  final VoidCallback? onBack;

  /// 自定义前导件（null = 复用 `.icon-btn-40` 返回键）。
  final Widget? leading;

  /// 返回图标边长（web `MyPostsPage.tsx:182` 是 **20**；
  /// 帖子详情头部 `PostDetailPage.tsx:405` 是 **22** ⇒ 逐处不同，勿统一）。
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final double w = MediaQuery.sizeOf(context).width;
    final bool lg = w >= AylaBreakpoints.lg; // 1025
    final bool sm = w >= 769;
    // ≥1025 左右 padding 变 sp6；否则 sp4（posts.css 603 / 660–661）
    final EdgeInsetsGeometry pad = EdgeInsets.symmetric(
      horizontal: lg ? AylaSpacing.sp6 : AylaSpacing.sp4,
      vertical: AylaSpacing.sp2,
    );
    Widget row = Padding(
      padding: pad,
      child: Row(
        // gap: var(--sp-3)
        spacing: AylaSpacing.sp3,
        children: <Widget>[
          leading ??
              AylaIconButton(
                icon: AylaIcon(aylaIconByName('iconBack')!, size: iconSize),
                onPressed: onBack,
                semanticLabel: '返回',
              ),
          Expanded(child: AylaPlaceholderTitle(title, textAlign: TextAlign.left)),
        ],
      ),
    );
    if (sm) {
      row = Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: lg ? 1200 : 680),
          child: SizedBox(width: double.infinity, child: row),
        ),
      );
    }
    return DecoratedBox(
      // border-bottom: 1px solid var(--glass-border)
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AylaColors.glassBorder),
        ),
      ),
      child: row,
    );
  }
}

/// 详情页的**绝对时间**文案（web `PostDetailPage.tsx:627`
/// `new Date(created_at).toLocaleString("zh-CN")`）。
///
/// zh-CN 的 `toLocaleString` 输出形如 `2026/9/28 20:15:00`（月日不补零、24 小时制）
/// ⇒ 这里按同一形状格式化（本地时区）。
///
/// ⚠️ **有意偏离（登记）**：web 对非法 ISO **无守卫**，会渲染出字面量 "Invalid Date"
/// （其卡片档 `PostCard.tsx:24–26` 反而有 `Number.isFinite` 守卫）；
/// Flutter 侧按「读不到不伪造」返回 null ⇒ 调用方不渲染时间行。
String? aylaPostDetailTime(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  final DateTime? parsed = DateTime.tryParse(iso);
  if (parsed == null) return null;
  final DateTime local = parsed.toLocal();
  String two(int v) => v < 10 ? '0$v' : '$v';
  return '${local.year}/${local.month}/${local.day} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

/// 画布样张（`.posts-skeleton` 三档 + `.my-posts-head` 两档居中）。
List<Widget> aylaPostChromeSamples() => <Widget>[
      const AylaPostsSkeleton(),
      const AylaMyPostsHead(title: '我的帖子'),
    ];
