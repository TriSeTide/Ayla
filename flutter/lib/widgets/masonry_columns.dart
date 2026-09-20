/// 双列等宽错排瀑布（web `hooks/useMasonryColumns.ts` 1–146 的 Flutter 等价物）。
///
/// 语义（逐条对齐）：
/// - 每个 item 分配到 **当前较矮列**（按实测列高 + 未实测批的预估增量），列宽一致、高度错落；
/// - **分配一旦确定就锁定**，不因高度测量而重排（避免视觉跳动与滚动恢复错位）；
/// - 分配记忆存**模块级 Map**（按 `memoryKey:columnCount` 隔离）→ 跨挂载恢复
///   （进详情→返回时列布局与离开时一致）；
/// - 列数变化（单列↔双列）不继承旧分配（web 2026-08-26 实测：否则全部挤进一列）；
/// - 每列高度由**渲染后实测**（web ResizeObserver → 这里用 postFrame 量 RenderBox）
///   供后续新 item 的插入决策；测量**不触发重排**。
library;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// 模块级分配记忆：`"memoryKey:columnCount"` → (itemKey → 列序号)。
final Map<String, Map<Object, int>> _columnMemory = <String, Map<Object, int>>{};

/// 清空分配记忆（测试隔离用；对齐 web `clearMasonryMemory`）。
void aylaClearMasonryMemory() => _columnMemory.clear();

/// 双列/单列瀑布容器。
class AylaMasonryColumns extends StatefulWidget {
  const AylaMasonryColumns({
    super.key,
    required this.itemCount,
    required this.columnCount,
    required this.memoryKey,
    required this.keyOf,
    required this.itemBuilder,
    this.estimatedItemHeight = 320,
    this.spacing = AylaSpacing.sp2,
  });

  /// 条目数。
  final int itemCount;

  /// 列数（宽屏 2 / 窄屏 1）。
  final int columnCount;

  /// 分配记忆键（web `memoryKey`，如 `posts-feed:all`）。
  final String memoryKey;

  /// 取条目稳定 key（用于分配记忆）。
  final Object Function(int index) keyOf;

  /// 构造第 [index] 项。
  final Widget Function(BuildContext context, int index) itemBuilder;

  /// 新项尚无实测高度时的预估增量（web `ESTIMATED_ITEM_HEIGHT = 320`）。
  final double estimatedItemHeight;

  /// 列间距与列内条目间距。
  final double spacing;

  @override
  State<AylaMasonryColumns> createState() => _AylaMasonryColumnsState();
}

class _AylaMasonryColumnsState extends State<AylaMasonryColumns> {
  final List<GlobalKey> _columnKeys = <GlobalKey>[];
  List<List<int>> _columns = <List<int>>[];
  List<double> _heights = <double>[];
  int _measuredForCount = -1;

  @override
  void initState() {
    super.initState();
    _assign();
  }

  @override
  void didUpdateWidget(covariant AylaMasonryColumns old) {
    super.didUpdateWidget(old);
    if (old.itemCount != widget.itemCount ||
        old.columnCount != widget.columnCount ||
        old.memoryKey != widget.memoryKey) {
      _assign();
    }
  }

  /// 分配（web 77–109）：清理失效 key → 已有分配锁定 → 新 key 插最矮列（预估增量）。
  void _assign() {
    final int count = widget.columnCount < 1 ? 1 : widget.columnCount;
    final String scoped = '${widget.memoryKey}:$count';
    final Map<Object, int> memory =
        _columnMemory.putIfAbsent(scoped, () => <Object, int>{});

    final Set<Object> live = <Object>{
      for (int i = 0; i < widget.itemCount; i++) widget.keyOf(i),
    };
    memory.removeWhere((Object key, int _) => !live.contains(key));

    final List<double> heights = <double>[
      for (int i = 0; i < count; i++) i < _heights.length ? _heights[i] : 0,
    ];
    final List<List<int>> columns = <List<int>>[
      for (int i = 0; i < count; i++) <int>[],
    ];
    for (int index = 0; index < widget.itemCount; index++) {
      final Object key = widget.keyOf(index);
      int? column = memory[key];
      if (column == null || column >= count) {
        int shortest = 0;
        for (int i = 1; i < count; i++) {
          if (heights[i] < heights[shortest]) shortest = i;
        }
        column = shortest;
        memory[key] = column;
        heights[column] += widget.estimatedItemHeight; // 预估增量：同批交错
      }
      columns[column].add(index);
    }
    while (_columnKeys.length < count) {
      _columnKeys.add(GlobalKey());
    }
    if (_columnKeys.length > count) {
      _columnKeys.removeRange(count, _columnKeys.length);
    }
    _columns = columns;
    _measureAfterFrame();
  }

  /// 渲染后实测列高（web ResizeObserver）：只更新 `_heights`，**不 setState**，
  /// 因此不会因测量而重排（记忆一旦分配即锁定）。
  void _measureAfterFrame() {
    final int signature = widget.itemCount * 1000 + widget.columnCount;
    if (_measuredForCount == signature) return;
    _measuredForCount = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final List<double> next = <double>[];
      for (final GlobalKey key in _columnKeys) {
        final RenderBox? box = key.currentContext?.findRenderObject() as RenderBox?;
        next.add(box != null && box.hasSize ? box.size.height : 0);
      }
      if (next.length == widget.columnCount &&
          next.any((double h) => h > 0)) {
        _heights = next;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final int count = widget.columnCount < 1 ? 1 : widget.columnCount;
    if (_columns.length != count) _assign();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int c = 0; c < count; c++) ...<Widget>[
          if (c > 0) SizedBox(width: widget.spacing),
          Expanded(
            child: Column(
              key: _columnKeys[c],
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (int i = 0; i < _columns[c].length; i++) ...<Widget>[
                  if (i > 0) SizedBox(height: widget.spacing),
                  widget.itemBuilder(context, _columns[c][i]),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}
