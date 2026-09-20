/// 资料卡与目录筛选（`UserProfileCard.tsx` + `DirectoryFilters.tsx`）。
///
/// 事实源见各段落注释。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, LogicalKeyboardKey;
import 'package:flutter/widget_previews.dart';

import '../theme/app_theme.dart';
import '../theme/buttons.dart' show AylaMsgActionButton;
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'avatar_halo.dart';
import 'dialogs.dart' show AylaModalOverlay;
import 'primitives.dart' show AylaNavHighlight, AylaNavHighlightState;
import 'reveal.dart';

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
              AvatarHalo(
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
              // → 复用组件库 [GlassButton]
              GlassButton(
                label: friendBusy ? '申请中…' : '加好友',
                variant: GlassButtonVariant.primary,
                onPressed: friendBusy ? null : onAddFriend,
              ),
              // 发消息（`.btn.btn-ghost`）：busy →「进入中…」
              GlassButton(
                label: chatBusy ? '进入中…' : '发消息',
                variant: GlassButtonVariant.ghost,
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

    // ---------- 卡面 → 复用组件库 [GlassCard] ----------
    //
    // web：`.user-profile-card` 除 `glass-card`（--glass-bg + --glass-filter +
    // 1px --glass-border + radius-card 16）外，还覆盖 `box-shadow:
    // --glass-shadow-modal`（比默认 --glass-shadow 更强）→ 用 `shadow` 参数表达。
    final Widget card = ConstrainedBox(
      // width: min(320px, 85vw)
      constraints: BoxConstraints(
        maxWidth: (MediaQuery.of(context).size.width * 0.85).clamp(0, 320),
      ),
      child: GlassCard(
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
/// 3. 容器材质一律走 [GlassSurface]（不自行拼玻璃层）。
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
  final List<FocusNode> _nodes = <FocusNode>[];
  final List<GlobalKey> _slotKeys = <GlobalKey>[];

  /// 高亮所在层的 key —— **测量基准必须与高亮同坐标系**。
  ///
  /// 高亮画在 `GlassSurface` 的 child 内（即 padding **之内**），而
  /// `AylaDirectoryFilters` 的 RenderBox 在 padding **之外**。若拿后者当
  /// `ancestor` 测量，槽位坐标会多减一次 padding → 高亮左移出卡片
  /// （实测：高亮跑到卡片左边被裁）。故测量与绘制都用同一层。
  final GlobalKey _stackKey = GlobalKey();

  /// 选中槽位的**实测矩形**（相对高亮所在层）——共享高亮按它定位。
  Rect? _capsuleRect;

  /// 指针当前所在**的选项卡索引**（-1 = 不在任何选项卡上）。
  ///
  /// ⚠️ 不能只记「是否 hover 选中项」这个 bool：web 的扫光选择器是
  /// `.has-auroraqua-highlight:hover > .auroraqua-nav-highlight::after`
  /// —— **CSS 每帧实时求值**。所以「指针静止、点击后高亮滑到指针下」
  /// 也会立即触发扫光；而 Flutter 的 `MouseRegion.onEnter/onExit`
  /// **只在指针移动时**触发，指针不动就收不到 → 漏掉这一半（实测报障）。
  ///
  /// 记索引 + 在 build 里求值 `_hoveredIndex == 选中索引`，即可复刻
  /// CSS 的实时语义：选中项一变，等式结果随之变化，无需新的指针事件。
  int _hoveredIndex = -1;

  /// **按压中**的选项卡索引（-1 = 无）。
  ///
  /// web 的胶囊是按钮的子元素 → 按钮 `:active { scale: .98 }` 时胶囊跟着缩。
  /// 本实现把胶囊放在容器级（为共享迁移），故需显式同步缩放。
  int _pressedIndex = -1;

  /// 直达高亮 State 的 key —— 让「指针进入选中项」**当场**启动扫光，
  /// 不经父级 setState → rebuild 的 1 帧往返（对齐 web `:hover` 的原生响应）。
  final GlobalKey<AylaNavHighlightState> _highlightKey =
      GlobalKey<AylaNavHighlightState>();

  /// 当前选中项索引。
  int get _selectedIndex => widget.options
      .indexWhere((({String key, String label}) o) => o.key == widget.value);

  @override
  void initState() {
    super.initState();
    _syncKeys();
  }

  void _syncKeys() {
    while (_slotKeys.length < widget.options.length) {
      _slotKeys.add(GlobalKey());
    }
  }

  @override
  void didUpdateWidget(covariant AylaDirectoryFilters old) {
    super.didUpdateWidget(old);
    if (old.options.length != widget.options.length) _syncKeys();
  }

  @override
  void dispose() {
    _scroll.dispose();
    for (final FocusNode n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  FocusNode _nodeFor(int i) {
    while (_nodes.length <= i) {
      _nodes.add(FocusNode(debugLabel: 'directory-filter-$i'));
    }
    return _nodes[i];
  }

  /// 布局后测量「选中槽位」矩形（含 padding —— 高亮必须铺满整个按钮）。
  ///
  /// 每次 build 都排一次测量：字体加载、滚动、切换都会改变几何。
  void _measureCapsule() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final int idx = widget.options
          .indexWhere((({String key, String label}) o) => o.key == widget.value);
      if (idx < 0 || idx >= _slotKeys.length) return;
      // 基准 = 高亮所在层（与高亮同坐标系），不是本组件的 RenderBox
      final RenderBox? self =
          _stackKey.currentContext?.findRenderObject() as RenderBox?;
      final RenderBox? slot =
          _slotKeys[idx].currentContext?.findRenderObject() as RenderBox?;
      if (self == null || slot == null || !slot.hasSize) return;
      final Rect rect =
          (slot.localToGlobal(Offset.zero, ancestor: self)) & slot.size;
      if (rect != _capsuleRect) setState(() => _capsuleRect = rect);
    });
  }

  /// 把第 [index] 项滚入可视区（**只滚筛选条**，保留结果区滚动位置）。
  void _reveal(int index) {
    if (!_scroll.hasClients ||
        index < 0 ||
        index >= widget.options.length ||
        index >= _slotKeys.length) {
      return;
    }
    final RenderBox? box =
        _slotKeys[index].currentContext?.findRenderObject() as RenderBox?;
    // 基准同高亮层（padding 之内）
    final RenderBox? self =
        _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || self == null || !box.hasSize || !self.hasSize) return;

    final Offset topLeft = box.localToGlobal(Offset.zero, ancestor: self);
    // padding 在 GlassSurface 内（sp3）；scroll-padding 与之同值
    const double padding = AylaSpacing.sp3;
    final double viewport = widget.narrow ? self.size.width : self.size.height;
    final double start = widget.narrow ? topLeft.dx : topLeft.dy;
    final double end = start + (widget.narrow ? box.size.width : box.size.height);
    final double usable = viewport - padding * 2;

    double delta = 0;
    if (start < padding) {
      delta = start - padding;
    } else if (end > padding + usable) {
      delta = end - (padding + usable);
    }
    if (delta == 0) return;
    _scroll.jumpTo(
      (_scroll.offset + delta).clamp(0, _scroll.position.maxScrollExtent),
    );
  }

  /// 键盘导航（tsx onKeyDown）：窄屏 ←/→、宽屏 ↑/↓ 循环；Home/End；
  /// **方向键同时改变选中值**。
  KeyEventResult _onKey(int index, FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final int n = widget.options.length;
    if (n == 0) return KeyEventResult.ignored;

    final LogicalKeyboardKey nextKey = widget.narrow
        ? LogicalKeyboardKey.arrowRight
        : LogicalKeyboardKey.arrowDown;
    final LogicalKeyboardKey prevKey = widget.narrow
        ? LogicalKeyboardKey.arrowLeft
        : LogicalKeyboardKey.arrowUp;

    int? nextIndex;
    if (event.logicalKey == LogicalKeyboardKey.home) {
      nextIndex = 0;
    } else if (event.logicalKey == LogicalKeyboardKey.end) {
      nextIndex = n - 1;
    } else if (event.logicalKey == nextKey) {
      nextIndex = (index + 1) % n;
    } else if (event.logicalKey == prevKey) {
      nextIndex = (index - 1 + n) % n;
    }
    if (nextIndex == null) return KeyEventResult.ignored;

    final String next = widget.options[nextIndex].key;
    _nodeFor(nextIndex).requestFocus();
    _reveal(nextIndex);
    if (next != widget.value) widget.onChange(next);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    _measureCapsule();

    // ---------- 选项卡（不含任何底；底由容器级高亮绘制） ----------
    final List<Widget> tabs = <Widget>[
      for (int i = 0; i < widget.options.length; i++)
        KeyedSubtree(
          key: _slotKeys[i],
          child: _FilterTab(
            focusNode: _nodeFor(i),
            label: widget.options[i].label,
            active: widget.options[i].key == widget.value,
            narrow: widget.narrow,
            style: t,
            onKey: (FocusNode n, KeyEvent e) => _onKey(i, n, e),
            onFocus: () => _reveal(i),
            // 只更新「指针所在索引」；扫光与否在 build 里按 CSS 语义求值
            onHoverChanged: (bool h) {
              final int next = h ? i : (_hoveredIndex == i ? -1 : _hoveredIndex);
              if (next != _hoveredIndex) {
                setState(() => _hoveredIndex = next);
              }
            },
            // 按压态上报（驱动容器级高亮的同步缩放，对齐 web 的
            // 「胶囊是按钮子元素 → 跟随 :active scale .98」）
            onPressedChanged: (bool p) {
              final int next = p ? i : (_pressedIndex == i ? -1 : _pressedIndex);
              if (next != _pressedIndex) {
                setState(() => _pressedIndex = next);
              }
            },
            // 选中项被指到/离开 → **直接**驱动高亮扫光（无父级 rebuild 往返）
            onSweep: (bool entering) {
              if (_highlightKey.currentState case final AylaNavHighlightState s) {
                s.setSweep(entering);
              }
            },
            onTap: () {
              if (widget.options[i].key != widget.value) {
                // **挂载即命中**（对齐 web）：点击的是一个「指针已经在上面」的
                // tab，web 上胶囊被挂载到该 tab 时 `:hover` 从第一帧就匹配 →
                // 首次绘制的 computed style 直接是 `translateX(120%)`（右侧界外），
                // **不产生 transition**。随后鼠标移走 → `120% → -120%` →
                // transition 跑出**完整的一次「从右往左」扫光**。
                //
                // 用 `jump: true` 把进度直接置到 1.0（= +120%），复刻这一语义。
                // 若改成 forward()，行程会在点击后立刻被消耗（16ms 才走 3%），
                // 「点击后马上移走」时回程几乎为零 → 看不到扫光（实测复现）。
                if (_highlightKey.currentState
                    case final AylaNavHighlightState sw) {
                  sw.setSweep(true, jump: true);
                }
                widget.onChange(widget.options[i].key);
              }
            },
          ),
        ),
    ];

    // ---------- 高亮（容器级单实例；尺寸 = 实测槽位矩形，含 padding） ----------
    // 高亮（容器级单实例）。用 [AnimatedPositioned] 让切换时**平滑迁移**
    // （300ms `--auroraqua-ease-out`）—— 等价 web 的 Framer `layoutId`：
    // 同一个实体在两项之间滑动，而不是旧底消失/新底出现。
    final Widget? highlight = _capsuleRect == null
        ? null
        : AnimatedPositioned(
            duration: AylaDurations.auroraqua, // 300ms --auroraqua-duration
            curve: AylaCurves.auroraquaEaseOut, // --auroraqua-ease-out
            left: _capsuleRect!.left,
            top: _capsuleRect!.top,
            width: _capsuleRect!.width,
            height: _capsuleRect!.height,
            // `:active → scale: .98` —— web 的胶囊是**按钮的子元素**
            // （`position:absolute; inset:0`），按钮按下缩放时胶囊**跟着缩**。
            // 本实现为支持共享迁移把胶囊放在**容器级**，因此不会自动继承按钮的
            // `AnimatedScale` → 需在此**同步同样的缩放**（时长/曲线一致）。
            // 判据：指针所在项 == 选中项 且该 tab 处于按压态。
            child: AnimatedScale(
              duration: const Duration(milliseconds: 200), // transition 200ms
              curve: AylaCurves.auroraqua,
              scale: _pressedIndex >= 0 && _pressedIndex == _selectedIndex
                  ? 0.98
                  : 1.0,
              child: AylaNavHighlight(
                key: _highlightKey,
                sweep: true,
                // CSS 语义：`.has-auroraqua-highlight:hover > .auroraqua-nav-highlight`
                // → 指针所在项 == 选中项时扫光（每帧求值，故"高亮滑到静止指针下"也触发）
                sweepActive: _hoveredIndex >= 0 && _hoveredIndex == _selectedIndex,
              ),
            ),
          );

    // ═══════════════ 窄屏（≤768）：无圆角顶栏 ═══════════════
    if (widget.narrow) {
      return AylaRevealItem(
        // animation: auroraqua-panel-from-top（0 -20px → 0,0）
        offset: const Offset(0, -20),
        child: GlassSurface(
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
            child: Stack(
              key: _stackKey, // 与高亮同坐标系（测量基准）
              clipBehavior: Clip.none,
              children: <Widget>[
                if (highlight != null) highlight,
                Row(
                  children: <Widget>[
                    for (int i = 0; i < tabs.length; i++) ...<Widget>[
                      if (i > 0) const SizedBox(width: AylaSpacing.sp2),
                      tabs[i],
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    // ═══════════════ 宽屏（>768）：玻璃卡片侧栏 ═══════════════
    return AylaRevealItem(
      // animation: auroraqua-sidebar-in（-20px 0 → 0,0）
      offset: const Offset(-20, 0),
      child: SizedBox(
        width: AylaDirectoryFilters.sidebarWidth, // flex: 0 0 224px
        child: GlassSurface(
          radius: AylaRadii.rCard, // border-radius: var(--radius-card) 16
          shadow: AylaShadows.compact, // --glass-shadow-compact
          padding: null,
          child: SingleChildScrollView(
            controller: _scroll,
            // ⚠️ **padding 必须放在滚动视图内部**：CSS 的 `overflow-y: auto`
            // 裁剪边界是 **padding box**（含 padding），而 Flutter 的
            // `SingleChildScrollView` 裁剪在**自己的 content box**。若 padding
            // 留在外层 `GlassSurface`，滚动视图就落在 padding 之内 → tab 的
            // hover 外阴影（`--glass-shadow-nav` 的 8px 扩散）**左右两侧被裁断**。
            // 故 padding 归滚动内容承担（与 CSS 的 padding 等效）。
            padding: const EdgeInsets.all(AylaSpacing.sp3), // padding: var(--sp-3)
            child: Stack(
              key: _stackKey, // 与高亮同坐标系（测量基准）
              clipBehavior: Clip.none,
              children: <Widget>[
                if (highlight != null) highlight,
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: AylaSpacing.sp2, // gap: sp2
                  children: <Widget>[
                    // leading / decor / header 仅宽屏渲染（窄屏 display:none）
                    if (widget.leading != null) widget.leading!,
                    if (widget.decor != null) widget.decor!,
                    if (widget.header != null) widget.header!,
                    ...tabs,
                  ],
                ),
              ],
            ),
          ),
        ),
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
      duration: const Duration(milliseconds: 200), // transition 200ms
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

// ======================= 预览 =======================

/// 资料卡（在线 / 离线 / busy / 错误态）。
@Preview(
  group: 'Widgets',
  name: 'UserProfileCard（在线/离线/申请中/进入中/错误）',
  size: Size(1000, 420),
  wrapper: previewTheme,
)
Widget previewUserProfileCard() {
  Widget frame(String label, Widget child) => SizedBox(
        width: 300,
        height: 330,
        child: Stack(
          children: <Widget>[
            child,
            Positioned(
              left: 0,
              bottom: 0,
              child: Text(label, style: const TextStyle(fontSize: 11)),
            ),
          ],
        ),
      );

  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp4),
    child: Row(
      children: <Widget>[
        frame('在线 + 签名', const AylaUserProfileCard(
          nickname: '小樱',
          signature: '今天也要开开心心的',
          online: true,
          displayStatus: '在线',
          onAddFriend: null,
          onSendMessage: null,
          onClose: null,
        )),
        const SizedBox(width: AylaSpacing.sp3),
        frame('离线 + 无签名 + 关闭', const AylaUserProfileCard(
          nickname: '阿蓝',
          username: 'ablu',
          online: false,
          displayStatus: '3 小时前在线',
          onClose: null,
        )),
        const SizedBox(width: AylaSpacing.sp3),
        frame('申请中（按钮禁用）', const AylaUserProfileCard(
          nickname: '小樱',
          online: true,
          displayStatus: '在线',
          friendBusy: true,
        )),
      ],
    ),
  );
}

/// 目录筛选条（宽屏玻璃卡片侧栏 / 窄屏无圆角顶栏）。
@Preview(
  group: 'Widgets',
  name: 'DirectoryFilters（宽屏卡片侧栏 / 窄屏无圆角顶栏）',
  size: Size(1100, 460),
  wrapper: previewTheme,
)
Widget previewDirectoryFilters() => const _DirectoryFiltersDemo();

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
