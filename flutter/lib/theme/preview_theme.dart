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
      // ⚠️ **必须显式提供 Localizations + MaterialLocalizations**：
      // `TextField` 构建时要求祖先存在 `MaterialLocalizations`，否则抛
      // "No MaterialLocalizations found. TextField widgets require
      //  MaterialLocalizations to be provided by a Localizations widget ancestor."
      // 预览宿主（widget_preview_scaffold）与 widget test 都不会自动提供，
      // 导致任何含输入框的组件（GlassInput / PrivacySheet /
      // VisibilitySelector / 登录页…）在预览与测试里全部崩溃。
      child: Localizations(
        // ⚠️ locale 必须是 `en`：`DefaultMaterialLocalizations.delegate`
        // 的 `isSupported` **只认英文**。若这里传 zh_CN，委托不会命中 →
        // Localizations.of<MaterialLocalizations> 返回 null → TextField 仍然
        // 抛 "No MaterialLocalizations found"（已实测踩过）。
        // 本组件的界面文案全部硬编码中文，不需要本地化资源，故用 en 即可。
        locale: const Locale('en'),
        delegates: const <LocalizationsDelegate<dynamic>>[
          DefaultMaterialLocalizations.delegate,
          DefaultWidgetsLocalizations.delegate,
        ],
        child: Material(
          type: MaterialType.transparency,
          // ⚠️ **必须提供 Overlay**：`EditableText`（TextField 内核）在获得焦点/
          // 选择文本时需要祖先 `Overlay` 承载选择工具栏与放大镜，否则抛
          // "No Overlay widget found. EditableText widgets require an Overlay
          //  widget ancestor within the closest LookupBoundary."
          // 预览宿主与 widget test 都不会自带 Overlay（只有 Navigator 会创建），
          // 故这里显式包一层。
          child: Overlay(
            initialEntries: <OverlayEntry>[
              OverlayEntry(
                builder: (BuildContext context) => AuroraBackground(
                  child: Center(child: child),
                ),
              ),
            ],
          ),
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
