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
///   （提前 240px 触发）⇒ Flutter 侧 = 直接监听**祖先 `ScrollPosition`**
///   （web 的观察器是全局的；Flutter 的 `Notification` 只向**祖先**冒泡，而本件在
///   `Scrollable` 的**子树下面**，详见 [State._position] 的实测证据）
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
    this.autoLoadMore = true,
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

  /// 是否由**本件自己**承担「触底自动加载」。
  ///
  /// - `true`（默认）= tsx 语义：本件监听祖先 `ScrollPosition`，距底
  ///   < [rootMargin] 即 `loadMore()`（`DirectoryLoadMore.tsx:21–28` 的
  ///   `IntersectionObserver{rootMargin:'240px 0px'}`）；
  /// - `false` = 触底 owner 已上移到**宿主滚动容器**，本件只保留
  ///   「加载更多」按钮与 `invalidated` 自动 refresh（视觉与三态一律不变）。
  ///
  /// **为什么需要这个开关**：web 里容器 `onScroll`（`ChannelSidebar.tsx:531–534`）
  /// 与页脚 `IntersectionObserver`（`DirectoryLoadMore.tsx:21–28`）是**两条并存**
  /// 的路径，靠 store 层 `_pending` 去重；但 Flutter 侧
  /// `AylaChannelDirectory.loadMore` 在测试里是**注入的计数回调**，绕过 store 去重
  /// ⇒ 两路并存会让侧栏「恰好触发一次」的回归锁失去判别力
  /// （侧栏已按 web 把触底 owner 上移到容器，见 `channel_sidebar.dart` 的
  /// `_onListScroll` / `_maybeLoadMore`）。
  final bool autoLoadMore;

  /// 触底预加载余量（tsx `rootMargin: "240px 0px"`）。
  static const double rootMargin = 240;

  @override
  State<AylaDirectoryLoadMore> createState() => _AylaDirectoryLoadMoreState();
}

class _AylaDirectoryLoadMoreState extends State<AylaDirectoryLoadMore> {
  bool _refreshing = false;

  /// 最近祖先 `Scrollable` 的滚动位置（触底判定的数据源）。
  ///
  /// ⚠️ **不能用 `NotificationListener`**：Flutter 的 `Notification` 只向**祖先**
  /// 冒泡（`framework.dart` 的 `_NotificationNode.dispatchNotification` 只走
  /// `parent`），而本件是**页脚**——它是`Scrollable` 的视图的**后代**，
  /// 通知从 `notificationContext`（`scrollable.dart:604`）起泡、**永远不会经过它**。
  /// 修复前 `:144` 的 `NotificationListener` 因此是**死路径**：
  /// - 实测探针①（最简复现）：滚动容器**内部**的监听器命中 **0** 次，
  ///   同一容器**外部**的命中 **6** 次；
  /// - 实测探针②（真实本件，`hasMore:true` 已渲染出「加载更多」按钮）：
  ///   放进 `SingleChildScrollView` 拖到底后打印
  ///   `calls=0  pixels=380.0  max=380.0  extentAfter=0.0` ——
  ///   **触底了但 `loadMore` 一次都没触发**（共享件级别的静默失效）。
  ///
  /// 故改为直接监听祖先 [ScrollPosition]（`ViewportOffset extends ChangeNotifier`，
  /// `viewport_offset.dart:100`），库内范本：`widgets/shell/fab.dart:326–351` 与
  /// `widgets/group/group_card.dart:259–273`。
  ScrollPosition? _position;

  /// post-frame 判定是否已排队（照 `fab.dart:344–351` 的 `_scheduleRecompute`）。
  bool _checkQueued = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 首帧 layout 之后才能读 `extentAfter`：此时补一次绑定 + 判定。
      // 这也顺带覆盖「短列表内容不足一屏 ⇒ 首帧就已在触发区」的情形。
      _bindPosition();
      _maybeAutoRefresh();
      _scheduleCheck();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindPosition();
  }

  @override
  void didUpdateWidget(covariant AylaDirectoryLoadMore old) {
    super.didUpdateWidget(old);
    _maybeAutoRefresh();
    // 排到帧后：`extentAfter` 依赖的 `maxScrollExtent` 要等新内容 layout 完成
    // 才是最终值。裸调 `_maybeAutoLoadMore()`（用旧值）会在「点「加载更多」→
    // loading 态塌缩页脚」等路径上产生虚假触发；帧后值是稳定的。
    _scheduleCheck();
  }

  @override
  void dispose() {
    _position?.removeListener(_scheduleCheck);
    super.dispose();
  }

  /// 绑定最近的祖先 `ScrollPosition`（`fab.dart:326–341` / `group_card.dart:259–273`）。
  ///
  /// 幂等；`didChangeDependencies` 在依赖变化时会再调一次，但此时
  /// [ScrollableState.position] 返回的是**同一个** `ScrollPosition` 对象
  /// （`scrollable.dart:618–637` 只在 didChangeDependencies 重建），故不会抖动。
  void _bindPosition() {
    if (!mounted) return;
    ScrollPosition? found;
    context.visitAncestorElements((Element element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        found = (element.state as ScrollableState).position; // 取最近的一个即停
        return false;
      }
      return true;
    });
    if (identical(found, _position)) return;
    _position?.removeListener(_scheduleCheck);
    _position = found;
    _position?.addListener(_scheduleCheck);
    _scheduleCheck();
  }

  /// 排到帧后判定一次（首帧 `viewportDimension`/`maxScrollExtent` 尚未就绪）。
  void _scheduleCheck() {
    if (_checkQueued) return;
    _checkQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkQueued = false;
      if (mounted) _maybeAutoLoadMore();
    });
  }

  /// 触底自动加载（web 语义，逐条对齐 `DirectoryLoadMore.tsx:21–28`）。
  ///
  /// ① tsx 22：`loading || error || invalidated || !hasMore` ⇒ 早退且**不观察**；
  /// ② tsx 25：`rootMargin: '240px 0px'` ⇒ 进入视口外扩 240px 即触发，
  ///    等价于「距底 < 240」（`my_posts_page.dart:188` / `post_detail_page.dart:366`
  ///    两处宿主自挂的容器级监听用的是同一条余量口径）；
  /// ③ tsx 24：`loadMore()`。观察器是**一次性**的（触发即 `disconnect`），
  ///    但 Flutter 的 `ScrollPosition` 是持续的 —— 二者的差值恰由 ② 的
  ///    `loading` 守卫接住：`loadMore` 同步置 `loading=true` 后本件重建，
  ///    后续滚动帧全部早退；`loading` 期间也**不重绑**该 position，
  ///    故不会出现重复触发。
  void _maybeAutoLoadMore() {
    if (!mounted || !widget.autoLoadMore) return;
    if (widget.loading ||
        widget.error != null ||
        widget.invalidated ||
        !widget.hasMore) {
      return;
    }
    final ScrollPosition? p = _position;
    // `extentAfter` / `pixels` 在首帧 layout 之前读取会抛 Null check
    // （`scroll_metrics.dart:202 / 152` ⇒ `scroll_position.dart:264`）。
    if (p == null || !p.hasContentDimensions || !p.hasPixels) return;
    if (p.extentAfter < AylaDirectoryLoadMore.rootMargin) {
      widget.loadMore();
    }
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

    // 触底触发不再挂在树的这一层：见 [State._position]（通知只向祖先冒泡，
    // 这里的 `NotificationListener` 是收不到滚动通知的死路径）。渲染结构保持原样。
    return AylaStablePaginationFooter(
      child: Center(child: content), // justify-content: center
    );
  }
}

// ======================= HistoryControls =======================
