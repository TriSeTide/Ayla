/// 个人主页（`/profile` · `/user/:id`）宽屏侧栏模式的页面级装配工具。
///
/// ## 为什么是页面级模块
/// 两个页面共用 `profile.css` 的 `:has(.profile-main)` 侧栏模式，但 Flutter 侧没有
/// CSS 的负 margin / `scroll-padding` / `align-self: stretch` 直接等价物 ——
/// 这些几何表达属**页面装配**（同 `hub_support.dart` 的性质），不是可复用视觉件。
///
/// ## 事实源（`profile.css:57–113`，逐条）
/// ```
/// .profile-page-split:has(.profile-main) {
///   height: 100%; min-height: 0; display: flex; flex-direction: column;
///   overflow: hidden; padding: var(--sp-3) var(--sp-3) 0;
/// }
/// … > .profile-column { display: flex; flex-direction: row; flex: 1 1 0;
///   gap: var(--sp-3); min-height: 0; align-items: stretch; margin: 0; }
/// .profile-side { align-self: stretch; gap: var(--sp-2); width/flex-basis: clamp(280px, 32%, 340px);
///   max-height: 100%; margin: 0 0 var(--sp-3); overflow-y: auto;
///   scroll-padding: var(--sp-3); overscroll-behavior: contain; }
/// .profile-main { flex: 1 1 0; min-height: 0; overflow-y: auto; scrollbar-gutter: stable;
///   margin: calc(-1 * var(--sp-3)) calc(-1 * var(--sp-3)) 0;
///   padding: var(--sp-3) calc(var(--sp-2) + var(--sp-3)) var(--sp-6); }
/// ```
///
/// ## 公开面
/// `aylaProfileSidebarScroll` · `aylaProfileMainScroll`
library;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import '../widgets/profile/profile_card.dart' show AylaProfileSidebarHeight;

/// 侧栏（`.profile-side`）：**铺满可用高度 + 自滚动 + 底部呼吸**。
///
/// - `min-height` 下限 = 可用高 − 底部 margin（表达卡片 `flex: 1 0 auto` ⇒ 铺满）；
/// - 超出下限（内容比侧栏高）时由 [SingleChildScrollView] 承担滚动（web `overflow-y: auto`）；
/// - `gap: var(--sp-2)` 与 `scroll-padding` / `overscroll-behavior: contain`：
///   Flutter 的滚动视图默认不外溢到父级（与 `contain` 同义）、`scroll-padding` 无等价物
///   （无锚点滚动），两者的单组件侧栏（`/profile`）也无实际影响 ⇒ 未显式表达。
///
/// ⚠️ 卡片内的「间隙自适应」由 [AylaProfileCard.fillHeight]（`space-between`）表达 ——
/// 实测：`ConstrainedBox(minHeight: X)` 内的 `Column(mainAxisSize: min, spaceBetween)`
/// 会把 `max(内容高, X) − 内容高` 平均分配到子项之间（`mainAxisSize.min` **不会**吞掉
/// 这段空间），这正是 web `flex: 1` + `margin-top: auto` 的净效果。
Widget aylaProfileSidebarScroll({
  required double availableHeight,
  required Widget child,
}) {
  final double minHeight =
      (availableHeight - AylaSpacing.sp3).clamp(0.0, double.infinity);
  return Padding(
    // margin: 0 0 var(--sp-3)
    padding: const EdgeInsets.only(bottom: AylaSpacing.sp3),
    child: SingleChildScrollView(
      // ⚠️ 必须同时注入高度：卡片的父级是 `AylaGlassCard` 的
      // `DecoratedBox > Stack(StackFit.loose)` ⇒ **约束会被放松**（minHeight 丢、
      // maxHeight 在滚动视图内为 ∞）⇒ 卡片内的 `space-between` 拿不到可用高。
      // 见 `AylaProfileSidebarHeight` 的说明。
      child: AylaProfileSidebarHeight(
        available: minHeight,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: minHeight),
          child: child,
        ),
      ),
    ),
  );
}

/// 内容区（`.profile-main`）：独立滚动 + 阴影绘制带（负 margin 的 Flutter 等价物）。
///
/// `margin: -sp3 -sp3 0` + padding 补偿让滚动裁剪盒上/左/右各外扩 12px，
/// 卡片阴影（模糊 32px）完整落在 padding box 内不被裁；视觉位置由
/// [Transform.translate] 回位。
///
/// ⚠️ 与 `widgets/base/directory_page.dart` 的 `_DirectoryContentBleed` 是**同源实现**
/// （那件是私有的目录页版本）—— 差异只在 padding 值与语义；两者都小到不值得为它
/// 抽一个公共件，按「同源登记」处理。
///
/// ⚠️ `RenderBox.hitTest` 有 `size.contains` 前置判断 ⇒ 外扩的 12px 绘制带不参与命中
/// （web 的盒真实外扩、可命中）—— 与目录页同款登记。
Widget aylaProfileMainScroll(Widget child) {
  return LayoutBuilder(
    builder: (BuildContext context, BoxConstraints c) {
      final bool bounded = c.maxHeight.isFinite;
      return OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: c.maxWidth + AylaSpacing.sp3 * 2,
        maxWidth: c.maxWidth + AylaSpacing.sp3 * 2,
        minHeight: bounded ? c.maxHeight + AylaSpacing.sp3 : null,
        maxHeight: bounded ? c.maxHeight + AylaSpacing.sp3 : null,
        child: Transform.translate(
          offset: const Offset(-AylaSpacing.sp3, -AylaSpacing.sp3),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              AylaSpacing.sp2 + AylaSpacing.sp3,
              AylaSpacing.sp3,
              AylaSpacing.sp2 + AylaSpacing.sp3,
              AylaSpacing.sp6,
            ),
            child: child,
          ),
        ),
      );
    },
  );
}
