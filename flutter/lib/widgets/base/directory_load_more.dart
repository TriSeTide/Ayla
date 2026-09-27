/// directory load more（自 `directory_controls.dart` 拆出：一文件一件）。
///
/// 事实源与逐条对照见 `docs/flutter/17-组件文件头归档（整理前原文）.md` 的 `directory_controls.dart` 一节
/// 与各件的 `///` 头注。
///
/// ## 公开面
/// `AylaDirectoryLoadMore`

library;

import 'package:flutter/material.dart';
import '../../theme/glass.dart';
import 'pagination_footer.dart';

/// 目录「加载更多」（`DirectoryLoadMore.tsx` + home.css 631–637）。
///
/// ## 事实源（tsx 行为）
/// - `error != null` → **返回 null**（错误由外层 AsyncState 呈现，页脚不重复报错）
/// - `!retainCompletedSpace && !loading && !hasMore && !invalidated` → 返回 null
///   （**紧凑侧栏不保留空页脚**；长 feed 保留终端滚动空间）
/// - `invalidated`（加载中数据被更新）→ **自动 `refresh()` 恢复**，不打扰用户；
///   刷新期间若再有更新会保持 invalidated 继续刷新直到稳定
/// - **触底自动加载**：IntersectionObserver `rootMargin: "240px 0px"`
///   （提前 240px 触发）
/// - 三态展示：invalidated → 点 + 「正在刷新列表」/
///   loading → 点 / hasMore → 「加载更多」ghost 按钮 / 否则空
///
/// `.home-load-more { display:flex; justify-content:center; gap:6px; padding: sp3 }`
class AylaDirectoryLoadMore extends StatefulWidget {
  const AylaDirectoryLoadMore({
    super.key,
    required this.loading,
    required this.error,
    required this.hasMore,
    required this.invalidated,
    required this.loadMore,
    required this.refresh,
    this.retainCompletedSpace = true,
  });

  /// 是否加载中。
  final bool loading;

  /// 错误文案（非 null 时本组件不渲染）。
  final String? error;

  /// 是否还有更多。
  final bool hasMore;

  /// 数据在加载过程中被更新（需自动刷新恢复）。
  final bool invalidated;

  /// 加载更多。
  final Future<void> Function() loadMore;

  /// 重新拉取（invalidated 时自动调用）。
  final Future<void> Function() refresh;

  /// 长 feed 保留终端滚动空间；紧凑侧栏传 false（无空页脚）。
  final bool retainCompletedSpace;

  /// 触底预加载余量（tsx `rootMargin: "240px 0px"`）。
  static const double rootMargin = 240;

  @override
  State<AylaDirectoryLoadMore> createState() => _AylaDirectoryLoadMoreState();
}

class _AylaDirectoryLoadMoreState extends State<AylaDirectoryLoadMore> {
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoRefresh());
  }

  @override
  void didUpdateWidget(covariant AylaDirectoryLoadMore old) {
    super.didUpdateWidget(old);
    _maybeAutoRefresh();
  }

  /// `invalidated && !loading` → 自动 refresh（tsx useEffect）。
  void _maybeAutoRefresh() {
    if (!mounted) return;
    if (widget.invalidated && !widget.loading && !_refreshing) {
      _refreshing = true;
      widget.refresh().whenComplete(() {
        _refreshing = false;
      });
    }
  }

  /// 触底自动加载（对齐 `IntersectionObserver{rootMargin:'240px 0px'}`）。
  ///
  /// 用 [NotificationListener] 监听**自身所在**滚动视图（页脚是滚动内容的一部分，
  /// 通知会向上冒泡经过它 → 可达）；判定「距底 ≤ 240px」即触发。
  bool _onScroll(ScrollNotification n) {
    if (widget.loading ||
        widget.error != null ||
        widget.invalidated ||
        !widget.hasMore) {
      return false;
    }
    final ScrollMetrics m = n.metrics;
    if (m.axis != Axis.vertical) return false;
    if (m.pixels >= m.maxScrollExtent - AylaDirectoryLoadMore.rootMargin) {
      widget.loadMore();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    // tsx：error 时完全不渲染（错误由外层呈现）
    if (widget.error != null) return const SizedBox.shrink();

    final bool idle =
        !widget.loading && !widget.hasMore && !widget.invalidated;
    // 紧凑侧栏不保留空页脚
    if (!widget.retainCompletedSpace && idle) return const SizedBox.shrink();

    Widget content;
    if (widget.invalidated) {
      content = const AylaPaginationLoadingDots(semanticLabel: '正在刷新列表');
    } else if (widget.loading) {
      content = const AylaPaginationLoadingDots();
    } else if (widget.hasMore) {
      // 2026-09-20 审查 R3：改用组件库 AylaGlassButton(ghost)——原 _GhostButton 手搓
      // `.btn-ghost`，缺 blur(8px)、600ms 扫光、hover scale 1.02 / press .98
      // 与 200ms transition 组（auroraqua.css 55–70/100–102/142–166）。
      content = AylaGlassButton(
        label: '加载更多',
        variant: AylaGlassButtonVariant.ghost,
        onPressed: () {
          widget.loadMore();
        },
      );
    } else {
      content = const SizedBox.shrink();
    }

    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: AylaStablePaginationFooter(
        child: Center(child: content), // justify-content: center
      ),
    );
  }
}

// ======================= HistoryControls =======================
