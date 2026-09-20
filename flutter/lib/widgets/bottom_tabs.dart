/// 窄屏底部五 tab（web `layout/BottomTabs.tsx` 1–91 + `shell.css` 77–162）。
///
/// 事实源要点（逐条对应，禁自由发挥）：
/// - 容器 `.bottom-tabs`：高 64px + safe-area、`--glass-bg` + `blur(18px) saturate(1.4)`、
///   **顶部 1px `--glass-border`、无圆角**（用户口中的「窄屏方角底栏」）；
/// - 五等分，视觉顺序 = 语音 / 直播 / **主页（居中凸起）** / 帖子 / 桌游
///   （`BottomTabs.tsx:18` 的 `TAB_ORDER`，与 `shellConfig.ts` 的 `PRIMARY_MODULES` 同源）；
/// - 主页 tab：48px 圆盘（`--surface` + 1px `--glass-border` + `--card-shadow`）`margin-top: -8px`
///   上浮，选中换 `--glow-shadow`（主 CTA 级辉光，§12.1「≤3 处/屏」纪律）；
/// - 选中态：共享胶囊 `AuroraquaNavHighlight`（radius-input 12、**无扫光** —— 底栏项不在
///   `::after` 扫光列表里）+ 图标/文字颜色 150ms `--ease-out` 过渡；
/// - 未读：`.tab-badge` 相对图标 `top:-4 / right:-12`（复用组件库 [TabBadge]）；
/// - 项属 auroraqua 236–249「导航/选项卡组」→ `:active scale .98`、hover **不**放大。
library;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/buttons.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'primitives.dart' show AylaNavHighlight;
import 'tab_badge.dart';

/// 一级模块（web `shellConfig.ts` `PRIMARY_MODULES`）。
enum AylaPrimaryModule {
  home,
  voice,
  live,
  posts,
  games;

  /// 显示文案。
  String get label => switch (this) {
        AylaPrimaryModule.home => '主页',
        AylaPrimaryModule.voice => '语音',
        AylaPrimaryModule.live => '直播',
        AylaPrimaryModule.posts => '帖子',
        AylaPrimaryModule.games => '桌游',
      };

  /// 路由路径。
  String get path => switch (this) {
        AylaPrimaryModule.home => '/group',
        AylaPrimaryModule.voice => '/voice',
        AylaPrimaryModule.live => '/live',
        AylaPrimaryModule.posts => '/posts',
        AylaPrimaryModule.games => '/games',
      };

  /// 图标名（`icons.tsx`：Mic / Video / Home / Post / Game）。
  String get iconName => switch (this) {
        AylaPrimaryModule.home => 'iconHome',
        AylaPrimaryModule.voice => 'iconMic',
        AylaPrimaryModule.live => 'iconVideo',
        AylaPrimaryModule.posts => 'iconPost',
        AylaPrimaryModule.games => 'iconGame',
      };
}

/// 底栏视觉顺序（`BottomTabs.tsx:18`：主页居中）。
const List<AylaPrimaryModule> aylaBottomTabOrder = <AylaPrimaryModule>[
  AylaPrimaryModule.voice,
  AylaPrimaryModule.live,
  AylaPrimaryModule.home,
  AylaPrimaryModule.posts,
  AylaPrimaryModule.games,
];

/// 窄屏底部五 tab（展示型：路由跳转由外层处理，本件只报选中 key）。
class AylaBottomTabs extends StatelessWidget {
  const AylaBottomTabs({
    super.key,
    this.module,
    this.onSelect,
    this.badges = const <AylaPrimaryModule, int>{},
  });

  /// 当前一级模块（`resolveModule` 输出；null = 无选中）。
  final AylaPrimaryModule? module;

  /// 点击回调（路由由外层）。
  final ValueChanged<AylaPrimaryModule>? onSelect;

  /// 各 tab 未读数（F8 接线；F1 恒空）。
  final Map<AylaPrimaryModule, int> badges;

  /// 容器高度（`shell.css:78` `height: calc(64px + safe-area)`）。
  static const double barHeight = 64;

  /// 主页凸起圆盘直径与上浮量（`shell.css:139–150`）。
  static const double homeDiscSize = 48;
  static const double homeDiscOffset = 8;

  @override
  Widget build(BuildContext context) {
    final double safeBottom = MediaQuery.of(context).padding.bottom;
    final Widget list = SizedBox(
      height: barHeight, // `.bottom-tabs-list { height: 64px }`
      child: Row(
        children: <Widget>[
          for (final AylaPrimaryModule item in aylaBottomTabOrder)
            Expanded(child: _tab(context, item)),
        ],
      ),
    );
    final Widget bar = DecoratedBox(
      decoration: const BoxDecoration(
        color: AylaColors.glassBg, // background: var(--glass-bg)
        // border-top: 1px solid var(--glass-border)（**方角**：无 border-radius）
        border: Border(top: BorderSide(color: AylaColors.glassBorder)),
      ),
      child: list,
    );
    return Semantics(
      label: '主导航',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // backdrop-filter: blur(18px) saturate(1.4)（18 档 → 1.4，见 skill 分档表）
          if (GlassConfig.useOpaqueFallback)
            bar
          else
            Stack(
              children: <Widget>[
                Positioned.fill(
                  child: BackdropFilter(
                    filter: GlassConfig.backdropFilter(
                      sigma: AylaGlass.blurNav,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
                bar,
              ],
            ),
          if (safeBottom > 0)
            SizedBox(height: safeBottom, child: const ColoredBox(color: AylaColors.glassBg)),
        ],
      ),
    );
  }

  Widget _tab(BuildContext context, AylaPrimaryModule item) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool active = module == item;
    final bool isHome = item == AylaPrimaryModule.home;
    final int count = badges[item] ?? 0;
    final Color color =
        active ? AylaColors.textPrimary : AylaColors.textSecondary;
    const BorderRadius radius = BorderRadius.all(
      Radius.circular(AylaRadii.rInput), // `.has-auroraqua-highlight { radius-input }`
    );

    Widget iconBox = Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        AylaIcon(aylaIconByName(item.iconName)!, size: 24, color: color),
        if (count > 0 && !isHome)
          // `.tab-badge` 相对 `.bottom-tab-icon`（position: relative）定位
          TabBadge(count: count, max: 99),
      ],
    );
    if (isHome) {
      iconBox = Transform.translate(
        offset: const Offset(0, -homeDiscOffset), // margin-top: -8px（上浮，不占布局）
        child: Container(
          width: homeDiscSize,
          height: homeDiscSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AylaColors.surface,
            border: Border.all(color: AylaColors.glassBorder),
            // 不透明面层 → 外阴影不会被透出（同 TabBadge 的理由）
            boxShadow: active ? AylaShadows.glow : AylaShadows.card,
          ),
          child: Center(
            child: AylaIcon(
              aylaIconByName(item.iconName)!,
              size: 24,
              color: color,
            ),
          ),
        ),
      );
    }

    final Widget content = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        iconBox,
        AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 150), // transition: color 150ms --ease-out
          curve: AylaCurves.easeOut,
          style: t.microTag.copyWith(color: color), // Fredoka 11/500/ls .8
          child: Text(item.label),
        ),
      ],
    );

    return AylaPressScale(
      onTap: onSelect == null ? null : () => onSelect!(item),
      semanticLabel: item.label,
      // auroraqua 236–249「导航/选项卡组」：只有 :active scale .98
      hoverScale: false,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48), // 触达目标 ≥40px
        child: Stack(
          children: <Widget>[
            if (active)
              Positioned.fill(
                child: AylaNavHighlight(
                  radiusValue: radius,
                  showBorder: false, // 底栏项自身无 1px 边框（share 档同款判断）
                ),
              ),
            Center(child: content),
          ],
        ),
      ),
    );
  }
}

// ======================= 预览 =======================

/// 窄屏底栏（375 宽；含未读徽标与主页居中凸起）.
@Preview(
  group: 'Widgets',
  name: 'BottomTabs 窄屏（语音/直播/主页/帖子/桌游）',
  size: Size(375, 120),
  wrapper: previewTheme,
)
Widget aylaBottomTabsPreview() {
  return const AylaBottomTabs(
    module: AylaPrimaryModule.home,
    badges: <AylaPrimaryModule, int>{
      AylaPrimaryModule.posts: 3,
      AylaPrimaryModule.live: 128,
    },
  );
}
