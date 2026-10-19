/// 顶部安全区（`env(safe-area-inset-top)` 的原生等价物）。
///
/// ## 为什么需要
/// 原生窗口是**边到边**的：整棵 UI 从 `y=0`（状态栏底下）开始画。
/// web 没这个问题不是因为它更简单 —— `index.html:5` 的 viewport **没有**
/// `viewport-fit=cover` ⇒ `env(safe-area-inset-top)` 在 web 上**恒为 0**，
/// 浏览器把页面排在状态栏之下（安全区由浏览器外壳代劳）。Flutter 没有那层外壳。
///
/// ## ⚠️ 关键：让出的高度必须**在玻璃材质内部**，不能是外层裸留白
///
/// 2026-10-19 用户实拍反馈「**割裂感**」：我曾在壳层给页面顶部塞一个纯
/// `SizedBox(height: top)` ⇒ 状态栏区域露出的是**页面底下的极光背景**，
/// 与紧邻的玻璃顶栏形成一条明显色带：
/// ```text
/// ┌──────────────┐
/// │ 1:03   5G  ▮ │  ← 极光底色，与下方玻璃断开（错）
/// ├──────────────┤
/// │ ← 群聊       │  ← 玻璃顶栏
/// ```
/// 用户认可的形态（群顶栏最初的做法）是**把状态栏吃进同一块玻璃**：
/// ```text
/// ┌──────────────┐
/// │ 1:03   5G  ▮ │  ← 同一块磨砂底的延伸
/// │ ← 群聊       │
/// └──────────────┘
/// ```
/// ⇒ 因此本件**不是一个外层 wrapper**，而是一个要放在材质**内部**的占位件。
///
/// ## 用法
/// 作为页面头部材质（`AylaGlassSurface` / `Container(decoration:)`）的**第一个 child**：
/// ```dart
/// AylaGlassSurface(
///   child: Column(children: [
///     const AylaTopInsetGap(),   // ← 状态栏高度，玻璃会铺到它下面
///     SizedBox(height: 56, child: 头部内容),
///   ]),
/// )
/// ```
/// 若头部没有材质（纯 Row），则把首个子件换成
/// `SizedBox(height: aylaTopInset(context))` 并在外层套一层玻璃底。
library;

import 'package:flutter/material.dart';

/// 当前顶部安全区高度（状态栏 / 刘海 / 灵动岛）。
///
/// ⚠️ 一律用 `viewPadding` 而不是 `padding`：后者是 `viewPadding` 与 `viewInsets`（键盘）
/// 的合成值 —— 用它会让头部因弹键盘而跳动。
/// `viewPadding` 只反映「系统 UI 占用的不可绘制区域」，正是我们要让的那部分。
double aylaTopInset(BuildContext context) =>
    MediaQuery.viewPaddingOf(context).top;

/// 放进头部材质**内部**的状态栏占位（高度 = [aylaTopInset]）。
///
/// 高度为 0 时不产出任何 widget（宽屏 / 无状态栏设备零开销）。
/// 见库文档：必须放在材质内部，否则状态栏区会露出页面底色形成色带。
class AylaTopInsetGap extends StatelessWidget {
  const AylaTopInsetGap({super.key});

  @override
  Widget build(BuildContext context) {
    final double top = aylaTopInset(context);
    if (top <= 0) return const SizedBox.shrink();
    return SizedBox(height: top);
  }
}

/// 给「没有自带材质的头部」用的便捷包装：
/// 用 [color] 铺一层底，再在其**内部**顶部加状态栏占位 ⇒ 与旁边的玻璃块连成一片。
///
/// `color` 传头部材质的底色（如 `AylaColors.glassBg`），不要传透明。
class AylaTopInsetSurface extends StatelessWidget {
  const AylaTopInsetSurface({
    super.key,
    required this.color,
    required this.child,
  });

  /// 底色（应与相邻头部材质一致，如 `AylaColors.glassBg`）。
  final Color color;

  /// 头部内容。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final double top = aylaTopInset(context);
    return ColoredBox(
      color: color,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (top > 0) SizedBox(height: top),
          child,
        ],
      ),
    );
  }
}
