/// live 域第三批（B2-3）：直播间封面侧栏 + 开播选择器。
///
/// ## 事实源（逐条对应 web，禁自由发挥）
/// ```
/// components/live/LiveChannelRail.tsx  168 行（nav 壳 / 操作区 / 封面列表 / 新建区 / 自动滚到当前项）
/// components/live/LiveStartSheet.tsx   86 行（开播入口：选已有直播间 or 新建）
/// live.css 311–326    .live-rail：flex none · width 240 · column · --glass-bg · blur24 sat1.4 ·
///                     1px 亮边 · radius 16 · --glass-shadow · margin 12 · min-height 0
/// live.css 10–12/22–29 .live-room-body.is-wide > .live-rail 入场 auroraqua-sidebar-in（500ms 左入；
///                     reduced-motion 关闭）
/// auroraqua.css 412–454（≤768）  .live-rail { width: min(240px, calc(100vw - 48px)) }
/// auroraqua.css 202–205 .live-rail.is-panel-motion { animation: none; translate: none }
///                     （窄屏覆盖层的从右入场由 Framer/调用方持有）
/// live.css 327–353    .live-rail-actions：min-height 54（与顶栏等高）· padding sp2 sp3 ·
///                     border-bottom 1px；.live-rail-icon-btn 36×36 pill
/// auroraqua.css 125–139  图标钮并入按钮组（玻璃材质 + button 阴影 + hover→button-hover），
///                     但**不在**扫光组（142–148）
/// live.css 355–363    .live-rail-list：flex 1 · min-height 0 · overflow-y auto · gap sp2 · padding sp3
/// live.css 232–239    wrap 相对定位 · .live-rail-del-btn（absolute right/top 4 · 22×22 · pill ·
///                     rgba(255,250,251,.72) · destructive · opacity 0→hover/focus 1 · disabled .4）
///                     · .live-rail-create（padding sp2 sp3 + border-top）· create-btn（1px dashed ice-500）
/// live.css 365–384    .live-rail-item：row · center · gap sp2 · padding sp2 · radius-input ·
///                     color secondary；hover → rgba(157,191,230,.18)；.is-active → .35（**被
///                     auroraqua 194–197 清零**，选中态由高亮元素提供）；过渡 background 180ms
/// live.css 386–409    .live-rail-cover：72 宽 · 16/9 · radius-input · 1px 亮边 · ice-500 图标；
///                     .live-rail-live-dot 8×8 pink-500 top/right 4
/// live.css 411–423    .live-rail-item-title：flex 1 · min-width 0 · 13/1.35 · 左对齐 ·
///                     color inherit · **-webkit-line-clamp: 2**
/// live.css 1356–1370  .live-rail-viewers：gap 2 · utility 11 · ls .3 · lh 1 · secondary（active→primary）
/// auroraqua.css 175–187  .auroraqua-nav-highlight：absolute inset 0 · radius inherit ·
///                     --nav-active-bg 渐变 · --glass-shadow-nav · 1px 亮边（**裸变体**，非 --rail 竖条）
/// live.css 48–139     .live-start-*（开播选择器全量，见各段落）
/// vitest/live-rail.test.tsx  官方用例（宽屏/收起态/窄屏覆盖层/自动滚动/开播控制台扩展/开播选择器）
/// ```
///
/// ## 与 web 的装配差异（组件不写页面）
/// - 数据（本人直播间列表 + WS 热更新合并排序）由页面投影：web 的 `useOwnedLiveDirectory` /
///   `listLiveChannelsPage` 属数据层；
/// - 窄屏覆盖层的**遮罩与定位**属 `LiveRoomBody`（`.live-room-rail-overlay` / `-rail-mask`），
///   本件只接受 [AylaLiveChannelRail.enterFromRight] 的入场档；
/// - 目录分页用 [AylaLiveChannelRail.directoryFooter] 槽注入（web 是 `<li><DirectoryLoadMore/></li>`）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/css_gradient.dart';
import '../theme/buttons.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/sample_media.dart' show aylaEnableSampleMedia;
import '../theme/tokens.dart';
import 'create_sheet.dart';
import 'dashed_border.dart';
import 'directory_controls.dart' show AylaDirectoryLoadMore;
import 'live_hall.dart'
    show
        AylaLiveCardData,
        AylaLiveStatus,
        aylaFormatViewerCount,
        aylaLiveViewerBadge;
import 'primitives.dart' show AylaNavHighlight, AylaNavHighlightState;
import 'resource_image.dart';
import 'reveal.dart';

/// `.live-rail` —— 直播间封面侧栏（`LiveChannelRail.tsx` 168 行）。
class AylaLiveChannelRail extends StatefulWidget {
  const AylaLiveChannelRail({
    super.key,
    required this.channels,
    required this.currentId,
    required this.onSelect,
    this.collapsed = false,
    this.onToggle,
    this.onBack,
    this.showBack = true,
    this.onDeleteChannel,
    this.onCreateNewChannel,
    this.deletingChannelId,
    this.enterFromRight = false,
    this.directoryFooter,
  });

  /// 频道列表（web `LiveChannelDescriptor[]`；此处用大厅同款投影）。
  final List<AylaLiveCardData> channels;

  /// 当前直播间 id。
  final String currentId;

  /// 切换直播间。
  final ValueChanged<String> onSelect;

  /// 宽屏收起态（**整个组件不渲染**；返回/展开键由顶栏承载，tsx 76–79）。
  final bool collapsed;

  /// 收起/展开切换（宽屏）；窄屏覆盖层用它关闭。
  final VoidCallback? onToggle;

  /// 返回（窄屏覆盖层 showBack=false 时不渲染）。
  final VoidCallback? onBack;

  /// 是否渲染返回键（宽屏 true）。
  final bool showBack;

  /// 每项删除键（仅开播控制台提供；null = 不渲染）。
  final ValueChanged<String>? onDeleteChannel;

  /// 底部「新建直播间」（仅开播控制台提供；null = 不渲染）。
  final VoidCallback? onCreateNewChannel;

  /// 正在删除的频道 id（该项禁用）。
  final String? deletingChannelId;

  /// 窄屏覆盖层：从右入场（`panelVariants(right)` 语义）。
  final bool enterFromRight;

  /// 列表末尾的目录分页槽（web `<li><DirectoryLoadMore/></li>`）。
  final Widget? directoryFooter;

  @override
  State<AylaLiveChannelRail> createState() => _AylaLiveChannelRailState();
}

class _AylaLiveChannelRailState extends State<AylaLiveChannelRail> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _contentKey = GlobalKey();
  final GlobalKey<AylaNavHighlightState> _highlightKey =
      GlobalKey<AylaNavHighlightState>();
  final Map<String, GlobalKey> _slotKeys = <String, GlobalKey>{};

  /// 选中高亮矩形（**相对滚动内容**的坐标系 ⇒ 滚动不影响它，与 web 的高亮在 item 内同义）。
  Rect? _highlightRect;

  /// 指针所在行 id（web：`.has-auroraqua-highlight:hover > .auroraqua-nav-highlight::after`）。
  String? _hoveredId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureHighlight();
      _scrollToCurrent();
    });
  }

  @override
  void didUpdateWidget(covariant AylaLiveChannelRail old) {
    super.didUpdateWidget(old);
    if (old.currentId != widget.currentId) {
      // 切台：**本帧内**就把高亮目标移到新槽位。槽位矩形在切台时不变化 ⇒ 用上一帧几何是安全的；
      // 赋值即可（build 紧随其后，无需 setState）。
      // ⚠️ 若只靠 postFrame 重测，会白白多等一帧才启动 300ms 迁移
      // （探针实测：+400ms 未动、+800ms 才到位）。
      _highlightRect = _slotRect(widget.currentId) ?? _highlightRect;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
    }
    if (old.channels.length != widget.channels.length ||
        old.collapsed != widget.collapsed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _measureHighlight();
        _scrollToCurrent();
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  GlobalKey _slotKey(String id) =>
      _slotKeys.putIfAbsent(id, () => GlobalKey(debugLabel: 'live-rail-$id'));

  /// 槽位矩形（**滚动内容坐标系**——滚动不改变它，与 web 的高亮在 item 内同义）。
  Rect? _slotRect(String id) {
    final RenderObject? content = _contentKey.currentContext?.findRenderObject();
    final RenderObject? slot =
        _slotKeys[id]?.currentContext?.findRenderObject();
    if (content is! RenderBox || slot is! RenderBox) return null;
    return slot.localToGlobal(Offset.zero, ancestor: content) & slot.size;
  }

  /// 量选中槽位矩形并驱动高亮迁移。
  void _measureHighlight() {
    if (!mounted) return;
    final Rect? rect = _slotRect(widget.currentId);
    if (rect == null || rect == _highlightRect) return;
    setState(() => _highlightRect = rect);
  }

  /// 把当前项滚进可视区 —— **CSS `scrollIntoView({ block: "nearest" })` 的显式等价**。
  ///
  /// ⚠️ 为什么不用 `Scrollable.ensureVisible`：它的 `keepVisibleAtEnd/Start` 是**单向**的
  /// （只在目标超出对应那一侧时才动），没有「哪边近就贴哪边」的组合；`explicit` 又会无条件
  /// 把目标对齐到给定 edge、**打断用户手动滚动**。这里按 CSS 语义显式判定：
  /// 目标已在可视区 ⇒ **一行不动**；在上方 ⇒ 顶对齐；在下方 ⇒ 底对齐。
  /// `prefers-reduced-motion` → 瞬时跳转（对应 `behavior: "auto"`）。
  void _scrollToCurrent() {
    if (!mounted || widget.collapsed) return;
    if (!_scroll.hasClients) return;
    final ScrollPosition pos = _scroll.position;
    // 首帧 layout 之前 viewportDimension / pixels 不可读（Null check operator 陷阱，见 skill）
    if (!pos.hasViewportDimension || !pos.hasPixels) return;
    final BuildContext? slotCtx = _slotKeys[widget.currentId]?.currentContext;
    final RenderObject? viewport =
        pos.context.storageContext.findRenderObject();
    final RenderObject? slot = slotCtx?.findRenderObject();
    if (viewport is! RenderBox || slot is! RenderBox) return;
    // **视口相对**测量（内容坐标系含列表 padding，直接用会差一个 padding：实测末项差 1px 露头）
    final double top = slot.localToGlobal(Offset.zero, ancestor: viewport).dy;
    final double bottom = top + slot.size.height;
    final double target;
    if (top < 0) {
      target = pos.pixels + top; // 上方超出 → 顶对齐
    } else if (bottom > pos.viewportDimension) {
      target = pos.pixels + bottom - pos.viewportDimension; // 下方超出 → 底对齐
    } else {
      return; // 已可见：不动（不打断手动滚动）
    }
    final double clamped = target.clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) {
      pos.jumpTo(clamped);
    } else {
      pos.animateTo(
        clamped,
        duration: AylaDurations.auroraqua, // web `behavior:"smooth"` 无显式时长 ⇒ 库内统一 300ms
        curve: AylaCurves.auroraquaEaseOut,
      );
    }
  }

  /// 点击选中项时「挂载即命中」：扫光直达（web 该帧已 `translateX(120%)`，不产生过渡）。
  void _jumpSweep() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _highlightKey.currentState?.setSweep(true, jump: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    // 收起态：整个组件不渲染（返回/展开键移到顶栏；`.live-rail-float` 是死 CSS，不复刻）
    if (widget.collapsed) return const SizedBox.shrink();

    final bool narrow = Breakpoint.isNarrow(MediaQuery.sizeOf(context).width);
    // ≤768：`width: min(240px, calc(100vw - 48px))`（auroraqua 412–454）
    final double width = narrow
        ? math.min(
            _railWidth,
            MediaQuery.sizeOf(context).width - 48,
          )
        : _railWidth;

    final Widget rail = Container(
      // `width: 240`（窄屏 min(240, vw-48)）+ `margin: 12`
      // ⚠️ 必须用 UnconstrainedBox 松掉父级的**横向**紧约束：`SizedBox(width:)` 内部的
      // `constraints.enforce` 会把宽度夹回父级给的 tight 值（实测放进 420 宽的紧约束宿主里
      // 变成 420-24），而 CSS 的 `width` 是压过父级拉伸的。竖向仍受父级约束
      //（web 的 flex 行默认 `align-items: stretch` ⇒ 侧栏拉满高度）。
      width: width,
      margin: const EdgeInsets.all(AylaSpacing.sidebarGutter),
      child: GlassSurface(
        // `.live-rail`：--glass-bg / blur24 sat1.4 / 1px 亮边 / radius 16 / --glass-shadow
        radiusOverride: BorderRadius.all(Radius.circular(AylaRadii.rCard)),
        blur: AylaGlass.blurCard,
        shadow: AylaShadows.glass,
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _actions(),
            Expanded(child: _list()),
            if (widget.onCreateNewChannel != null) _create(),
          ],
        ),
      ),
    );

    final Widget content = widget.enterFromRight
        ? AylaRevealItem(
            // 窄屏覆盖层：从右入场（auroraqua 202–205 已关掉 CSS 侧的左侧入场动画）
            offset: const Offset(20, 0),
            child: rail,
          )
        : rail;
    return UnconstrainedBox(
      constrainedAxis: Axis.vertical,
      alignment: Alignment.topLeft,
      child: content,
    );
  }

  /// `.live-rail-actions`（tsx 85–107 + live.css 327–353）。
  Widget _actions() {
    return Container(
      constraints: const BoxConstraints(minHeight: _actionsMinHeight), // 与顶栏等高对齐
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp3,
        vertical: AylaSpacing.sp2,
      ),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AylaColors.glassBorder)),
      ),
      child: Row(
        spacing: AylaSpacing.sp2, // gap: var(--sp-2)
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          if (widget.showBack)
            AylaIconButton(
              icon: AylaIcon(aylaIconByName('iconBack')!, size: 18),
              size: 36, // `.live-rail-icon-btn { width/height: 36px }`
              semanticLabel: '返回',
              onPressed: widget.onBack,
            ),
          AylaIconButton(
            icon: AylaIcon(aylaIconByName('iconChevronLeft')!, size: 18),
            size: 36,
            semanticLabel: '收起直播间列表',
            onPressed: widget.onToggle,
          ),
        ],
      ),
    );
  }

  /// `.live-rail-list`（live.css 355–363）：滚动内容 + 容器级单实例高亮。
  Widget _list() {
    return SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.all(AylaSpacing.sp3), // padding: var(--sp-3)
      child: Stack(
        key: _contentKey,
        children: <Widget>[
          // 高亮在**滚动内容内**（web 里它是 item 的子元素）⇒ 随内容滚动、坐标不随滚动变化
          if (_highlightRect case final Rect rect)
            AnimatedPositioned(
              // 跨项迁移 300ms（等价 Framer `layoutId` 投影）
              duration: AylaDurations.auroraqua,
              curve: AylaCurves.auroraquaEaseOut,
              left: rect.left,
              top: rect.top,
              width: rect.width,
              height: rect.height,
              child: AylaNavHighlight(
                key: _highlightKey,
                radiusValue: BorderRadius.circular(
                  AylaRadii.rInput,
                ), // `border-radius: inherit`（item 是 radius-input）
                sweep: true,
                sweepActive: _hoveredId == widget.currentId,
              ),
            ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: AylaSpacing.sp2, // gap: var(--sp-2)
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final AylaLiveCardData channel in widget.channels)
                _RaiseSlot(
                  key: _slotKey(channel.id),
                  child: _RailItem(
                    channel: channel,
                    active: channel.id == widget.currentId,
                    deleting: channel.id == widget.deletingChannelId,
                    onSelect: () {
                      _jumpSweep();
                      widget.onSelect(channel.id);
                    },
                    onDelete: widget.onDeleteChannel == null
                        ? null
                        : () => widget.onDeleteChannel!(channel.id),
                    onHoverChanged: (bool hovered) {
                      if (hovered) {
                        setState(() => _hoveredId = channel.id);
                      } else if (_hoveredId == channel.id) {
                        setState(() => _hoveredId = null);
                      }
                    },
                  ),
                ),
              if (widget.directoryFooter case final Widget footer) footer,
            ],
          ),
        ],
      ),
    );
  }

  /// `.live-rail-create`（tsx 158–165 + live.css 237–239）。
  Widget _create() {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp3,
        vertical: AylaSpacing.sp2,
      ),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AylaColors.glassBorder)),
      ),
      child: Semantics(
        button: true,
        label: '新建直播间',
        child: _CreateButton(onTap: widget.onCreateNewChannel!),
      ),
    );
  }

  /// `.live-rail { width: 240px }`。
  static const double _railWidth = 240;

  /// `.live-rail-actions { min-height: 54px }`（与直播顶栏 `.live-room-head` 等高对齐）。
  static const double _actionsMinHeight = 54;
}

/// 槽位包装：只给 `GlobalKey` 用（不改变布局）。
class _RaiseSlot extends StatelessWidget {
  const _RaiseSlot({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// `.live-rail-item-wrap` + `.live-rail-item` + 删除键（tsx 114–153）。
class _RailItem extends StatefulWidget {
  const _RailItem({
    required this.channel,
    required this.active,
    required this.deleting,
    required this.onSelect,
    required this.onDelete,
    required this.onHoverChanged,
  });

  final AylaLiveCardData channel;
  final bool active;
  final bool deleting;
  final VoidCallback onSelect;
  final VoidCallback? onDelete;
  final ValueChanged<bool> onHoverChanged;

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final AylaLiveCardData channel = widget.channel;
    final int? viewers = aylaLiveViewerBadge(channel.status, channel.viewerCount);
    // `.live-rail-item { color: var(--text-secondary) }`；`.is-active { color: var(--text-primary) }`
    final Color rowColor =
        widget.active ? AylaColors.textPrimary : AylaColors.textSecondary;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        setState(() => _hovered = true);
        widget.onHoverChanged(true);
      },
      onExit: (_) {
        setState(() => _hovered = false);
        widget.onHoverChanged(false);
      },
      child: Stack(
        children: <Widget>[
          GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSelect,
        child: Semantics(
          button: true,
          selected: widget.active,
          label: '切换到直播间 ${channel.title}', // tsx 120
          child: Container(
            padding: const EdgeInsets.all(AylaSpacing.sp2), // padding: var(--sp-2)
            decoration: BoxDecoration(
              // hover → rgba(157,191,230,.18)；选中项**自身底色透明**
              // （auroraqua 194–197 把 `.is-active` 的 .35 清零，选中态交给高亮元素）
              color: (_hovered && !widget.active)
                  ? AylaColors.ice500.withValues(alpha: 0.18)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(AylaRadii.rInput),
            ),
            child: Row(
              spacing: AylaSpacing.sp2, // gap: var(--sp-2)
              children: <Widget>[
                _cover(),
                Expanded(
                  child: Text(
                    channel.title,
                    // `.live-rail-item-title`：13 / 1.35 / 左对齐 / **2 行截断**
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: AylaFonts.body,
                      fontFamilyFallback: AylaFonts.cjkFallback,
                      fontSize: 13,
                      height: 1.35,
                      color: rowColor,
                    ),
                  ),
                ),
                if (viewers != null) _viewers(t, viewers, rowColor),
              ],
            ),
          ),
        ),
          ),
          // `.live-rail-del-btn`：右 4 / 上 4；整行 hover 或自身 focus 才显形
          if (widget.onDelete case final VoidCallback remove)
            Positioned(
              top: 4,
              right: 4,
              child: _RailDeleteButton(
                visible: _hovered,
                deleting: widget.deleting,
                onPressed: remove,
                label: '删除直播间 ${channel.title}',
              ),
            ),
        ],
      ),
    );
  }

  /// `.live-rail-cover`（live.css 386–409）。
  Widget _cover() {
    final String? cover = widget.channel.cover;
    return SizedBox(
      width: _coverWidth, // 72
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AylaRadii.rInput),
            border: Border.all(color: AylaColors.glassBorder),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AylaRadii.rInput),
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: cover == null
                      ? Center(
                          child: AylaIcon(
                            aylaIconByName('iconVideo')!,
                            size: 18, // tsx 127：`IconVideo 18`
                            color: AylaColors.ice500,
                          ),
                        )
                      : ResourceImage(
                          src: cover,
                          alt: '',
                          fit: BoxFit.cover,
                          // 装饰图：失败只回退图标（tsx 125 `fallback={<IconVideo 18/>}`）
                          fallback: Center(
                            child: AylaIcon(
                              aylaIconByName('iconVideo')!,
                              size: 18,
                              color: AylaColors.ice500,
                            ),
                          ),
                        ),
                ),
                if (widget.channel.status == AylaLiveStatus.live)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Semantics(
                      label: '直播中', // tsx 130
                      child: Container(
                        width: 8, // `.live-rail-live-dot`：8×8 / pink-500
                        height: 8,
                        decoration: const BoxDecoration(
                          color: AylaColors.pink500,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// `.live-rail-viewers`（live.css 1356–1370）。
  Widget _viewers(AylaTextStyles t, int viewers, Color color) {
    final TextStyle style = TextStyle(
      fontFamily: AylaFonts.utility, // utility 11 / ls .3 / lh 1
      fontFamilyFallback: AylaFonts.cjkFallback,
      fontSize: 11,
      letterSpacing: 0.3,
      height: 1,
      color: color,
    );
    return Semantics(
      label: '$viewers 人在看', // tsx 135
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 2, // gap: 2px
        children: <Widget>[
          AylaIcon(aylaIconByName('iconUsers')!, size: 11, color: color),
          Text(aylaFormatViewerCount(viewers), style: style),
        ],
      ),
    );
  }

  /// `.live-rail-cover { width: 72px }`。
  static const double _coverWidth = 72;
}

/// `.live-rail-del-btn`（live.css 233–236）：整行 hover 才显形。
class _RailDeleteButton extends StatefulWidget {
  const _RailDeleteButton({
    required this.visible,
    required this.deleting,
    required this.onPressed,
    required this.label,
  });

  final bool visible;
  final bool deleting;
  final VoidCallback onPressed;
  final String label;

  @override
  State<_RailDeleteButton> createState() => _RailDeleteButtonState();
}

class _RailDeleteButtonState extends State<_RailDeleteButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Focus(
        onFocusChange: (bool has) => setState(() => _focused = has),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.deleting ? null : widget.onPressed,
          child: Semantics(
            button: true,
            enabled: !widget.deleting,
            label: widget.label, // tsx 147
            child: AnimatedOpacity(
              // `.live-rail-item-wrap:hover .live-rail-del-btn, :focus-visible { opacity: 1 }`
              opacity: widget.deleting
                  ? 0.4 // `.live-rail-del-btn:disabled { opacity: .4 }`
                  : ((widget.visible || _focused) ? 1 : 0),
              duration: AylaDurations.fast,
              child: Container(
                width: 22, // 22×22 pill
                height: 22,
                decoration: BoxDecoration(
                  color: const Color(0xB8FFFAFB), // rgba(255,250,251,.72)
                  borderRadius: AylaRadii.pill,
                ),
                alignment: Alignment.center,
                child: AylaIcon(
                  aylaIconByName('iconClose')!,
                  size: 14, // tsx 150：`IconClose 14`
                  color: AylaColors.destructive,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.live-rail-create-btn`（live.css 238–239）：1px 虚线 `--ice-500`。
class _CreateButton extends StatefulWidget {
  const _CreateButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_CreateButton> createState() => _CreateButtonState();
}

class _CreateButtonState extends State<_CreateButton> {
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
        child: AylaDashedBorder(
          radius: AylaRadii.rInput,
          color: AylaColors.ice500, // `border: 1px dashed var(--ice-500)`
          child: Container(
            constraints: const BoxConstraints(minHeight: 40),
            decoration: BoxDecoration(
              // hover → `background: var(--glass-bg)`
              color: _hovered ? AylaColors.glassBg : Colors.transparent,
              borderRadius: BorderRadius.circular(AylaRadii.rInput),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: AylaSpacing.sp2, // gap: var(--sp-2)
              children: <Widget>[
                AylaIcon(aylaIconByName('iconPlus')!, size: 16), // tsx 161
                Text(
                  '新建直播间',
                  style: t.body.copyWith(
                    fontSize: 13, // `.live-rail-create-btn { font-size: 13px }`
                    color: AylaColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `.live-start-picker` —— 开播选择器（`LiveStartSheet.tsx` 86 行）。
///
/// 主播专用入口：列出**自己的**直播间（数据由页面投影，web 是 `useOwnedLiveDirectory` +
/// WS 热更新重排），选择后进入开播控制台；底部是「+ 添加新的直播间」（`.btn.btn-glow`）。
class AylaLiveStartSheet extends StatelessWidget {
  const AylaLiveStartSheet({
    super.key,
    required this.channels,
    required this.onStart,
    required this.onCreateNew,
    this.loading = false,
    this.loaded = false,
    this.error,
    this.invalidated = false,
    this.hasMore = false,
    this.creatingNew = false,
    this.createError,
    this.directoryFooter,
    this.onRetry,
  });

  /// 本人直播间列表（页面投影；排序由页面按 `sortLiveChannels` 处理）。
  final List<AylaLiveCardData> channels;

  /// 选择一个已有直播间（进入开播控制台）。
  final ValueChanged<AylaLiveCardData> onStart;

  /// 新建直播间。
  final VoidCallback onCreateNew;

  /// 列表加载中（web `directory.loading`）。
  final bool loading;

  /// 列表已加载过一次（web `directory.loaded`）。
  final bool loaded;

  /// 列表错误文案（web `directory.error`）。
  final String? error;

  /// 加载中数据被更新（web `directory.invalidated`）。
  final bool invalidated;

  /// 还有更多（web `directory.hasMore`）。
  final bool hasMore;

  /// 正在创建新直播间（按钮置「创建中…」并禁用）。
  final bool creatingNew;

  /// 创建失败文案。
  final String? createError;

  /// 目录分页槽（web `<DirectoryLoadMore {...directory} />`）。
  final Widget? directoryFooter;

  /// 列表加载失败时的「重试」（web `directory.refresh()`）。
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    // 列表渲染条件（tsx 53）：loaded && (有内容 || error || hasMore || invalidated)
    final bool showList =
        loaded &&
        (channels.isNotEmpty || error != null || hasMore || invalidated);
    final bool showListError = error != null && !loaded && !creatingNew;
    final bool showEmpty =
        loaded &&
        !loading &&
        error == null &&
        !invalidated &&
        !hasMore &&
        channels.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: AylaSpacing.sp4, // gap: var(--sp-4)
      children: <Widget>[
        // `.live-start-intro`：strong 20 Fredoka + span 13 secondary（gap sp1）
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          spacing: AylaSpacing.sp1,
          children: <Widget>[
            Text(
              '选择一个直播间开始', // tsx 32
              style: TextStyle(
                fontFamily: AylaFonts.display,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 20,
                color: AylaColors.textPrimary,
              ),
            ),
            Text(
              '已有直播间可以直接复用，直播画面和弹幕会在开播控制台里一起显示。', // tsx 33
              style: t.body.copyWith(
                fontSize: 13,
                color: AylaColors.textSecondary,
              ),
            ),
          ],
        ),
        if (loading && !loaded)
          Text(
            '正在加载你的直播间…', // tsx 36
            style: t.body.copyWith(fontSize: 13, color: AylaColors.textSecondary),
          ),
        if (showListError)
          _ErrorRow(
            message: '直播间列表加载失败：$error', // tsx 39
            action: GlassButton(
              label: '重试', // tsx 41
              variant: GlassButtonVariant.ghost,
              onPressed: onRetry,
            ),
          ),
        if (createError case final String message)
          _ErrorRow(message: '创建直播间失败：$message'), // tsx 47
        if (showEmpty)
          Text(
            '还没有自己的直播间，先创建一个吧。', // tsx 51
            style: t.body.copyWith(fontSize: 13, color: AylaColors.textSecondary),
          ),
        if (showList)
          ConstrainedBox(
            // `.live-start-list { max-height: min(42vh, 360px); overflow-y: auto }`
            constraints: BoxConstraints(
              maxHeight: math.min(
                MediaQuery.sizeOf(context).height * 0.42,
                360,
              ),
            ),
            child: SingleChildScrollView(
              child: Semantics(
                label: '我的直播间', // tsx 54
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: AylaSpacing.sp2, // gap: var(--sp-2)
                  children: <Widget>[
                    for (final AylaLiveCardData channel in channels)
                      _StartChannelRow(
                        channel: channel,
                        onTap: () => onStart(channel),
                      ),
                    if (directoryFooter case final Widget footer) footer,
                  ],
                ),
              ),
            ),
          ),
        // `.btn.btn-glow.live-start-new { align-self: stretch }`
        GlassButton(
          label: creatingNew ? '创建中…' : '+ 添加新的直播间', // tsx 82
          variant: GlassButtonVariant.glow,
          expand: true,
          onPressed: creatingNew ? null : onCreateNew,
        ),
      ],
    );
  }
}

/// `.live-start-error`（live.css 140）：destructive 13 + 右端操作。
class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.message, this.action});

  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Semantics(
      liveRegion: true, // `role="alert"`
      child: Row(
        spacing: AylaSpacing.sp3, // gap: var(--sp-3)
        children: <Widget>[
          Expanded(
            child: Text(
              message,
              style: t.body.copyWith(
                fontSize: 13,
                color: AylaColors.destructive,
              ),
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

/// `.live-start-channel`（tsx 56–70 + live.css 82–138）。
class _StartChannelRow extends StatefulWidget {
  const _StartChannelRow({required this.channel, required this.onTap});

  final AylaLiveCardData channel;
  final VoidCallback onTap;

  @override
  State<_StartChannelRow> createState() => _StartChannelRowState();
}

class _StartChannelRowState extends State<_StartChannelRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final AylaLiveCardData channel = widget.channel;
    final bool live = channel.status == AylaLiveStatus.live;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Semantics(
          button: true,
          label: '${channel.title}${live ? ' 正在直播，可继续开播' : ' 准备开播'}',
          child: AnimatedContainer(
            duration: AylaDurations.fast, // `transition: background/box-shadow 180ms`
            curve: AylaCurves.easeOut,
            constraints: const BoxConstraints(minHeight: 68), // min-height: 68px
            padding: const EdgeInsets.all(AylaSpacing.sp2),
            decoration: BoxDecoration(
              color: _hovered
                  ? AylaColors.ice500.withValues(alpha: 0.22) // hover .22（同色相，防灰闪）
                  : const Color(0x73FFFAFB), // rgba(255,250,251,.45)
              borderRadius: BorderRadius.circular(AylaRadii.rCard),
              border: Border.all(color: AylaColors.glassBorder),
              boxShadow: _hovered
                  ? const <BoxShadow>[
                      // hover → `0 0 12px rgba(247,150,255,.2)`
                      BoxShadow(color: Color(0x33F796FF), blurRadius: 12),
                    ]
                  : AylaShadows.compact, // `--glass-shadow-compact`
            ),
            child: Row(
              spacing: AylaSpacing.sp3, // gap: var(--sp-3)
              children: <Widget>[
                // `.live-start-channel-cover`：82 宽 / 16:9 / 145deg ice-300→sakura-100 /
                // utility 10 / w600 / text-on-pink / 文案「LIVE」或空
                SizedBox(
                  width: 82,
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: cssLinearGradient(
                          angleDeg: 145,
                          colors: <Color>[
                            AylaColors.ice300,
                            AylaColors.sakura100,
                          ],
                          aspectRatio: 16 / 9,
                        ),
                        borderRadius: BorderRadius.circular(AylaRadii.rInput),
                      ),
                      child: Center(
                        child: Text(
                          live ? 'LIVE' : '',
                          style: const TextStyle(
                            fontFamily: AylaFonts.utility,
                            fontFamilyFallback: AylaFonts.cjkFallback,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: AylaColors.textOnPink,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    spacing: 2, // gap: 2px
                    children: <Widget>[
                      Text(
                        channel.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis, // `.copy strong`：单行省略
                        style: t.body.copyWith(
                          fontSize: 14,
                          color: AylaColors.textPrimary,
                        ),
                      ),
                      Text(
                        live ? '正在直播，可继续开播' : '准备开播', // tsx 67
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.body.copyWith(
                          fontSize: 13,
                          color: AylaColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '→', // tsx 69（`aria-hidden` 装饰字形）
                  style: t.body.copyWith(
                    fontSize: 20,
                    color: AylaColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ======================= 预览样张 =======================

/// 直播侧栏 + 开播选择器样张（可交互）。
Widget aylaLiveRailSamples() {
  aylaEnableSampleMedia();
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      _Stage(
        viewport: const Size(360, 520),
        label:
            '直播侧栏（宽屏展开态：240 + margin 12；操作区 min-height 54）· 可交互：点封面切台（高亮 300ms 迁移）/ 点收起',
        child: const _RailDemo(studio: false),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(360, 520),
        label: '开播控制台扩展（每行右侧删除键 hover 显形 + 底部「新建直播间」虚线键）',
        child: const _RailDemo(studio: true),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        // ⚠️ 舞台宽必须 >768 才落在**宽屏档**（620 宽会掉进窄屏档、变成贴底卡：
        //    探针实测过——见 13 号 §6.30 追加条目）
        viewport: const Size(900, 560),
        label:
            '开播弹窗 = `AylaCreateSheet`（A3 的通用创建浮层）+ 选择器**内容本体** · **宽屏**居中卡（`--glass-bg-strong` + blur24 + radius 20 + modal 阴影 + **`max-height: 80vh`**，内容超高时卡内滚动）· 可交互：点条目进控制台 / 点 glow 键 / ESC·遮罩·关闭钮三路关闭',
        child: const _StartSheetDemo(),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(420, 620),
        label: '同上的**窄屏**形态（≤768）：贴底滑入卡（`radius 24 24 0 0` + 去左右下边框 + 250ms 滑入 + safe-area）',
        child: _StartSheetDemo(viewport: const Size(420, 620)),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        // 宽屏档 + 内容偏高 ⇒ 直接演示 `max-height: 80vh` 的限高与卡内滚动
        viewport: const Size(900, 520),
        label: '弹窗内容本体 · 三态同框（空态 / 列表失败 = role=alert + 重试 / 创建失败 = alert）· 宽屏档下内容超高 ⇒ **限高 80vh + 卡内滚动**（web `.create-sheet-card { max-height:80vh; overflow-y:auto }`）',
        child: const _StartSheetStatesDemo(),
      ),
    ],
  );
}

class _RailDemo extends StatefulWidget {
  const _RailDemo({required this.studio});

  final bool studio;

  @override
  State<_RailDemo> createState() => _RailDemoState();
}

class _RailDemoState extends State<_RailDemo> {
  String _current = 'lc2';
  bool _collapsed = false;
  int _deleted = 0;

  static const List<AylaLiveCardData> _channels = <AylaLiveCardData>[
    AylaLiveCardData(
      id: 'lc1',
      title: '深夜电台 · 爱莉陪你写代码',
      status: AylaLiveStatus.live,
      viewerCount: 12,
    ),
    AylaLiveCardData(
      id: 'lc2',
      title: '第二场直播，标题长一些试试两行截断的效果',
      status: AylaLiveStatus.live,
      viewerCount: 1240,
    ),
    AylaLiveCardData(id: 'lc3', title: '周末的雪山行记', status: AylaLiveStatus.ended),
    AylaLiveCardData(id: 'lc4', title: '未开播的房间', status: AylaLiveStatus.idle),
  ];

  @override
  Widget build(BuildContext context) {
    if (_collapsed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: AylaSpacing.sp2,
          children: <Widget>[
            const Text(
              '收起态 = 组件不渲染（返回/展开键移到顶栏；\n`.live-rail-float` 是死 CSS，不复刻）',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11),
            ),
            GlassButton(
              label: '重新展开',
              variant: GlassButtonVariant.ghost,
              onPressed: () => setState(() => _collapsed = false),
            ),
            if (_deleted > 0)
              Text('已点删除 $_deleted 次', style: const TextStyle(fontSize: 11)),
          ],
        ),
      );
    }
    return AylaLiveChannelRail(
      channels: _channels,
      currentId: _current,
      showBack: !widget.studio ? true : false,
      onSelect: (String id) => setState(() => _current = id),
      onToggle: () => setState(() => _collapsed = true),
      onBack: () {},
      onDeleteChannel: widget.studio
          ? (_) => setState(() => _deleted += 1)
          : null,
      onCreateNewChannel: widget.studio
          ? () => setState(() => _deleted += 0)
          : null,
    );
  }
}

class _StartSheetDemo extends StatefulWidget {
  const _StartSheetDemo({this.viewport});

  /// 仅用于样张舞台尺寸提示（弹窗形态由 `AylaCreateSheet` 按 MediaQuery 断点自判）。
  final Size? viewport;

  @override
  State<_StartSheetDemo> createState() => _StartSheetDemoState();
}

class _StartSheetDemoState extends State<_StartSheetDemo> {
  bool _open = true;
  String? _started;
  bool _creating = false;

  @override
  Widget build(BuildContext context) {
    if (!_open) {
      return Center(
        child: GlassButton(
          label: '重新打开开播弹窗',
          variant: GlassButtonVariant.ghost,
          onPressed: () => setState(() => _open = true),
        ),
      );
    }
    // 开播弹窗 = `AylaCreateSheet`（`layout/CreateSheet.tsx`；A3 已提取的通用创建浮层）：
    // 宽屏居中卡、窄屏贴底滑入 —— **同一个类型**，发帖/语音/直播三条创建流共用。
    // ⚠️ 样张的演示状态行必须放在**弹窗之外**（曾放在卡内 ⇒ 内容被顶过 `max-height: 80vh`，
    //    触发了外层卡滚动 + 桌面端自动 Scrollbar 那条竖线；用户 2026-09-22 报出）。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: AylaCreateSheet(
      title: '开始直播', // CreateFab.tsx:88（群内入口是「群内开播」）
      onClose: () => setState(() => _open = false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AylaLiveStartSheet(
            channels: const <AylaLiveCardData>[
              AylaLiveCardData(
                id: 'lc1',
                title: '我的深夜电台直播间',
                status: AylaLiveStatus.live,
              ),
              AylaLiveCardData(
                id: 'lc2',
                title: '准备中的第二场直播',
                status: AylaLiveStatus.idle,
              ),
            ],
            loaded: true,
            onStart: (AylaLiveCardData c) =>
                setState(() => _started = c.title),
            onCreateNew: () {
              setState(() => _creating = true);
              Future<void>.delayed(const Duration(milliseconds: 800), () {
                if (mounted) setState(() => _creating = false);
              });
            },
            creatingNew: _creating,
            directoryFooter: const Padding(
              padding: EdgeInsets.symmetric(vertical: AylaSpacing.sp2),
              child: AylaDirectoryLoadMore(
                loading: false,
                error: null,
                hasMore: true,
                invalidated: false,
                loadMore: _noopAsync,
                refresh: _noopAsync,
                retainCompletedSpace: true, // 侧栏是紧凑列表
              ),
            ),
          ),
        ],
      ),
          ),
        ),
        const SizedBox(height: AylaSpacing.sp2),
        Text(
          _started == null ? '未选择（点条目试一下）' : '已选择：$_started',
          style: const TextStyle(fontSize: 11),
        ),
      ],
    );
  }
}

class _StartSheetStatesDemo extends StatefulWidget {
  const _StartSheetStatesDemo();

  @override
  State<_StartSheetStatesDemo> createState() => _StartSheetStatesDemoState();
}

class _StartSheetStatesDemoState extends State<_StartSheetStatesDemo> {
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    if (!_open) {
      return Center(
        child: GlassButton(
          label: '重新打开',
          variant: GlassButtonVariant.ghost,
          onPressed: () => setState(() => _open = true),
        ),
      );
    }
    return AylaCreateSheet(
      title: '群内开播', // ChannelSidebar.tsx:548
      onClose: () => setState(() => _open = false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: AylaSpacing.sp4,
        children: <Widget>[
          // 空态
          AylaLiveStartSheet(
            channels: const <AylaLiveCardData>[],
            loaded: true,
            onStart: (_) {},
            onCreateNew: () {},
          ),
          const Divider(height: 1),
          // 列表加载失败（role=alert + 重试）
          AylaLiveStartSheet(
            channels: const <AylaLiveCardData>[],
            error: '网络异常',
            onStart: (_) {},
            onCreateNew: () {},
            onRetry: () {},
          ),
          const Divider(height: 1),
          // 创建失败（alert）
          const AylaLiveStartSheet(
            channels: <AylaLiveCardData>[],
            loaded: true,
            createError: '名称重复',
            onStart: _noopStart,
            onCreateNew: _noopNew,
          ),
        ],
      ),
    );
  }
}

void _noopStart(AylaLiveCardData _) {}

void _noopNew() {}

Future<void> _noopAsync() async {}

/// 固定视口的样张舞台。
class _Stage extends StatelessWidget {
  const _Stage({
    required this.viewport,
    required this.label,
    required this.child,
  });

  final Size viewport;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: viewport.width,
          height: viewport.height,
          child: Builder(
            builder: (BuildContext inner) => MediaQuery(
              data: MediaQuery.of(inner).copyWith(size: viewport),
              child: child,
            ),
          ),
        ),
        const SizedBox(height: AylaSpacing.sp1),
        SizedBox(
          width: viewport.width,
          child: Text(label, style: const TextStyle(fontSize: 11)),
        ),
      ],
    );
  }
}

/// 直播侧栏 + 开播选择器。
@Preview(
  group: 'Widgets',
  name: '直播侧栏 + 开播选择器',
  size: Size(420, 1700),
  wrapper: previewTheme,
)
Widget aylaLiveRailPreview() => aylaLiveRailSamples();
