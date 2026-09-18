/// Widget Preview 包装器（Ayla 组件库预览三件套，缺一崩/缺背景）。
///
/// 实测约束（2026-09-18）：
/// - 预览宿主 Theme **没有 AylaTextStyles 扩展** → 页面强解包崩
///   "Unexpected null value" → 必须包 [previewTheme]；
/// - 宿主**不渲染根部极光背景** → 不包就没有 Ayla 语境 → 必须包
///   [previewTheme]（内含 [AuroraBackground]）；
/// - Consumer 页面还要再包 [previewScope]（宿主无 Provider 容器）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_theme.dart';
import 'aurora_background.dart';

/// 预览 wrapper：主题 + 极光背景。
///
/// 公开命名（@Preview 参数必须是字面量或公共符号，私有名会报
/// `invalid_widget_preview_private_argument`，实测）。
Widget previewTheme(Widget child) {
  return Theme(
    data: buildAylaTheme(),
    child: Directionality(
      // 预览宿主可能没有 MaterialApp → 缺 Directionality(Material 的
      // Stack/alignment 断言)与 Material 祖先(TextField 断言)会直接崩溃
      textDirection: TextDirection.ltr,
      child: Material(
        type: MaterialType.transparency,
        child: AuroraBackground(
          child: Center(child: child),
        ),
      ),
    ),
  );
}

/// 预览 wrapper：Provider 容器 + 主题 + 极光背景（Consumer 页面用）。
Widget previewScope(Widget child) {
  return ProviderScope(
    child: previewTheme(child),
  );
}
