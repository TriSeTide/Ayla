/// 资料卡与目录筛选（`UserProfileCard.tsx` + `DirectoryFilters.tsx`）。
///
/// 事实源见各段落注释。
library;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/buttons.dart' show AylaMsgActionButton;
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import 'avatar_halo.dart';
import 'dialogs.dart' show AylaModalOverlay;
import 'nav_highlight_list.dart'
    show AylaNavHighlightList, AylaNavHighlightListState, AylaNavHighlightSlot;
import 'reveal.dart';
import 'sidebar_card.dart';

// ======================= UserProfileCard =======================

/// 用户资料卡（`UserProfileCard.tsx` + search.css 304–361）。
///
/// ## 事实源
/// ```
/// .user-profile-overlay { fixed; inset:0; z-index:60; center;
///   background: rgba(70,91,146,.25) }             ← --overlay-dim
/// .user-profile-card { width: min(320px, 85vw); padding: var(--sp-6);
///   flex column; gap: var(--sp-4); --glass-filter; --glass-shadow-modal }
///   （另有 `glass-card` 类 → --glass-bg + 1px --glass-border + radius-card 16）
/// .user-profile-body { flex column; center; gap: var(--sp-2); text-align:center }
/// .user-profile-nick { font-display 20/600 --text-primary }
/// .user-profile-status { font-utility 12 --text-secondary }
/// .user-profile-signature { 13px --text-secondary; max-width: 260px }
/// .user-profile-error { 12px --destructive }
/// .user-profile-actions { flex; gap: var(--sp-2); justify-content:center }
/// ```
///
/// ## 行为（tsx）
/// - 头像 56（带光环，`online` 由 presence 决定）
/// - 昵称：`nickname || username`
/// - **加好友**（`btn-primary`）：busy 时文案「申请中…」且禁用
/// - **发消息**（`btn-ghost`）：busy 时「进入中…」且禁用
/// - 可选「关闭」（`msg-action-btn`）
/// - 失败显示 `error`（12px destructive）
class AylaUserProfileCard extends StatelessWidget {
  const AylaUserProfileCard({
    super.key,
    required this.nickname,
    this.username = '',
    this.signature,
    this.avatarUrl,
    this.online = false,
    this.displayStatus,
    this.error,
    this.friendBusy = false,
    this.chatBusy = false,
    this.onAddFriend,
    this.onSendMessage,
    this.onClose,
  });

  /// 昵称（空则用 [username]）。
  final String nickname;

  /// 用户名（昵称兜底）。
  final String username;

  /// 个性签名（可选）。
  final String? signature;

  /// 头像 URL。
  final String? avatarUrl;

  /// 是否在线（驱动光环）。
  final bool online;

  /// 展示状态文案（`useDisplayStatus`：在线/离线/群内活跃等）。
  final String? displayStatus;

  /// 错误文案。
  final String? error;

  /// 「加好友」进行中。
  final bool friendBusy;

  /// 「发消息」进行中。
  final bool chatBusy;

  /// 加好友回调。
  final VoidCallback? onAddFriend;

  /// 发消息回调。
  final VoidCallback? onSendMessage;

  /// 关闭回调（null 则不渲染关闭按钮）。
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final String name = nickname.isNotEmpty ? nickname : username;
    // ---------- 卡内容（padding sp6 / gap sp4） ----------
    final Widget body = Padding(
      padding: const EdgeInsets.all(AylaSpacing.sp6), // padding: var(--sp-6)
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: AylaSpacing.sp4, // gap: var(--sp-4)
        children: <Widget>[
          // ---------- .user-profile-body ----------
          Column(
            mainAxisSize: MainAxisSize.min,
            spacing: AylaSpacing.sp2, // gap: var(--sp-2)
            children: <Widget>[
              AylaAvatarHalo(
                label: name,
                size: 56, // <Avatar size={56} online={online} />
                online: online,
                resourceUrl: avatarUrl,
              ),
              Text(
                name,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: AylaFonts.display, // --font-display
                  fontFamilyFallback: AylaFonts.cjkFallback,
                  fontSize: 20, // font-size: 20px
                  fontWeight: FontWeight.w600, // font-weight: 600
                  color: AylaColors.textPrimary,
                ),
              ),
              if (displayStatus != null)
                Text(
                  displayStatus!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: AylaFonts.utility, // --font-utility
                    fontFamilyFallback: AylaFonts.cjkFallback,
                    fontSize: 12, // font-size: 12px
                    color: AylaColors.textSecondary,
                  ),
                ),
              if (signature != null && signature!.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260), // max-width
                  child: Text(
                    signature!,
                    textAlign: TextAlign.center,
                    style: t.caption.copyWith(
                      fontSize: 13, // font-size: 13px
                      color: AylaColors.textSecondary,
                    ),
                  ),
                ),
              if (error != null)
                Text(
                  error!,
                  textAlign: TextAlign.center,
                  style: t.caption.copyWith(
                    fontSize: 12, // font-size: 12px
                    color: AylaColors.destructive, // --destructive
                  ),
                ),
            ],
          ),
          // ---------- .user-profile-actions ----------
          Row(
            mainAxisAlignment: MainAxisAlignment.center, // justify-content: center
            spacing: AylaSpacing.sp2, // gap: var(--sp-2)
            children: <Widget>[
              // 加好友（`.btn.btn-primary`）：busy →「申请中…」
              // → 复用组件库 [AylaGlassButton]
              AylaGlassButton(
                label: friendBusy ? '申请中…' : '加好友',
                variant: AylaGlassButtonVariant.primary,
                onPressed: friendBusy ? null : onAddFriend,
              ),
              // 发消息（`.btn.btn-ghost`）：busy →「进入中…」
              AylaGlassButton(
                label: chatBusy ? '进入中…' : '发消息',
                variant: AylaGlassButtonVariant.ghost,
                onPressed: chatBusy ? null : onSendMessage,
              ),
              // 关闭（`.msg-action-btn`）
              if (onClose != null)
                AylaMsgActionButton(label: '关闭', onPressed: onClose),
            ],
          ),
        ],
      ),
    );

    // ---------- 卡面 → 复用组件库 [AylaGlassCard] ----------
    //
    // web：`.user-profile-card` 除 `glass-card`（--glass-bg + --glass-filter +
    // 1px --glass-border + radius-card 16）外，还覆盖 `box-shadow:
    // --glass-shadow-modal`（比默认 --glass-shadow 更强）→ 用 `shadow` 参数表达。
    final Widget card = ConstrainedBox(
      // width: min(320px, 85vw)
      constraints: BoxConstraints(
        maxWidth: (MediaQuery.of(context).size.width * 0.85).clamp(0, 320),
      ),
      child: AylaGlassCard(
        padding: EdgeInsets.zero, // padding 由 body 提供（sp6）
        radius: AylaRadii.rCard, // --radius-card 16
        shadow: AylaShadows.modal, // --glass-shadow-modal
        child: body,
      ),
    );

    // ---------- overlay → 复用组件库 [AylaModalOverlay] ----------
    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      child: AylaModalOverlay(
        // `.user-profile-overlay { background: var(--overlay-dim) }` + 居中
        onDismiss: onClose,
        padding: 0, // web 无 padding（卡宽已由 min(320,85vw) 控制）
        child: card,
      ),
    );
  }
}

// ======================= DirectoryFilters =======================

/// 目录筛选条（`DirectoryFilters.tsx` + directory-filters.css 22–130 / 221–258）。
///
/// ## 事实源
///
/// **容器（两形态）**
/// ```
/// 宽屏 .directory-filters {
///   flex column; align-self:stretch; gap: sp2; width:224px; flex:0 0 224px;
///   max-height:100%; margin: 0 0 sp3; padding: sp3;
///   overflow-y:auto; scroll-padding: sp3; overscroll-behavior: contain;
///   1px --glass-border; border-radius: var(--radius-card);   ← 玻璃卡片
///   --glass-bg; --glass-filter; --glass-shadow-compact;
///   animation: auroraqua-sidebar-in 300ms ease-out }         ← 左移 -20px 淡入
///
/// 窄屏(@max-768) .directory-filters {
///   flex-direction:row; width:100%; max-height:none; margin:0;
///   padding: sp2 sp3; overflow-x:auto; overscroll-behavior-x: contain;
///   border-width: 0 0 1px;      ← **只有下边框**
///   border-radius: 0;           ← **无圆角**
///   box-shadow: none;           ← **无阴影**
///   animation: auroraqua-panel-from-top 300ms ease-out }     ← 上移 -20px 淡入
/// ```
///
/// **选项卡 `.directory-filter`**
/// ```
/// flex; justify-content:flex-start; min-height:44px; padding: sp2 sp3;
/// border: 1px transparent; border-radius: var(--radius-input);  ← 12
/// --text-primary; 14/600; white-space: nowrap;
/// transition: background/border-color/box-shadow/scale 200ms
/// .is-active { background: transparent; border-color: --glass-border;
///              box-shadow: none }              ← 选中底**不由按钮画**
/// :hover  → background --ice-100 + border --glass-border
///           + --glass-shadow-nav + scale 1.02
/// :active → scale .98
/// :focus-visible → outline 2px --glow-500 + offset 2 + --glow-shadow
/// 窄屏：justify-content:center; min-width:44px; padding-inline: sp2
/// ```
///
/// **选中底**：`.auroraqua-nav-highlight { position:absolute; inset:0;
/// border-radius:inherit; z-index:-1 }`（tsx 每项各渲染一个 **同 id** 实例
/// ⇒ Framer layout 在两项间迁移 300ms）。
///
/// ## 本实现的要点
/// 1. **高亮必须铺满按钮**：web 的 `inset: 0` 相对**按钮本体**（border box），
///    而按钮有 `padding: sp2 sp3`。若把高亮画在**带 padding 的容器内部**，
///    它只能铺到 padding 内沿（**这是之前的 bug**）。故高亮由**容器级 Stack**
///    绘制、尺寸取**实测槽位矩形**（含 padding）。
/// 2. **迁移用 `AnimatedPositioned`**（B3 已验证的等价做法）：即 Framer
///    `layoutId` 的 Flutter 等价，300ms `--auroraqua-ease-out`。
/// 3. 容器材质一律走 [AylaGlassSurface]（不自行拼玻璃层）。
///
/// ## 行为（tsx）
/// - **键盘**：窄屏 ←/→、宽屏 ↑/↓ 循环；Home/End 跳首末；**方向键同时改选中值**
/// - **滚动揭示**：选中/聚焦项若在可视区外，**只滚动筛选条自身**（保留结果区
///   独立滚动位置），带 `scroll-padding` 补偿
/// - `aria-orientation` 随形态；`role=tablist` / 每项 `role=tab`
class AylaDirectoryFilters extends StatefulWidget {
  const AylaDirectoryFilters({
    super.key,
    required this.label,
    required this.options,
    required this.value,
    required this.onChange,
    this.narrow = false,
    this.leading,
    this.header,
    this.decor,
  });

  /// tablist 的 aria-label。
  final String label;

  /// 选项（key + 显示文案）。
  final List<({String key, String label})> options;

  /// 当前选中 key。
  final String value;

  /// 选中变化。
  final ValueChanged<String> onChange;

  /// 窄屏形态（横向顶栏）。
  final bool narrow;

  /// 宽屏侧栏左上角独立操作（返回键等）；窄屏不渲染。
  final Widget? leading;

  /// 侧栏标题/统计区；窄屏不渲染。
  final Widget? header;

  /// 仅装饰的侧栏图标；窄屏隐藏。
  final Widget? decor;

  /// 宽屏侧栏宽度（`flex: 0 0 224px`）。
  static const double sidebarWidth = 224;

  @override
  State<AylaDirectoryFilters> createState() => _AylaDirectoryFiltersState();
}

class _AylaDirectoryFiltersState extends State<AylaDirectoryFilters> {
  final ScrollController _scroll = ScrollController();

  /// 直达槽位列表 State（子项 onFocus → 滚动揭示；本件不再自持高亮测量）。
  final GlobalKey<AylaNavHighlightListState> _navKey =
      GlobalKey<AylaNavHighlightListState>();

  /// 当前选中项索引（-1 = 无）。
  int get _selectedIndex => widget.options
      .indexWhere((({String key, String label}) o) => o.key == widget.value);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);

    // ---------- 选项卡（不含任何底；底由容器级共享高亮绘制） ----------
    //
    // ⚠️ 高亮/迁移/按压/扫光/键盘/滚动揭示**全部**由公共件
    // [AylaNavHighlightList] 承担（2026-09-24 从本文件抽出 —— 用户点名
    // 「会话列表背景卡片、选中高亮、切换动画等应直接复用 DirectoryFilters 宽屏侧栏」
    // ⇒ 抽成公共件后 `AylaDirectoryFilters` 与会话列表共用同一份实现）。
    final Widget nav = AylaNavHighlightList(
      key: _navKey,
      itemCount: widget.options.length,
      selectedIndex: _selectedIndex,
      axis: widget.narrow ? Axis.horizontal : Axis.vertical,
      gap: AylaSpacing.sp2, // gap: sp2
      scrollController: _scroll,
      semanticLabel: widget.label, // role=tablist 的 aria-label
      // 方向键同时改变选中值（tsx onKeyDown 语义）
      onSelect: (int i) => widget.onChange(widget.options[i].key),
      itemBuilder: (BuildContext context, AylaNavHighlightSlot slot) => _FilterTab(
        focusNode: slot.focusNode,
        label: widget.options[slot.index].label,
        active: slot.active,
        narrow: widget.narrow,
        style: t,
        onKey: slot.onKey,
        // 聚焦揭示由公共件的 FocusNode listener 处理（等价 web 的 onFocus → reveal）
        onFocus: () {},
        onTap: slot.onTap,
        onSweep: slot.onSweep,
        onPressedChanged: slot.onPressedChanged,
        onHoverChanged: slot.onHoverChanged,
      ),
    );

    // ═══════════════ 窄屏（≤768）：无圆角顶栏 ═══════════════
    if (widget.narrow) {
      return AylaRevealItem(
        // animation: auroraqua-panel-from-top（0 -20px → 0,0）
        offset: const Offset(0, -20),
        child: AylaGlassSurface(
          // border-radius: 0 + border-width: 0 0 1px + box-shadow: none
          radiusOverride: BorderRadius.zero,
          borderOverride: const Border(
            bottom: BorderSide(color: AylaColors.glassBorder),
          ),
          shadow: const <BoxShadow>[], // box-shadow: none
          // 同宽屏：padding 放滚动视图内部，避免横向滚动裁剪掉 tab 的 hover 外阴影
          padding: null,
          child: SingleChildScrollView(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: AylaSpacing.sp3, // padding: sp2 sp3
              vertical: AylaSpacing.sp2,
            ),
            child: nav,
          ),
        ),
      );
    }

    // ═══════════════ 宽屏（>768）：玻璃卡片侧栏 ═══════════════
    // 容器材质/滚动/入场统一走公共件 [AylaSidebarCard]
    // （`.directory-page .directory-filters`：224 / `--glass-shadow-compact` /
    //  `auroraqua-sidebar-in` **300ms**；padding 归滚动内容承担的理由见该件文档）。
    return AylaSidebarCard(
      width: AylaDirectoryFilters.sidebarWidth, // flex: 0 0 224px
      shadow: AylaShadows.compact, // --glass-shadow-compact
      padding: const EdgeInsets.all(AylaSpacing.sp3), // padding: var(--sp-3)
      enterDuration: AylaDurations.auroraqua, // --auroraqua-duration 300ms
      scrollController: _scroll,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: AylaSpacing.sp2, // gap: sp2
        children: <Widget>[
          // leading / decor / header 仅宽屏渲染（窄屏 display:none）
          if (widget.leading != null) widget.leading!,
          if (widget.decor != null) widget.decor!,
          if (widget.header != null) widget.header!,
          nav,
        ],
      ),
    );
  }
}


/// `.directory-filter` —— 44 高选项卡。
///
/// **不含选中底**：底由 [AylaDirectoryFilters] 的容器级共享高亮绘制
/// （web 的 `is-active { background: transparent }`），这样高亮才能铺满
/// 按钮本体（含 padding）。
class _FilterTab extends StatefulWidget {
  const _FilterTab({
    required this.focusNode,
    required this.label,
    required this.active,
    required this.style,
    required this.onKey,
    required this.onFocus,
    required this.onTap,
    required this.onHoverChanged,
    required this.onSweep,
    required this.onPressedChanged,
    this.narrow = false,
  });

  final FocusNode focusNode;
  final String label;
  final bool active;
  final AylaTextStyles style;
  final KeyEventResult Function(FocusNode, KeyEvent) onKey;
  final VoidCallback onFocus;
  final VoidCallback onTap;

  /// **本 tab 被指到/离开且它就是选中项**时立即调用（直接驱动高亮扫光，
  /// 不经父级 rebuild，避免 1 帧延迟 —— 对齐 web `:hover` 的原生响应）。
  final ValueChanged<bool> onSweep;

  /// 按压态变化（供容器级高亮同步 `:active scale .98`）。
  final ValueChanged<bool> onPressedChanged;

  /// hover 状态上报（驱动容器级高亮的扫光）。
  final ValueChanged<bool> onHoverChanged;

  /// 窄屏：`justify-content:center; min-width:44px; padding-inline: sp2`。
  final bool narrow;

  @override
  State<_FilterTab> createState() => _FilterTabState();
}

class _FilterTabState extends State<_FilterTab> {
  bool _hovered = false;

  /// 按压（`:active { scale: .98 }`）。
  bool _pressed = false;

  /// 焦点（`:focus-visible → --glow-shadow`）。
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    // `.directory-filter { min-height:44px; padding: sp2 sp3;
    //   border: 1px transparent; border-radius: var(--radius-input) }`
    final BorderRadius r = BorderRadius.circular(AylaRadii.rInput);

    // `:hover → background: var(--ice-100)`；`:active/.is-active` 时
    // web 未给背景（.is-active 是 transparent，选中底由高亮层画）
    Widget tab = AnimatedContainer(
      // ⚠️ **选中态不给过渡**：web 的 `.has-auroraqua-highlight.is-active {
      // background: transparent }\` 是瞬时的 —— 选中底直接交还给共享胶囊；渐隐会让
      // 半透明底色与后方胶囊/玻璃混色成灰（实测「出现和消失有一段
      // 灰色过渡，拖沓很脏」）。未选中态（hover 底色）保留 200ms。
      duration: widget.active
          ? Duration.zero
          : const Duration(milliseconds: 200), // transition 200ms
      curve: AylaCurves.auroraqua,
      constraints: BoxConstraints(
        minHeight: 44, // min-height: 44px
        minWidth: widget.narrow ? 44 : 0, // 窄屏：min-width: 44px
      ),
      padding: EdgeInsets.symmetric(
        // 窄屏：padding-inline: sp2；宽屏：padding: sp2 sp3
        horizontal: widget.narrow ? AylaSpacing.sp2 : AylaSpacing.sp3,
        vertical: AylaSpacing.sp2,
      ),
      decoration: BoxDecoration(
        // ── hover 事实源（directory-filters.css 118–142 + auroraqua.css 194）──
        //
        // :hover → background: var(--ice-100) / border-color: --glass-border
        //          / box-shadow: --glass-shadow-nav / scale: 1.02
        // .has-auroraqua-highlight:is(.is-active,.active) {
        //   background: transparent; box-shadow: none }   ← 取消**选中项自身**的底
        //
        // **只有 background / box-shadow 被取消，border 与 scale 仍然生效**。
        // 且 hover 的特异性 `(0,3,0)` > `.has-auroraqua-highlight:is(...)` 的
        // `(0,2,0)` ⇒ **选中项 hover 时 `--glass-shadow-nav` 照样出现**。
        //
        // ⚠️ **零透明必须用同色相**，不能用 `Colors.transparent`：
        // `Colors.transparent` = `0x00000000`（**透明黑**）。Flutter 的
        // `Color.lerp` 是**逐通道直插**（`painting.dart` 424–457：alpha/red/
        // green/blue 各自 lerp，**不按 alpha 加权**）→ 从透明黑插到 `#ECF0F2`
        // 的中途 (t=.3) 是 `rgb(71,72,73)` 半透明 **深灰**，t=.5 是 `rgb(118,120,121)`
        // **中灰** → 悬停/按压瞬间闪一下灰色。
        // CSS 用 **premultiplied alpha** 插值（色相不变、只变不透明），故 web 无此现象。
        // 修法：用**同色相零透明**，插值全程色相一致。
        color: _hovered && !widget.active
            ? AylaColors.ice100 // :hover → var(--ice-100)；选中项由胶囊画底
            : AylaColors.ice100.withValues(alpha: 0), // 同色相零透明（非透明黑）
        borderRadius: r,
        border: Border.all(
          // is-active / hover → border-color: var(--glass-border)
          color: widget.active || _hovered
              ? AylaColors.glassBorder
              // 同色相零透明（避免白→灰→白 的插值闪灰）
              : AylaColors.glassBorder.withValues(alpha: 0),
        ),
        // hover → --glass-shadow-nav（选中项也生效：特异性更高）
        //
        // ⚠️ **不能用 `boxShadow:`**：Flutter 的 `BoxShadow` 会把阴影**铺满整个
        // 形状含内部**，而 CSS 规范规定 `box-shadow` **不在 border-box 内部绘制**。
        // `--glass-shadow-nav` = `0 0 8px rgba(157,191,230,.3)`（冰蓝）+ `--glass-inset`
        // → 裸用 `boxShadow` 会让冰蓝染进按钮内部，**悬停非高亮项时闪一下蓝色**。
        // 故阴影改由下方 `AylaGlassShadow.ring` 单独绘制（只画形状之外）。
        boxShadow: null,
      ),
      child: Align(
        // 窄屏 `justify-content: center`；宽屏 `flex-start`
        alignment: widget.narrow ? Alignment.center : Alignment.centerLeft,
        child: Text(
          widget.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis, // white-space: nowrap
          style: widget.style.label.copyWith(
            fontSize: 14, // font-size: 14px
            fontWeight: FontWeight.w600, // font-weight: 600
            color: AylaColors.textPrimary,
          ),
        ),
      ),
    );

    // hover → `--glass-shadow-nav`：**只画形状之外**（见上方 boxShadow 注释）。
    //
    // 用 `AylaGlassShadow.ring` 而非 `boxShadow`，因为 Flutter 的 `BoxShadow`
    // 在 blurRadius 从 0 起插值时是个**实心矩形**（blur=0 ⇒ 不模糊 ⇒ 铺满形状），
    // 冰蓝会整块闪现在按钮内部 —— 这正是"悬停瞬间闪一下蓝色"的根因。
    // ring 把形状内部挖空，无论 blur 多小都不会染色。
    //
    // `transition: box-shadow 200ms var(--auroraqua-ease)` → 用 AnimatedOpacity
    // 淡入淡出（opacity 0 时 Flutter 的 RenderOpacity 会跳过绘制，无额外开销）。
    tab = Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200), // transition 200ms
              curve: AylaCurves.auroraqua,
              opacity: _hovered ? 1.0 : 0.0,
              child: AylaGlassShadow.ring(radius: r, shadows: AylaShadows.nav),
            ),
          ),
        ),
        tab,
      ],
    );

    // `:hover → scale: 1.02`；`:active → scale: .98`（200ms --auroraqua-ease）
    tab = AnimatedScale(
      duration: const Duration(milliseconds: 200),
      curve: AylaCurves.auroraqua,
      scale: _pressed ? 0.98 : (_hovered ? 1.02 : 1.0),
      child: tab,
    );

    // `:focus-visible → box-shadow: var(--glow-shadow)`（描边由 outline 表达）——
    // 只画形状之外 + 200ms 淡入淡出（2026-09-20 审查 R2：原 DecoratedBox 裸阴影
    // 会把辉光铺进按钮内部）
    tab = AylaGlassShadow.fadeRing(
      radius: r,
      shadows: AylaShadows.glow,
      visible: _focused,
      duration: AylaDurations.button,
      child: tab,
    );

    return Semantics(
      button: true,
      selected: widget.active,
      label: widget.label,
      child: Focus(
        focusNode: widget.focusNode,
        onKeyEvent: widget.onKey,
        onFocusChange: (bool f) {
          setState(() => _focused = f);
          if (f) widget.onFocus();
        },
        child: MouseRegion(
          onEnter: (_) {
            setState(() => _hovered = true);
            // ⚠️ **本 tab 就是选中项时，直接在此处启动扫光** ——
            // 不走父级 setState/rebuild 往返（那会多 1 帧延迟）。
            // web 的 `:hover` 由浏览器合成器原生响应（0 帧），
            // 而 Dart 的「通知父级 → 父级 rebuild → 子级才 forward()」
            // 需要 2 帧（实测 32ms），手感明显滞后。
            if (widget.active) widget.onSweep(true);
            widget.onHoverChanged(true);
          },
          onExit: (_) {
            setState(() {
              _hovered = false;
              _pressed = false;
            });
            if (widget.active) widget.onSweep(false);
            widget.onHoverChanged(false);
          },
          child: Listener(
            onPointerDown: (_) {
              setState(() => _pressed = true);
              widget.onPressedChanged(true);
            },
            onPointerUp: (_) {
              setState(() => _pressed = false);
              widget.onPressedChanged(false);
            },
            onPointerCancel: (_) {
              setState(() => _pressed = false);
              widget.onPressedChanged(false);
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: tab,
            ),
          ),
        ),
      ),
    );
  }
}

// ======================= 样张 =======================


/// 可交互样张：点击/键盘切换选项卡，高亮 300ms 迁移（**不是静态摆拍**）。
class _DirectoryFiltersDemo extends StatefulWidget {
  const _DirectoryFiltersDemo();

  @override
  State<_DirectoryFiltersDemo> createState() => _DirectoryFiltersDemoState();
}

class _DirectoryFiltersDemoState extends State<_DirectoryFiltersDemo> {
  /// 宽屏侧栏选中项（点击切换）。
  String _wideValue = 'posts';

  /// 窄屏顶栏选中项（点击切换）。
  String _narrowValue = 'groups';

  static const List<({String key, String label})> opts =
      <({String key, String label})>[
    (key: 'all', label: '全部'),
    (key: 'users', label: '用户'),
    (key: 'groups', label: '群聊'),
    (key: 'posts', label: '帖子'),
    (key: 'live', label: '直播间'),
    (key: 'games', label: '桌游室'),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp4),
    child: Wrap(
      spacing: AylaSpacing.sp4,
      runSpacing: AylaSpacing.sp4,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        // 宽屏侧栏形态
        SizedBox(
          height: 400,
          child: AylaDirectoryFilters(
            label: '搜索结果分类',
            options: opts,
            value: _wideValue, // 可交互：点击/键盘切换
            onChange: (String v) => setState(() => _wideValue = v),
            header: Column(
              spacing: 2,
              children: <Widget>[
                Text('SEARCH', style: TextStyle(
                  fontFamily: 'Fredoka', fontSize: 10, fontWeight: FontWeight.w600,
                  letterSpacing: 1.4, color: AylaColors.pink500)),
                const Text('搜索结果', style: TextStyle(
                  fontFamily: 'Fredoka', fontSize: 16, fontWeight: FontWeight.w600,
                  color: AylaColors.textPrimary)),
              ],
            ),
          ),
        ),
        // 窄屏顶栏形态（无圆角、只下边框、无阴影）
        SizedBox(
          width: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AylaDirectoryFilters(
                label: '搜索结果分类（窄屏顶栏）',
                options: opts,
                value: _narrowValue, // 可交互：点击/←→ 切换
                narrow: true,
                onChange: (String v) => setState(() => _narrowValue = v),
              ),
              const SizedBox(height: 8),
              const Text(
                '窄屏：无圆角顶栏（只下边框）+ 横向滚动 + ←/→ 导航',
                style: TextStyle(fontSize: 11),
              ),
              const SizedBox(height: 6),
              // 下方内容区（验证顶栏与内容的衔接）
              Container(
                height: 120,
                alignment: Alignment.center,
                child: const Text('内容区', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ),
      ],
    ),
    );
  }
}
