/// 会话「⋯ 更多」按钮 + 弹出菜单（置顶/取消置顶、可选删除）。
///
/// **1:1 对照 `ConversationMoreMenu.tsx` + `app.css` 618–693**。
///
/// ## 触发按钮 `.conv-more-btn`（app.css 627–641）
/// ```
/// display:grid; place-items:center; width:40px; height:40px;   /* 触达 ≥40 */
/// border-radius:12px; color:#a9b8d4;
/// transition: background 180ms, color 180ms;
/// …（逐条 CSS 对照 / 层叠推导**原文**见 `docs/flutter/17-组件文件头归档（整理前原文）.md` 的 `widgets/chat/conversation_more_menu.dart` 一节）
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
///
/// ## 公开面
/// `AylaConversation` · `AylaConversationMoreMenu` · `AylaConversationMoreAlign`

library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;

import '../../theme/app_icons.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import '../base/dialogs.dart' show AylaConfirmDialog;
import '../base/menu_item.dart';
import '../base/overlays.dart';

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
/// [onDelete] 仅当 [showDelete] 为 true 时提供。
///
/// ## 删除的二次确认在**本件内部**完成（2026-10-15 补齐，P0-2）
/// web `ConversationMoreMenu.tsx:105–120`：点「删除会话」只做
/// `closeMenu(); setConfirmDeleteOpen(true)`，确认后 `doDelete` 才发起请求
/// `hideConversation(id).then(() => removeConversation(id))`。
/// 此前 Flutter 侧把确认留给调用方（注释原文「确认流程由调用方负责」），
/// 但四个挂载点实际上都没做 ⇒ 点一下就直删。现改为与 web 同构：
/// 菜单项 → [AylaConfirmDialog]（`ConfirmDialog.tsx` 同款文案与语义）→ [onDelete]。
///
/// 确认层的挂法与菜单本身一致（`aylaOverlayEntry` + `Overlay.of(context)`）：
/// 本件在会话行的 `Stack` 里是 `Positioned`，弹层若留在自身子树会被行的
/// 圆角/裁剪与层叠上下文困住。**与菜单不会并存**——点「删除会话」时先
/// `_closeMenu()` 移除菜单 entry，再插确认 entry ⇒ 不存在同级层序竞争
/// （`create_sheet.dart:129–136` 那条「每层各开一个 portal 会层序不可控」的
/// 教训针对的是**并存**场景，本处不适用）。
class AylaConversationMoreMenu extends StatefulWidget {
  const AylaConversationMoreMenu({
    super.key,
    required this.conversation,
    this.showDelete = true,
    this.onTogglePin,
    this.onDelete,
    this.busy = false,
    this.align = AylaConversationMoreAlign.centerRight,
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
  final AylaConversationMoreAlign align;

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
enum AylaConversationMoreAlign {
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

  /// 删除确认层的 Overlay entry（web `confirmDeleteOpen` 的开合，tsx 44/105–120）。
  ///
  /// Flutter 侧用 entry 的在否表达「确认层是否打开」（web 的布尔由
  /// `{confirmDeleteOpen && <ConfirmDialog …/>}` 条件渲染表达，语义等价）；
  /// 因此不额外存一份 bool 状态 —— 两份状态必然有不同步的路径。
  OverlayEntry? _confirmEntry;

  /// 触发按钮与面板的全局矩形（面板内容测量用）。
  Rect? _anchorRect;

  @override
  void dispose() {
    _removeEntry();
    _removeConfirmEntry();
    super.dispose();
  }

  void _removeEntry() {
    _entry?.remove();
    _entry = null;
  }

  void _removeConfirmEntry() {
    _confirmEntry?.remove();
    _confirmEntry = null;
  }

  /// 打开删除确认层（web `handleDelete` → `setConfirmDeleteOpen(true)`）。
  void _openConfirmDelete() {
    if (_confirmEntry != null) return;
    _confirmEntry = aylaOverlayEntry(
      builder: (BuildContext context) => AylaConfirmDialog(
        // ConfirmDialog.tsx:112–113 / ConversationMoreMenu.tsx:206–213 原文
        title: '删除会话',
        message: '删除会话「${widget.conversation.title}」？\n'
            '消息记录会保留，对方再发消息时会话将重新出现。',
        // web `doDelete`（tsx 110–120）：先 setConfirmDeleteOpen(false)，
        // 再 `hideConversation(id).then(() => removeConversation(id))`，
        // 失败静默（`.catch(() => {})`，由调用方 [onDelete] 承担）。
        onConfirm: () {
          _closeConfirmDelete();
          widget.onDelete?.call();
        },
        // web `onClose`（tsx 214）：关闭确认后把焦点还给触发按钮。
        onClose: () {
          _closeConfirmDelete();
          _focusTrigger();
        },
      ),
    );
    Overlay.of(context).insert(_confirmEntry!);
  }

  /// 关闭删除确认层（web `setConfirmDeleteOpen(false)`）。
  void _closeConfirmDelete() {
    _removeConfirmEntry();
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
          // web `handleDelete`（tsx 105–108）：只 closeMenu() + 打开确认，
          // **不直接删除**；真正发请求在 doDelete（确认后）。
          _closeMenu();
          _openConfirmDelete();
        },
      ),
    );
    // ⚠️ 用**最近**的 Overlay，不要 `rootOverlay: true`：画布/测试宿主
    // （`theme/preview_theme.dart:55` 那层）没有 Navigator ⇒ 会抛
    // `No Overlay widget found` 刷屏（用户 2026-10-02 实报）。真实 app 里最近的就是 root ⇒ 等价。
    Overlay.of(context).insert(_entry!);
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
      case AylaConversationMoreAlign.centerRight:
        // `.conv-more { top:50%; right:6px; transform:translateY(-50%) }`
        return Positioned(
          top: 0,
          bottom: 0,
          right: widget.right ?? 6,
          child: Center(child: button),
        );
      case AylaConversationMoreAlign.bottomRight:
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
      disabled: busy,
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
  const _HoverBuilder({required this.builder, this.disabled = false});

  final Widget Function(BuildContext, bool hovered) builder;

  /// 禁用档（web `disabled={busy}` ⇒ `base.css:343 cursor: not-allowed`）。
  final bool disabled;

  @override
  State<_HoverBuilder> createState() => _HoverBuilderState();
}

class _HoverBuilderState extends State<_HoverBuilder> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // `.conv-more-btn`（app.css:627–642）在 web 是 `<button type="button">`
    // （`ConversationMoreMenu.tsx:124–127`）⇒ `base.css:340` 全局 `cursor: pointer`
    // （该选择器自身无 cursor 声明）；`disabled={busy}` ⇒ `base.css:343` not-allowed。
    // ⚠️ `busy` 由 `_MenuTrigger.busy` 决定 —— 该件只在 `_HoverBuilder` 里拿到
    // hovered，故禁用档由构造方通过 [disabled] 传入（默认 false）。
    final bool clickable = !widget.disabled;
    return MouseRegion(
      cursor: clickable
          ? SystemMouseCursors.click
          : SystemMouseCursors.forbidden,
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

  /// 首帧的**估算**左上 x（真实值在 [_measure] 里算）：右对齐锚点并按视口夹取。
  ///
  /// 用菜单的最小宽度（152，`.conv-menu { min-width }`）估算即可 —— 这一帧是
  /// `Opacity(0)` 不可见的，只要不跑到视口外让 `Positioned` 撑出滚动范围就行。
  double _estLeft(BuildContext context) {
    final double maxLeft =
        (MediaQuery.of(context).size.width - AylaConversationMoreMenu.menuMinWidth -
                AylaConversationMoreMenu.menuEdge)
            .clamp(AylaConversationMoreMenu.menuEdge, 1e9);
    // 与 [_measure] 同坐标系（Overlay 局部），否则首帧会整体跳 76px。
    return (_anchorInOverlay.right - AylaConversationMoreMenu.menuMinWidth)
        .clamp(AylaConversationMoreMenu.menuEdge, maxLeft);
  }

  /// 首帧的**估算**左上 y：默认贴锚点下方（与 tsx「下方放不下才向上」同一起点）。
  double get _estTop =>
      _anchorInOverlay.bottom + AylaConversationMoreMenu.menuGap;

  /// 锚点矩形从**全局坐标**换算到**本 Overlay 的局部坐标**。
  ///
  /// ⚠️ **这是「菜单不紧贴 ⋯ 按钮」的真正根因**（2026-10-18 用户三张截图 + 像素反推）：
  /// `_anchorRect` 来自 `anchor.localToGlobal()` ⇒ 原点是 **RenderView 左上角（窗口原点）**；
  /// 而 `Positioned(left/top)` 的参照是 **本 Overlay 的 Stack 左上角**。
  /// 本 App 的 Overlay **不是**从窗口原点开始 —— 它挂在 `AppShell` 内容区，
  /// 顶部被 TopNav（64）+ 外边距（12）= **76px** 占掉。
  ///
  /// 实测反推（用户第二张截图）：锚点 `bottom`≈371 + 20 + gap6 = 397；
  /// 菜单实际出现在 y≈474 ⇒ **差值 76**，与「TopNav 64 + 上边距 12」完全吻合。
  /// web 之所以没这问题：菜单是 `position: fixed`，参照系恒为窗口，
  /// 而 `getBoundingClientRect()` 也是窗口坐标 ⇒ 天然一致。
  ///
  /// 修法：取本 Overlay 自己的 `RenderBox` 原点做差 ⇒ 与 web 的 fixed 语义等价，
  /// 且**对任何挂载层级都成立**（不写死 76，避免 TopNav 高度/边距改动后再次错位）。
  Rect get _anchorInOverlay {
    final Rect global = widget.anchorRect;
    final RenderObject? self = context.findRenderObject();
    if (self is! RenderBox || !self.hasSize) return global;
    final Offset origin = self.localToGlobal(Offset.zero);
    return global.shift(-origin);
  }

  void _measure() {
    if (!mounted) return;
    final RenderBox? panel = widget.panelKey.currentContext?.findRenderObject()
        as RenderBox?;
    if (panel == null) return;

    final Size vp = MediaQuery.of(context).size;
    final Rect a = _anchorInOverlay;
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
    // ⚠️ **必须 `fit: StackFit.expand`**（2026-10-18 用户实报「置顶菜单没像 web 一样紧贴」）：
    // web 的菜单是 `position: fixed` + `left/top` 取自 `getBoundingClientRect()`
    // ⇒ 坐标原点恒为**窗口左上角**。
    // Flutter 侧 `Stack` 默认 `StackFit.loose` ⇒ 当子级全是 `Positioned` 时，
    // Stack 会**收缩到子级包围盒**，于是 `Positioned(left: _pos.dx)` 的参照系
    // 不再是屏幕原点（面板被整体平移，视觉上"漂"在卡片中部而不是贴着 ⋯ 按钮）。
    // `expand` 让 Stack 占满 Overlay（= 全屏），与 `position: fixed` 同语义。
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // 外点关闭层（覆盖全屏；translucent 让滚动仍可传递）
        //
        // 指针（2026-10-09 核查，**刻意不改**）：web 用 document 级 pointerdown 关闭菜单，
        // 菜单外**没有**任何覆盖元素 ⇒ 落在菜单外的指针保持页面原有 cursor。
        // Flutter 侧本层不声明 cursor ⇒ `MouseCursor.defer` 会按命中链继续往外找
        // （下层可点件仍是手型），与 web 同义 —— 故**不加** `basic`：
        // 它会把下层所有可点件的手型一起抹掉（反向缺陷）。
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
        // ⚠️ **面板必须常驻渲染**，不能写成 `if (_pos != null)`（2026-10-15 修复）。
        //
        // 原实现是「测出位置才渲染面板」，但位置恰恰要靠**面板的真实尺寸**才能算
        // （[_measure] 读 `panelKey.currentContext` 的 RenderBox）⇒ 面板不渲染就量不到
        // ⇒ `_pos` 永远是 null ⇒ 面板永远不出现。用户点「⋯」只看到外层关闭层，
        // 菜单项（置顶 / 删除会话）一个都不出现 —— 这正是 P0-1 / P0-2 在真机上
        // 「点了没反应」的第一道断点（web 无此问题：portal 的菜单用
        // `useLayoutEffect` 量真实 DOM）。
        //
        // 现在的做法：首帧先按**估算位置**渲染（右对齐窗口 + 锚点下方），
        // 用 `Opacity(0)` + `IgnorePointer` 藏这一帧；[_measure] 拿到真实尺寸后
        // setState 到精确位置并转可见 ⇒ 无闪烁、无误命中。
        Positioned(
          left: _pos?.dx ?? _estLeft(context),
          top: _pos?.dy ?? _estTop,
          child: Opacity(
            opacity: _pos == null ? 0 : 1,
            child: IgnorePointer(
              ignoring: _pos == null,
              // ⚠️ **必须给宽度**：`Positioned(left:, top:)` 只定位不给约束 ⇒ 子件拿到
              // 的是无界宽度（`BoxConstraints()`）⇒ 面板里的 `Column(crossAxisAlignment:
              // stretch)` 会被迫按无限宽布局而抛
              // `BoxConstraints forces an infinite width`（实测）。
              //
              // 取值 = `.conv-menu { min-width: 152px }`：本菜单只有两项、文案最长
              // 「取消置顶」4 字 14px ⇒ 内容宽（图标 16 + gap 8 + 文字 + padding 24）
              // 恒 < 152 ⇒ web 的实际盒宽恒等于 152（`width: auto` 被 min-width 顶住）。
              // 视口过窄时按 `max-width: calc(100vw - 16px)` 收窄。
              child: SizedBox(
                width: (AylaConversationMoreMenu.menuMinWidth).clamp(
                  0,
                  vp.width - AylaConversationMoreMenu.menuEdge * 2,
                ),
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
            ),
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
    final bool opaque = AylaGlassConfig.useOpaqueFallback;

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
            // 背后内容层统一走 AylaGlassBackdrop（质量档 owner，§8.17）。
            child: AylaGlassBackdrop(
              radius: r,
              filter: AylaGlassConfig.backdropFilter(sigma: AylaGlass.blurCard),
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
      child: MouseRegion(
        // 面板本体：web `.conv-menu`（app.css:643–661）是 `<div>` 且**无 cursor 声明**
        // ⇒ 菜单面/分隔空白处是浏览器默认箭头（菜单项各自是 `<button>` ⇒ 手型）。
        // 显式 `basic` 防止 `defer` 继续往外找（会命中行/卡的手型而假显可点）。
        cursor: SystemMouseCursors.basic,
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
                // `.conv-menu { background: var(--glass-bg-strong); backdrop-filter:
                // var(--glass-filter) }`（app.css:643–661）—— 只命中 app.css:252–270
                // 的 `.92` 降级段（不在 auroraqua.css:527–551 清单里）
                // ⇒ 实底档用软值 `.92`（opaqueSoft）。
                color: AylaGlassConfig.resolveBackground(
                  strong: true, // .78
                  opaqueSoft: true,
                ),
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
