/// 响应式顶部导航 —— 宽屏 `TopNav` 与窄屏 `NarrowTopBar` **两形态同一组件**，按宽度切换
/// （web `AppShell.tsx:105–109`：`isNarrow ? <NarrowTopBar/> : <TopNav/>`，判据 `NARROW_QUERY` = `max-width: 768px`）。
///
/// ## 事实源（逐条核对；含「后加载文件覆盖」关系）
///
/// ### 宽屏（`layout/TopNav.tsx` 1–343 + `shell.css` 162–400 + `auroraqua.css` 全部命中 + `search.css` 365–486）
/// - `.top-nav` 基础（shell.css:162–178）：`height: 64px`、`gap: sp6`、`padding: 0 sp6`、
///   `--glass-bg` + `blur(18px) saturate(1.4)`、底部 1px 边、z 50；
/// - **被 `auroraqua.css:262–270` 顶层覆写为「浮动圆角卡」**：`margin: 12px 12px 0`
///   （`--sidebar-gutter` = 12px，tokens.css:132）、四周 1px `--glass-border`、`border-radius: --radius-card`（16）、
///   `box-shadow: --glass-shadow`、`backdrop-filter: --glass-filter`
///   ⇒ 配方与组件库 [GlassCard] 完全一致 → **直接复用 GlassCard**（仅把模糊档 24 → 导航 18）；
/// - `.top-nav-modules`：`gap: sp2`、`align-items: center`（auroraqua:256）；
/// - `.top-nav-module`（shell.css:193–237 + auroraqua:257–261）：`padding: 0 sp3`、15px/700、`min-height: 44px`、
///   `min-width: max-content`、`nowrap`、`radius-input`；hover → `rgba(157,191,230,.18)`；
///   选中底条 `::after`（left/right sp3、bottom 6、2px、`--glow-500`）**在带 `has-auroraqua-highlight` 时
///   `content: none`**（auroraqua:213–214）⇒ 本件模块项配共享胶囊 ⇒ **不画底条**；
/// - `.top-nav-module-icon`：16px、`margin-right: 6px`、`translate: 0 -2px`（字形视觉重心）；
/// - `.top-nav-logo`（shell.css:239–272）：**绝对居中**、display 22/600、`ls -0.3px`、
///   渐变字 `linear-gradient(120deg, --indigo-700, --grape-700)` + `background-clip: text`、
///   hover `brightness(1.12)`、**≤1240px 隐藏**（shell.css:268–272）；
/// - `.top-nav-right`：`margin-left: auto`、`gap: sp3`；
/// - `.top-nav-icon-btn`（shell.css:281–314 + auroraqua:120/125–133）：40×40、玻璃小卡
///   （`--glass-bg` + 1px 边 + `--glass-shadow-button` + `blur(8px)`），hover `--glass-shadow-button-hover` + `scale 1.02`、
///   active `scale .98`（200ms `--auroraqua-ease`）；消息钮 `radius-pill`，
///   **「更多」钮被 auroraqua:120 改成 `radius-input`**；消息选中 → 冰蓝底 + 底条（left/right 10、bottom 2、2px、`--glow-500`）；
/// - `.top-nav-search`（shell.css:316–349 + auroraqua:503–520）：240×40、`gap sp2`、`padding 0 sp3`、
///   归「文本字段族」：`--glass-bg` + 1px 边 + **`radius-input`**（覆盖 home.css 的 pill）+ `--glass-inset` + `--glass-filter`；
///   `focus-within` → `--glow-500` 边 + `--glow-shadow`；placeholder `--slate-500`；
/// - 搜索尾部按钮（search.css:413–441）：各 40×40 圆形、`--text-secondary`（submit `--indigo-700`）、hover 冰蓝 .18；
/// - **769–900px 收窄**（auroraqua:476–487）：`.top-nav { gap sp3; padding-inline sp3 }`、modules `gap sp1`、
///   module `padding-inline sp2`、right `gap sp2`、搜索框 `clamp(160px, 22vw, 200px)`；
/// - 浮层：`.top-nav-more-menu`（shell.css:354–391）与 `.top-nav-search-panel`（search.css:365–387）同为
///   `absolute; top: calc(100% + 8px); right: 0` + `radius-card` + `--glass-bg-strong` + 1px 边 + `--glass-shadow`；
///   菜单 `min-width 160` + `padding sp2` + z30 + `auroraqua-menu-in` 入场（home.css:150–153：
///   `opacity 0→1` / `translateY(-8→0)` / `scale(.95→1)`，300ms `--auroraqua-ease-out`）；
///   面板 `width 360` / `max-height 360` 可滚动 / `padding sp2` / `gap 2` / z40；菜单项高 40、14/600、hover 冰蓝 .18；
/// - 下拉分组（search.css:443–486）：组头 `padding sp2 sp3 sp1` + 11/500/ls .8/**大写**；行 `min-h 40`/`gap sp3`/
///   `radius-input`/14px；「查看更多」12/600 `--ice-500` pill；`count===0` 不渲染、`count>3` 才显示「查看更多」。
///
/// ### 窄屏（`layout/NarrowTopBar.tsx` 1–199 + `home.css` 34–180）
/// - `.narrow-topbar`：**高 56**、`padding 0 sp4`、`gap sp3`、sticky top 0、z50、底部 1px 边；
///   `max-width:768px` 内带入场 `auroraqua-panel-from-top`（auroraqua:414–424）；
/// - `default`：头像 **36**（`:182`）+ 搜索胶囊（IconSearch 16 + 文案「搜索」，`:189–192`）+ 更多钮；
/// - `search`：返回钮（20px 返回图标）+ 输入框（`padding 0 sp3`、placeholder「搜索用户、群、帖子…」、
///   **进态自动聚焦**、提交走 replace）+ 更多钮；
/// - `favorites`：返回钮 + `.narrow-topbar-title`（display 18/600 + 省略号）+ 更多钮；
/// - `.narrow-topbar-search`：`flex:1`、**`min-width: 0`**、高 40、`gap sp2`、`padding 0 sp4`；
/// - `.narrow-topbar-menu`：与 `.top-nav-more-menu` 同款（同一入场上浮动画）。
///
/// ## 复用（组件库清点后，**无新增基础件**）
/// [GlassCard]（宽屏条 = 浮动圆角卡）、[GlassSurface]（窄屏条 = 方角 + 单底边；搜索框 = 圆角输入）
/// [AvatarHalo]（40 / 36）、[AylaIconButton]（表面图标钮；`square: true` → `radius-input`）、
/// [TabBadge]（消息未读）、[AylaNavHighlight]（模块共享胶囊）、[AylaPressScale]（按压 + hover 1.02）、
/// [AylaTextStyles]（`pageTitle` 供 logo / `bodyStrong` 供模块项 / `body` 供 14px 文案 / `microTag` 供组头 / `caption` 供错误行）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/buttons.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'avatar_halo.dart';
import 'overlays.dart';
import 'reveal.dart';
import 'bottom_tabs.dart' show AylaPrimaryModule, aylaBottomTabOrder;
import 'primitives.dart' show AylaNavHighlight, AylaNavHighlightState;
import 'tab_badge.dart';

/// 一级模块顺序 —— **宽屏顶栏专用**，与 `shellConfig.ts:22–28` 的 `PRIMARY_MODULES` 一致
/// （`TopNav.tsx:145` 直接 map 它）：主页 / 语音 / 直播 / 帖子 / 桌游。
///
/// ⚠️ 与底栏 [aylaBottomTabOrder]（主页居中：语音|直播|主页|帖子|桌游）**不同** ——
/// 底栏是「视觉顺序」（`BottomTabs.tsx:18` 的 `TAB_ORDER`），顶栏用配置表原顺序。
const List<AylaPrimaryModule> aylaPrimaryModuleOrder = <AylaPrimaryModule>[
  AylaPrimaryModule.home,
  AylaPrimaryModule.voice,
  AylaPrimaryModule.live,
  AylaPrimaryModule.posts,
  AylaPrimaryModule.games,
];

/// 窄屏顶栏形态（`NarrowTopBar.tsx:23` 的 `variant`）。
enum AylaTopNavVariant {
  /// 主页三件套：头像 36 + 搜索胶囊 + 更多（`:176–196`）。
  home,

  /// 搜索输入态：返回 + 输入框（自动聚焦）+ 更多（`:145–175`）。
  search,

  /// 收藏：返回 + 标题 + 更多（`:139–144`）。
  favorites,
}

/// 「更多」菜单项（宽窄屏同三项：`TopNav.tsx:275–305` / `NarrowTopBar.tsx:100–131`）。
enum AylaTopNavMenuAction {
  profile('个人主页'),
  favorites('我的收藏'),
  logout('退出登录');

  const AylaTopNavMenuAction(this.label);

  /// 菜单文案。
  final String label;
}

/// 宽屏内联搜索下拉的分组（web `SearchDropGroup`：`TopNav.tsx:318–343`）。
class AylaSearchDropGroup {
  const AylaSearchDropGroup({
    required this.title,
    required this.count,
    this.rows = const <String>[],
    this.onMore,
    this.onRowTap,
  });

  /// 组标题（用户 / 群聊 / 帖子 / 直播间 / 语音房 / 桌游室）。
  final String title;

  /// 该类型总数（`> 3` 才出现「查看更多」；`0` 整组不渲染）。
  final int count;

  /// 行文案（每组 ≤3 条）。
  final List<String> rows;

  /// 「查看更多」回调（跳完整搜索页）。
  final VoidCallback? onMore;

  /// 行点击（行索引）。
  final ValueChanged<int>? onRowTap;
}

/// 响应式顶部导航（宽屏圆角浮动卡 / 窄屏方角条）。
class AylaTopNav extends StatefulWidget {
  const AylaTopNav({
    super.key,
    this.module,
    this.messagesActive = false,
    this.messageBadge = 0,
    this.userName = '',
    this.userAvatarUrl,
    this.userOnline = true,
    this.variant = AylaTopNavVariant.home,
    this.favoritesTitle = '我的收藏',
    this.searchQuery = '',
    this.onSearchChanged,
    this.onSearchSubmitted,
    this.onSearchCleared,
    this.onAvatarTap,
    this.onMessagesTap,
    this.onLogoTap,
    this.onModuleTap,
    this.onSearchFieldTap,
    this.onMenuSelected,
    this.onBack,
    this.dropGroups = const <AylaSearchDropGroup>[],
  });

  /// 当前一级模块（宽屏模块链选中态）。
  final AylaPrimaryModule? module;

  /// 消息路由选中态（`/messages`、`/chat/:id`）。
  final bool messagesActive;

  /// 消息未读聚合（F8 接线；F1 恒 0）。
  final int messageBadge;

  /// 当前用户昵称。
  final String userName;

  /// 头像 URL（null = 文字头像）。
  final String? userAvatarUrl;

  /// 在线状态（光环）。
  final bool userOnline;

  /// 窄屏形态。
  final AylaTopNavVariant variant;

  /// 窄屏 favorites 的标题文案。
  final String favoritesTitle;

  /// 搜索输入（受控）。
  final String searchQuery;

  /// 输入变化。
  final ValueChanged<String>? onSearchChanged;

  /// 回车提交（宽屏进 `/search`）。
  final ValueChanged<String>? onSearchSubmitted;

  /// 清除输入。
  final VoidCallback? onSearchCleared;

  /// 头像点击（→ 个人主页）。
  final VoidCallback? onAvatarTap;

  /// 消息钮（→ /messages）。
  final VoidCallback? onMessagesTap;

  /// logo 点击（→ 首页）。
  final VoidCallback? onLogoTap;

  /// 模块点击。
  final ValueChanged<AylaPrimaryModule>? onModuleTap;

  /// 窄屏 default 的搜索胶囊点击（→ 搜索页）。
  final VoidCallback? onSearchFieldTap;

  /// 「更多」菜单选择。
  final ValueChanged<AylaTopNavMenuAction>? onMenuSelected;

  /// 窄屏 search / favorites 的返回钮。
  final VoidCallback? onBack;

  /// 宽屏搜索下拉分组（空 = 不出面板）。
  final List<AylaSearchDropGroup> dropGroups;

  /// 宽屏条高（shell.css:168）。
  static const double wideHeight = 64;

  /// 窄屏条高（home.css:44）。
  static const double narrowHeight = 56;

  /// 宽屏外边距（auroraqua.css:263 `margin: var(--sidebar-gutter) var(--sidebar-gutter) 0`）。
  static const EdgeInsets wideMargin = EdgeInsets.fromLTRB(12, 12, 12, 0);

  /// logo 隐藏阈值（shell.css:268–272 `@media (max-width: 1240px)`）。
  static const double logoMinWidth = 1240;

  /// 收窄布局阈值（auroraqua.css:476 `@media (min-width: 769px) and (max-width: 900px)`）。
  static const double crampedMaxWidth = 900;

  /// 窄屏断点（web `NARROW_QUERY`）。
  static const double narrowMaxWidth = 768;

  @override
  State<AylaTopNav> createState() => _AylaTopNavState();
}

class _AylaTopNavState extends State<AylaTopNav> {
  bool _menuOpen = false;
  bool _panelOpen = false;
  final FocusNode _searchFocus = FocusNode();
  final TextEditingController _queryCtrl = TextEditingController();
  final GlobalKey _moreKey = GlobalKey();
  OverlayEntry? _overlay;

  /// 失焦延时关闭面板的计时器（web `onBlur` 延时 150ms，`TopNav.tsx:190`）。
  Timer? _blurTimer;

  /// 模块链 Stack 的 key（实测坐标系基准）。
  final GlobalKey _chainKey = GlobalKey();

  /// 各模块项槽位 —— 项宽由内容决定（`inline-flex`），**不能按等分推算**，必须实测。
  final Map<AylaPrimaryModule, GlobalKey> _moduleKeys =
      <AylaPrimaryModule, GlobalKey>{
    for (final AylaPrimaryModule m in aylaPrimaryModuleOrder) m: GlobalKey(),
  };

  /// 选中模块的实测矩形（相对模块链 Stack）；null = 不画胶囊。
  Rect? _capsuleRect;

  /// 指针所在模块（驱动悬停冰蓝底与胶囊扫光）。
  ///
  /// ⚠️ 不能只记「是否 hover 选中项」这个 bool：web 的扫光选择器是
  /// `.has-auroraqua-highlight:hover > .auroraqua-nav-highlight::after`，**CSS 每帧实时求值**；
  /// 而 Flutter 的 `MouseRegion.onEnter/onExit` 只在指针移动时触发 →
  /// 「指针静止、点击后高亮滑到指针下」会漏掉（同 AylaDirectoryFilters 的注释，profile_and_filters.dart:344–354）。
  AylaPrimaryModule? _hoveredModule;

  /// **按压中**的模块（驱动容器级胶囊同步 `.98`）。
  ///
  /// web 的胶囊是按钮的**子元素** → 按钮 `:active { scale: .98 }` 时胶囊跟着缩；
  /// 本实现为支持共享迁移把胶囊放在容器级，故必须显式同步
  /// （范本：profile_and_filters.dart:356–360 + 568–578）。
  AylaPrimaryModule? _pressedModule;

  /// 直达高亮 State 的 key —— 「指针进入选中项」时**当场**启动扫光，
  /// 不经父级 setState → rebuild 的 1 帧往返（对齐 web `:hover` 原生响应）。
  final GlobalKey<AylaNavHighlightState> _moduleHighlightKey =
      GlobalKey<AylaNavHighlightState>();

  /// 浮层锚点：等价 web 的「`position: relative` wrap + `absolute; top: calc(100% + 8px); right: 0`」。
  /// 用 [LayerLink] 让浮层**跟随锚点**，不再手算全局坐标（手算会导致错位）。
  final GlobalKey _searchAnchorKey = GlobalKey(); // 搜索框锚点（面板定位用）

  @override
  void initState() {
    super.initState();
    _queryCtrl.text = widget.searchQuery;
    _searchFocus.addListener(_onFocusChanged);
    _measureModules(); // 首帧后实测选中模块槽位（胶囊定位）
    // 窄屏 search 变体：进态自动聚焦（`NarrowTopBar.tsx:37–39`）
    if (widget.variant == AylaTopNavVariant.search) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(covariant AylaTopNav old) {
    super.didUpdateWidget(old);
    // URL 回退等外部改动同步输入框（`TopNav.tsx:61` / `NarrowTopBar.tsx:42–44`）
    if (widget.searchQuery != old.searchQuery && _queryCtrl.text != widget.searchQuery) {
      _queryCtrl.text = widget.searchQuery;
    }
    // 选中模块变化 → 重新实测胶囊槽位（迁移由 AnimatedPositioned 负责）
    if (widget.module != old.module) _measureModules();
  }

  /// 布局后实测**选中模块项**的矩形（胶囊 `inset: 0` 落在项内）。
  /// 项宽由内容决定（`inline-flex`）⇒ 必须实测，不能按等分推算。
  void _measureModules() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final AylaPrimaryModule? active = widget.module;
      if (active == null) {
        if (_capsuleRect != null) setState(() => _capsuleRect = null);
        return;
      }
      final RenderBox? chain =
          _chainKey.currentContext?.findRenderObject() as RenderBox?;
      final RenderBox? item =
          _moduleKeys[active]?.currentContext?.findRenderObject() as RenderBox?;
      if (chain == null || item == null || !chain.hasSize || !item.hasSize) {
        return;
      }
      final Rect rect =
          item.localToGlobal(Offset.zero, ancestor: chain) & item.size;
      if (rect != _capsuleRect) setState(() => _capsuleRect = rect);
    });
  }

  @override
  void dispose() {
    _blurTimer?.cancel();
    _searchFocus.removeListener(_onFocusChanged);
    _removeOverlay();
    _queryCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool narrow = MediaQuery.sizeOf(context).width <= AylaTopNav.narrowMaxWidth;
    return narrow ? _buildNarrow(context) : _buildWide(context);
  }

  // ===================== 宽屏（TopNav） =====================

  Widget _buildWide(BuildContext context) {
    final double width = MediaQuery.sizeOf(context).width;
    final bool cramped = width <= AylaTopNav.crampedMaxWidth; // 769–900 收窄
    final double hPad = cramped ? AylaSpacing.sp3 : AylaSpacing.sp6;
    final double gap = cramped ? AylaSpacing.sp3 : AylaSpacing.sp6;

    final Widget bar = SizedBox(
      height: AylaTopNav.wideHeight,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: hPad),
        // ⚠️ 必须显式垂直居中：`Stack` 默认 `alignment: topStart`，非定位 child（这条 Row）
        // 会**贴顶**，导致头像/模块/图标钮/搜索框整体偏上（2026-09-20 用户看图指出）。
        // web 对应 `.top-nav { display: flex; align-items: center }`（shell.css:165–166）。
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            Row(
              children: <Widget>[
                // 头像 40（`TopNav.tsx:135–140`）
                AvatarHalo(
                  label: widget.userName,
                  size: 40,
                  online: widget.userOnline,
                  resourceUrl: widget.userAvatarUrl,
                  onTap: widget.onAvatarTap,
                  semanticLabel: '个人主页',
                ),
                SizedBox(width: gap),
                _wideModules(cramped: cramped),
                const Spacer(),
                _wideRight(cramped: cramped),
              ],
            ),
            // 品牌 logo **绝对居中**；≤1240px 隐藏（shell.css:239–272）
            if (width > AylaTopNav.logoMinWidth)
              Center(child: _wideLogo(context)),
          ],
        ),
      ),
    );

    // 条 = 浮动圆角卡（auroraqua.css:262–270 覆写）⇒ 复用 [GlassCard]；
    // 模糊档取导航 18（shell.css:166 的 blur(18px) saturate(1.4)），不是卡片默认 24。
    return Padding(
      padding: AylaTopNav.wideMargin,
      child: GlassCard(
        padding: EdgeInsets.zero,
        radius: AylaRadii.rCard,
        blur: AylaGlass.blurNav,
        child: bar,
      ),
    );
  }

  /// logo：渐变字（`linear-gradient(120deg, --indigo-700, --grape-700)` + `background-clip: text`）、
  /// display 22/600/ls -0.3（shell.css:239–260）。复用 `pageTitle`（Fredoka 600 + ls -0.3）改字号。
  Widget _wideLogo(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return AylaPressScale(
      onTap: widget.onLogoTap,
      semanticLabel: 'Ayla 首页',
      hoverScale: false,
      child: ShaderMask(
        shaderCallback: (Rect bounds) => const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight, // 120deg ≈ 左上→右下
          colors: <Color>[AylaColors.indigo700, AylaColors.grape700],
        ).createShader(bounds),
        blendMode: BlendMode.srcIn,
        child: Text('Ayla', style: t.pageTitle.copyWith(fontSize: 22)),
      ),
    );
  }

  /// 一级模块链（`shell.css:186–237` + `auroraqua:256–261`）。
  ///
  /// 顺序 = `aylaPrimaryModuleOrder`（主页/语音/直播/帖子/桌游）；
  /// 高光与切换动画**复用群内顶栏那套**：容器级共享胶囊（跨槽 300ms `[0,0,.58,1]`）+
  /// 悬停冰蓝底（`shell.css:207–210`）+ 悬停扫光（`auroraqua.css:161–166`）。
  Widget _wideModules({required bool cramped}) {
    final double gap = cramped ? AylaSpacing.sp1 : AylaSpacing.sp2;
    return Semantics(
      label: '一级模块',
      child: Stack(
        key: _chainKey,
        children: <Widget>[
          if (_capsuleRect case final Rect r)
            AnimatedPositioned(
              duration: AylaDurations.auroraqua, // 300ms
              curve: AylaCurves.auroraquaEaseOut, // [0,0,.58,1]
              left: r.left,
              top: r.top,
              width: r.width,
              height: r.height,
              // `:active → scale: .98` —— web 的胶囊是**按钮的子元素**（`inset: 0`），
              // 按钮按下缩放时胶囊**跟着缩**；本实现为支持共享迁移把胶囊放在容器级，
              // 不会自动继承 → 需在此同步同样的缩放（复刻范本 AylaDirectoryFilters 的
              // 做法，profile_and_filters.dart:568–578）。
              child: AnimatedScale(
                duration: AylaDurations.button, // transition 200ms
                curve: AylaCurves.auroraqua, // --auroraqua-ease
                scale: _pressedModule != null && _pressedModule == widget.module
                    ? 0.98
                    : 1.0,
                child: AylaNavHighlight(
                  key: _moduleHighlightKey, // 供 onSweep 直达（省 1 帧）
                  radiusValue: BorderRadius.circular(AylaRadii.rInput),
                  // 白边走库内默认（showBorder: true = `border: 1px solid --glass-border`，
                  // auroraqua.css:186）；此前误传 false ⇒ 用户「看不出来有白边」。
                  sweep: true,
                  // CSS：`.has-auroraqua-highlight:hover > .auroraqua-nav-highlight`
                  // → 指针所在项 == 选中项时扫光（**每帧求值**，故「高亮滑到静止指针下」也触发）
                  sweepActive: _hoveredModule != null && _hoveredModule == widget.module,
                ),
              ),
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (int i = 0; i < aylaPrimaryModuleOrder.length; i++) ...<Widget>[
                if (i > 0) SizedBox(width: gap),
                _wideModuleItem(aylaPrimaryModuleOrder[i], cramped: cramped),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _wideModuleItem(AylaPrimaryModule m, {required bool cramped}) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool active = widget.module == m;
    final Color color = active ? AylaColors.textPrimary : AylaColors.textSecondary;
    // 模块项：15px/700（= bodyStrong）
    // ⚠️ 不要擅自设 `height`：web 的 `.top-nav-module` 只声明 font-size(15)/font-weight(700)，
    // 行高继承 body；此前写死 `height: 1.2` 导致图标与文字视觉不齐（用户给 web 参考图指出）。
    final TextStyle style = t.bodyStrong.copyWith(color: color);

    final Widget inner = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: cramped ? AylaSpacing.sp2 : AylaSpacing.sp3,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 图标 16 + margin-right 6；垂直微调**经用户实测校准为 0**：
          //   web 的 `.top-nav-module-icon { translate: 0 -2px }`（shell.css:214–219）是针对浏览器
          //   字形重心硬调的；Flutter 里同一图标（Lucide 数据）+ 同一字体栈（Nunito → PingFang/
          //   Noto/YaHei）+ 同一行高（15 × 1.55 = 23px）渲染后，`-2` 反而偏上 ⇒ 用户实机判断
          //   「下移 2px」→ 取 0。保留 Transform 以便后续按 px 微调。
          Transform.translate(
            // 用户逐次实机校准（preview 与 release 观感有差）：web 的 -2 在此字形下偏上
            // → 下移 2 → 上移 1 → 下移 0.5 → 上移 0.5 ⇒ +1
            offset: const Offset(0, 1),
            child: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: AylaIcon(
                aylaIconByName(m.iconName)!, // 与 BottomTabs 同源映射
                size: 16,
                color: color,
              ),
            ),
          ),
          Text(m.label, style: style),
        ],
      ),
    );

    // 悬停冰蓝底（`shell.css:207–210`）：`transition: background 180ms --ease-out`
    final bool hovered = _hoveredModule == m;
    // 复刻范本 AylaDirectoryFilters 的选项卡交互（profile_and_filters.dart:861–898）：
    //   ① hover 上报（驱动容器级胶囊扫光的每帧求值）；
    //   ② 本项**就是选中项**时，在 MouseRegion 里**当场**驱动扫光（省掉父级 rebuild 的 1 帧）；
    //   ③ Listener 上报按压态（驱动容器级胶囊同步 `.98`）。
    return MouseRegion(
      onEnter: (_) {
        setState(() => _hoveredModule = m);
        if (active) {
          _moduleHighlightKey.currentState?.setSweep(true);
        }
      },
      onExit: (_) {
        setState(() {
          _hoveredModule = null;
          if (_pressedModule == m) _pressedModule = null;
        });
        if (active) {
          _moduleHighlightKey.currentState?.setSweep(false);
        }
      },
      child: SizedBox(
        key: _moduleKeys[m], // 供胶囊实测（项宽由内容决定）
        // ⚠️ 必须**固定** 44：web 是 `min-height: 44px` + 内容高（≈22）⇒ 按钮高 44；
        // 若用 `minHeight` + 外层 `Center`，Center 在「无高度约束」下会撑满整条 64，
        // 胶囊随之变成 64 高（2026-09-20 用户实测指出「圆角块比我大」，实测 76.5×64）。
        height: 44, // auroraqua:258
        child: AylaPressScale(
          onTap: widget.onModuleTap == null
              ? null
              : () {
                  // **挂载即命中**（对齐 web，同范本 profile_and_filters.dart:533–550）：
                  // 点击的是「指针已经在上面」的 tab 时，web 上胶囊被挂载到该项，`:hover`
                  // 从第一帧就匹配 → 首次绘制即 `translateX(120%)`（右侧界外），**不产生 transition**；
                  // 随后鼠标移走 → `120% → -120%` → 跑出完整一次「从右往左」扫光。
                  // 用 `jump: true` 把进度直接置 1.0 复刻该语义（若用 forward()，行程会在
                  // 点击后立刻被消耗，移走时回程几乎为零 → 看不到扫光）。
                  _moduleHighlightKey.currentState?.setSweep(true, jump: true);
                  widget.onModuleTap!(m);
                },
          semanticLabel: m.label,
          hoverScale: false, // 导航组：只 :active scale .98（auroraqua:245–249）
          // 按压态上报 → 容器级胶囊同步 `.98`（web 胶囊是按钮子元素，自动跟随）
          onPressChanged: (bool pressed) {
            setState(() => _pressedModule = pressed ? m : null);
          },
          child: AnimatedContainer(
            // ⚠️ 覆写链：`shell.css:204–205` 给的是 `var(--dur-fast)`(180ms)，但
            // `auroraqua.css:236–243` 的导航组（含 `.top-nav-module`）把它覆写为
            // `background var(--auroraqua-duration) var(--auroraqua-ease)` = **300ms**。
            duration: AylaDurations.auroraqua, // 300ms（auroraqua:238）
            curve: AylaCurves.auroraqua,
            decoration: BoxDecoration(
              color: hovered && !active
                  ? AylaColors.ice500.withValues(alpha: 0.18)
                  : AylaColors.ice500.withValues(alpha: 0), // 同色相零透明
              borderRadius: BorderRadius.circular(AylaRadii.rInput),
            ),
            child: Center(child: inner),
          ),
        ),
      ),
    );
  }

  /// 右侧集群：消息钮 + 搜索框 + 更多钮（`TopNav.tsx:168–308`）。
  Widget _wideRight({required bool cramped}) {
    final double gap = cramped ? AylaSpacing.sp2 : AylaSpacing.sp3;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _surfaceIconButton(
          wrapKey: null,
          iconName: 'iconMessage',
          semanticLabel: '消息',
          size: 20, // `<IconMessage width={20}>`
          onPressed: widget.onMessagesTap,
          active: widget.messagesActive,
          badge: widget.messageBadge,
        ),
        SizedBox(width: gap),
        // 面板锚在**搜索框**上（web `.top-nav-search-wrap { position: relative }` + 面板 absolute）
        KeyedSubtree(
          key: _searchAnchorKey, // 面板锚点（相对 Overlay 求坐标）
          child: _wideSearchField(cramped: cramped),
        ),
        SizedBox(width: gap),
        _surfaceIconButton(
          wrapKey: _moreKey, // 菜单锚点（相对 Overlay 求坐标）
          iconName: 'iconDots',
          semanticLabel: '更多',
          size: 20,
          onPressed: _toggleMenu,
          square: true, // 「更多」钮圆角是 radius-input（auroraqua:120）
          sweep: true, // 唯一带扫光的图标钮（auroraqua.css:142–148）
        ),
      ],
    );
  }

  /// 宽屏搜索框（shell.css:316–349 + auroraqua:503–520 文本字段族）。
  /// 复用 [GlassSurface]（自带 `--glass-bg`/1px 边/`--glass-inset` 内高光 + blur），
  /// 圆角取 `radius-input`（auroraqua 覆盖 home.css 的 pill）；focus 换辉光边 + 辉光阴影。
  Widget _wideSearchField({required bool cramped}) {
    final bool focused = _searchFocus.hasFocus;
    final double width = cramped
        ? (MediaQuery.sizeOf(context).width * 0.22).clamp(160.0, 200.0)
        : 240;
    return SizedBox(
      width: width,
      child: GlassSurface(
        radius: AylaRadii.rInput,
        blur: AylaGlass.blurButton, // 文本字段族用 --glass-filter（8px 档）
        shadow: focused ? AylaShadows.glow : const <BoxShadow>[],
        borderOverride: Border.all(
          color: focused ? AylaColors.glow500 : AylaColors.glassBorder,
        ),
        padding: EdgeInsets.zero,
        child: SizedBox(
          height: 40,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp3),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _queryCtrl,
                    focusNode: _searchFocus,
                    onChanged: (String v) {
                      setState(() {});
                      widget.onSearchChanged?.call(v);
                    },
                    onSubmitted: widget.onSearchSubmitted,
                    style: AylaTextStyles.of(context).body.copyWith(fontSize: 14),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                      hintText: '搜索',
                    ),
                  ),
                ),
                if (_queryCtrl.text.isNotEmpty)
                  _searchTailButton(
                    iconName: 'iconClose',
                    iconSize: 14, // `<IconClose width={14}>`
                    semanticLabel: '清除搜索',
                    color: AylaColors.textSecondary,
                    hoverColor: AylaColors.textPrimary, // search.css:427–430
                    onPressed: () {
                      _queryCtrl.clear();
                      setState(() {});
                      widget.onSearchCleared?.call();
                    },
                  ),
                _searchTailButton(
                  iconName: 'iconSearch',
                  iconSize: 16, // `<IconSearch width={16}>`
                  semanticLabel: '搜索',
                  color: AylaColors.indigo700, // submit 用主交互色（search.css:433）
                  onPressed: () => widget.onSearchSubmitted?.call(_queryCtrl.text),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 搜索框尾部按钮（search.css:417–441）：40×40 圆形、**透明底**、
  /// `transition: background/color 180ms --ease-out`、hover → 冰蓝 `.18`。
  /// clear 的 hover 还会把图标转到 `--text-primary`；submit 图标是 `--indigo-700`。
  Widget _searchTailButton({
    required String iconName,
    required double iconSize,
    required String semanticLabel,
    required Color color,
    Color? hoverColor,
    VoidCallback? onPressed,
  }) {
    return _SearchTailButton(
      iconName: iconName,
      iconSize: iconSize,
      semanticLabel: semanticLabel,
      color: color,
      hoverColor: hoverColor,
      onPressed: onPressed,
    );
  }

  /// 表面图标钮：复用 [AylaIconButton]（40×40 + 玻璃底 + 1px 边 + `--glass-shadow-button`
  /// + `--glass-inset` + blur8 + hover `scale 1.02` / active `.98`）；
  /// 外层补「消息选中底条」与「未读徽标」（`TopNav.tsx:169–181` / shell.css:298–314）。
  Widget _surfaceIconButton({
    required Key? wrapKey,
    required String iconName,
    required String semanticLabel,
    required double size,
    VoidCallback? onPressed,
    bool active = false,
    int badge = 0,
    bool square = false,
    bool sweep = false,
  }) {
    return Stack(
      key: wrapKey,
      clipBehavior: Clip.none,
      children: <Widget>[
        // ⚠️ `AylaIconButton` 内部背景固定（玻璃底 + hover 冰蓝），不接受「选中底色」；
        // 而 web `.top-nav-icon-btn.is-active` 是**两者都要**（shell.css:297–314）：
        //   `color: --text-primary` + `background: rgba(157,191,230,.18)` + `::after` 底条
        // → 选中底色由外层补，圆角与按钮一致（`.top-nav-icon-btn` = pill；「更多」钮 = radius-input）。
        DecoratedBox(
          decoration: BoxDecoration(
            color: active ? AylaColors.ice500.withValues(alpha: 0.18) : null,
            borderRadius: square
                ? BorderRadius.circular(AylaRadii.rInput)
                : AylaRadii.pill,
          ),
          child: AylaIconButton(
            icon: AylaIcon(aylaIconByName(iconName)!, size: size),
            onPressed: onPressed,
            square: square,
            // 扫光只给「更多」钮（auroraqua.css:142–148 的选择器组）：
            // `.top-nav-more > .top-nav-icon-btn` / `.narrow-topbar-more > .icon-btn-40`
            sweep: sweep,
            semanticLabel: semanticLabel,
          ),
        ),
        if (active)
          // 消息选中底条：left/right 10、bottom 2、2px、--glow-500（shell.css:303–312）
          const Positioned(
            left: 10,
            right: 10,
            bottom: 2,
            child: SizedBox(
              height: 2,
              child: DecoratedBox(
                decoration: BoxDecoration(color: AylaColors.glow500),
              ),
            ),
          ),
        if (badge > 0)
          // `.tab-badge`（99+ 封顶，`TopNav.tsx:176–180`）。
          // ⚠️ `TabBadge` **内部自带** `Positioned(top: -4, right: -12)`，外层不要再套 Positioned
          // （两层 Positioned 会触发 Competing ParentDataWidgets 断言）。
          TabBadge(count: badge, max: 99),
      ],
    );
  }

  // ===================== 窄屏（NarrowTopBar） =====================

  Widget _buildNarrow(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    // 三变体（`NarrowTopBar.tsx:137–197`）
    final List<Widget> items = switch (widget.variant) {
      AylaTopNavVariant.favorites => <Widget>[
          _narrowBackButton(),
          Expanded(
            child: Text(
              widget.favoritesTitle,
              style: t.pageTitle.copyWith(fontSize: 18), // display 18/600（home.css:55–67）
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _narrowMoreButton(),
        ],
      AylaTopNavVariant.search => <Widget>[
          _narrowBackButton(),
          Expanded(child: _narrowSearchField(context)),
          _narrowMoreButton(),
        ],
      AylaTopNavVariant.home => <Widget>[
          AvatarHalo(
            label: widget.userName,
            size: 36, // `NarrowTopBar.tsx:182` size={36}
            online: widget.userOnline,
            resourceUrl: widget.userAvatarUrl,
            onTap: widget.onAvatarTap,
            semanticLabel: '个人主页',
          ),
          Expanded(child: _narrowSearchEntry(context)),
          _narrowMoreButton(),
        ],
    };

    // 入场动画（`auroraqua.css:412–424`）：`@media (max-width:768px)` 内 `.narrow-topbar`
    // 与一批「窄屏顶栏类」元素共用 `auroraqua-panel-from-top` ——
    // 关键帧（auroraqua.css:18–21）：`from { opacity: 0; translate: 0 -20px } → to { … 0 0 }`，
    // 时长/曲线 `var(--auroraqua-duration)`(300ms) `var(--auroraqua-ease-out)`；
    // reduced-motion 由 `AylaRevealItem` 内部处理（auroraqua.css:631 亦有开关）。
    // 复用现成件 [AylaRevealItem]（offset 上入 20px = 同一关键帧语义）。
    return AylaRevealItem(
      offset: const Offset(0, -AylaRevealMotion.distance), // `translate: 0 -20px`
      child: _narrowBar(context, items),
    );
  }

  /// 窄屏条本体：无圆角 + 仅底部 1px 边（home.css:34–48）⇒ 复用 [GlassSurface] + override。
  Widget _narrowBar(BuildContext context, List<Widget> items) {
    return GlassSurface(
      blur: AylaGlass.blurNav,
      shadow: const <BoxShadow>[], // 窄屏条未声明阴影
      radiusOverride: BorderRadius.zero,
      borderOverride: const Border(
        bottom: BorderSide(color: AylaColors.glassBorder),
      ),
      padding: EdgeInsets.zero,
      child: SizedBox(
        height: AylaTopNav.narrowHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp4),
          child: Row(
            children: <Widget>[
              for (int i = 0; i < items.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: AylaSpacing.sp3), // gap: sp3
                items[i],
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 返回钮（`NarrowTopBar.tsx:69–78`：`.icon-btn-40` + 20px 返回图标）。
  Widget _narrowBackButton() {
    return AylaIconButton(
      icon: AylaIcon(aylaIconByName('iconBack')!, size: 20),
      onPressed: widget.onBack,
      square: true, // `.icon-btn-40` 圆角被 auroraqua:119–121 改为 radius-input
      semanticLabel: '返回',
    );
  }

  /// 更多钮（宽窄屏同款：`icon-btn-40` + `IconDots` 20 + `.narrow-topbar-menu`）。
  Widget _narrowMoreButton() {
    return _surfaceIconButton(
      wrapKey: _moreKey,
      iconName: 'iconDots',
      semanticLabel: '更多',
      size: 20,
      onPressed: _toggleMenu,
      square: true,
      sweep: true, // `.narrow-topbar-more > .icon-btn-40` 在扫光组（auroraqua:142–148）
    );
  }

  /// 窄屏搜索胶囊（default）：`IconSearch` 16 + 文案「搜索」（`NarrowTopBar.tsx:189–192`）。
  Widget _narrowSearchEntry(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return AylaPressScale(
      onTap: widget.onSearchFieldTap,
      semanticLabel: '全局搜索',
      child: GlassSurface(
        radius: AylaRadii.rInput, // 文本字段族（auroraqua:503–507 覆盖 home.css 的 pill）
        blur: AylaGlass.blurButton,
        shadow: const <BoxShadow>[],
        padding: EdgeInsets.zero,
        child: SizedBox(
          height: 40,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp4),
            child: Row(
              children: <Widget>[
                AylaIcon(
                  aylaIconByName('iconSearch')!,
                  size: 16,
                  color: AylaColors.textSecondary,
                ),
                const SizedBox(width: AylaSpacing.sp2),
                Text(
                  '搜索',
                  style: t.body.copyWith(
                    fontSize: 14,
                    color: AylaColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 窄屏搜索输入态（search 变体）：`padding: 0 sp3`、自动聚焦、尾部 clear/submit。
  Widget _narrowSearchField(BuildContext context) {
    final bool focused = _searchFocus.hasFocus;
    return GlassSurface(
      radius: AylaRadii.rInput,
      blur: AylaGlass.blurButton,
      shadow: focused ? AylaShadows.glow : const <BoxShadow>[],
      borderOverride: Border.all(
        color: focused ? AylaColors.glow500 : AylaColors.glassBorder,
      ),
      padding: EdgeInsets.zero,
      child: SizedBox(
        height: 40,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp3),
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _queryCtrl,
                  focusNode: _searchFocus,
                  onChanged: (String v) {
                    setState(() {});
                    widget.onSearchChanged?.call(v);
                  },
                  onSubmitted: widget.onSearchSubmitted,
                  style: AylaTextStyles.of(context).body.copyWith(fontSize: 14),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    hintText: '搜索用户、群、帖子…',
                  ),
                ),
              ),
              if (_queryCtrl.text.isNotEmpty)
                _searchTailButton(
                  iconName: 'iconClose',
                  iconSize: 14,
                  semanticLabel: '清除搜索',
                  color: AylaColors.textSecondary,
                  onPressed: () {
                    _queryCtrl.clear();
                    setState(() {});
                    widget.onSearchCleared?.call();
                  },
                ),
              _searchTailButton(
                iconName: 'iconSearch',
                iconSize: 18, // 窄屏 submit 图标 18（NarrowTopBar.tsx:171）
                semanticLabel: '搜索',
                color: AylaColors.indigo700,
                onPressed: () => widget.onSearchSubmitted?.call(_queryCtrl.text),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ===================== 浮层（Overlay） =====================
  //
  // web 用 `document.addEventListener("pointerdown", ...)` + `Escape` 关闭
  // （`TopNav.tsx:64–78` / `NarrowTopBar.tsx:46–60`）。Flutter 侧用 Overlay：
  // 第一层是全屏关闭层（等价 pointerdown），第二层按锚点定位浮层。

  /// 宽屏搜索面板开关：聚焦且有下拉数据 → 开面板（web `onFocus` + 300ms 去抖，去抖在页面层接）；
  /// 失焦延时 **150ms** 关闭（`TopNav.tsx:190`）。
  void _onFocusChanged() {
    _blurTimer?.cancel();
    if (_searchFocus.hasFocus) {
      if (!_panelOpen && widget.dropGroups.isNotEmpty) {
        setState(() => _panelOpen = true);
        _showOverlay(anchorKey: _searchAnchorKey, content: _panelContent);
      }
      return;
    }
    _blurTimer = Timer(const Duration(milliseconds: 150), () {
      if (!mounted || _searchFocus.hasFocus) return;
      _closeOverlay();
    });
  }

  void _toggleMenu() {
    if (_menuOpen) {
      _closeOverlay();
      return;
    }
    setState(() => _menuOpen = true);
    _showOverlay(anchorKey: _moreKey, content: _menuContent);
  }

  /// 打开浮层。定位等价 web 的「`position: relative` wrap + `absolute; top: calc(100% + 8px); right: 0`」
  /// （`shell.css:354–358` 菜单 / `search.css:365–373` 面板）。
  ///
  /// ⚠️ 坐标必须**相对 Overlay 容器**求（`localToGlobal(..., ancestor: overlayBox)`）：
  /// 用屏幕坐标或 `CompositedTransformFollower` 在画布/多屏下都会错位
  /// （2026-09-20 实测：菜单落到 `Rect.fromLTRB(-16, 151.5, 41, 173.5)`）。
  void _showOverlay({
    required GlobalKey anchorKey,
    required Widget Function(BuildContext) content,
  }) {
    final BuildContext? anchorCtx = anchorKey.currentContext;
    if (anchorCtx == null) return;
    final RenderObject? anchorRO = anchorCtx.findRenderObject();
    final RenderObject? overlayRO =
        Overlay.of(context).context.findRenderObject();
    if (anchorRO is! RenderBox || overlayRO is! RenderBox) return;
    if (!anchorRO.hasSize) return;
    // 基准是锚点**右下角**：CSS 的 `top: calc(100% + 8px); right: 0` 以按钮底边/右缘为准
    final Offset bottomRight = anchorRO.localToGlobal(
      anchorRO.size.bottomRight(Offset.zero),
      ancestor: overlayRO,
    );
    final double overlayWidth = overlayRO.size.width;
    _removeOverlay();
    // 浮层一律走统一入口（`overlays.dart`）：它在 entry 内部兜底 DefaultTextStyle
    // （Overlay 的 entry 是独立子树，页面里的 Material 传不进来）。
    _overlay = aylaOverlayEntry(
      builder: (BuildContext ctx) {
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _closeOverlay, // 点外部关闭（等价 web document pointerdown）
              ),
            ),
            Positioned(
              top: bottomRight.dy + 8, // `top: calc(100% + 8px)`
              right: overlayWidth - bottomRight.dx, // `right: 0`：浮层右缘对齐锚点右缘
              child: _overlayIn(child: content(ctx)),
            ),
          ],
        );
      },
    );
    Overlay.of(context).insert(_overlay!);
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  void _closeOverlay() {
    _removeOverlay();
    if (!mounted) return;
    setState(() {
      _menuOpen = false;
      _panelOpen = false;
    });
  }

  /// 入场 `auroraqua-menu-in`（home.css:150–153）：
  /// `opacity 0→1` + `translateY(-8px→0)` + `scale(.95→1)`，300ms `--auroraqua-ease-out`。
  Widget _overlayIn({required Widget child}) {
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: AylaDurations.auroraqua,
      curve: AylaCurves.auroraquaEaseOut,
      builder: (BuildContext context, double v, Widget? c) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, -8 * (1 - v)),
          child: Transform.scale(scale: 0.95 + 0.05 * v, child: c),
        ),
      ),
      child: child,
    );
  }

  /// 「更多」菜单（shell.css:354–391 / home.css:136–179）：
  /// `--glass-bg-strong` + `radius-card` + `padding sp2` + `min-width 160` + 菜单项高 40 / 14/600。
  Widget _menuContent(BuildContext context) {
    return GlassSurface(
      strong: true, // --glass-bg-strong
      radius: AylaRadii.rCard,
      blur: AylaGlass.blurCard,
      shadow: AylaShadows.glass,
      padding: const EdgeInsets.all(AylaSpacing.sp2),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 160),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final AylaTopNavMenuAction a in AylaTopNavMenuAction.values)
              _TopNavMenuItem(
                label: a.label,
                onTap: () {
                  _closeOverlay();
                  widget.onMenuSelected?.call(a);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 宽屏内联搜索下拉面板（search.css:365–387 + 443–486）。
  Widget _panelContent(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final List<AylaSearchDropGroup> groups = widget.dropGroups
        .where((AylaSearchDropGroup g) => g.count > 0)
        .toList();
    if (groups.isEmpty) return const SizedBox.shrink();
    return GlassSurface(
      strong: true,
      radius: AylaRadii.rCard,
      blur: AylaGlass.blurCard,
      shadow: AylaShadows.glass,
      padding: const EdgeInsets.all(AylaSpacing.sp2),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 360, // search.css:373 width: 360px
          maxHeight: 360, // search.css:374 max-height: 360px
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final AylaSearchDropGroup g in groups)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2), // gap: 2px
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      // 组头：padding sp2 sp3 sp1；标题 microTag 大写；count>3 才「查看更多」
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AylaSpacing.sp3,
                          AylaSpacing.sp2,
                          AylaSpacing.sp3,
                          AylaSpacing.sp1,
                        ),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                g.title.toUpperCase(), // text-transform: uppercase
                                style: t.microTag.copyWith(
                                  color: AylaColors.textSecondary,
                                ),
                              ),
                            ),
                            if (g.count > 3)
                              AylaPressScale(
                                onTap: g.onMore,
                                semanticLabel: '查看更多${g.title}',
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: AylaSpacing.sp2,
                                    vertical: AylaSpacing.sp1,
                                  ),
                                  child: Text(
                                    '查看更多',
                                    style: t.body.copyWith(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: AylaColors.ice500, // search.css:472
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      for (int i = 0; i < g.rows.length; i++)
                        AylaPressScale(
                          onTap: g.onRowTap == null ? null : () => g.onRowTap!(i),
                          semanticLabel: g.rows[i],
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 40),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AylaSpacing.sp3,
                              ),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  g.rows[i],
                                  style: t.body.copyWith(
                                    fontSize: 14, // search.css:401
                                    color: AylaColors.textPrimary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 顶栏「更多」菜单项（`shell.css:377–391`）：
/// `height: 40px` / `padding: 0 sp3` / `border-radius: var(--radius-input)` /
/// `font-size: 14px` / `font-weight: 600` / `color: --text-primary`；
/// `:hover → background: rgba(157,191,230,.18)`。
///
/// 复用范本 `conversation_more_menu.dart` 的 `_MenuItem`（同款 hover 语义 +
/// **同色相零透明**做法：透明黑参与插值会闪灰，见该文件 705–715 注释）。
class _TopNavMenuItem extends StatefulWidget {
  const _TopNavMenuItem({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_TopNavMenuItem> createState() => _TopNavMenuItemState();
}

class _TopNavMenuItemState extends State<_TopNavMenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AylaDurations.fast, // transition 180ms --ease-out
          curve: AylaCurves.easeOut,
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp3),
          decoration: BoxDecoration(
            color: _hovered
                ? AylaColors.ice500.withValues(alpha: 0.18)
                : AylaColors.ice500.withValues(alpha: 0), // 同色相零透明
            borderRadius: BorderRadius.circular(AylaRadii.rInput),
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              widget.label,
              style: t.body.copyWith(
                fontSize: 14,
                fontWeight: FontWeight.w600, // shell.css:385
                color: AylaColors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
/// 搜索框尾部按钮（`search.css:413–441`）：40×40 圆形、无边框、
/// `--dur-fast --ease-out` 过渡；hover 冰蓝 `.18`（clear 再转 `--text-primary`）。
class _SearchTailButton extends StatefulWidget {
  const _SearchTailButton({
    required this.iconName,
    required this.iconSize,
    required this.semanticLabel,
    required this.color,
    this.hoverColor,
    this.onPressed,
  });

  final String iconName;
  final double iconSize;
  final String semanticLabel;
  final Color color;
  final Color? hoverColor;
  final VoidCallback? onPressed;

  @override
  State<_SearchTailButton> createState() => _SearchTailButtonState();
}

class _SearchTailButtonState extends State<_SearchTailButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final Color iconColor =
        _hovered ? (widget.hoverColor ?? widget.color) : widget.color;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: AylaDurations.fast, // 180ms（--dur-fast）
          curve: AylaCurves.easeOut,
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle, // border-radius: 50%（search.css:423）
            color: _hovered
                ? AylaColors.ice500.withValues(alpha: 0.18)
                : Colors.transparent,
          ),
          child: Center(
            child: AylaIcon(
              aylaIconByName(widget.iconName)!,
              size: widget.iconSize,
              color: iconColor,
            ),
          ),
        ),
      ),
    );
  }
}

// ===================== 画布样张（可交互） =====================

/// 画布/预览用样张：宽屏（>768）圆角浮动卡；窄屏（≤768）方角条，
/// 点「更多」开会菜单、点模块切选中看共享胶囊迁移。
Widget aylaTopNavSamples() => const _TopNavDemo();

class _TopNavDemo extends StatefulWidget {
  const _TopNavDemo();

  @override
  State<_TopNavDemo> createState() => _TopNavDemoState();
}

class _TopNavDemoState extends State<_TopNavDemo> {
  AylaPrimaryModule _module = AylaPrimaryModule.home;
  /// 消息（私信）钮选中态 —— **独立状态**，点它自己切换
  /// （此前误绑在「模块 == 帖子」上，导致点它没有反应）。
  bool _messagesActive = false;
  int _badge = 5;
  String _query = '';
  String _lastAction = '（无）';
  AylaTopNavVariant _variant = AylaTopNavVariant.home;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final double width = MediaQuery.sizeOf(context).width;
    final bool narrow = width <= AylaTopNav.narrowMaxWidth;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AylaTopNav(
          module: _module,
          messagesActive: _messagesActive,
          messageBadge: _badge,
          userName: '爱莉',
          userOnline: true,
          variant: _variant,
          searchQuery: _query,
          onSearchChanged: (String v) => setState(() => _query = v),
          onSearchSubmitted: (String v) => setState(() => _lastAction = '搜索「$v」'),
          onSearchCleared: () => setState(() => _query = ''),
          onAvatarTap: () => setState(() => _lastAction = '个人主页'),
          onMessagesTap: () => setState(() {
            _messagesActive = !_messagesActive;
            _lastAction = _messagesActive ? '进入消息中心（已选中）' : '离开消息中心';
          }),
          onLogoTap: () => setState(() => _lastAction = '回首页'),
          onModuleTap: (AylaPrimaryModule m) => setState(() => _module = m),
          onSearchFieldTap: () => setState(() {
            _variant = AylaTopNavVariant.search;
            _lastAction = '进搜索页';
          }),
          onMenuSelected: (AylaTopNavMenuAction a) => setState(() {
            _lastAction = '菜单：${a.label}';
            if (a == AylaTopNavMenuAction.logout) _badge = 0;
          }),
          onBack: () => setState(() => _variant = AylaTopNavVariant.home),
          dropGroups: <AylaSearchDropGroup>[
            AylaSearchDropGroup(
              title: '用户',
              count: 7,
              rows: const <String>['爱莉', '汐汐', '阿绫'],
              onMore: () => setState(() => _lastAction = '查看更多：用户'),
              onRowTap: (int i) => setState(() => _lastAction = '行 $i'),
            ),
            AylaSearchDropGroup(
              title: '群聊',
              count: 2,
              rows: const <String>['群 · 深夜电台', '群 · 桌游部'],
              onRowTap: (int i) => setState(() => _lastAction = '群行 $i'),
            ),
          ],
        ),
        const SizedBox(height: AylaSpacing.sp3),
        Text(
          "形态：${narrow ? '窄屏（≤768）' : '宽屏'} · 模块：${_module.label} · 未读：$_badge"
          " · 搜索：「$_query」· 最近动作：$_lastAction",
          style: t.caption.copyWith(color: AylaColors.textSecondary),
        ),
        const SizedBox(height: AylaSpacing.sp2),
        Wrap(
          spacing: AylaSpacing.sp2,
          children: <Widget>[
            GlassButton(
              label: _variant == AylaTopNavVariant.home ? '切到搜索态' : '切回主页态',
              variant: GlassButtonVariant.ghost,
              onPressed: () => setState(() {
                _variant = _variant == AylaTopNavVariant.home
                    ? AylaTopNavVariant.search
                    : AylaTopNavVariant.home;
              }),
            ),
            GlassButton(
              label: '切换收藏态',
              variant: GlassButtonVariant.ghost,
              onPressed: () => setState(() {
                _variant = _variant == AylaTopNavVariant.favorites
                    ? AylaTopNavVariant.home
                    : AylaTopNavVariant.favorites;
              }),
            ),
            GlassButton(
              label: '未读 +1',
              variant: GlassButtonVariant.ghost,
              onPressed: () => setState(() => _badge += 1),
            ),
          ],
        ),
      ],
    );
  }
}

// ===================== 预览 =====================

/// 响应式顶栏（宽度 >768 走宽屏圆角卡；≤768 走窄屏方角条）。
@Preview(
  group: 'Widgets',
  name: 'TopNav 响应式（宽屏圆角浮动卡）',
  // 高 140 → 220：宽屏样例除顶栏（64 + 上边距 12）还有说明行与按钮行，
  // 实测 140 会 RenderFlex 溢出 15px（2026-09-21 预览日志定位）。
  size: Size(1600, 220),
  wrapper: previewTheme,
)
Widget aylaTopNavWidePreview() => aylaTopNavSamples();

/// 窄屏口径（375 宽，default / search / favorites 三态可切）。
@Preview(
  group: 'Widgets',
  name: 'NarrowTopBar 窄屏（375 宽）',
  size: Size(375, 260),
  wrapper: previewTheme,
)
Widget aylaTopNavNarrowPreview() => aylaTopNavSamples();
