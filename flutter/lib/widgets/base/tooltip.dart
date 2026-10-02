/// 悬停/长按提示（`AylaTooltip`）—— 全库统一项（2026-09-25 补齐）。
///
/// ## 事实源
/// web 侧图标钮与小元素普遍带**原生** `title=`（`grep -rn "title={" web/src` 共 28 处），例如
/// `FavoriteButton.tsx:72`（`actionError ?? state.error ?? label`）、`VoiceMemberRow.tsx:178/189`
/// （`一键禁音` / `{昵称} 静音`）、`ChannelSidebar.tsx:457`（`编辑` / `退出编辑`）、
/// `MessageList.tsx:1000`（`未读消息` / `有人 @ 我` / `有人回复了你`）、`ShareButton.tsx:29`（`label`）、
/// `ScrollingText.tsx:50` / `ScrollingTags.tsx:54`（溢出文本）、`MediaContent.tsx:726/831`（文件名）等。
/// ⚠️ 那份提示气泡由**浏览器/操作系统绘制**，没有 CSS 可移植（不属 `styles/*.css` 任何一条规则）。
///
/// ## 机制差异（有意偏离，登记）
/// Flutter 没有「原生 title 提示」，平台等价物 = Material `Tooltip`：
/// - **迟滞取 [AylaTooltipMetrics.wait] = 500ms**：浏览器 `title` 的典型迟滞量级；
///   Material 默认 `waitDuration` 为 0 ⇒ 指针一掠过就弹，观感比 web 吵得多。
/// - **样式保留 Material 默认**（底色/字号/圆角）：web 那份是 OS 绘制、无源码可对齐 ⇒ 不做「凭印象设计」。
/// - ⚠️ **触发方式固定为 «TooltipTriggerMode.manual»（2026-09-28 实测修正）**：Material 默认在
///   android/iOS 是「**长按**触发」⇒ 会**抢走宿主自身的长按手势**（实测：给 «AylaAvatarHalo» 接上后，
///   «message_bubble_test» 的「长按头像 500ms → 插入 @该用户」直接红）。web 的 «title» 从不由长按触发
///   ⇒ «manual» 才贴近事实源；**hover 显示不受影响**（hover 由 Tooltip 自己的 MouseRegion 驱动，
///   与 triggerMode 无关）。
/// - 键盘可达性：`Tooltip` 自带 `Semantics(tooltip:)`，会并入无障碍名（web 的 `title` 也是可访问名来源）✓。
///
/// ## ⚠️ 语义崩溃规避：锚点子树必须 `Semantics(container: true)`（2026-10-02 实测复现）
///
/// Material `Tooltip` **无条件**在内层套 `OverlayPortal`，而 `OverlayPortal` 又在
/// `build` 里**无条件**插入 `Semantics(traversalParentIdentifier: this)`
/// （框架 `widgets/overlay.dart:2096/2116`，`this` = OverlayPortal 自己的 State；`lib/` 从未传过该参数）。
/// 于是每个 Tooltip 都会在语义树里留下一个由 `OverlayPortal` 持有的**遍历锚点**（本地实测：
/// 语义树里 `traversalParentIdentifier != null` 的节点 100% 来自它）。
///
/// 该锚点会被 `SemanticsConfiguration.absorb` 上提进祖先节点（`semantics.dart:3884/6837`）。
/// 当**带 GlobalKey 的行在未加 key 的列表 item 之间下移索引**（行跨 item 重挂、且新旧两个
/// `IndexedSemantics` 节点同帧变脏）时，`SemanticsOwner.sendSemanticsUpdate` 会报：
///
/// ```
/// 'semantics.dart': Failed assertion: line 5016 pos 13:
/// 'The traversalParentIdentifier must be unique. No two semantics nodes can share the same
///  traversalParentIdentifier.'
/// ```
///
/// 这是 **Flutter framework 缺陷**，不是本库传参错误：断言引入于
/// `fccfa978a976`（"Reland Refactor OverlayPortal semantics (#173005)"，随 3.41.0 发布），
/// 至今（master / 3.47.4 stable）未修，上游 issue **#193677**（open）即此形态。
///
/// **处置**：按上游 issue 作者实测有效的 workaround，在 Tooltip 之外套一层
/// `Semantics(container: true)` —— 它让锚点留在**稳定位置**、不再随 item 索引变化，
/// 从根上消除同帧双持有者。
///
/// ⚠️ **视觉零影响**：多出的这层只是语义边界，无尺寸/颜色/动画/布局副作用。
/// ⚠️ **语义等价**（R1/R2 语义树实测对照）：`Semantics(container: true)` **本身不产生独立语义节点**
/// （R2 实测仅多一层 `children=1` 的透传节点），锚点仍留在 Tooltip 自身那一层；
/// 可访问名与 tooltip 语义**一字不变**。
///
/// ## 公开面
/// `AylaTooltip` · `AylaTooltipMetrics`
library;

import 'package:flutter/material.dart';

/// 提示的时长常量（集中一处，全库一致）。
abstract final class AylaTooltipMetrics {
  /// 悬停迟滞（浏览器 `title` 的典型量级；Material 默认 0 太吵）。
  static const Duration wait = Duration(milliseconds: 500);

  /// 展示时长（Material 默认 1.5s，与浏览器同量级）。
  static const Duration show = Duration(milliseconds: 1500);
}

/// 悬停提示：包住任意子件，指针停留 [AylaTooltipMetrics.wait] 后弹出 [message]。
///
/// [message] 为 null / 空串时**完全透传**（等价 web 的 `title={undefined}`：不渲染提示，
/// 例如 `SubGroupDialog.tsx:86` 的 `canDelete ? undefined : "默认组不可删除"`）。
class AylaTooltip extends StatelessWidget {
  const AylaTooltip({super.key, required this.message, required this.child});

  /// 提示文案（null / '' ⇒ 不提示）。
  final String? message;

  /// 被包住的元素（图标钮 / 文本 / 徽标…）。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final String? text = message;
    if (text == null || text.isEmpty) return child;
    // ⚠️ 「`container: true` 必须在 Tooltip **之外**」：它让 OverlayPortal 的遍历锚点
    // 留在稳定位置（不随列表 item 索引迁移），从而消除 `traversalParentIdentifier`
    // 重复断言；换成包在 `child:` 里无效（实测两者锚点节点不同）。依据见文件头。
    return Semantics(
      container: true,
      child: Tooltip(
        message: text,
        waitDuration: AylaTooltipMetrics.wait,
        showDuration: AylaTooltipMetrics.show,
        // manual：不跟随 tap/longPress（见文件头「触发方式」条）——否则会抢宿主长按手势
        triggerMode: TooltipTriggerMode.manual,
        child: child,
      ),
    );
  }
}
