/// 浮层（`OverlayEntry`）文本作用域 —— 组件库**统一入口**。
///
/// ## 为什么必须逐 entry 兜底（2026-09-20 用户实测：「release 版弹窗出现莫名其妙的黄线」）
///
/// `Overlay` 的每个 entry 都是**独立子树**，其祖先链只到 `Overlay` 为止：页面里的
/// `Material` / `DefaultTextStyle` **传不进 entry**（`theme/preview_theme.dart` 里记过同类坑 ——
/// `EditableText` 同样要求「Overlay ancestor within the closest LookupBoundary」）。
///
/// 缺兜底时，entry 内的 `Text` 会落到 `DefaultTextStyle.fallback`：
/// `decoration: underline` + `decorationColor: 红` + `decorationStyle: double`
/// —— 就是用户看到的「莫名其妙的黄线」。
///
/// 因此**所有** `OverlayEntry(builder: ...)` 都必须套一层 [aylaOverlayScope]；
/// 直接调用 [aylaOverlayEntry] 可自动完成（组件库内一律走后者）。
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 浮层统一入口：构造 `OverlayEntry` 时自动套 [aylaOverlayScope]。
OverlayEntry aylaOverlayEntry({
  required WidgetBuilder builder,
}) {
  return OverlayEntry(
    builder: (BuildContext ctx) =>
        aylaOverlayScope(context: ctx, child: builder(ctx)),
  );
}

/// 浮层文本作用域：用库内 `body` 样式兜底。
///
/// 各 `Text` 自己的 `style` 仍按 `TextStyle.merge` 语义覆盖对应字段（未指定的字段
/// 继承这里，而不是继承 fallback 的下划线）。
Widget aylaOverlayScope({required BuildContext context, required Widget child}) {
  return DefaultTextStyle(
    style: AylaTextStyles.of(context).body,
    child: child,
  );
}
