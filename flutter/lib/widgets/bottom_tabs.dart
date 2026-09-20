/// 窄屏底部五 tab —— 完整调用链（2026-09-20 逐条核对，含覆盖关系）：
///
/// 结构（`layout/BottomTabs.tsx` 1–91）：`nav.bottom-tabs > ul.bottom-tabs-list > li.bottom-tab
/// (+.bottom-tab-home) > a.bottom-tab-link.has-auroraqua-highlight[.is-active]`，内含
/// `AuroraquaNavHighlight`（仅 active，`layoutId` → **跨槽迁移**）、主页 `.bottom-tab-home-disc` /
/// 其它 `.bottom-tab-icon`、以及 `.bottom-tab-label`。
///
/// 样式链（按加载顺序；**后者覆盖前者**）：
/// | # | 出处 | 内容 |
/// |---|---|---|
/// | 1 | `shell.css:77–86` | 64+safe-area、`--glass-bg`、blur(18px) saturate(1.4)、border-top 1px、z50 |
/// | 2 | `shell.css:96–139` | 列表 64；tab flex1；link column/center/**gap 2**/min-h 48/color 150ms ease-out |
/// | 3 | `shell.css:141–158` | 圆盘 48 + **margin-top:-8** + pill + `--surface`+1px边+`--card-shadow`；选中 `--glow-shadow` |
/// | 4 | `auroraqua.css:238–249` | `.bottom-tab-link` 属导航组 → `:active scale .98`（hover 不放大） |
/// | 5 | `auroraqua.css:252/254`（顶层） | 圆角 `20 20 0 0` + `--glass-shadow`；link `margin 4px 2px` + `radius-input` |
/// | 6 | `shell.css:667`（`@media max-width:768px`） | 主页圆盘选中辉光**降档** `0 0 16px rgba(247,150,255,.32)` |
/// | 7 | **`auroraqua.css:412 块内 447–448`** | **`.bottom-tabs { border-radius: 0 }` → 最终是「方角」**（覆盖 #5） |
/// | 8 | `auroraqua.css:149–166/175–187/194–197` | 胶囊 inset0/z-1/radius inherit/`--nav-active-bg`/`--glass-shadow-nav`/1px 边；父 hover 扫光 700ms |
/// | 9 | `auroraqua.css:655–676` | reduced-motion：扫光关、scale 取消 |
///
/// 复用（组件库全量清点后无新增件）：容器 [GlassSurface]、选中 [AylaNavHighlight]、
/// 按压 [AylaPressScale]、图标 [AylaIcon]、token 取 [AylaColors]/[AylaRadii]/[AylaSpacing]/
/// [AylaDurations]/[AylaCurves]。
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

  /// 图标名（`icons.tsx`）。
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

/// 窄屏底部五 tab（展示型：路由跳转由外层处理）。
class AylaBottomTabs extends StatefulWidget {
  const AylaBottomTabs({super.key, this.module, this.onSelect});

  /// 当前一级模块（null = 无选中，胶囊不渲染）。
  final AylaPrimaryModule? module;

  /// 点击回调。
  final ValueChanged<AylaPrimaryModule>? onSelect;

  /// 条高（`shell.css:78`）。
  static const double barHeight = 64;

  /// 按钮外边距（`auroraqua.css:254` `margin: 4px 2px`）——胶囊 `inset:0` 在按钮内，随之内缩。
  static const EdgeInsets tabMargin =
      EdgeInsets.symmetric(vertical: 4, horizontal: 2);

  /// 主页圆盘（`shell.css:141–158`）。
  static const double homeDiscSize = 48;
  static const double homeDiscOffset = 8;

  /// 主页圆盘选中辉光 —— **窄屏降档值**（`shell.css:667` 在 `@media (max-width:768px)` 内：
  /// `0 0 16px rgba(247,150,255,.32)`，§9「≤768px 辉光降 30%」）。
  /// 底栏本身只出现在窄屏 → 用降档值，不用全局 `--glow-shadow`。
  static const List<BoxShadow> homeDiscGlow = <BoxShadow>[
    BoxShadow(color: Color(0x52F796FF), blurRadius: 16),
  ];

  @override
  State<AylaBottomTabs> createState() => _AylaBottomTabsState();
}

class _AylaBottomTabsState extends State<AylaBottomTabs> {
  /// 指针所在槽位（-1 = 无）。web 是 `:hover` 谓词 → 记录索引、**build 时求值**。
  int _hoveredIndex = -1;

  @override
  Widget build(BuildContext context) {
    final double safeBottom = MediaQuery.of(context).padding.bottom;
    final int activeIndex = widget.module == null
        ? -1
        : aylaBottomTabOrder.indexOf(widget.module!);

    return Semantics(
      label: '主导航',
      child: GlassSurface(
        blur: AylaGlass.blurNav, // blur(18px) saturate(1.4)（shell.css:81）
        shadow: AylaShadows.glass, // auroraqua 252：`--glass-shadow`
        // auroraqua 447–448（@media max-width:768px）：`border-radius: 0` → **方角**
        radiusOverride: BorderRadius.zero,
        borderOverride:
            const Border(top: BorderSide(color: AylaColors.glassBorder)),
        padding: EdgeInsets.zero,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              height: AylaBottomTabs.barHeight,
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints c) {
                  final double slot =
                      c.maxWidth / aylaBottomTabOrder.length;
                  const EdgeInsets m = AylaBottomTabs.tabMargin;
                  const BorderRadius capsuleRadius = BorderRadius.all(
                    Radius.circular(AylaRadii.rInput), // auroraqua 254
                  );
                  return Stack(
                    children: <Widget>[
                      // 容器级共享胶囊：跨槽 300ms 迁移（web framer `layoutId` 语义）
                      if (activeIndex >= 0)
                        AnimatedPositioned(
                          duration: AylaDurations.auroraqua, // 0.3s
                          curve: AylaCurves.auroraquaEaseOut, // [0,0,.58,1]
                          left: activeIndex * slot + m.horizontal / 2,
                          top: m.top,
                          width: slot - m.horizontal,
                          height: AylaBottomTabs.barHeight - m.vertical,
                          child: AylaNavHighlight(
                            radiusValue: capsuleRadius,
                            showBorder: false, // link 自身无 1px 边
                            sweep: true,
                            sweepActive: _hoveredIndex == activeIndex,
                          ),
                        ),
                      Row(
                        children: <Widget>[
                          for (int i = 0;
                              i < aylaBottomTabOrder.length;
                              i++)
                            Expanded(
                              child: _tab(
                                aylaBottomTabOrder[i],
                                i,
                                active: i == activeIndex,
                              ),
                            ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
            // 安全区与条同属一个玻璃面（shell.css:79：padding-bottom 在容器内）
            if (safeBottom > 0) SizedBox(height: safeBottom),
          ],
        ),
      ),
    );
  }

  Widget _tab(AylaPrimaryModule item, int index, {required bool active}) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    const Color idle = AylaColors.textSecondary;
    const Color selected = AylaColors.textPrimary;
    final Widget icon = AylaIcon(
      aylaIconByName(item.iconName)!,
      size: 24,
      color: active ? selected : idle,
    );
    final bool isHome = item == AylaPrimaryModule.home;

    final Widget iconSlot = isHome
        // `margin-top: -8px` = **底边贴槽底、向上溢出 8**，布局占位 48→40
        // （用 topCenter 会往下溢压住文案；用 Transform.translate 则占满 48 撑破 56 槽）
        ? SizedBox(
            width: AylaBottomTabs.homeDiscSize,
            height: AylaBottomTabs.homeDiscSize -
                AylaBottomTabs.homeDiscOffset, // 40
            child: OverflowBox(
              alignment: Alignment.bottomCenter,
              maxWidth: AylaBottomTabs.homeDiscSize,
              maxHeight: AylaBottomTabs.homeDiscSize,
              child: Container(
                width: AylaBottomTabs.homeDiscSize,
                height: AylaBottomTabs.homeDiscSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AylaColors.surface, // --surface
                  border: Border.all(color: AylaColors.glassBorder),
                  // 选中 → 窄屏降档辉光；未选中 → --card-shadow
                  boxShadow: active
                      ? AylaBottomTabs.homeDiscGlow
                      : AylaShadows.card,
                ),
                child: Center(child: icon),
              ),
            ),
          )
        : icon;

    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredIndex = index),
      onExit: (_) => setState(() => _hoveredIndex = -1),
      child: Padding(
        padding: AylaBottomTabs.tabMargin,
        child: AylaPressScale(
          onTap: widget.onSelect == null
              ? null
              : () => widget.onSelect!(item),
          semanticLabel: item.label,
          hoverScale: false, // 导航组：只 :active scale .98
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: 2, // `.bottom-tab-link { gap: 2px }`（shell.css:118–131）
              children: <Widget>[
                iconSlot,
                // color 150ms --ease-out（图标与文字同步过渡）
                TweenAnimationBuilder<double>(
                  duration: const Duration(milliseconds: 150),
                  curve: AylaCurves.easeOut,
                  tween: Tween<double>(
                    begin: active ? 0 : 1,
                    end: active ? 1 : 0,
                  ),
                  builder: (
                    BuildContext context,
                    double v,
                    Widget? child,
                  ) =>
                      DefaultTextStyle(
                    style: t.microTag.copyWith(
                      color: Color.lerp(idle, selected, v),
                    ),
                    child: child!,
                  ),
                  child: Text(item.label),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ======================= 画布样张（可交互） =======================

/// 画布/预览用**可交互**样张：点任一 tab 切换选中，观察共享胶囊跨槽迁移（300ms）。
///
/// 组件本身是**受控**的（`module` + `onSelect`，与 web 的路由驱动一致）：样张若不传
/// `onSelect`，`AylaPressScale` 处于 disabled，点击自然无响应（2026-09-20 用户实测）。
Widget aylaBottomTabsSamples() => const _BottomTabsDemo();

class _BottomTabsDemo extends StatefulWidget {
  const _BottomTabsDemo();

  @override
  State<_BottomTabsDemo> createState() => _BottomTabsDemoState();
}

class _BottomTabsDemoState extends State<_BottomTabsDemo> {
  AylaPrimaryModule _module = AylaPrimaryModule.home;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 375, // 窄屏口径（底栏只出现在窄屏）
      child: AylaBottomTabs(
        module: _module,
        onSelect: (AylaPrimaryModule next) => setState(() => _module = next),
      ),
    );
  }
}

// ======================= 预览 =======================

/// 窄屏底栏（375 宽，选中主页；F1 阶段不渲染红点；**方角**）。
@Preview(
  group: 'Widgets',
  name: 'BottomTabs 窄屏（方角玻璃条 + 主页居中凸起）',
  size: Size(375, 120),
  wrapper: previewTheme,
)
Widget aylaBottomTabsPreview() {
  // 可交互：点 tab 看胶囊跨槽迁移
  return aylaBottomTabsSamples();
}

/// 未选中（胶囊不渲染）与「帖子」选中对照 —— 看胶囊位置/尺寸与迁移起点。
@Preview(
  group: 'Widgets',
  name: 'BottomTabs 窄屏（未选中 / 帖子选中）',
  size: Size(375, 260),
  wrapper: previewTheme,
)
Widget aylaBottomTabsStatesPreview() {
  return const Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      AylaBottomTabs(),
      SizedBox(height: AylaSpacing.sp4),
      AylaBottomTabs(module: AylaPrimaryModule.posts),
    ],
  );
}
