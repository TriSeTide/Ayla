/// 主页页头 `.home-toolbar`（home.css 18–30）—— 群聊标题 + 布局开关。
///
/// ## 事实源
/// - `home.css:18–23` `.home-toolbar { display:flex; align-items:center;
///   justify-content:space-between; padding: var(--sp-3) var(--sp-4) }`；
/// - `home.css:25–30` `.home-title { font-family: var(--font-display); font-size:28px;
///   font-weight:600; color: var(--text-primary) }`；
/// - 调用点 `HomePage.tsx:163–166`（`h1.home-title` 文案「群聊」+ `<LayoutSwitch>`）。
///
/// ## 为什么提出成件
/// 19 号 §7.5 range B 的 B 类把 `home-toolbar`/`home-title` 登记为「库内无对应件」的
/// 页面内联件 ⇒ 按纪律**先补件进画布再装配**（画布节 = `AylaHomeToolbar`）。
/// 它是页面级页头，只有主页一个消费者，但样式有独立事实源，故仍按件交付。
///
/// ## 公开面
/// `AylaHomeToolbar`
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../base/layout_switch.dart' show AylaLayoutSwitch;

/// 画布样张（卡片档 / 列表档）。
List<Widget> aylaHomeToolbarSamples() => <Widget>[
      AylaHomeToolbar(isCard: true, onLayoutChanged: (_) {}),
      AylaHomeToolbar(isCard: false, onLayoutChanged: (_) {}),
    ];

/// `.home-toolbar`：左标题 + 右布局开关。
class AylaHomeToolbar extends StatelessWidget {
  const AylaHomeToolbar({
    super.key,
    required this.isCard,
    required this.onLayoutChanged,
    this.title = '群聊',
    this.semanticLabel = '主页布局',
  });

  /// 当前布局（true = 卡片档）。
  final bool isCard;

  /// 布局切换回调（true = 卡片档）。
  final ValueChanged<bool> onLayoutChanged;

  /// 标题文案（web tsx 164 逐字「群聊」）。
  final String title;

  /// 开关组语义标签（`LayoutSwitch.tsx:21` 的 `aria-label="主页布局"`）。
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // padding: var(--sp-3) var(--sp-4)
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp4,
        vertical: AylaSpacing.sp3,
      ),
      child: Row(
        // justify-content: space-between
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontFamily: AylaFonts.display,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 28, // .home-title
                fontWeight: FontWeight.w600,
                color: AylaColors.textPrimary,
              ),
            ),
          ),
          AylaLayoutSwitch(
            isCard: isCard,
            onChanged: onLayoutChanged,
            semanticLabel: semanticLabel,
          ),
        ],
      ),
    );
  }
}
