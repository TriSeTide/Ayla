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
/// - 触屏**长按**同样触发（Material 行为），与桌面 hover 语义一致。
/// - 键盘可达性：`Tooltip` 自带 `Semantics(tooltip:)`，会并入无障碍名（web 的 `title` 也是可访问名来源）✓。
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
    return Tooltip(
      message: text,
      waitDuration: AylaTooltipMetrics.wait,
      showDuration: AylaTooltipMetrics.show,
      child: child,
    );
  }
}
