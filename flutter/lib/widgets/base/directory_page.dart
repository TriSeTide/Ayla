/// 目录页族 A 类跨页复用件 —— `.directory-page` 三件套 + 侧栏标题 / 装饰图标 / 返回键。
///
/// 六个目录页共用（SearchPage / FavoritesPage / VoiceHubPage / LiveHubPage /
/// PostsHubPage / GamesHubPage）—— 事实源 CSS 首行的 `:is()` 列表即它们：
/// `directory-filters.css:2`。
///
/// ## 事实源（逐条对应 web 源码，无自由发挥）
///
/// | web | 行 | 本件 |
/// |---|---|---|
/// | `.directory-page:is(.search-page, .favorites-page, .voice-hub, .live-hub, .posts-hub, .games-hub)` | 2–10 | [AylaDirectoryPage]（根：height 100% / flex column / overflow hidden / padding sp3 sp3 0） |
/// | `.directory-page > .directory-body` | 12–20 | [AylaDirectoryPage] body（flex 1 1 0 / row / gap sp3 / min-height 0） |
/// | `.directory-page .directory-content` | 145–156 | [AylaDirectoryContent]（flex 1 1 0 / 纵向独立滚动 / padding sp2 sp2 sp6） |
/// | `keyframes directory-content-in` | 158–167 | [AylaDirectoryContent] 的 [AylaRevealItem]（opacity 0→1 + translateY 12→0 / 300ms） |
/// | ≥769 负 margin 绘制带 | 189–208 | [AylaDirectoryContent] 外层 _DirectoryContentBleed（绘制带外扩 12 / padding 补偿） |
/// | ≤768 档 | 219–247 | 窄屏 padding 0 / column 单列 / content padding sp2 sp4 (68+safe) |
/// | `.directory-filter-header` / `-kicker` / `-title` / `-stats` | 62–96 | [AylaDirectorySidebarHeader]（窄屏 display:none，241–242） |
/// | `.directory-filter-decor`（+ 相邻规则） | 46–59 / 98–100 / 241 | [AylaDirectoryDecorIcon]（窄屏 display:none） |
/// | `.directory-filter-back` = `.icon-btn-40` | FavoritesPage.tsx:309 / SearchPage.tsx:352 | [AylaDirectoryBackButton]（复用 [AylaIconButton]） |
///
/// TSX 装配：`DirectoryFilters.tsx:6–85`（槽位顺序 leading → decor → header → nav）；
/// 内容区 `role="tabpanel" + aria-labelledby + tabIndex=0`（GamesHubPage.tsx:181–183、
/// SearchPage.tsx:359–361、PostsHubPage.tsx:314–316、VoiceHubPage.tsx:285–287、
/// LiveHubPage.tsx:140–142；FavoritesPage.tsx 的 wrapResults 同构）。
///
/// ## 与 web 的机制差异（必读）
/// 1. **负 margin 绘制带**：CSS `margin: -sp3 -sp3 0` + `padding: sp3 (sp2+sp3) sp6`
///    让滚动裁剪盒向左右上各外扩 12px、内容位置不变。Flutter 的 `Padding` 不接受负值
///    ⇒ 用 `OverflowBox`（盒尺寸外扩）+ `Transform.translate(-12,-12)`（视觉回原位）表达。
///    ⚠️ `RenderBox.hitTest` 有 `size.contains(position)` 前置判断 ⇒ **溢出到槽位之外的
///    12px 绘制带不参与命中**（web 的盒真实外扩、可命中）。功能影响：页面 padding 空白处
///    （左右各 12px）不能起拖/滚轮，内容区内部的滚动与点击不受影响。
/// 2. **`scrollbar-gutter: stable`** 在 Flutter 无等价（滚动条为 overlay 且默认不预留槽位）
///    ⇒ 未表达；若页面层需要固定槽位，自行预留宽度。
/// 3. **`user-select: none`** 在 Flutter 无等价（文本默认不可选）⇒ 未表达。
/// 4. **`overscroll-behavior-y: contain`**：Flutter 的内层 `Scrollable` 到达边界后
///    本来就不会驱动外层滚动（与 CSS 同义）⇒ 未显式表达。
/// 5. **`min-height: 0` / `min-width: 0`**（3–5 / 16–17）：CSS flex 项的收缩下限修正；
///    Flutter 的 flex 项默认即可收缩到 0 ⇒ 无需表达。
/// 6. **窄屏顶栏的左右横滑**（`overflow-x: auto` / `touch-action: pan-x pinch-zoom`）
///    归 [AylaDirectoryFilters]（本件只负责 page/body/content 三件套）。
///
/// ## 公开面
/// `AylaDirectoryPage` · `AylaDirectoryContent` · `AylaDirectorySidebarHeader` ·
/// `AylaDirectoryDecorIcon` · `AylaDirectoryBackButton` ·
/// `aylaDirectoryIsNarrow` · `aylaDirectoryIsWide` · `aylaDirectoryListPaddingTop`
library;

import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../../theme/buttons.dart';
import '../../theme/tokens.dart';
import 'reveal.dart';

/// 目录页窄屏判定（CSS `max-width: 768px`，即 ≤768 走窄屏档）。
bool aylaDirectoryIsNarrow(BuildContext context) =>
    MediaQuery.sizeOf(context).width <= AylaBreakpoints.sm;

/// 目录页宽屏判定（≥769；CSS `min-width: 769px`）。
bool aylaDirectoryIsWide(BuildContext context) =>
    !aylaDirectoryIsNarrow(context);

/// ≥769 时列表容器的 `padding-top` 归零（web 组规则 `directory-filters.css:204–208`）。
///
/// Flutter 无「后代选择器」⇒ 该规则由**调用方**在列表容器上表达：宽屏返回 `0`，
/// 窄屏返回 `null`（表示「保持你自己的默认值」，如 `AylaGamesGrid` / `AylaMasonryGrid`
/// 的默认 `padding` 顶部 sp3）。用法：
/// `padding: EdgeInsets.fromLTRB(sp4, aylaDirectoryListPaddingTop(context) ?? sp3, sp4, sp3)`
double? aylaDirectoryListPaddingTop(BuildContext context) =>
    aylaDirectoryIsWide(context) ? 0 : null;

/// 目录页三件套的根 —— `.directory-page` + `.directory-body`。
///
/// - 根（`.directory-page`，2–10）：`height: 100%` / `min-height: 0` /
///   `min-width: 0` / `flex-direction: column` / `overflow: hidden` /
///   `padding: sp3 sp3 0`；窄屏（220）：`padding: 0`。
/// - body（`.directory-page > .directory-body`，12–20）：`flex: 1 1 0`（根里唯一子项 ⇒
///   [Expanded]）/ `gap: sp3` / `min-height: 0`，**两列方向 = row**（侧栏 + 内容区）；
///   窄屏（221）：`flex-direction: column` + `gap: 0`（顶栏 + 内容区单列）。
///
/// ⚠️ `height: 100%` 要求父级给出**有界高度**（页面层由 AppShell 的固定高度内容区提供）；
/// 与 web 相同，放进无界高度父级不是本件支持的用法。
///
/// `overflow: hidden` 在 Flutter 侧的等价是「子级不得溢出」：内容区的滚动与
/// 阴影绘制带外扩都在本件的裁剪边界内完成（见 [AylaDirectoryContent]）。
class AylaDirectoryPage extends StatelessWidget {
  const AylaDirectoryPage({
    super.key,
    required this.filters,
    required this.content,
  });

  /// 侧栏（宽屏固定 224；窄屏变横向顶栏）—— 传入 AylaDirectoryFilters 本体。
  final Widget filters;

  /// 内容区 —— 传入 [AylaDirectoryContent]。窄屏/宽屏档切换由本件按
  /// `MediaQuery` 自行判定，调用方无需重复判断。
  final Widget content;

  @override
  Widget build(BuildContext context) {
    final bool narrow = aylaDirectoryIsNarrow(context);

    // `.directory-page > .directory-body`：flex 1 1 0 + gap sp3（≤768 变 column + gap 0）
    final Widget body = narrow
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[filters, Expanded(child: content)],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: AylaSpacing.sp3, // gap: var(--sp-3)
            children: <Widget>[
              filters,
              // ≥769：内容区带「阴影绘制带」外扩（199–208）
              Expanded(child: _DirectoryContentBleed(child: content)),
            ],
          );

    return Padding(
      // `.directory-page { padding: var(--sp-3) var(--sp-3) 0 }`（9）；窄屏 0（220）
      padding: narrow
          ? EdgeInsets.zero
          : const EdgeInsets.only(
              top: AylaSpacing.sp3,
              left: AylaSpacing.sp3,
              right: AylaSpacing.sp3,
            ),
      child: Column(
        mainAxisSize: MainAxisSize.max, // height: 100%（父级有界）
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[Expanded(child: body)],
      ),
    );
  }
}

/// 内容区（`.directory-page .directory-content`）—— **独立滚动** + 切分类入场 + tabpanel 语义。
///
/// - 盒（145–156）：`flex: 1 1 0`（由 [AylaDirectoryPage] 的 [Expanded] 承担）/
///   `overflow-y: auto` / `overflow-x: hidden` / `overscroll-behavior-y: contain` /
///   `scrollbar-gutter: stable` / `padding: sp2 sp2 sp6`。
/// - ≥769（199–203）：外层外扩 12（绘制带）+ 内部
///   `padding: sp3 (sp2+sp3) sp6`。
/// - ≤768（244–246）：`padding: sp2 sp4 (68px + env(safe-area-inset-bottom))`。
/// - 入场（154–167）：`animation: directory-content-in 300ms var(--auroraqua-ease)`
///   —— `opacity 0 + translateY(12px)` → `1 / none`；切换分类时 web 以
///   `key={scope}` **重挂载**该元素 ⇒ 动画重播一次。Flutter 同构写法：
///   传 [scope]（变化 ⇒ 内部 `KeyedSubtree` 换 key ⇒ 重建 ⇒ [AylaRevealItem] 重播）；
///   曲线用 [AylaCurves.auroraqua]（CSS `--auroraqua-ease: ease`，**不是** `ease-out`）。
/// - reduced-motion（249–254）：`animation: none` ⇒ [AylaRevealItem] 在
///   `MediaQuery.disableAnimations` 下直接返回子件（无动画、无位移）。
/// - 语义：`role="tabpanel"` + `aria-labelledby="{id}-{filter}"` + `tabIndex=0`
///   ⇒ [Semantics] 的 `role: SemanticsRole.tabPanel`（Flutter 无 id 引用 ⇒
///   [label] 传选中分类文案作近似）+ [Focus]（可 Tab 聚焦）。
class AylaDirectoryContent extends StatelessWidget {
  const AylaDirectoryContent({
    super.key,
    required this.child,
    this.controller,
    this.scope,
    this.label,
    this.fadeGlass = true,
  });

  /// 列表/状态内容。
  final Widget child;

  /// 滚动控制器（页面层需要 `onScroll` 分页时持有）。
  final ScrollController? controller;

  /// 当前分类作用域（web `key={scope}`）：值变化 → 内容区重挂载 → 入场动画重播。
  /// `null` = 不挂 key（内容常驻、不重播）。
  final Object? scope;

  /// tabpanel 的可访问名（web `aria-labelledby` 指向选中 tab 的文案）。
  final String? label;

  /// 内容区是否含玻璃（`BackdropFilter`）—— 透传给 [AylaRevealItem.fadeGlass]。
  ///
  /// 目录内容区在 web 上就是**卡片列表**（收藏 / 语音 / 直播 / 帖子 / 游戏 / 搜索
  /// 六页都渲染 `AylaGlassSurface` 卡）⇒ 六个调用点一律显式传 `false`；
  /// 默认 `true` 只为与本件改造前的行为一致（见 [AylaRevealItem.fadeGlass] 的说明）。
  final bool fadeGlass;

  @override
  Widget build(BuildContext context) {
    final bool narrow = aylaDirectoryIsNarrow(context);
    // ≤768：padding-bottom = 68px + env(safe-area-inset-bottom)
    final double safeBottom = MediaQuery.viewPaddingOf(context).bottom;

    Widget viewport = SingleChildScrollView(
      controller: controller,
      // overflow-x: hidden（纵向 ScrollView 的横轴本就不可滚）；overscroll 不驱动外层
      padding: narrow
          ? EdgeInsets.fromLTRB(
              AylaSpacing.sp4,
              AylaSpacing.sp2,
              AylaSpacing.sp4,
              68 + safeBottom,
            )
          : const EdgeInsets.fromLTRB(
              AylaSpacing.sp2 + AylaSpacing.sp3,
              AylaSpacing.sp3,
              AylaSpacing.sp2 + AylaSpacing.sp3,
              AylaSpacing.sp6,
            ),
      child: child,
    );

    // `animation: directory-content-in 300ms var(--auroraqua-ease)`（155 / 158–167）
    viewport = AylaRevealItem(
      fadeGlass: fadeGlass, // 内容区是卡片列表（含玻璃）⇒ 调用点传 false
      offset: const Offset(0, 12), // translateY(12px)
      duration: AylaDurations.auroraqua, // 300ms
      curve: AylaCurves.auroraqua, // --auroraqua-ease = ease
      child: viewport,
    );

    Widget content = Semantics(
      role: SemanticsRole.tabPanel, // role="tabpanel"
      label: label, // aria-labelledby 的近似（Flutter 无 id 引用）
      container: true,
      child: Focus(
        // tabIndex = 0（进入 Tab 序列）
        child: viewport,
      ),
    );

    if (scope != null) {
      // web key={scope} ⇒ 重挂载
      content = KeyedSubtree(key: ValueKey<Object>(scope!), child: content);
    }
    return content;
  }
}

/// ≥769 的内容区「阴影绘制带」—— CSS `margin: -sp3 -sp3 0`（201）+ padding 补偿（202）。
///
/// 卡片阴影（`--glass-shadow` 模糊 32px）在滚动容器 padding box 内完整绘制、
/// 不被 `overflow` 裁剪（注释 194–198）；padding 补偿后卡片位置与宽度不变。
///
/// ⚠️ 命中差异见文件头「机制差异 1」。
class _DirectoryContentBleed extends StatelessWidget {
  const _DirectoryContentBleed({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final bool bounded = c.maxHeight.isFinite;
        return OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: c.maxWidth + AylaSpacing.sp3 * 2,
          maxWidth: c.maxWidth + AylaSpacing.sp3 * 2,
          minHeight: bounded ? c.maxHeight + AylaSpacing.sp3 : null,
          maxHeight: bounded ? c.maxHeight + AylaSpacing.sp3 : null,
          child: Transform.translate(
            // 视觉回到槽位原位（负 margin 与 padding 补偿的净效果）
            offset: const Offset(-AylaSpacing.sp3, -AylaSpacing.sp3),
            child: child,
          ),
        );
      },
    );
  }
}

/// 目录侧栏标题区（`.directory-filter-header` + kicker / title / stats）。
///
/// 事实源 `directory-filters.css:62–96`：
/// - header（62–71）：`flex: none` / column / `gap: 2px` / `align-items: center` /
///   `margin: sp1 0 sp2` / `text-align: center` / `user-select: none`；
/// - kicker（73–81）：Display **10** / **w600** / `letter-spacing: .14em`（= 1.4px）/
///   `--pink-500` / **opacity .75** / `text-transform: uppercase`；
/// - title（83–89）：Display **17** / **w700** / `--text-primary` / `line-height: 1.25`；
/// - stats（91–96）：Utility **12** / `--text-secondary` / `margin-top: 2px`
///   （叠加容器 `gap: 2px` ⇒ 实际间距 4）。
///
/// **窄屏 display:none**（241–242）：[AylaDirectoryFilters] 的 `header` 槽位在窄屏
/// **本就不渲染**（`profile_and_filters.dart` 的宽屏分支才渲染）⇒ 本件无需自带
/// 窄屏隐藏逻辑。
///
/// 六处调用（kicker / title / stats 逐字）：
/// Search `全局搜索` · Favorites `我的收藏` · Voice `语音房间` · Live `直播间` ·
/// Posts `帖子` · Games `桌游室`（各页 TSX：SearchPage.tsx:354–358、
/// FavoritesPage.tsx:311–315、VoiceHubPage.tsx:276–284、LiveHubPage.tsx:135–139、
/// PostsHubPage.tsx:309–313、GamesHubPage.tsx:176–180）。
class AylaDirectorySidebarHeader extends StatelessWidget {
  const AylaDirectorySidebarHeader({
    super.key,
    required this.kicker,
    required this.title,
    this.stats,
  });

  /// 上标（web 原文如 `Voice`；CSS `text-transform: uppercase` ⇒ 渲染为 `VOICE`）。
  final String kicker;

  /// 标题（web 原文如 `语音房间`）。
  final String title;

  /// 统计行（web 原文如 `12 房间在线 · 3 人在聊`；null = 不渲染）。
  final String? stats;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // margin: var(--sp-1) 0 var(--sp-2)（68）
      padding: const EdgeInsets.only(
        top: AylaSpacing.sp1,
        bottom: AylaSpacing.sp2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center, // align-items: center
        spacing: 2, // gap: 2px（66）
        children: <Widget>[
          // .directory-filter-kicker：color + opacity 两段与 CSS 一一对应
          Opacity(
            opacity: 0.75, // opacity: 0.75（79）
            child: Text(
              kicker.toUpperCase(), // text-transform: uppercase（80）
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: AylaFonts.display,
                // ⚠️ 必须带 CJK 回退链（全局约定 app_theme.dart:4）：Fredoka 无中文字形，
                // 缺 fallback 时中文会落到引擎默认字体（2026-09-28 用户实报）。
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.4, // 0.14em × 10px
                color: AylaColors.pink500,
              ),
            ),
          ),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: AylaFonts.display,
              fontFamilyFallback: AylaFonts.cjkFallback, // 「语音房间」等中文标题的字体
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: AylaColors.textPrimary,
              height: 1.25,
            ),
          ),
          if (stats != null)
            Padding(
              padding: const EdgeInsets.only(top: 2), // margin-top: 2px（95）
              child: Text(
                stats!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: AylaFonts.utility,
                  fontFamilyFallback: AylaFonts.cjkFallback, // 「41 直播间 · 12 在播」
                  fontSize: 12,
                  color: AylaColors.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 目录侧栏装饰图标（`.directory-filter-decor`，纯装饰、非交互）。
///
/// 事实源 `directory-filters.css:50–59`：
/// `flex: none` / `align-self: center` / `margin: 6px auto 2px` /
/// `color: --pink-500` / `opacity: .42` / `transform: rotate(-8deg)` /
/// `pointer-events: none` / `user-select: none`。
///
/// 相邻兄弟规则（本件以参数表达）：
/// - `.directory-filter-back + .directory-filter-decor { margin-top: 2px }`（46–48）
///   ⇒ 紧随返回键时传 [marginTop] = 2；
/// - `.directory-filter-decor + .directory-filter { margin-top: var(--sp-1) }`（98–100）
///   ——⚠️ **残留（2026-09-28 独立审计登记，未修）**：该规则在**窄屏**才生效
///   （宽屏 decor 与选项卡之间夹着 header，选择器不匹配）。web 窄屏下 decor 仍进 DOM
///   （只是 `display:none`，CSS 相邻兄弟选择器**照常匹配**）⇒ 首个选项卡带 4px 上外边距
///   （标签条高 +4、首 tab 下移 2px）。Flutter 侧 AylaDirectoryFilters 窄屏不渲染 decor
///   槽位 ⇒ 该 4px 无人表达。修它要动 AylaNavHighlightList 的槽位测量（胶囊会连带变高），
///   属跨组件改动 ⇒ 按纪律登记待用户裁决，不在本轮擅动。
///   ⇒ 该 4px 加在**选项卡**上（不在本件），由 filters 容器/调用方表达。
///
/// **窄屏 display:none**（241）：[AylaDirectoryFilters] 的 `decor` 槽位在窄屏不渲染。
///
/// 六处调用（`width={64} height={64}`，逐处不同图标）：
/// 1. `SearchPage.tsx:353` → `iconSearch`
/// 2. `FavoritesPage.tsx:310` → `iconHeart`
/// 3. `VoiceHubPage.tsx:275` → `iconMic`
/// 4. `LiveHubPage.tsx:134` → `iconVideo`
/// 5. `PostsHubPage.tsx:308` → `iconPost`
/// 6. `GamesHubPage.tsx:175` → `iconGame`
class AylaDirectoryDecorIcon extends StatelessWidget {
  const AylaDirectoryDecorIcon({
    super.key,
    required this.icon,
    this.size = 64,
    this.color = AylaColors.pink500,
    this.marginTop = 6,
    this.marginBottom = 2,
  });

  /// 图标数据（六个调用点各传不同图标，size 恒 64）。
  final AylaIconData icon;

  /// 边长（六处调用点均为 64）。
  final double size;

  /// 颜色（六处调用点均为 `--pink-500`）。
  final Color color;

  /// 上外边距（默认 6；紧随 `.directory-filter-back` 时传 2）。
  final double marginTop;

  /// 下外边距（恒 2）。
  final double marginBottom;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      // pointer-events: none（57）
      child: ExcludeSemantics(
        // web 六处均 role="presentation" aria-hidden="true"
        child: Padding(
          padding: EdgeInsets.only(top: marginTop, bottom: marginBottom),
          child: Align(
            // align-self: center（52）
            alignment: Alignment.center,
            child: Opacity(
              opacity: 0.42, // opacity: 0.42（55）
              child: Transform.rotate(
                angle: -8 * math.pi / 180, // transform: rotate(-8deg)（56）
                child: AylaIcon(icon, size: size, color: color),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 目录侧栏返回键（`.directory-filter-back`）—— `.icon-btn-40` + `IconBack 20` + aria-label。
///
/// 事实源：`FavoritesPage.tsx:309` / `SearchPage.tsx:352`
/// （`button.icon-btn-40.directory-filter-back` + `aria-label="返回"` + `IconBack 20`，
/// 逐字同构）。
///
/// 材质与交互由 [AylaIconButton] 承担（`.icon-btn-40`：40×40 / pill 在
/// `home.css:121–129`；`--glass-bg` + 1px `--glass-border` +
/// `--glass-shadow-button` + `blur(8px)` 在 `auroraqua.css:125–132` 的
/// `:is(.icon-btn-40, …)` 组；**不是** `auroraqua.css:119–122` —— 那条是
/// `.narrow-topbar-more > .icon-btn-40` 的 radius-input 覆写，不匹配本件；
/// 本件不重复实现）。两个真实调用点**都不传 sweep**
/// （扫光组只含 `.top-nav-more > .top-nav-icon-btn` 与
/// `.narrow-topbar-more > .icon-btn-40`）。
///
/// **窄屏**：web 由 AppShell 顶栏接管（`DirectoryFilters.tsx:18–19` 的 `leading` 槽位
/// 在窄屏不渲染），[AylaDirectoryFilters] 已按此实现。
///
/// ## 为什么它是目录页族的第 9 件
/// `Ayla/docs/flutter/19-页面内视觉件审查.md:505` 的 A 类行点名的件数是 **8**
/// （AylaDirectoryPage / AylaDirectorySidebarHeader / AylaDirectoryDecorIcon /
/// AylaPageState / AylaGroupSceneHead / AylaGroupScenePlaceholder /
/// AylaGroupChatSubgroupBar / AylaGroupPostsComposer），但同格「条数」列写 **9**
/// ⇒ 少一件。判据：`.directory-filter-back` 在 web 有 **2 处真实调用点**
/// （FavoritesPage.tsx:309、SearchPage.tsx:352），且与同族的 decor / header 同属
/// `DirectoryFilters` 的槽位装配（`DirectoryFilters.tsx:70` 的 `{!narrow && leading}`）
/// —— 即「目录页族第 9 件」。
class AylaDirectoryBackButton extends StatelessWidget {
  const AylaDirectoryBackButton({
    super.key,
    this.onPressed,
    this.size = 40,
    this.iconSize = 20,
    this.semanticLabel = '返回',
  });

  /// 点击（web 两处均为 `navigate(-1)`）。
  final VoidCallback? onPressed;

  /// 按钮边长（`.icon-btn-40` 恒 40）。
  final double size;

  /// 图标边长（`IconBack width/height 20`）。
  final double iconSize;

  /// 可访问性标签（`aria-label="返回"`，两处逐字相同）。
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    // 侧栏 Column 是 stretch（.directory-filters 无 align-items 声明）：
    // web 靠按钮固定 width:40 保持 40×40 靠左 ⇒ Flutter 侧用 Align 抵消拉伸。
    return Align(
      alignment: Alignment.centerLeft,
      child: AylaIconButton(
        icon: AylaIcon(aylaIconByName('iconBack')!, size: iconSize),
        size: size,
        semanticLabel: semanticLabel,
        onPressed: onPressed,
      ),
    );
  }
}
