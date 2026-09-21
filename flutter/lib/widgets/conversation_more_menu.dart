/// 会话「⋯ 更多」按钮 + 弹出菜单（置顶/取消置顶、可选删除）。
///
/// **1:1 对照 `ConversationMoreMenu.tsx` + `app.css` 618–693**。
///
/// ## 触发按钮 `.conv-more-btn`（app.css 627–641）
/// ```
/// display:grid; place-items:center; width:40px; height:40px;   /* 触达 ≥40 */
/// border-radius:12px; color:#a9b8d4;
/// transition: background 180ms, color 180ms;
/// :hover, [aria-expanded="true"] { background: rgba(157,191,230,.25);
///                                 color: var(--text-primary); }
/// ```
/// 外框 `.conv-more { position:absolute; top:50%; right:6px; translateY(-50%) }`；
/// 群卡片覆写为 `bottom:10px; right:8px`（home.css 267–272），群列表覆写
/// `right:6px`（home.css 536–538）。
///
/// ## 弹出面板 `.conv-menu`（app.css 643–661）
/// ```
/// position:fixed; z-index:75; min-width:152px;
/// max-width:calc(100vw - 16px); max-height:calc(100dvh - 16px); overflow-y:auto;
/// padding: var(--sp-1); flex column; gap:2px;
/// border-radius: var(--radius-card);      /* 16 */
/// background: var(--glass-bg-strong);     /* .78 */
/// backdrop-filter: var(--glass-filter);   /* blur24 + saturate1.4 */
/// border:1px solid var(--glass-border); box-shadow: var(--glass-shadow);
/// ```
/// ## 菜单项 `.conv-menu-item`（663–693）
/// ```
/// flex; gap: var(--sp-2); min-height:40px; padding: 0 var(--sp-3);
/// border-radius:10px; font-size:14px; font-weight:600; color: var(--text-primary);
/// :hover → background: rgba(157,191,230,.22);
/// :disabled → opacity: .5;
/// danger → color: var(--destructive); danger:hover → rgba(224,100,100,.12);
/// ```
///
/// ## 行为（tsx）
/// - **定位**（useLayoutEffect 66–86）：gap 6、edge 8；默认向下，下方放不下则向上；
///   left 右对齐 `anchor.right` 并夹在 `[edge, innerWidth-w-edge]`。
/// - **外点关闭**（pointerdown，含面板外任意处）、**滚动关闭**、
///   **Esc 关闭并把焦点还给触发按钮**。
/// - **键盘**：触发按钮上 ArrowDown/ArrowUp 即打开并聚焦首/末项；面板内
///   ArrowDown/Up 循环、Home/End 跳首末、Tab 关闭。
/// - 打开时自动聚焦首项。
///
/// ## Flutter 侧的两点等价说明
/// 1. web 用 `createPortal` 把面板挂到 `body`（脱离滚动裁剪与 backdrop 层叠
///    上下文）→ Flutter 用 [OverlayEntry] 达到同一目的。
/// 2. 定位在插入 Overlay 后**下一帧测量**（需要真实尺寸才能算上/下与夹取）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;

import '../theme/app_icons.dart';
import '../theme/glass.dart';
import '../theme/tokens.dart';
import 'menu_item.dart';
import 'overlays.dart';

/// 会话摘要（菜单所需字段；对应 tsx 的 `conversation` 参数）。
class AylaConversation {
  const AylaConversation({
    required this.id,
    required this.title,
    this.isPinned = false,
  });

  /// 会话 id。
  final String id;

  /// 会话标题（aria 文案用）。
  final String title;

  /// 是否已置顶（决定菜单项文案「置顶 / 取消置顶」）。
  final bool isPinned;
}

/// `.conv-more` —— 更多按钮 + 弹出菜单。
///
/// [onTogglePin] 收到新值（true = 置顶）。
/// [onDelete] 仅当 [showDelete] 为 true 时提供；web 侧先弹 ConfirmDialog 确认，
/// 确认流程由调用方负责（弹层批次实现）。
class AylaConversationMoreMenu extends StatefulWidget {
  const AylaConversationMoreMenu({
    super.key,
    required this.conversation,
    this.showDelete = true,
    this.onTogglePin,
    this.onDelete,
    this.busy = false,
    this.align = ConversationMoreAlign.centerRight,
    this.right,
  });

  /// 会话。
  final AylaConversation conversation;

  /// 是否提供「删除会话」项（群聊不提供；私信保留）。
  final bool showDelete;

  /// 置顶切换回调（新值）。
  final ValueChanged<bool>? onTogglePin;

  /// 删除回调（需调用方自行确认）。
  final VoidCallback? onDelete;

  /// 请求进行中（禁用按钮与菜单项）。
  final bool busy;

  /// 垂直对齐（`.conv-more { top:50% }` vs `.group-card .conv-more { bottom:10px }`）。
  final ConversationMoreAlign align;

  /// 右侧偏移（`right:6px` / 群卡片 `right:8px`）。
  final double? right;

  /// 菜单最小宽度（`.conv-menu { min-width: 152px }`）。
  static const double menuMinWidth = 152;

  /// 定位间隙（tsx `gap = 6`）。
  static const double menuGap = 6;

  /// 视口边缘留白（tsx `edge = 8`）。
  static const double menuEdge = 8;

  @override
  State<AylaConversationMoreMenu> createState() =>
      _AylaConversationMoreMenuState();
}

/// 更多按钮的垂直定位方式。
enum ConversationMoreAlign {
  /// 行内垂直居中（`.conv-more { top:50%; translateY(-50%) }`）。
  centerRight,

  /// 贴近底部（`.group-card .conv-more { bottom:10px }`）。
  bottomRight,
}

class _AylaConversationMoreMenuState extends State<AylaConversationMoreMenu> {
  final GlobalKey _anchorKey = GlobalKey();
  final GlobalKey<_MenuPanelState> _panelKey = GlobalKey<_MenuPanelState>();

  OverlayEntry? _entry;
  bool _open = false;

  /// 触发按钮与面板的全局矩形（面板内容测量用）。
  Rect? _anchorRect;

  @override
  void dispose() {
    _removeEntry();
    super.dispose();
  }

  void _removeEntry() {
    _entry?.remove();
    _entry = null;
  }

  void _openMenu({bool last = false}) {
    if (widget.busy || _open) return;

    final RenderBox? anchor =
        _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (anchor == null) return;
    _anchorRect = anchor.localToGlobal(Offset.zero) & anchor.size;

    setState(() => _open = true);
    // 浮层一律走统一入口（`overlays.dart`）：它在 entry 内部兜底 DefaultTextStyle ——
    // Overlay 的 entry 是独立子树、页面 Material 传不进来，缺兜底时内部 Text 会落到
    // `DefaultTextStyle.fallback`（双下划线 + 红色 = 用户看到的「黄线」）。
    _entry = aylaOverlayEntry(
      builder: (BuildContext context) => _MenuOverlay(
        anchorRect: _anchorRect!,
        onDismiss: () => _closeMenu(),
        panelKey: _panelKey,
        showDelete: widget.showDelete,
        busy: widget.busy,
        pinned: widget.conversation.isPinned,
        openLast: last,
        onTogglePin: () {
          _closeMenu(restoreFocus: true);
          widget.onTogglePin?.call(!widget.conversation.isPinned);
        },
        onDelete: () {
          _closeMenu();
          widget.onDelete?.call();
        },
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_entry!);
  }

  void _closeMenu({bool restoreFocus = false}) {
    if (!_open) return;
    _removeEntry();
    setState(() => _open = false);
    if (restoreFocus) {
      // 把焦点还给触发按钮（tsx closeMenu(true) → triggerRef.focus()）
      _focusTrigger();
    }
  }

  void _focusTrigger() {
    final BuildContext? ctx = _anchorKey.currentContext;
    if (ctx == null) return;
    FocusScope.of(ctx).requestFocus(_triggerFocus);
  }

  final FocusNode _triggerFocus = FocusNode(debugLabel: 'conv-more-trigger');

  @override
  Widget build(BuildContext context) {
    final Widget button = _MoreButton(
      key: _anchorKey,
      focusNode: _triggerFocus,
      busy: widget.busy,
      expanded: _open,
      onTap: () => _open ? _closeMenu() : _openMenu(),
      onArrowOpen: (bool last) => _openMenu(last: last),
    );

    switch (widget.align) {
      case ConversationMoreAlign.centerRight:
        // `.conv-more { top:50%; right:6px; transform:translateY(-50%) }`
        return Positioned(
          top: 0,
          bottom: 0,
          right: widget.right ?? 6,
          child: Center(child: button),
        );
      case ConversationMoreAlign.bottomRight:
        // `.group-card .conv-more { top:auto; bottom:10px; right:8px; transform:none }`
        return Positioned(
          bottom: 10,
          right: widget.right ?? 8,
          child: button,
        );
    }
  }
}

/// `.conv-more-btn` —— 40×40 / radius 12 / 静息 `#a9b8d4`；hover 与展开态冰蓝底。
class _MoreButton extends StatelessWidget {
  const _MoreButton({
    super.key,
    required this.focusNode,
    required this.busy,
    required this.expanded,
    required this.onTap,
    required this.onArrowOpen,
  });

  final FocusNode focusNode;
  final bool busy;
  final bool expanded;
  final VoidCallback onTap;

  /// 方向键打开（true = ArrowUp → 聚焦末项）。
  final ValueChanged<bool> onArrowOpen;

  @override
  Widget build(BuildContext context) {
    return _HoverBuilder(
      builder: (BuildContext context, bool hovered) {
        final bool active = hovered || expanded;
        return Semantics(
          button: true,
          enabled: !busy,
          expanded: expanded,
          label: '更多操作',
          child: Focus(
            focusNode: focusNode,
            onKeyEvent: (FocusNode node, KeyEvent event) {
              // tsx: ArrowDown/ArrowUp → 打开并聚焦首/末项
              if (event is KeyDownEvent &&
                  (event.logicalKey == LogicalKeyboardKey.arrowDown ||
                      event.logicalKey == LogicalKeyboardKey.arrowUp)) {
                onArrowOpen(event.logicalKey == LogicalKeyboardKey.arrowUp);
                return KeyEventResult.handled;
              }
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.enter) {
                onTap();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: busy ? null : onTap,
              child: AnimatedContainer(
                duration: AylaDurations.fast, // var(--dur-fast) 180ms
                curve: AylaCurves.easeOut,
                width: 40, // width: 40px
                height: 40, // height: 40px
                decoration: BoxDecoration(
                  // :hover / [aria-expanded=true] → rgba(157,191,230,.25)
                  // ⚠️ 零透明用**同色相**（`Colors.transparent` 是透明黑，
                  // AnimatedContainer 逐通道插值的中途会闪灰；见
                  // profile_and_filters.dart 的详细说明）
                  color: active
                      ? AylaColors.ice500.withValues(alpha: 0.25)
                      : AylaColors.ice500.withValues(alpha: 0),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Opacity(
                  opacity: busy ? 0.5 : 1.0,
                  child: Center(
                    child: AylaIcon(
                      aylaIconByName('iconDots')!,
                      size: 18, // <IconDots width={18} height={18} />
                      color: active
                          ? AylaColors.textPrimary
                          : AylaColors.convMoreIdle,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 悬浮状态构建器（避免为每个按钮写一遍 StatefulWidget）。
class _HoverBuilder extends StatefulWidget {
  const _HoverBuilder({required this.builder});

  final Widget Function(BuildContext, bool hovered) builder;

  @override
  State<_HoverBuilder> createState() => _HoverBuilderState();
}

class _HoverBuilderState extends State<_HoverBuilder> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: widget.builder(context, _hovered),
    );
  }
}

/// 面板覆盖层（挂进 Overlay）：外点/滚动关闭 + 定位 + 面板本体。
class _MenuOverlay extends StatefulWidget {
  const _MenuOverlay({
    required this.anchorRect,
    required this.onDismiss,
    required this.panelKey,
    required this.showDelete,
    required this.busy,
    required this.pinned,
    required this.openLast,
    required this.onTogglePin,
    required this.onDelete,
  });

  final Rect anchorRect;
  final VoidCallback onDismiss;
  final GlobalKey<_MenuPanelState> panelKey;
  final bool showDelete;
  final bool busy;
  final bool pinned;
  final bool openLast;
  final VoidCallback onTogglePin;
  final VoidCallback onDelete;

  @override
  State<_MenuOverlay> createState() => _MenuOverlayState();
}

class _MenuOverlayState extends State<_MenuOverlay> {
  /// 面板左上角（测量后得出）。
  Offset? _pos;

  @override
  void initState() {
    super.initState();
    // 插入 Overlay 后下一帧测量真实尺寸 → 算上下方向与夹取（对应 tsx positionMenu）
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _measure() {
    if (!mounted) return;
    final RenderBox? panel = widget.panelKey.currentContext?.findRenderObject()
        as RenderBox?;
    if (panel == null) return;

    final Size vp = MediaQuery.of(context).size;
    final Rect a = widget.anchorRect;
    final Size ms = panel.size;

    const double gap = AylaConversationMoreMenu.menuGap; // 6
    const double edge = AylaConversationMoreMenu.menuEdge; // 8

    final double below = a.bottom + gap;
    final double above = a.top - gap - ms.height;
    final double rawTop =
        (below + ms.height <= vp.height - edge) ? below : above;

    // left 右对齐 anchor.right，并夹在 [edge, vp.width - w - edge]
    final double maxLeft = (vp.width - ms.width - edge).clamp(edge, 1e9);
    final double left = (a.right - ms.width).clamp(edge, maxLeft);
    final double maxTop = (vp.height - ms.height - edge).clamp(edge, 1e9);
    final double top = rawTop.clamp(edge, maxTop);

    setState(() => _pos = Offset(left, top));

    // 打开后聚焦首/末项（tsx initialFocus）
    widget.panelKey.currentState?.focusInitial(last: widget.openLast);
  }

  @override
  Widget build(BuildContext context) {
    final Size vp = MediaQuery.of(context).size;
    return Stack(
      children: <Widget>[
        // 外点关闭层（覆盖全屏；translucent 让滚动仍可传递）
        Positioned(
          left: 0,
          top: 0,
          width: vp.width,
          height: vp.height,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onDismiss,
            child: const SizedBox.expand(),
          ),
        ),
        if (_pos != null)
          Positioned(
            left: _pos!.dx,
            top: _pos!.dy,
            child: _MenuPanel(
              key: widget.panelKey,
              showDelete: widget.showDelete,
              busy: widget.busy,
              pinned: widget.pinned,
              onDismiss: widget.onDismiss,
              onTogglePin: widget.onTogglePin,
              onDelete: widget.onDelete,
            ),
          ),
      ],
    );
  }
}

/// `.conv-menu` 面板（玻璃材质 + 菜单项 + 键盘导航）。
class _MenuPanel extends StatefulWidget {
  const _MenuPanel({
    super.key,
    required this.showDelete,
    required this.busy,
    required this.pinned,
    required this.onDismiss,
    required this.onTogglePin,
    required this.onDelete,
  });

  final bool showDelete;
  final bool busy;
  final bool pinned;
  final VoidCallback onDismiss;
  final VoidCallback onTogglePin;
  final VoidCallback onDelete;

  @override
  State<_MenuPanel> createState() => _MenuPanelState();
}

class _MenuPanelState extends State<_MenuPanel> {
  late final List<FocusNode> _nodes = <FocusNode>[
    FocusNode(debugLabel: 'conv-menu-item-0'),
    if (widget.showDelete) FocusNode(debugLabel: 'conv-menu-item-1'),
  ];

  @override
  void dispose() {
    for (final FocusNode n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  /// 打开时聚焦首项（或末项，当用 ArrowUp 打开）。
  void focusInitial({required bool last}) {
    if (_nodes.isEmpty) return;
    _nodes[last ? _nodes.length - 1 : 0].requestFocus();
  }

  /// 面板内键盘：Esc/Tab 关闭；ArrowDown/Up 循环；Home/End 跳首末。
  /// 对应 tsx 面板 onKeyDown。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final int count = _nodes.length;
    final int index = _nodes.indexOf(node);

    switch (event.logicalKey) {
      case LogicalKeyboardKey.escape:
        widget.onDismiss();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.tab:
        widget.onDismiss();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        if (count > 0) _nodes[(index + 1) % count].requestFocus();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        if (count > 0) _nodes[(index - 1 + count) % count].requestFocus();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.home:
        if (count > 0) _nodes.first.requestFocus();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.end:
        if (count > 0) _nodes.last.requestFocus();
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final BorderRadius r = BorderRadius.circular(AylaRadii.rCard); // 16
    final bool opaque = GlassConfig.useOpaqueFallback;

    final Widget items = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      // `.conv-menu { gap: 2px }` —— gap 只在项**之间**（用 margin 会给末项
      // 也加 2px，面板底部多出空隙）；Column.spacing 语义与 CSS gap 一致。
      spacing: 2,
      children: <Widget>[
        AylaMenuItem(
          focusNode: _nodes[0],
          onKey: _onKey,
          icon: AylaIcon(aylaIconByName('iconPin')!, size: 16),
          label: widget.pinned ? '取消置顶' : '置顶',
          disabled: widget.busy,
          onTap: widget.onTogglePin,
        ),
        if (widget.showDelete)
          AylaMenuItem(
            focusNode: _nodes[1],
            onKey: _onKey,
            icon: const _TrashGlyph(),
            label: '删除会话',
            danger: true,
            disabled: widget.busy,
            onTap: widget.onDelete,
          ),
      ],
    );

    // 面板内容（`.conv-menu` 的 padding / min-width / gap）
    final Widget body = Container(
      constraints: const BoxConstraints(
        minWidth: AylaConversationMoreMenu.menuMinWidth, // min-width: 152px
      ),
      padding: const EdgeInsets.all(AylaSpacing.sp1), // padding: var(--sp-1)
      child: items,
    );

    // 玻璃层（blur24 + saturate1.4，只作用于背后的页面内容）
    Widget layered = body;
    if (!opaque) {
      layered = Stack(
        children: <Widget>[
          Positioned.fill(
            child: ClipRRect(
              borderRadius: r,
              child: BackdropFilter(
                filter: GlassConfig.backdropFilter(sigma: AylaGlass.blurCard),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          body,
        ],
      );
    }

    return Focus(
      onKeyEvent: (FocusNode node, KeyEvent event) {
        // 焦点落在面板本身时也可 Esc 关闭
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          widget.onDismiss();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {}, // 面板内点击不冒泡到外点关闭层
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            // 外阴影：**只画形状之外**（CSS box-shadow 不在 border-box 内绘制）。
            // 2026-09-20 审查 R2：原裸 boxShadow 会把 .2 indigo 染进 .78 玻璃内部。
            Positioned.fill(
              child: IgnorePointer(
                child: AylaGlassShadow.ring(
                  radius: r,
                  shadows: AylaShadows.glass,
                ),
              ),
            ),
            // 底 + 亮边
            DecoratedBox(
              decoration: BoxDecoration(
                color: GlassConfig.resolveBackground(strong: true), // .78
                borderRadius: r,
                border: Border.all(color: AylaColors.glassBorder),
              ),
              child: ClipRRect(borderRadius: r, child: layered),
            ),
            // --glass-inset 顶沿 1px 内高光
            Positioned.fill(
              child: IgnorePointer(
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints c) {
                    return DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: r,
                        gradient: AylaInset.topHighlight(c.maxHeight),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 删除会话图标（tsx 内联 svg：16×16，`fill="currentColor"`）。
class _TrashGlyph extends StatelessWidget {
  const _TrashGlyph();

  @override
  Widget build(BuildContext context) {
    final Color color = IconTheme.of(context).color ?? AylaColors.textPrimary;
    return SizedBox(
      width: 16,
      height: 16,
      child: CustomPaint(painter: _TrashPainter(color)),
    );
  }
}

class _TrashPainter extends CustomPainter {
  const _TrashPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // tsx: `<path d="M6 7h12l-1 13H7L6 7zm3-3h6l1 2H8l1-2z" fill="currentColor"/>`
    // viewBox 24 → 缩放到 16
    canvas.scale(size.width / 24);
    final Path p = Path()
      ..moveTo(6, 7)
      ..lineTo(18, 7)
      ..lineTo(17, 20)
      ..lineTo(7, 20)
      ..close()
      ..moveTo(9, 4)
      ..lineTo(15, 4)
      ..lineTo(16, 6)
      ..lineTo(8, 6)
      ..close();
    canvas.drawPath(p, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _TrashPainter old) => old.color != color;
}
