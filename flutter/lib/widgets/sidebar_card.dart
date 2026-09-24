/// 宽屏侧栏玻璃卡 —— web 三处侧栏容器的**同一份材质与滚动语义**。
///
/// ## 事实源（三处同款，只有宽度/阴影/入场时长不同）
///
/// | web 类 | 宽 | 阴影 | 入场 |
/// |---|---|---|---|
/// | `directory-filters.css:22–41` `.directory-page .directory-filters` | **224** | `--glass-shadow-compact` | `auroraqua-sidebar-in` **300ms**（`--auroraqua-duration`） |
/// | `app.css:391–407` `.chat-sidebar` | **300** | `--glass-shadow` | `auroraqua-sidebar-in` **500ms**（`--auroraqua-duration-enter`） |
/// | `messages.css:243–256` `.wide-messages-sidebar` | **332** | `--glass-shadow` | 同上 **500ms** |
///
/// 三者共同：`--glass-bg` + `--glass-filter`(blur24 sat1.4) + 1px `--glass-border` +
/// `radius-card 16` + `align-self: stretch` + `max-height: 100%` + `overflow-y: auto`
/// + `scroll-padding: sp3`；入场关键帧 `auroraqua.css:8–11`（`-20px 0` → `0 0` + 淡入）。
///
/// ## ⚠️ 照实：`margin: var(--sidebar-gutter)` 是**死声明**
/// 三处都写了 `margin: var(--sidebar-gutter)`，但该变量在 web **全历史未定义**
/// （`grep -rn 'sidebar-gutter' web/src/styles/*.css` 只有 5 处引用、零定义）
/// ⇒ 按 CSS 规范属「invalid at computed-value time」，**整条 `margin` 简写作废、回落初始值 0**
/// ⇒ 侧栏卡实际**没有外边距**。本件照实不加 margin（同 `--glass-bg-hover` 的既有先例，
/// 见 13 号 §6.21）。
///
/// ## 为什么抽这一件（2026-09-24 用户点名）
/// > 「会话列表背景卡片、选中高亮、切换动画等应直接复用 DirectoryFilters 宽屏侧栏」
///
/// `AylaDirectoryFilters` 的宽屏档原本自己拼了这套容器；会话侧栏（`WideMessagesSidebar`
/// 等待做件）若再拼一遍就是第三份。抽为公共件后三处共用（宽度/阴影/入场时长由参数区分）。
library;

import 'package:flutter/material.dart';

import '../theme/glass.dart';
import '../theme/tokens.dart';
import 'reveal.dart';

/// 宽屏侧栏玻璃卡（材质 + 自滚动 + 入场）。
class AylaSidebarCard extends StatelessWidget {
  const AylaSidebarCard({
    super.key,
    required this.child,
    this.width,
    this.shadow = AylaShadows.glass,
    this.padding = const EdgeInsets.all(AylaSpacing.sp3),
    this.scrollController,
    this.enterDuration = AylaDurations.enter,
    this.enterOffset = const Offset(-20, 0),
    this.enter = true,
    this.scrollable = true,
  });

  /// 卡片内容。
  final Widget child;

  /// 固定宽度（224 / 300 / 332）。null = 由父级决定。
  ///
  /// ⚠️ 传了宽度就要**松掉横向紧约束**：`SizedBox(width:)` 走 `constraints.enforce`，
  /// 紧宿主里会被夹回宿主宽（13 号 §五；库内先例 `live_rail.dart`）——本件内部已处理。
  final double? width;

  /// 外阴影（侧栏卡：`.chat-sidebar` / `.wide-messages-sidebar` 用 `--glass-shadow`；
  /// `.directory-filters` 用 `--glass-shadow-compact`）。
  final List<BoxShadow> shadow;

  /// 内容内边距（`padding: var(--sp-3)`；滚动的裁剪边界按 CSS 是 padding box，
  /// 故 padding 归**滚动内容**承担 —— 见 [child] 的滚动层）。
  final EdgeInsetsGeometry padding;

  /// 滚动控制器（需要「滚动揭示」时由调用方持有，如 `AylaNavHighlightList`）。
  final ScrollController? scrollController;

  /// 入场时长（`--auroraqua-duration` 300ms / `--auroraqua-duration-enter` 500ms）。
  final Duration enterDuration;

  /// 入场位移（`auroraqua-sidebar-in`：`-20px 0` → `0 0`）。
  final Offset enterOffset;

  /// 是否播入场（已有动画宿主时传 false）。
  final bool enter;

  /// 是否自滚动。
  ///
  /// `.directory-filters` / `.chat-sidebar` 自身 `overflow-y: auto`（内容整体滚），
  /// 而 **`.wide-messages-sidebar` 不声明 overflow**（`min-height: 0`，滚动归各 tab 内容区）
  /// ⇒ 后者传 `false`（用 `Padding` 代替滚动视图），否则会出现「内外双滚动」且 tabs 跟着滚。
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    Widget card = GlassSurface(
      radius: AylaRadii.rCard,
      shadow: shadow,
      padding: null,
      child: scrollable
          ? SingleChildScrollView(
              controller: scrollController,
              padding: padding,
              child: child,
            )
          : Padding(padding: padding, child: child),
    );

    if (width != null) {
      card = UnconstrainedBox(
        // 横向松约束（保宽度权威）、纵向仍受父约束 = web `align-self: stretch`
        constrainedAxis: Axis.vertical,
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: card),
      );
    }

    if (!enter) return card;
    return AylaRevealItem(
      offset: enterOffset,
      duration: enterDuration,
      curve: AylaCurves.auroraquaEaseOut,
      child: card,
    );
  }
}
