/// AylaGroupChatSubgroupBar —— 群聊子群切换条（窄屏，输入框上沿）。
///
/// ## ⚠️ 这一段历史必须留着（第二次「按类名前缀整块判定」事故）
/// 19 号 §七 7.1 的全仓扫描把本件判成「**已覆盖**」——依据是「群聊的子群功能看起来有了」，
/// 但实际命中是**别的件**：channel_sidebar 只有 :2459 一条**注释**提到类名、group_top_tabs
/// 是群内**场景**顶栏、messages_tabs 是消息中心选项卡，三者都不是它。
/// 2026-09-28 穷举复核（19 号 :389）已就地更正：群聊子群切换条（group-chat-subgroup-*）
/// 在 Flutter 侧**零命中，是真缺口**，本轮补做。
/// 教训（已写进 skill）：审计缺件必须**按交互控件/类名逐条回查**，
/// 不能按「前缀整块看起来有了」下结论。
///
/// ## 事实源（逐条 web 文件:行 → 数值/结构）
/// ```
/// GroupChat.tsx 334–343   渲染条件 isNarrow && max(subgroups.length, subgroupPage.total) > 1；
///                         switcher 是绝对定位锚在 compose-area 上沿的手势孤岛
///                         （pointer/touch 五个 capture 全 stopPropagation —— DOM 事件委托的
///                          绕行办法，Flutter 走手势竞技场，**不需要**这层转发）
/// GroupChat.tsx 344–357   折叠键：className = collapsed ? group-chat-subgroup-collapsed
///                         : group-chat-subgroup-collapse-btn；aria-label「展开子群选项卡」/
///                         「收起子群选项卡」· aria-expanded={!collapsed} · aria-controls=panelId
///                         · title「展开子群」/「收起子群」· motion y: 0 / −4 ·
///                         IconChevronUp 14（收起）/ IconChevronDown 14（展开）
/// GroupChat.tsx 358–365   面板：motion disclosure「height auto/0 + opacity」·
///                         overflow hidden · pointerEvents: collapsed ? none : auto
/// GroupChat.tsx 366–371   选项卡行 role=tablist aria-label「子群切换」 aria-hidden={collapsed}
/// GroupChat.tsx 372–400   每个子群：role=tab · aria-selected · disabled={collapsed} ·
///                         tabIndex={collapsed ? −1 : undefined} ·
///                         className「group-chat-subgroup-tab has-auroraqua-highlight[ is-active]」
///                         · {active && <AuroraquaNavHighlight id={selectionId}/>} ·
///                         span.group-chat-subgroup-tab-name · 禁言 chip（title「已禁言（仅群主/管理员可发言）」）
///                         · 未读数 > 0 才出徽标（>99 → 「99+」· aria-label「N 条未读」）
/// GroupChat.tsx 401–403   hasMore ⇒ 额外一个普通 tab：「加载更多子群」/「加载中…」
/// GroupChat.tsx 263–266   switchSubgroup：**同 id 提前 return**（点击选中项不重复触发）
/// group.css 152–161       .group-chat-subgroup-switcher：absolute · left/right sp3 · bottom 100% ·
///                         z-index 1 · height 0 · min-width 0 · pointer-events none
/// group.css 163–170       .group-chat-subgroup-panel：absolute · left 40 · right −sp3 · bottom 0 ·
///                         min-width 0 · pointer-events auto
/// group.css 173–185       .group-chat-subgroup-tabs：flex none · row · align center · gap sp2 ·
///                         **min-height 40** · padding 0 · overflow-x auto · scrollbar 隐藏 ·
///                         -webkit-overflow-scrolling touch · touch-action pan-x
/// group.css 191–210       折叠键：absolute · left −8 · bottom 0 · 48×32 · transparent · 无边框 ·
///                         color --text-secondary · pointer-events auto
/// group.css 212–241       收起态 ::before：36×18 · left 6 · bottom 0 · radius 18 18 0 0 ·
///                         background --glass-bg-strong(.78) · transition background 200ms
///                         var(--auroraqua-ease)；hover → rgba(157,191,230,.35) + color --text-primary；
///                         svg 14 定位 left 50% / bottom 2 / translate −50% 0
/// group.css 243–269       展开态 ::after：32×32 · left 8 · top 0 · radius 50% ·
///                         background rgba(255,250,251,.6)；hover → rgba(157,191,230,.18) + --text-primary
/// group.css 271–286       .group-chat-subgroup-tab：flex none · inline-flex · gap sp2 · height 32 ·
///                         padding 0 sp3 · radius pill · background rgba(255,250,251,.6) · border 0 ·
///                         color --text-secondary · 14 / w600 · nowrap · transition background/color/
///                         box-shadow 180ms ease-out
/// group.css 288–290       :hover ⇒ background rgba(157,191,230,.18)
/// group.css 292–296       .is-active ⇒ background rgba(157,191,230,.35) + --text-primary + --glass-inset
/// auroraqua.css 190–192   :is(..., .group-chat-subgroup-tab).has-auroraqua-highlight
///                         ⇒ border-radius: **--radius-pill**（库内 AylaNavHighlight 已登记该覆写：
///                           nav_highlight.dart:76）· 199 ⇒ 胶囊自身 border: 0
/// auroraqua.css 194–197   .has-auroraqua-highlight:is(.is-active,.active) ⇒ background: transparent +
///                         box-shadow: none（**选中底交给胶囊**）· 特异度与 :hover 相同但后加载 ⇒
///                         选中项 hover 时底色仍是透明（底归胶囊）
/// group.css 298–302       .group-chat-subgroup-tab-name：max-width 120 · overflow hidden · ellipsis
/// group.css 304–316       .group-chat-subgroup-tab-badge：min-width 16 · height 16 · padding 0 4 ·
///                         radius pill · background --pink-500 · color #fffafb · Fredoka 11 ·
///                         line-height 16 · text-align center · flex none
/// group.css 318–331       禁言 chip（与侧栏/群信息共用视觉）：padding 1px 6px · radius pill ·
///                         background --ice-300 · color --indigo-700 · Fredoka 10 · lh 1.4 · nowrap
/// auroraquaMotion.ts 89–95 disclosureVariants：height auto ↔ 0 + opacity，300ms easeOut；
///                         reduced ⇒ duration 0
/// ```
///
/// ## 复用（不另写一套）
/// 选中胶囊 = 库内 **AylaNavHighlightList**（容器级单实例胶囊 + 300ms 迁移 + 按压 .98 +
/// 扫光 + 键盘 + 滚动揭示）：本件只按子群列表渲染槽位，**不自己实现选中底**——
/// 与 web 的 has-auroraqua-highlight + AuroraquaNavHighlight 同构。
///
/// ## 定位契约（调用方）
/// 本件的盒 = **compose-area 的整宽**，底边 = 输入框上沿。调用方放进 Stack：
/// ```dart
/// Positioned(
///   left: 0, right: 0,
///   bottom: composerHeight,            // web 的 bottom: 100%（锚在输入区上沿）
///   child: AylaGroupChatSubgroupBar(...),
/// )
/// ```
/// 内部坐标按 group.css 原文从 switcher（left/right = sp3）折算：折叠键 left = sp3 − 8 = 4、
/// 面板 left = sp3 + 40 = 52 / right = sp3 − 12 = 0。web 的 switcher 只有 left/right（height 0），
/// 故调用方**不要**再给本件加横向内缩（否则折叠键与面板整体右移 12px）。
///
/// ## 公开面
/// AylaGroupChatSubgroupTab · AylaGroupChatSubgroupBar · 样张 aylaGroupChatSubgroupBarSamples()

library;

import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import '../base/nav_highlight_list.dart';
import '../base/tooltip.dart';

/// 子群选项卡数据（web SubGroup 的最小投影：id / name / muted / 未读数）。
class AylaGroupChatSubgroupTab {
  const AylaGroupChatSubgroupTab({
    required this.id,
    required this.name,
    this.muted = false,
    this.unread = 0,
  });

  final String id;
  final String name;

  /// sg.muted === true（GroupChat.tsx:388）⇒ 出「禁言」chip。
  final bool muted;

  /// unreadByKey[subgroupKey(groupId, sg.id)] ?? 0 ⇒ >0 才出徽标，>99 显示「99+」。
  final int unread;
}

/// 群聊子群切换条（group.css 152–331 + GroupChat.tsx 334–407）。
class AylaGroupChatSubgroupBar extends StatefulWidget {
  const AylaGroupChatSubgroupBar({
    super.key,
    required this.subgroups,
    required this.activeId,
    required this.onSelect,
    this.collapsed,
    this.onCollapsedChanged,
    this.hasMore = false,
    this.loadingMore = false,
    this.onLoadMore,
  });

  /// 子群列表。
  final List<AylaGroupChatSubgroupTab> subgroups;

  /// 当前选中子群 id（web activeSubgroupId）。
  final String? activeId;

  /// 选中回调（web switchSubgroup；**同 id 不触发**）。
  final ValueChanged<AylaGroupChatSubgroupTab> onSelect;

  /// 收起态（web subgroupsCollapsed，默认 true）。传 null ⇒ 内部自持。
  final bool? collapsed;

  /// 展开/收起变化通知（web setSubgroupsCollapsed）。
  final ValueChanged<bool>? onCollapsedChanged;

  /// subgroupPage.hasMore ⇒ 追加「加载更多子群」键。
  final bool hasMore;

  /// subgroupPage.loading（加载中 ⇒ 文案「加载中…」且禁用）。
  final bool loadingMore;

  /// 加载更多回调。
  final VoidCallback? onLoadMore;

  /// 折叠键命中区高度（group.css 202：height 32px）。
  static const double handleHeight = 32;

  /// 选项卡行 min-height（group.css 178：40px）。
  static const double tabsMinHeight = 40;

  /// 折叠键相对 compose-area 左缘：web left: −8 于 switcher（其 left = sp3）⇒ 4。
  static const double handleLeft = AylaSpacing.sp3 - 8;

  /// 面板相对 compose-area 左缘：web left: 40px 于 switcher（其 left = sp3）⇒ 52。
  static const double panelLeft = AylaSpacing.sp3 + 40;

  /// 面板右缘：web right: −sp3 于 switcher（其 right = sp3）⇒ 与 compose-area 右缘齐平。
  static const double panelRight = 0;

  /// 折叠键（48×32 命中区）的查找键 —— 调用方/测试定位 aria-expanded 语义节点用。
  static const Key collapseHandleKey = ValueKey<String>(
    'ayla-group-chat-subgroup-collapse-handle',
  );

  @override
  State<AylaGroupChatSubgroupBar> createState() =>
      _AylaGroupChatSubgroupBarState();
}

class _AylaGroupChatSubgroupBarState extends State<AylaGroupChatSubgroupBar> {
  final ScrollController _scroll = ScrollController();

  /// 内部收起态（widget.collapsed == null 时生效；默认收起 = web 的 useState(true)）。
  bool _internalCollapsed = true;
  bool _handleHovered = false;

  bool get _collapsed => widget.collapsed ?? _internalCollapsed;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _toggle() {
    final bool next = !_collapsed;
    if (widget.collapsed == null) setState(() => _internalCollapsed = next);
    widget.onCollapsedChanged?.call(next);
  }

  /// 选中项索引（-1 = 无；「加载更多」键不参与选中）。
  int get _selectedIndex {
    final String? id = widget.activeId;
    if (id == null) return -1;
    return widget.subgroups.indexWhere(
      (AylaGroupChatSubgroupTab sg) => sg.id == id,
    );
  }

  /// 折叠键图标色：hover → --text-primary（group.css 231–233 / 261–263）。
  Color get _handleColor =>
      _handleHovered ? AylaColors.textPrimary : AylaColors.textSecondary;

  @override
  Widget build(BuildContext context) {
    final bool collapsed = _collapsed;
    final Duration duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : AylaDurations.auroraqua; // disclosureVariants：300ms easeOut（reduced ⇒ 0）

    // 盒高：收起 = 折叠键 32；展开 = 选项卡行 min-height 40（底边恒在输入框上沿）
    return AnimatedContainer(
      duration: duration,
      curve: AylaCurves.auroraquaEaseOut,
      height: collapsed
          ? AylaGroupChatSubgroupBar.handleHeight
          : AylaGroupChatSubgroupBar.tabsMinHeight,
      child: Stack(
        children: <Widget>[
          // ---- 面板（disclosure：height auto ↔ 0 + opacity）----
          Positioned(
            left: AylaGroupChatSubgroupBar.panelLeft,
            right: AylaGroupChatSubgroupBar.panelRight,
            bottom: 0,
            child: ExcludeSemantics(
              excluding: collapsed, // aria-hidden={collapsed}
              child: IgnorePointer(
                ignoring: collapsed, // pointerEvents: none
                child: AnimatedOpacity(
                  duration: duration,
                  curve: AylaCurves.auroraquaEaseOut,
                  opacity: collapsed ? 0 : 1,
                  child: AnimatedSize(
                    duration: duration,
                    curve: AylaCurves.auroraquaEaseOut,
                    alignment: Alignment.bottomCenter,
                    child: collapsed
                        ? const SizedBox(width: double.infinity, height: 0)
                        : _tabsRow(collapsed),
                  ),
                ),
              ),
            ),
          ),
          // ---- 折叠键（收起 bottom 0 / 展开 motion y −4）----
          AnimatedPositioned(
            duration: duration,
            curve: AylaCurves.auroraquaEaseOut,
            left: AylaGroupChatSubgroupBar.handleLeft,
            bottom: collapsed ? 0 : 4,
            width: 48, // group.css 201
            height: AylaGroupChatSubgroupBar.handleHeight,
            child: _collapseHandle(collapsed),
          ),
        ],
      ),
    );
  }

  /// 选项卡行（role=tablist「子群切换」；横向可滚，滚动条不画）。
  Widget _tabsRow(bool collapsed) {
    final int extra = widget.hasMore ? 1 : 0;
    return SizedBox(
      height: AylaGroupChatSubgroupBar.tabsMinHeight, // min-height: 40px
      child: SingleChildScrollView(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        // scrollbar 隐藏（::-webkit-scrollbar { display: none }）：Flutter 侧不装滚动条即无
        child: AylaNavHighlightList(
          itemCount: widget.subgroups.length + extra,
          selectedIndex: _selectedIndex,
          axis: Axis.horizontal, // 窄屏横滚 + ←→ 方向键
          gap: AylaSpacing.sp2, // gap: var(--sp-2)
          scrollController: _scroll,
          semanticLabel: '子群切换', // role=tablist aria-label
          onSelect: (int i) {
            if (i < widget.subgroups.length) {
              final AylaGroupChatSubgroupTab sg = widget.subgroups[i];
              if (sg.id == widget.activeId) return; // web switchSubgroup 提前 return
              widget.onSelect(sg);
            } else {
              widget.onLoadMore?.call();
            }
          },
          itemBuilder: (BuildContext context, AylaNavHighlightSlot slot) {
            if (slot.index < widget.subgroups.length) {
              return _subgroupTab(slot, widget.subgroups[slot.index], collapsed);
            }
            return _loadMoreTab(slot, collapsed);
          },
        ),
      ),
    );
  }

  /// 单个子群选项卡。
  Widget _subgroupTab(
    AylaNavHighlightSlot slot,
    AylaGroupChatSubgroupTab sg,
    bool collapsed,
  ) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return _tabShell(
      slot: slot,
      collapsed: collapsed,
      semanticLabel: sg.name, // role=tab 的可访问名
      selected: slot.active, // aria-selected
      enabled: !collapsed, // disabled={collapsed}
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: AylaSpacing.sp2, // gap: var(--sp-2)
        children: <Widget>[
          // .group-chat-subgroup-tab-name：max-width 120 + ellipsis
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              sg.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: t.label.copyWith(
                fontSize: 14, // font-size: 14px
                fontWeight: FontWeight.w600, // font-weight: 600
                color: slot.active
                    ? AylaColors.textPrimary
                    : AylaColors.textSecondary,
              ),
            ),
          ),
          if (sg.muted)
            AylaTooltip(
              // title「已禁言（仅群主/管理员可发言）」（GroupChat.tsx:389）
              message: '已禁言（仅群主/管理员可发言）',
              child: _mutedChip(),
            ),
          if (sg.unread > 0)
            Semantics(
              label: '\${sg.unread} 条未读', // aria-label「N 条未读」
              child: _unreadBadge(sg.unread),
            ),
        ],
      ),
    );
  }

  /// 「加载更多子群」键（普通 tab 档：**不带 has-auroraqua-highlight**，无胶囊）。
  Widget _loadMoreTab(AylaNavHighlightSlot slot, bool collapsed) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool loading = widget.loadingMore;
    final bool enabled = !collapsed && !loading;
    return _tabShell(
      slot: slot,
      collapsed: collapsed,
      semanticLabel: loading ? '加载中…' : '加载更多子群',
      selected: false,
      enabled: enabled,
      child: Text(
        loading ? '加载中…' : '加载更多子群',
        maxLines: 1,
        softWrap: false,
        style: t.label.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: AylaColors.textSecondary,
        ),
      ),
    );
  }

  /// 选项卡外壳：几何 + 状态底 + 手势/焦点/扫光接线（与 conversation_list 同款）。
  ///
  /// 底归胶囊（auroraqua 194–197）：选中项自身**透明**；非选中 hover → rgba(157,191,230,.18)。
  Widget _tabShell({
    required AylaNavHighlightSlot slot,
    required bool collapsed,
    required String semanticLabel,
    required bool selected,
    required bool enabled,
    required Widget child,
  }) {
    final bool active = slot.active;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: semanticLabel,
      child: Listener(
        onPointerDown: (_) => slot.onPressedChanged(true),
        onPointerUp: (_) => slot.onPressedChanged(false),
        onPointerCancel: (_) => slot.onPressedChanged(false),
        child: MouseRegion(
          cursor: enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: (_) {
            slot.onHoverChanged(true);
            // 扫光由**父级 hover** 驱动（auroraqua 161–166）：只有选中项被指到时直达高亮
            if (active) slot.onSweep(true);
          },
          onExit: (_) {
            slot.onHoverChanged(false);
            if (active) slot.onSweep(false);
          },
          child: Focus(
            focusNode: slot.focusNode,
            canRequestFocus: enabled, // tabIndex={−1} / disabled
            onKeyEvent: slot.onKey,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: enabled ? slot.onTap : null,
              child: _TabBackground(
                // 选中态自身底透明（底由容器级胶囊画）
                active: active,
                child: SizedBox(
                  height: 32, // height: 32px
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AylaSpacing.sp3, // padding: 0 var(--sp-3)
                    ),
                    child: Center(child: child),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 未读徽标（.group-chat-subgroup-tab-badge）。
  Widget _unreadBadge(int unread) {
    return Container(
      constraints: const BoxConstraints(minWidth: 16), // min-width: 16px
      height: 16,
      padding: const EdgeInsets.symmetric(horizontal: 4), // padding: 0 4px
      decoration: const BoxDecoration(
        color: AylaColors.pink500,
        borderRadius: AylaRadii.pill,
      ),
      alignment: Alignment.center,
      child: Text(
        unread > 99 ? '99+' : '$unread', // {unread > 99 ? "99+" : unread}
        style: const TextStyle(
          fontFamily: AylaFonts.display,
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 11,
          height: 16 / 11, // line-height: 16px
          color: Color(0xFFFFFAFB), // color: #fffafb
        ),
      ),
    );
  }

  /// 禁言 chip（.group-chat-subgroup-tab-muted，group.css 318–331）。
  Widget _mutedChip() {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 6,
        vertical: 1,
      ), // padding: 1px 6px
      decoration: const BoxDecoration(
        color: AylaColors.ice300,
        borderRadius: AylaRadii.pill,
      ),
      child: const Text(
        '禁言',
        style: TextStyle(
          fontFamily: AylaFonts.display,
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 10, // font-size: 10px
          height: 1.4, // line-height: 1.4
          color: AylaColors.indigo700,
        ),
      ),
    );
  }

  /// 折叠键（48×32 命中区；收起 = 上半圆把手 / 展开 = 32 圆形玻璃钮）。
  Widget _collapseHandle(bool collapsed) {
    return AylaTooltip(
      message: collapsed ? '展开子群' : '收起子群', // title：展开子群 / 收起子群
      child: Semantics(
        key: AylaGroupChatSubgroupBar.collapseHandleKey,
        button: true,
        expanded: !collapsed, // aria-expanded={!subgroupsCollapsed}
        label: collapsed ? '展开子群选项卡' : '收起子群选项卡', // aria-label
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _handleHovered = true),
          onExit: (_) => setState(() => _handleHovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggle,
            child: Stack(
              children: <Widget>[
                if (collapsed)
                  // ::before：36×18 · left 6 · bottom 0 · radius 18 18 0 0 · --glass-bg-strong
                  // （background 走 200ms transition：group.css 223）
                  Positioned(
                    left: 6,
                    bottom: 0,
                    width: 36,
                    height: 18,
                    child: AnimatedContainer(
                      duration: AylaDurations.button, // transition background 200ms
                      curve: AylaCurves.auroraqua, // var(--auroraqua-ease) = ease
                      decoration: BoxDecoration(
                        color: _handleHovered
                            ? const Color(0x599DBFE6) // rgba(157,191,230,.35)
                            : AylaColors.glassBgStrong, // --glass-bg-strong(.78)
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(18),
                        ),
                      ),
                    ),
                  ),
                // svg：收起 left 50% / bottom 2（translate −50% 0）
                // 48×32 命中区里 free = 32 − 14 = 18 ⇒ y = (32/2 − 2 − 14/2) / 9 = 7/9
                // 展开：::after 32 圆（left 8 top 0）在 48 命中区里水平居中 ⇒ 同样落 left 8
                Positioned.fill(
                  child: collapsed
                      ? Align(
                          alignment: const Alignment(0, 7 / 9),
                          child: _handleIcon(collapsed),
                        )
                      : Center(child: _expandedFace()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// IconChevronUp / IconChevronDown 14（收起态 / 展开态）。
  Widget _handleIcon(bool collapsed) => AylaIcon(
    aylaIconByName(collapsed ? 'iconChevronUp' : 'iconChevronDown')!,
    size: 14,
    color: _handleColor,
  );

  /// 展开态 ::after：32×32 正圆 · left 8 · top 0 · rgba(255,250,251,.6)
  /// （background 走 200ms transition：group.css 253）。
  Widget _expandedFace() {
    return AnimatedContainer(
      duration: AylaDurations.button, // transition background 200ms
      curve: AylaCurves.auroraqua,
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: _handleHovered
            ? const Color(0x2E9DBFE6) // rgba(157,191,230,.18)
            : const Color(0x99FFFAFB), // rgba(255,250,251,.6)
        shape: BoxShape.circle,
      ),
      child: Center(child: _handleIcon(false)),
    );
  }
}

/// 选项卡底/悬停色层（选中项自身透明 —— 底归容器级胶囊）。
class _TabBackground extends StatefulWidget {
  const _TabBackground({required this.child, required this.active});

  final Widget child;
  final bool active;

  @override
  State<_TabBackground> createState() => _TabBackgroundState();
}

class _TabBackgroundState extends State<_TabBackground> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // .group-chat-subgroup-tab { background: rgba(255,250,251,.6) }；
    // 选中项 transparent（auroraqua 194–197 后加载压过 :hover 规则）；
    // hover（非选中）→ rgba(157,191,230,.18)
    final Color color = widget.active
        ? Colors.transparent
        : (_hovered ? const Color(0x2E9DBFE6) : const Color(0x99FFFAFB));
    return MouseRegion(
      onEnter: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: AnimatedContainer(
        duration: AylaDurations.fast, // transition background 180ms ease-out（tab 档）
        curve: AylaCurves.easeOut,
        decoration: BoxDecoration(
          color: color,
          borderRadius: AylaRadii.pill, // auroraqua 190–192 覆写为 radius-pill
        ),
        child: widget.child,
      ),
    );
  }
}


// ======================= 样张 =======================

/// 群聊子群切换条样张。
///
/// 固定文案（「禁言」「加载更多子群」「加载中…」与 aria 文案）逐字取自 GroupChat.tsx；
/// 子群名与未读数是**运行期数据**，样张用库内既有示例名（与 post_card / post_editor 同源）。
Widget aylaGroupChatSubgroupBarSamples() => const _SubgroupBarSamples();

class _SubgroupBarSamples extends StatefulWidget {
  const _SubgroupBarSamples();

  @override
  State<_SubgroupBarSamples> createState() => _SubgroupBarSamplesState();
}

class _SubgroupBarSamplesState extends State<_SubgroupBarSamples> {
  static const List<AylaGroupChatSubgroupTab> _subgroups =
      <AylaGroupChatSubgroupTab>[
        AylaGroupChatSubgroupTab(id: 'all', name: '默认组'),
        AylaGroupChatSubgroupTab(id: 'sg-1', name: '星海观测站', unread: 3),
        AylaGroupChatSubgroupTab(id: 'sg-2', name: '深夜电台', muted: true),
        AylaGroupChatSubgroupTab(
          id: 'sg-3',
          name: '超长的子群名称用来验证单行省略',
          unread: 120,
        ),
      ];

  final TextEditingController _field = TextEditingController();
  String _activeId = 'all';
  bool _collapsed = true;
  int _selectCount = 0;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AylaSpacing.sp6),
      child: Wrap(
        spacing: AylaSpacing.sp6,
        runSpacing: AylaSpacing.sp6,
        crossAxisAlignment: WrapCrossAlignment.start,
        children: <Widget>[
          _stage(
            '收起态（默认；底沿只露 36×18 上半圆把手）· 点把手展开 · '
            'onSelect 触发次数：$_selectCount，当前子群：$_activeId',
            const AylaGroupChatSubgroupBar(
              subgroups: _subgroups,
              activeId: 'all',
              onSelect: _noop,
              collapsed: true,
            ),
          ),
          _stage(
            '展开态（role=tablist「子群切换」；选中胶囊 = AylaNavHighlight 300ms 迁移；'
            '未读徽标 / 禁言 chip / 长名省略 / 末尾「加载更多子群」）',
            AylaGroupChatSubgroupBar(
              subgroups: _subgroups,
              activeId: _activeId,
              collapsed: _collapsed,
              hasMore: true,
              onCollapsedChanged: (bool value) =>
                  setState(() => _collapsed = value),
              onSelect: (AylaGroupChatSubgroupTab sg) => setState(() {
                _activeId = sg.id;
                _selectCount++;
              }),
              onLoadMore: () => setState(() => _selectCount++),
            ),
          ),
          _stage(
            '展开态 · 加载更多中（「加载中…」且禁用；hasMore 为 false 时不渲染该键）',
            const AylaGroupChatSubgroupBar(
              subgroups: _subgroups,
              activeId: 'sg-2',
              onSelect: _noop,
              collapsed: false,
              hasMore: true,
              loadingMore: true,
            ),
          ),
        ],
      ),
    );
  }

  static void _noop(AylaGroupChatSubgroupTab sg) {}

  /// 舞台：375 宽窄屏宿主 + 模拟 .group-chat-compose-area（本件锚在它的上沿）。
  Widget _stage(String label, AylaGroupChatSubgroupBar bar) {
    return SizedBox(
      width: 420,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(label, style: AylaTextStyles.of(context).caption),
          const SizedBox(height: AylaSpacing.sp2),
          Builder(
            builder: (BuildContext ctx) => MediaQuery(
              data: MediaQuery.of(ctx).copyWith(size: const Size(375, 812)),
              child: SizedBox(
                width: 375,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    // 模拟输入区（web .group-chat-compose-area 的高度锚点）
                    AylaGlassSurface(
                      radius: AylaRadii.rCard,
                      padding: const EdgeInsets.all(AylaSpacing.sp3),
                      child: AylaGlassInput(
                        controller: _field,
                        hintText: '发消息…',
                        minHeight: 40,
                        semanticLabel: '发消息（样张模拟输入区）',
                      ),
                    ),
                    // 子群条：底边贴输入区上沿（web bottom: 100%）
                    Positioned(left: 0, right: 0, bottom: 72, child: bar),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
