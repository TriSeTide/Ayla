/// 共享胶囊高亮列表 —— 「容器级单实例高亮 + 300ms 迁移 + 按压同步 + 扫光直达 + 键盘 +
/// 滚动揭示」的公共实现。
///
/// ## 为什么要抽这一件（2026-09-24 用户点名）
/// > 「会话列表背景卡片、选中高亮、切换动画等应直接复用 DirectoryFilters 宽屏侧栏」
///
/// `AylaDirectoryFilters`（`profile_and_filters.dart`）里那套高亮机制原本**内联在它内部**，
/// 会话列表（`conversation_list.dart`）只能照抄一遍 —— 违反「凡『每个都带』的东西要建基类」。
/// 本文件把该机制抽成公共件，`AylaDirectoryFilters` 与会话列表**共用同一份代码**。
///
/// ## 事实源
///
/// | 本文件 | web |
/// |---|---|
/// | 胶囊本体 | `auroraqua.css:175–185`（`.auroraqua-nav-highlight`：`inset:0` / `z-index:-1` / `--nav-active-bg` / 1px 边 / `--glass-shadow-nav`）+ `188` 的 `::after` 扫光 700ms |
/// | 宿主类 | `auroraqua.css:169–173`（`.has-auroraqua-highlight`）+ `194–197`（选中项**自身底取消**，底归胶囊） |
/// | 迁移语义 | Framer `layoutId` 等价：同一实体在两项之间滑动（`AnimatedPositioned` 300ms） |
/// | 扫光两态 | `auroraqua.css:161–166`（`:hover` 驱动）+ 「挂载即命中不产生过渡」 |
/// | 键盘 | `DirectoryFilters.tsx` 的 onKeyDown（宽屏 ↑↓ / 窄屏 ←→ 循环、Home/End、**方向键同时改选中**） |
/// | 滚动揭示 | 选中/聚焦项若在视口外只滚动**本列表**自身，带 `scroll-padding: sp3` 补偿 |
///
/// ## 使用方式
/// 调用方给出**项数**与 `itemBuilder`；[AylaNavHighlightSlot] 提供槽位 key、FocusNode、
/// hover/press 上报、扫光直达与点击处理，由子项按自身样式渲染（**子项自己不给选中底**：
/// web 的 `is-active { background: transparent }` 把底交给胶囊）。
///
/// ## 公开面
/// `AylaNavHighlightSlot` · `AylaNavHighlightList` · `AylaNavHighlightListState`

library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyEvent, KeyDownEvent, LogicalKeyboardKey;

import '../../theme/tokens.dart';
import 'primitives.dart' show AylaNavHighlight, AylaNavHighlightState;

/// 传给 [AylaNavHighlightList.itemBuilder] 的槽位句柄。
class AylaNavHighlightSlot {
  const AylaNavHighlightSlot({
    required this.index,
    required this.slotKey,
    required this.focusNode,
    required this.active,
    required this.onHoverChanged,
    required this.onPressedChanged,
    required this.onSweep,
    required this.onTap,
    required this.onKey,
  });

  final int index;

  /// 槽位 key（容器级高亮按它的**实测矩形**定位 —— 含子项 padding，与 web `inset:0` 一致）。
  final Key slotKey;

  /// 键盘焦点节点（方向键在项间移动焦点）。
  final FocusNode focusNode;

  /// 是否选中（子项据此去掉自身底）。
  final bool active;

  /// 指针进入/离开本槽位（调用方只需上报，扫光的**求值在 build 里**按 CSS 语义进行）。
  final ValueChanged<bool> onHoverChanged;

  /// 按压态上报（驱动容器级胶囊同步 `scale .98`）。
  final ValueChanged<bool> onPressedChanged;

  /// 选中项被指到/离开时**直接**驱动胶囊扫光（不经父级 rebuild 的一帧往返）。
  final ValueChanged<bool> onSweep;

  /// 点击本槽位（选中变化 + 「挂载即命中」扫光直达由本件内部处理）。
  final VoidCallback onTap;

  /// 键盘事件（挂到子项的 `Focus(onKeyEvent:)`）。
  final KeyEventResult Function(FocusNode node, KeyEvent event) onKey;
}

/// 共享胶囊高亮列表。
class AylaNavHighlightList extends StatefulWidget {
  const AylaNavHighlightList({
    super.key,
    required this.itemCount,
    required this.selectedIndex,
    required this.itemBuilder,
    this.axis = Axis.vertical,
    this.gap = AylaSpacing.sp2,
    this.onSelect,
    this.scrollController,
    this.scrollPadding = AylaSpacing.sp3,
    this.selectOnKeyNav = true,
    this.semanticLabel,
  });

  final int itemCount;

  /// 当前选中索引（-1 = 无选中，此时不画胶囊）。
  final int selectedIndex;

  /// 项构建器（按索引给 [AylaNavHighlightSlot]）。
  final Widget Function(BuildContext context, AylaNavHighlightSlot slot) itemBuilder;

  /// 主轴方向：`vertical` → ↑↓ 导航（宽屏侧栏）；`horizontal` → ←→（窄屏顶栏）。
  final Axis axis;

  /// 项间距（`gap: sp2`）。
  final double gap;

  /// 选中变化（点击或方向键触发）。
  final ValueChanged<int>? onSelect;

  /// 传入则做**滚动揭示**（选中/聚焦项不在视口时只滚动本列表自身）。
  final ScrollController? scrollController;

  /// 滚动补偿（`scroll-padding: var(--sp-3)`）。
  final double scrollPadding;

  /// 方向键是否同时改变选中（`DirectoryFilters` 为 true；只挪焦点的场景传 false）。
  final bool selectOnKeyNav;

  /// 语义标签（等价 `role=tablist` 的 aria-label）。
  final String? semanticLabel;

  @override
  State<AylaNavHighlightList> createState() => AylaNavHighlightListState();
}

/// 列表状态（公开以便调用方驱动滚动揭示，先例：`AylaNavHighlightState`）。
class AylaNavHighlightListState extends State<AylaNavHighlightList> {
  final List<GlobalKey> _slotKeys = <GlobalKey>[];
  final List<FocusNode> _nodes = <FocusNode>[];

  /// 高亮所在层的 key —— **测量基准必须与高亮同坐标系**。
  ///
  /// 高亮画在容器的 padding **之内**（调用方把 padding 交给滚动内容承担），
  /// 若拿容器 RenderBox 当 `ancestor` 测量会多减一次 padding（实测：高亮左移出卡片）。
  final GlobalKey _stackKey = GlobalKey();

  /// 选中槽位的实测矩形（相对高亮所在层）。
  Rect? _capsuleRect;

  /// 指针当前所在索引（-1 = 不在任何项上）。
  ///
  /// ⚠️ 不能只记「是否 hover 选中项」这个 bool：web 的扫光选择器
  /// `.has-auroraqua-highlight:hover > .auroraqua-nav-highlight::after` 是**每帧求值**的，
  /// 所以「指针静止、点击后高亮滑到指针下」也会立即触发扫光；而 `MouseRegion.onEnter/onExit`
  /// **只在指针移动时**触发 ⇒ 记索引 + 在 build 里求值即可复刻 CSS 语义。
  int _hoveredIndex = -1;

  /// 按压中的索引（-1 = 无；胶囊跟随 `.98`）。
  int _pressedIndex = -1;

  /// 直达高亮 State 的 key（让「指针进入选中项」当场启动扫光）。
  final GlobalKey<AylaNavHighlightState> _highlightKey =
      GlobalKey<AylaNavHighlightState>();

  GlobalKey<AylaNavHighlightState> get highlightKey => _highlightKey;

  @override
  void initState() {
    super.initState();
    _syncKeys();
  }

  void _syncKeys() {
    while (_slotKeys.length < widget.itemCount) {
      _slotKeys.add(GlobalKey());
    }
  }

  @override
  void didUpdateWidget(covariant AylaNavHighlightList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemCount != widget.itemCount) _syncKeys();
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      // 切换选中**当帧重测**：项几何在切换时并不变化（仅状态变），排到 postFrame
      // 会白等一帧才启动 300ms 迁移动画（13 号 §六「切换类动画」）。
      // 注意：本件**仍**在每次 build 排一次 postFrame 测量（字体加载/滚动/换行都会改几何）。
      final RenderBox? self =
          _stackKey.currentContext?.findRenderObject() as RenderBox?;
      final int idx = widget.selectedIndex;
      if (self != null && self.hasSize && idx >= 0 && idx < _slotKeys.length) {
        final RenderBox? slot =
            _slotKeys[idx].currentContext?.findRenderObject() as RenderBox?;
        if (slot != null && slot.hasSize) {
          final Rect rect =
              (slot.localToGlobal(Offset.zero, ancestor: self)) & slot.size;
          if (rect != _capsuleRect) {
            setState(() => _capsuleRect = rect);
          }
        }
      }
    }
  }

  @override
  void dispose() {
    for (final FocusNode n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  FocusNode _nodeFor(int i) {
    while (_nodes.length <= i) {
      final int index = _nodes.length;
      final FocusNode node = FocusNode(debugLabel: 'nav-highlight-$index');
      // 聚焦即把该项滚入可视区（web 的 onFocus → reveal；`DirectoryFilters.tsx` 同款）
      node.addListener(() {
        if (node.hasFocus) reveal(index);
      });
      _nodes.add(node);
    }
    return _nodes[i];
  }

  /// 布局后测量「选中槽位」矩形（含子项 padding —— 高亮必须铺满整个项）。
  void _measureCapsule() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final int idx = widget.selectedIndex;
      if (idx < 0 || idx >= _slotKeys.length) return;
      final RenderBox? self =
          _stackKey.currentContext?.findRenderObject() as RenderBox?;
      final RenderBox? slot =
          _slotKeys[idx].currentContext?.findRenderObject() as RenderBox?;
      if (self == null || slot == null || !slot.hasSize || !self.hasSize) return;
      final Rect rect =
          (slot.localToGlobal(Offset.zero, ancestor: self)) & slot.size;
      if (rect != _capsuleRect) setState(() => _capsuleRect = rect);
    });
  }

  /// 把第 [index] 项滚入可视区（**只滚本列表**）。
  void reveal(int index) {
    final ScrollController? scroll = widget.scrollController;
    if (scroll == null ||
        !scroll.hasClients ||
        index < 0 ||
        index >= widget.itemCount ||
        index >= _slotKeys.length) {
      return;
    }
    final RenderBox? box =
        _slotKeys[index].currentContext?.findRenderObject() as RenderBox?;
    final RenderBox? self =
        _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || self == null || !box.hasSize || !self.hasSize) return;

    final Offset topLeft = box.localToGlobal(Offset.zero, ancestor: self);
    final bool horizontal = widget.axis == Axis.horizontal;
    final double start = horizontal ? topLeft.dx : topLeft.dy;
    final double end = start + (horizontal ? box.size.width : box.size.height);
    // ⚠️ **视口尺寸必须取 ScrollPosition.viewportDimension**（不能用 `self.size`）：
    // `self` 是滚动内容里的 Stack，高度 = **内容全高** ⇒ 算出的 usable 远大于真实视口，
    // 「末项在视口外」会被判成「在视口内」而不滚动（抽件时实测复现；原
    // `AylaDirectoryFilters` 的实现同样取 self 尺寸，属继承来的潜在 bug，此处一并修正）。
    final double viewport = scroll.position.viewportDimension;
    final double usable = viewport - widget.scrollPadding * 2;

    double delta = 0;
    if (start < widget.scrollPadding) {
      delta = start - widget.scrollPadding;
    } else if (end > widget.scrollPadding + usable) {
      delta = end - (widget.scrollPadding + usable);
    }
    if (delta == 0) return;
    scroll.jumpTo(
      (scroll.offset + delta).clamp(0, scroll.position.maxScrollExtent),
    );
  }

  /// 键盘导航：`axis` 决定方向键；Home/End 跳首末；**方向键同时改变选中**。
  KeyEventResult _onKey(int index, FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final int n = widget.itemCount;
    if (n == 0) return KeyEventResult.ignored;

    final bool horizontal = widget.axis == Axis.horizontal;
    final LogicalKeyboardKey nextKey =
        horizontal ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowDown;
    final LogicalKeyboardKey prevKey =
        horizontal ? LogicalKeyboardKey.arrowLeft : LogicalKeyboardKey.arrowUp;

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
    if (!widget.selectOnKeyNav) {
      // 只挪焦点（会话列表等以「选择」为主要动作的场景仍走 onSelect）
      _nodeFor(nextIndex).requestFocus();
      reveal(nextIndex);
      return KeyEventResult.handled;
    }

    _nodeFor(nextIndex).requestFocus();
    reveal(nextIndex);
    if (nextIndex != widget.selectedIndex) widget.onSelect?.call(nextIndex);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    _measureCapsule();

    final List<Widget> items = <Widget>[
      for (int i = 0; i < widget.itemCount; i++)
        KeyedSubtree(
          key: _slotKeys[i],
          child: Builder(
            builder: (BuildContext context) => widget.itemBuilder(
              context,
              AylaNavHighlightSlot(
                index: i,
                slotKey: _slotKeys[i],
                focusNode: _nodeFor(i),
                active: i == widget.selectedIndex,
                onHoverChanged: (bool h) {
                  final int next = h ? i : (_hoveredIndex == i ? -1 : _hoveredIndex);
                  if (next != _hoveredIndex) {
                    setState(() => _hoveredIndex = next);
                  }
                },
                onPressedChanged: (bool p) {
                  final int next = p ? i : (_pressedIndex == i ? -1 : _pressedIndex);
                  if (next != _pressedIndex) {
                    setState(() => _pressedIndex = next);
                  }
                },
                onSweep: (bool entering) {
                  if (_highlightKey.currentState case final AylaNavHighlightState s) {
                    s.setSweep(entering);
                  }
                },
                onTap: () {
                  if (i != widget.selectedIndex) {
                    // **挂载即命中**（对齐 web）：点击的是一个「指针已经在上面」的项，
                    // web 上胶囊被挂载到该项时 `:hover` 从第一帧就匹配 ⇒ 首次绘制的
                    // computed style 直接是 `translateX(120%)`（右侧界外），**不产生 transition**；
                    // 随后鼠标移走 → `120% → -120%` 跑出完整一次「从右往左」扫光。
                    // 用 `jump: true` 把进度直接置到 1.0，复刻该语义（forward() 会让行程
                    // 在点击后立刻被消耗，回程几乎为零 → 看不到扫光）。
                    if (_highlightKey.currentState
                        case final AylaNavHighlightState sw) {
                      sw.setSweep(true, jump: true);
                    }
                    widget.onSelect?.call(i);
                  }
                },
                onKey: (FocusNode n, KeyEvent e) => _onKey(i, n, e),
              ),
            ),
          ),
        ),
    ];

    // 容器级单实例胶囊：`AnimatedPositioned` 300ms 迁移（Framer `layoutId` 等价）
    final Widget? highlight = _capsuleRect == null || widget.selectedIndex < 0
        ? null
        : AnimatedPositioned(
            duration: AylaDurations.auroraqua,
            curve: AylaCurves.auroraquaEaseOut,
            left: _capsuleRect!.left,
            top: _capsuleRect!.top,
            width: _capsuleRect!.width,
            height: _capsuleRect!.height,
            // `:active → scale: .98`：web 的胶囊是**按钮子元素**、跟随按钮缩放；
            // 本实现为支持共享迁移把胶囊放在容器级 ⇒ 在此同步同样的缩放。
            child: AnimatedScale(
              duration: const Duration(milliseconds: 200),
              curve: AylaCurves.auroraqua,
              scale:
                  _pressedIndex >= 0 && _pressedIndex == widget.selectedIndex
                      ? 0.98
                      : 1.0,
              child: AylaNavHighlight(
                key: _highlightKey,
                sweep: true,
                // CSS 语义：`.has-auroraqua-highlight:hover > .auroraqua-nav-highlight`
                sweepActive:
                    _hoveredIndex >= 0 && _hoveredIndex == widget.selectedIndex,
              ),
            ),
          );

    final Widget list = widget.axis == Axis.horizontal
        ? Row(
            children: <Widget>[
              for (int i = 0; i < items.length; i++) ...<Widget>[
                if (i > 0) SizedBox(width: widget.gap),
                items[i],
              ],
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: widget.gap,
            children: items,
          );

    final Widget stack = Stack(
      key: _stackKey, // 与高亮同坐标系（测量基准）
      clipBehavior: Clip.none,
      children: <Widget>[
        if (highlight != null) highlight,
        list,
      ],
    );

    final String? label = widget.semanticLabel;
    return label == null
        ? stack
        : Semantics(container: true, label: label, child: stack);
  }
}
