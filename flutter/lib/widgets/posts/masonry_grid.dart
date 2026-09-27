/// 等宽错排瀑布流容器（web `hooks/useMasonryColumns.ts` 146 行 + `posts.css 607–694` /
/// `profile.css 458–545`）。
///
/// ## 事实源
/// ```
/// useMasonryColumns.ts 22   ESTIMATED_ITEM_HEIGHT = 320（同批新项无实测高度时的预估卡高）
/// useMasonryColumns.ts 25   模块级分配记忆：memoryKey → (itemKey → columnIndex)，**跨挂载恢复**
///                           （进详情→返回时列布局与离开时一致，scrollTop 才能精确恢复）
/// useMasonryColumns.ts 38   scopedKey = `${memoryKey}:${columnCount}`（**断点切换不继承旧分配**）
/// tsx 96–117                分配：新项插**当前最矮列**（并列取下标小者），插后 heights[c] += 320；
///                           已分配的项**锁定原列**（永不因测量重排）；越界（断点切换）重新分配；
///                           已消失的 item 清理分配记忆
/// tsx 120–140               列高由 ResizeObserver 实测（offsetHeight）；**单列跳过**
/// posts.css 607–611         .posts-feed：column · gap sp3 · padding sp3 sp4
/// posts.css 615–626         .posts-feed-item（flex none / min-width 0）· .posts-masonry-col（column · gap sp3）
/// posts.css 677–691         （≥1025 由页面加 `.is-masonry`）row + wrap + align-items flex-start ·
///                           `.posts-masonry-col { flex: 1 1 0 }` · `.home-load-more { flex-basis: 100% }`
/// profile.css 458–476       .favorites-list：column · gap **sp2** · padding sp3 sp4；
///                           .favorites-masonry-col：column · gap **sp2**
/// profile.css 526–537       （≥769 双列）row · align-items flex-start · 容器 gap **sp3** ·
///                           padding-top/bottom **sp4** · 列 gap **sp3**
/// ```
/// ⚠️ 两处**有意差异**（逐条登记，勿当遗漏）：① 单列 gap 与双列 gap 不同（posts 都是 sp3；
/// favorites 单列 sp2 / 双列 sp3）⇒ 暴露 [gap] 与 [masonryGap]；② favorites 双列时容器上下
/// padding 由 sp3 变 **sp4** ⇒ 暴露 [masonryPadding]。
///
/// ## 机制差异（登记）
/// web 用 `ResizeObserver` 量列高、用模块级 `Map` 存分配记忆；Flutter 等价物：
/// 列容器挂 `GlobalKey` 在**帧后**实测高度（同 `AylaStablePaginationFooter` 的测量手法），
/// 分配记忆用模块级 `Map`（[aylaClearMasonryMemory] 供测试隔离）。
///
/// ## 公开面
/// `AylaMasonryGrid` · `aylaClearMasonryMemory` · `kAylaMasonryEstimatedItemHeight`
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// 同批新项无实测高度时的预估卡高（web `ESTIMATED_ITEM_HEIGHT`）。
const double kAylaMasonryEstimatedItemHeight = 320;

/// 模块级分配记忆：`memoryKey:columnCount` → (`itemKey` → 列下标)。
///
/// 与 web 同语义：**跨挂载恢复**列布局（返回列表时不错位），断点切换按列数隔离。
final Map<String, Map<Object, int>> _masonryMemory = <String, Map<Object, int>>{};

/// 清空分配记忆（测试隔离用；web `clearMasonryMemory`）。
void aylaClearMasonryMemory() => _masonryMemory.clear();

/// 等宽错排瀑布流：单列（窄）或 N 列（宽），列内纵向排布、高度随内容错落。
class AylaMasonryGrid<T> extends StatefulWidget {
  const AylaMasonryGrid({
    super.key,
    required this.items,
    required this.itemBuilder,
    required this.itemKey,
    this.memoryKey = '',
    this.columns,
    this.twoColumnMinWidth = 1025,
    this.gap = AylaSpacing.sp3,
    this.masonryGap,
    this.padding = const EdgeInsets.fromLTRB(
      AylaSpacing.sp4,
      AylaSpacing.sp3,
      AylaSpacing.sp4,
      AylaSpacing.sp3,
    ),
    this.masonryPadding,
    this.footer,
    this.estimatedItemHeight = kAylaMasonryEstimatedItemHeight,
  });

  /// 列表数据（顺序即分配顺序）。
  final List<T> items;

  /// 单项构建（`index` 为**全局**下标）。
  final Widget Function(BuildContext context, T item, int index) itemBuilder;

  /// 稳定 key（web `getKey`）：分配记忆按它索引。
  final Object Function(T item) itemKey;

  /// 分配记忆键（web `memoryKey`，通常传滚动恢复键）。
  final String memoryKey;

  /// 显式列数；null ⇒ 按可用宽与 [twoColumnMinWidth] 自动（web 页面用 `(min-width: 1025px)`）。
  final int? columns;

  /// 双列断点（CSS px；web 页面常量 `MASONRY_QUERY = (min-width: 1025px)`）。
  final double twoColumnMinWidth;

  /// 单列间距（`.posts-feed`/`.favorites-list` 基样式：posts sp3 / favorites sp2）。
  final double gap;

  /// 双列间距（`.posts-masonry-col` / `.favorites-list.is-masonry { gap }`；null ⇒ 同 [gap]）。
  final double? masonryGap;

  /// 单列内距（基样式 `padding: sp3 sp4`）。
  final EdgeInsetsGeometry padding;

  /// 双列内距（收藏双列时上下变 sp4；null ⇒ 同 [padding]）。
  final EdgeInsetsGeometry? masonryPadding;

  /// 跨列底部内容（web `.home-load-more { flex-basis: 100% }`；null ⇒ 无）。
  final Widget? footer;

  /// 同批新项预估高度（分配临时决策用）。
  final double estimatedItemHeight;

  @override
  State<AylaMasonryGrid<T>> createState() => _AylaMasonryGridState<T>();
}

class _AylaMasonryGridState<T> extends State<AylaMasonryGrid<T>> {
  /// 每列一个测量 key（帧后量真实高度，等价 web 的 ResizeObserver）。
  final List<GlobalKey> _columnKeys = <GlobalKey>[];

  /// 每列累计高度（只有分配决策读它）。
  List<double> _heights = <double>[];

  /// 上一帧的列数：变化即重置高度（旧列高属旧布局）。
  int _lastColumnCount = 0;

  int get _columnCount =>
      widget.columns ?? (MediaQuery.sizeOf(context).width >= widget.twoColumnMinWidth ? 2 : 1);

  // ⚠️ 不在 `initState` 读 `MediaQuery`（库内既有结论：会抛 dependOnInheritedWidget 断言）——
  //    列键与高度都在 `build` 里按当帧列数同步（[_syncColumnKeys] 幂等）。

  void _syncColumnKeys(int count) {
    while (_columnKeys.length < count) {
      _columnKeys.add(GlobalKey());
    }
    if (_columnKeys.length > count) {
      _columnKeys.removeRange(count, _columnKeys.length);
    }
    if (_lastColumnCount != count) {
      // 列数变化 ⇒ 旧列高作废（web：`colHeights.current` 重置）
      _heights = List<double>.filled(count, 0);
      _lastColumnCount = count;
    } else {
      while (_heights.length < count) {
        _heights.add(0);
      }
      if (_heights.length > count) {
        _heights.removeRange(count, _heights.length);
      }
    }
  }

  /// 帧后实测每列高度（等价 `ResizeObserver` 的 `measureColumns`）。
  void _measureColumns() {
    if (!mounted || _lastColumnCount <= 1) return; // 单列跳过（web 同）
    bool changed = false;
    final List<double> next = List<double>.of(_heights);
    for (int i = 0; i < _columnKeys.length; i++) {
      final RenderBox? box =
          _columnKeys[i].currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final double h = box.size.height;
      if (h > 0 && (h - next[i]).abs() > 0.5) {
        next[i] = h;
        changed = true;
      }
    }
    if (changed) _heights = next; // 不改 setState：只影响**后续**分配决策，本帧无需重排
  }

  /// web tsx 96–117 的分配：新项插最矮列 + 预估增量；已分配项锁定；越界重分配；清理消失项。
  List<List<T>> _distribute() {
    final int count = _columnCount;
    _syncColumnKeys(count);
    final Map<Object, int> memory = _masonryMemory.putIfAbsent(
      '${widget.memoryKey}:$count',
      () => <Object, int>{},
    );
    final Set<Object> live = <Object>{
      for (final T item in widget.items) widget.itemKey(item),
    };
    memory.removeWhere((Object k, int _) => !live.contains(k));

    final List<List<T>> columns = <List<T>>[
      for (int i = 0; i < count; i++) <T>[],
    ];
    final List<double> heights = List<double>.of(_heights);
    for (final T item in widget.items) {
      final Object k = widget.itemKey(item);
      int? c = memory[k];
      if (c == null || c >= count) {
        int shortest = 0;
        for (int i = 1; i < count; i++) {
          if (heights[i] < heights[shortest]) shortest = i;
        }
        c = shortest;
        memory[k] = c;
        heights[c] += widget.estimatedItemHeight; // 同批交错
      }
      columns[c].add(item);
    }
    return columns;
  }

  @override
  Widget build(BuildContext context) {
    final int count = _columnCount;
    _syncColumnKeys(count);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureColumns());

    // 全局下标（web 的 map 回调拿的是列内下标，这里给全局下标更有用）
    final Map<Object, int> indexOf = <Object, int>{};
    for (int i = 0; i < widget.items.length; i++) {
      indexOf[widget.itemKey(widget.items[i])] = i;
    }
    final List<List<T>> columns = _distribute();
    final double gap = count > 1 ? (widget.masonryGap ?? widget.gap) : widget.gap;
    final EdgeInsetsGeometry padding = count > 1
        ? (widget.masonryPadding ?? widget.padding)
        : widget.padding;

    Widget columnAt(int i) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: gap,
      key: _columnKeys[i],
      children: <Widget>[
        for (final T item in columns[i])
          KeyedSubtree(
            key: ValueKey<Object>(widget.itemKey(item)),
            child: widget.itemBuilder(context, item, indexOf[widget.itemKey(item)] ?? 0),
          ),
      ],
    );

    final Widget body = count <= 1
        ? columnAt(0)
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start, // align-items: flex-start
            spacing: widget.masonryGap ?? widget.gap,
            children: <Widget>[
              for (int i = 0; i < count; i++)
                Expanded(child: columnAt(i)), // flex: 1 1 0
            ],
          );

    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          body,
          if (widget.footer != null) ...<Widget>[
            SizedBox(height: gap),
            widget.footer!, // web：flex-basis 100% ⇒ 横跨两列
          ],
        ],
      ),
    );
  }
}
