/// 基元族的**分件转出**（barrel）。
///
/// 2026-09-25 整理：原单文件「多件混装」（1566 行）已按**一文件一件**拆成下列 6 件，
/// 本文件只做转出 —— 保证既有调用方的 import 不变；**新代码请直接 import 具体件**。
///
/// - `layout_switch.dart` — `AylaLayoutSwitch`
/// - `segmented_tabs.dart` — `AylaSegmentedTabs` / `AylaSegmentedTab` / `AylaSegmentedTabsVariant`
/// - `nav_highlight.dart` — `AylaNavHighlight`（共享胶囊）/ `AylaNavHighlightState` / `AylaNavHighlightVariant`
/// - `capsule_tag.dart` — `AylaCapsuleTag` / `AylaSourceTag` / `AylaCapsuleTone`
/// - `scrolling_text.dart` — `AylaScrollingText`
/// - `scrolling_tags.dart` — `AylaScrollingTags`
///
/// 原文件头（逐条 CSS 对照与轮次叙事）已整批归档到
/// `docs/flutter/17-组件文件头归档（整理前原文）.md`。
library;

export 'capsule_tag.dart';
export 'layout_switch.dart';
export 'nav_highlight.dart';
export 'scrolling_tags.dart';
export 'scrolling_text.dart';
export 'segmented_tabs.dart';
