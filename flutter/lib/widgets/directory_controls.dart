/// 目录/分页族与收藏按钮
/// （`FavoriteButton.tsx` / `DirectoryLoadMore.tsx` / `StablePaginationFooter.tsx`
/// / `HistoryControls.tsx`）。
///
/// 事实源见各段落注释（逐条对照 tsx 与 CSS）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';

// ======================= StablePaginationFooter =======================

/// 稳定分页页脚（`StablePaginationFooter.tsx` + home.css 639–656）。
///
/// ## 事实源
/// ```
/// .stable-pagination-footer { display:flex; flex:none; width:100%;
///   min-height:80px; padding: var(--sp-3); flex-direction:column;
///   align-items:center; justify-content:center; gap: var(--sp-2);
///   overflow-anchor:none; }
/// ```
/// **核心语义**：记住**测到过的最大高度**，并在列表仍挂载期间把它写回
/// `min-height` —— 这样「重试/进度/已到底」三态切换时**页脚盒子不塌缩**，
/// 下方内容不跳动（tsx 用 `useLayoutEffect` 首测 + `ResizeObserver` 增量测）。
///
/// Flutter 等价：`LayoutBuilder` 首测 + 内容变化后重测，用 `Container.minHeight`
/// 锁定历史最大值（`overflowAnchor:none` 对应 Flutter 无隐含锚定行为，无需处理）。
class StablePaginationFooter extends StatefulWidget {
  const StablePaginationFooter({
    super.key,
    required this.child,
    this.minHeight = 80,
  });

  /// 页脚内容（三态之一）。
  final Widget child;

  /// 初始最小高度（`.stable-pagination-footer { min-height: 80px }`）。
  final double minHeight;

  @override
  State<StablePaginationFooter> createState() => _StablePaginationFooterState();
}

class _StablePaginationFooterState extends State<StablePaginationFooter> {
  final GlobalKey _contentKey = GlobalKey();

  /// 历史最大高度（tsx `tallest` ref）。
  double _tallest = 0;

  @override
  Widget build(BuildContext context) {
    // 内容变化后测真实高度并抬高 minHeight（tsx：useLayoutEffect 首测 +
    // ResizeObserver 增量测）。用 post-frame 测量避免布局期内 setState。
    WidgetsBinding.instance.addPostFrameCallback((_) => _retainHeight());
    return Container(
      width: double.infinity, // width: 100%
      constraints: BoxConstraints(
        minHeight: _tallest > widget.minHeight ? _tallest : widget.minHeight,
      ),
      padding: const EdgeInsets.all(AylaSpacing.sp3), // padding: var(--sp-3)
      child: UnconstrainedBox(
        // 让内容按自然高度布局（不被 minHeight 拉伸，才能测准）
        constrainedAxis: Axis.horizontal,
        child: KeyedSubtree(key: _contentKey, child: widget.child),
      ),
    );
  }

  /// 记住测到过的最大高度（`.stable-pagination-footer` 的核心语义：
  /// 三态切换时页脚盒子不塌缩、下方内容不跳动）。
  void _retainHeight() {
    if (!mounted) return;
    final RenderBox? box =
        _contentKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final double h = box.size.height;
    if (h > _tallest && mounted) {
      setState(() => _tallest = h);
    }
  }
}

// ======================= 加载点 =======================

/// `.pagination-loading-dots` —— 三个 6px 冰蓝圆点（home.css 659–671）。
class PaginationLoadingDots extends StatelessWidget {
  const PaginationLoadingDots({super.key, this.semanticLabel});

  /// 无障碍标签（如「正在加载历史」）。
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final Widget dots = SizedBox(
      // min-height: 40px
      height: 40,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6, // gap: 6px
        children: <Widget>[
          for (int i = 0; i < 3; i++)
            Container(
              width: 6, // width: 6px
              height: 6, // height: 6px
              decoration: const BoxDecoration(
                color: AylaColors.ice500, // background: var(--ice-500)
                shape: BoxShape.circle, // border-radius: pill
              ),
            ),
        ],
      ),
    );
    return semanticLabel == null
        ? dots
        : Semantics(label: semanticLabel, child: dots);
  }
}

// ======================= DirectoryLoadMore =======================

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
      content = const PaginationLoadingDots(semanticLabel: '正在刷新列表');
    } else if (widget.loading) {
      content = const PaginationLoadingDots();
    } else if (widget.hasMore) {
      // 2026-09-20 审查 R3：改用组件库 GlassButton(ghost)——原 _GhostButton 手搓
      // `.btn-ghost`，缺 blur(8px)、600ms 扫光、hover scale 1.02 / press .98
      // 与 200ms transition 组（auroraqua.css 55–70/100–102/142–166）。
      content = GlassButton(
        label: '加载更多',
        variant: GlassButtonVariant.ghost,
        onPressed: () {
          widget.loadMore();
        },
      );
    } else {
      content = const SizedBox.shrink();
    }

    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: StablePaginationFooter(
        child: Center(child: content), // justify-content: center
      ),
    );
  }
}

// ======================= HistoryControls =======================

/// 历史分页控制（`HistoryControls.tsx`）。
///
/// 同样是「投影边界 + 显式续读/重试」：
/// - `error` → 文案 + 「重试」（loading 时禁用）
/// - `loading` → 三点 + aria「正在加载历史」
/// - `hasMore` → 「加载更早记录」
/// - `hasNewer` → 「返回最新消息」（loading 时禁用）
///
/// `role`：有 error 时 `alert`，否则 `status`；`aria-busy = loading`。
class AylaHistoryControls extends StatelessWidget {
  const AylaHistoryControls({
    super.key,
    required this.loading,
    required this.error,
    required this.hasMore,
    required this.hasNewer,
    required this.loadOlder,
    required this.returnLatest,
    required this.retry,
  });

  /// 是否加载中。
  final bool loading;

  /// 错误文案。
  final String? error;

  /// 是否还有更早的记录。
  final bool hasMore;

  /// 是否有更新的消息（可跳回最新）。
  final bool hasNewer;

  /// 加载更早。
  final Future<void> Function() loadOlder;

  /// 返回最新。
  final Future<void> Function() returnLatest;

  /// 重试。
  final Future<void> Function() retry;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);

    final List<Widget> items = <Widget>[
      if (error != null) ...<Widget>[
        Text(
          error!,
          style: t.body.copyWith(color: AylaColors.destructive),
        ),
        GlassButton(
          label: '重试',
          variant: GlassButtonVariant.ghost,
          onPressed: loading
              ? null
              : () {
                  retry();
                },
        ),
      ],
      if (loading)
        const PaginationLoadingDots(semanticLabel: '正在加载历史')
      else if (hasMore)
        GlassButton(
          label: '加载更早记录',
          variant: GlassButtonVariant.ghost,
          onPressed: () {
            loadOlder();
          },
        ),
      if (hasNewer)
        GlassButton(
          label: '返回最新消息',
          variant: GlassButtonVariant.ghost,
          onPressed: loading
              ? null
              : () {
                  returnLatest();
                },
        ),
    ];

    return StablePaginationFooter(
      child: Semantics(
        liveRegion: error != null, // role=alert
        label: error != null ? '加载出错' : '分页状态',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: AylaSpacing.sp2, // gap: var(--sp-2)
          children: items,
        ),
      ),
    );
  }
}

// ======================= FavoriteButton =======================

/// 收藏三态（对应 tsx 的 `state.favoriteId`：undefined / null / 数字）。
enum FavoriteState {
  /// 状态未知（加载中）→ 禁用 + 「加载中…」
  unknown,

  /// 未收藏 → 「收藏」
  notFavorited,

  /// 已收藏 → 「已收藏」
  favorited,

  /// 状态加载失败 → 「重试收藏状态」（点击重新拉取）
  error,
}

/// 收藏按钮（`FavoriteButton.tsx` + app.css 3312–3341）。
///
/// ## 事实源
/// ```
/// .favorite-toggle { inline-flex; center; gap: var(--sp-1);
///   min-height: 36px; padding: 0 var(--sp-2);
///   border: 1px solid var(--glass-border); border-radius: var(--radius-pill);
///   background: var(--glass-bg-strong); color: var(--text-secondary); }
/// :hover, :focus-visible, .is-active {
///   color: var(--pink-500); border-color: var(--pink-500);
///   box-shadow: var(--glow-shadow); }
/// .is-compact { min-width:32px; min-height:32px; padding: 0 var(--sp-1) }
/// :disabled { cursor: wait; opacity: .7 }
/// ```
/// **图标**：`IconHeart`，compact 时 16、否则 18；**已收藏时 `fill=currentColor`**
/// （实心），未收藏 `fill=none`（线框）。
/// **文案**：`!compact` 才显示文字（error→「重试收藏状态」/unknown→「加载中…」
/// /active→「已收藏」/else→「收藏」）。
///
/// ## 行为（tsx）
/// - 点击 **stopPropagation**（不触发卡片自身的打开动作）
/// - `busy || loading` 时忽略点击；`unknown && !error` 时按钮 disabled
/// - **状态未知或出错时点击 = 重新拉取状态**（不是收藏）
/// - 请求中 busy；失败显示 `actionError`（`role=alert`）
/// - `aria-pressed = unknown ? undefined : active`
class AylaFavoriteButton extends StatefulWidget {
  const AylaFavoriteButton({
    super.key,
    required this.state,
    this.compact = false,
    this.busy = false,
    this.actionError,
    this.onToggle,
    this.onRetryStatus,
    this.onPressedInsideCard,
  });

  /// 收藏状态。
  final FavoriteState state;

  /// 紧凑形态（`.is-compact`：32×32、无文字、图标 16）。
  final bool compact;

  /// 请求进行中（禁用）。
  final bool busy;

  /// 操作失败文案（`role=alert`）。
  final String? actionError;

  /// 切换收藏（传入目标状态：true = 收藏）。
  final ValueChanged<bool>? onToggle;

  /// 状态未知/出错时点击 → 重新拉取状态。
  final VoidCallback? onRetryStatus;

  /// 点击前的拦截（卡片内使用时用于 stopPropagation）。
  final VoidCallback? onPressedInsideCard;

  @override
  State<AylaFavoriteButton> createState() => _AylaFavoriteButtonState();
}

class _AylaFavoriteButtonState extends State<AylaFavoriteButton> {
  bool _hovered = false;
  bool _focused = false;

  bool get _active => widget.state == FavoriteState.favorited;

  /// `favoriteId === undefined`（状态未知）。
  bool get _unknown =>
      widget.state == FavoriteState.unknown || widget.state == FavoriteState.error;

  /// tsx 69 行：`disabled={busy || state.loading || (unknown && !state.error)}`
  ///
  /// **关键**：**error 态不 disabled** —— 正是为了「点击重试拉取状态」
  /// （tsx 35–38：`if (state.error || state.favoriteId === undefined)
  ///  { loadFavoriteStatuses(...); return; }`）。
  /// 只有「加载中（unknown 且无 error）」才禁用。
  bool get _disabled =>
      widget.busy || (widget.state == FavoriteState.unknown);

  /// tsx `label`（aria）：error → 「收藏状态加载失败，点击重试」；
  /// unknown → 「正在加载收藏状态」；active → 「取消收藏」；else → 「收藏」。
  String get _ariaLabel {
    switch (widget.state) {
      case FavoriteState.error:
        return '收藏状态加载失败，点击重试';
      case FavoriteState.unknown:
        return '正在加载收藏状态';
      case FavoriteState.favorited:
        return '取消收藏';
      case FavoriteState.notFavorited:
        return '收藏';
    }
  }

  /// `!compact` 时显示的文案。
  String get _text {
    switch (widget.state) {
      case FavoriteState.error:
        return '重试收藏状态';
      case FavoriteState.unknown:
        return '加载中…';
      case FavoriteState.favorited:
        return '已收藏';
      case FavoriteState.notFavorited:
        return '收藏';
    }
  }

  void _handleTap() {
    widget.onPressedInsideCard?.call(); // stopPropagation 等价
    // tsx 34：`if (busy || state.loading) return`
    if (widget.busy || widget.state == FavoriteState.unknown) return;
    // tsx 35–38：error 或 favoriteId===undefined → 重新拉取状态（不是收藏）
    if (_unknown) {
      widget.onRetryStatus?.call();
      return;
    }
    widget.onToggle?.call(!_active);
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool highlight = _hovered || _focused || _active;

    final Widget button = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _disabled ? null : _handleTap,
        child: Focus(
          onFocusChange: (bool f) => setState(() => _focused = f),
          child: AnimatedContainer(
            duration: AylaDurations.fast, // --dur-fast 180ms
            curve: AylaCurves.easeOut,
            // `.favorite-toggle { min-height: 36px }`；`.is-compact { min-width:32;
            //   min-height:32; padding: 0 var(--sp-1) }`
            // compact 给**固定宽 32**（而非仅 minWidth）：否则内部
            // `MainAxisSize.max` 会撑满父级可用宽度（实测 800）。
            width: widget.compact ? 32 : null,
            constraints: BoxConstraints(
              minHeight: widget.compact ? 32 : 36,
              minWidth: widget.compact ? 32 : 0,
            ),
            padding: EdgeInsets.symmetric(
              horizontal: widget.compact ? AylaSpacing.sp1 : AylaSpacing.sp2,
            ),
            decoration: BoxDecoration(
              color: GlassConfig.resolveBackground(strong: true), // .78
              borderRadius: AylaRadii.pill,
              border: Border.all(
                // hover/focus/active → --pink-500；否则 --glass-border
                color: highlight ? AylaColors.pink500 : AylaColors.glassBorder,
              ),
            ),
            child: Row(
              // compact 时容器被 `minWidth: 32` 撑开、而内容只有 16 图标 + padding，
              // 若用 MainAxisSize.min + 默认 start 对齐，图标会**贴左偏 3px**
              // （实测：图标中心 397 vs 容器中心 400）。
              // web 是 inline-flex + **justify-content:center** → 内容始终居中。
              mainAxisSize:
                  widget.compact ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: AylaSpacing.sp1, // gap: var(--sp-1)
              children: <Widget>[
                AylaIcon(
                  aylaIconByName('iconHeart')!,
                  // compact 16、否则 18
                  size: widget.compact ? 16 : 18,
                  color: highlight
                      ? AylaColors.pink500 // color: var(--pink-500)
                      : AylaColors.textSecondary,
                  // fill={active ? "currentColor" : "none"} → 已收藏实心
                  filled: _active,
                ),
                if (!widget.compact)
                  Text(
                    _text,
                    style: t.label.copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: highlight
                          ? AylaColors.pink500
                          : AylaColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    // hover/focus/active → --glow-shadow：只画形状之外 + 180ms 淡入淡出
    // （2026-09-20 审查 R2：原裸 boxShadow 会把 .45 粉辉光染进 .78 强玻璃内部）
    final Widget withGlow = AylaGlassShadow.fadeRing(
      radius: AylaRadii.pill,
      shadows: AylaShadows.glow,
      visible: highlight,
      duration: AylaDurations.fast,
      child: button,
    );

    Widget result = Semantics(
      button: true,
      enabled: !_disabled,
      label: _ariaLabel,
      // aria-pressed = unknown ? undefined : active
      selected: _unknown ? null : _active,
      child: Opacity(
        // :disabled { opacity: .7 }
        opacity: _disabled && widget.busy ? 0.7 : 1,
        child: withGlow,
      ),
    );

    if (widget.actionError != null) {
      result = Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          result,
          Positioned(
            left: 0,
            right: 0,
            top: 40,
            child: Semantics(
              liveRegion: true, // role=alert
              child: Text(
                widget.actionError!,
                style: t.caption.copyWith(color: AylaColors.destructive),
              ),
            ),
          ),
        ],
      );
    }
    return result;
  }
}

// ======================= 内部：ghost 按钮 =======================

// ======================= 预览 =======================

/// 分页族三态（loadMore / loading / invalidated / 到底）。
@Preview(
  group: 'Widgets',
  name: '分页族（加载更多/加载中/刷新中/到底/历史控制）',
  size: Size(1000, 420),
  wrapper: previewTheme,
)
Widget previewPaginationFamily() {
  Widget cell(String label, Widget child) => SizedBox(
        width: 220,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0x33465B92)),
              ),
              child: child,
            ),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(fontSize: 11)),
          ],
        ),
      );

  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp4),
    child: Wrap(
      spacing: AylaSpacing.sp4,
      runSpacing: AylaSpacing.sp4,
      children: <Widget>[
        cell(
          'hasMore → 加载更多',
          AylaDirectoryLoadMore(
            loading: false, error: null, hasMore: true, invalidated: false,
            loadMore: () async {}, refresh: () async {},
          ),
        ),
        cell(
          'loading → 三点',
          AylaDirectoryLoadMore(
            loading: true, error: null, hasMore: true, invalidated: false,
            loadMore: () async {}, refresh: () async {},
          ),
        ),
        cell(
          'invalidated → 刷新中（auto refresh）',
          AylaDirectoryLoadMore(
            loading: false, error: null, hasMore: true, invalidated: true,
            loadMore: () async {}, refresh: () async {},
          ),
        ),
        cell(
          'error → 不渲染（外层负责）',
          AylaDirectoryLoadMore(
            loading: false, error: '网络错误', hasMore: true, invalidated: false,
            loadMore: () async {}, refresh: () async {},
          ),
        ),
        cell(
          '历史控制：更早 + 返回最新',
          AylaHistoryControls(
            loading: false, error: null, hasMore: true, hasNewer: true,
            loadOlder: () async {}, returnLatest: () async {}, retry: () async {},
          ),
        ),
        cell(
          '历史控制：error + 重试',
          AylaHistoryControls(
            loading: false, error: '加载历史失败', hasMore: false, hasNewer: false,
            loadOlder: () async {}, returnLatest: () async {}, retry: () async {},
          ),
        ),
      ],
    ),
  );
}

/// FavoriteButton 三态 + 紧凑形态。
@Preview(
  group: 'Widgets',
  name: 'FavoriteButton（收藏/已收藏/加载中/失败/紧凑）',
  size: Size(760, 200),
  wrapper: previewTheme,
)
Widget previewFavoriteButton() {
  Widget cell(String label, Widget child) => Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          child,
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      );

  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp4),
    child: Wrap(
      spacing: AylaSpacing.sp4,
      runSpacing: AylaSpacing.sp4,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        cell('未收藏', AylaFavoriteButton(
          state: FavoriteState.notFavorited, onToggle: (_) {})),
        cell('已收藏（实心 + 辉光）', AylaFavoriteButton(
          state: FavoriteState.favorited, onToggle: (_) {})),
        cell('加载中（禁用）', AylaFavoriteButton(
          state: FavoriteState.unknown, onRetryStatus: () {})),
        cell('状态失败 → 点击重试', AylaFavoriteButton(
          state: FavoriteState.error, onRetryStatus: () {})),
        cell('紧凑（32 圆钮 · 图标 16）', AylaFavoriteButton(
          state: FavoriteState.favorited, compact: true, onToggle: (_) {})),
        cell('操作失败提示（role=alert）', AylaFavoriteButton(
          state: FavoriteState.notFavorited,
          actionError: '收藏操作失败，请重试',
          onToggle: (_) {},
        )),
      ],
    ),
  );
}

// ======================= VisibilitySelector =======================

/// 可见性多选值（`VisibilitySelection`，tsx 10–14）。
///
/// **互斥规则**：`public` 与 `friends` **互斥**；`group`（群白名单）**独立**，
/// 可与二者任一叠加（「公开+群」「好友+群」均合法）。
class VisibilitySelection {
  const VisibilitySelection({
    this.isPublic = false,
    this.friends = false,
    this.group = false,
  });

  /// 公开。
  final bool isPublic;

  /// 好友可见。
  final bool friends;

  /// 指定群可见。
  final bool group;

  VisibilitySelection copyWith({bool? isPublic, bool? friends, bool? group}) =>
      VisibilitySelection(
        isPublic: isPublic ?? this.isPublic,
        friends: friends ?? this.friends,
        group: group ?? this.group,
      );
}

/// 可见性选择器（`VisibilitySelector.tsx` + app.css 92–200 + private.css 108–140）。
///
/// ## 事实源
/// ```
/// .visibility-selector { flex column; gap: sp2; border:none; padding:0; margin:0 }
/// .visibility-selector legend { font-display 12/500; ls .8; --text-secondary }
/// .visibility-selector-options { flex wrap; gap: sp2 }
/// .visibility-selector-options label {
///   inline-flex; center; gap: sp2; min-height:40; padding: 0 sp4;
///   1px --glass-border; radius-pill; --glass-bg; --text-primary; 14/600;
///   transition: background/border-color/box-shadow var(--dur-fast) }
/// label:hover                → background: rgba(249,176,255,.12)
/// label:has(:checked)        → border glow-500 + rgba(249,176,255,.16) + grape-700
/// label:has(:disabled)       → opacity .55
/// label.is-locked:has(:checked) → opacity 1（保持选中视觉、仅禁点）
/// input[type=checkbox]       → 16×16; accent-color: --glow-500
/// .visibility-selector-groups { glass 小卡：sp3 内边距 + radius-input 12 +
///   max-height 200 + overflow-y auto + --glass-shadow-compact + blur }
/// .group-create-chip { inline-flex; gap 4; padding 2px 8px 2px 10px; radius-pill;
///   --ice-100 底; 12/600 } · .group-create-chip-x { 16×16; hover → --destructive }
/// ```
///
/// ## 行为（tsx）
/// - `togglePublic`：勾选公开 → **friends 置 false**（互斥）
/// - `toggleFriends`：勾选好友 → **public 置 false**（互斥）
/// - `toggleGroup`：**独立切换**；取消勾选时**清空已选群**
/// - `lockGroup`（群内创建）：群大类**恒勾选且不可取消**；本群条目
///   `disabled` 且 `is-locked`（保持选中视觉）；其余群仍可多选
/// - 群搜索无结果 → 「没有匹配的群」
class AylaVisibilitySelector extends StatefulWidget {
  const AylaVisibilitySelector({
    super.key,
    required this.value,
    required this.onChange,
    this.selectedGroupIds = const <String>[],
    this.onSelectedGroupIdsChange,
    this.groups = const <({String id, String title})>[],
    this.groupsLoading = false,
    this.initialGroupId,
    this.lockGroup = false,
    this.legend = '可见范围',
  });

  /// 当前值。
  final VisibilitySelection value;

  /// 值变化。
  final ValueChanged<VisibilitySelection> onChange;

  /// 已选群 id。
  final List<String> selectedGroupIds;

  /// 已选群变化。
  final ValueChanged<List<String>>? onSelectedGroupIdsChange;

  /// 可搜索的群列表（真实数据由 `useSocialPage('conversations')` 提供）。
  final List<({String id, String title})> groups;

  /// 群列表是否加载中。
  final bool groupsLoading;

  /// 群内创建时的本群 id（锁定项）。
  final String? initialGroupId;

  /// 锁定群可见（本群强制勾选且不可取消）。
  final bool lockGroup;

  /// legend 文案（默认「可见范围」）。
  final String legend;

  @override
  State<AylaVisibilitySelector> createState() => _AylaVisibilitySelectorState();
}

class _AylaVisibilitySelectorState extends State<AylaVisibilitySelector> {
  final TextEditingController _query = TextEditingController();

  /// 群复选框实际勾选状态（lockGroup 时恒 true）。
  bool get _groupChecked => widget.lockGroup ? true : widget.value.group;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _togglePublic(bool checked) {
    // 公开与好友互斥；群可见独立保留
    widget.onChange(widget.value.copyWith(
      isPublic: checked,
      friends: checked ? false : widget.value.friends,
    ));
  }

  void _toggleFriends(bool checked) {
    widget.onChange(widget.value.copyWith(
      friends: checked,
      isPublic: checked ? false : widget.value.isPublic,
    ));
  }

  void _toggleGroup(bool checked) {
    if (widget.lockGroup) return; // 锁定大类不可取消（双保险）
    widget.onChange(widget.value.copyWith(group: checked));
    if (!checked) {
      widget.onSelectedGroupIdsChange?.call(<String>[]); // 取消勾选清空已选群
    }
  }

  List<({String id, String title})> get _filtered {
    final String q = _query.text.trim();
    if (q.isEmpty) return widget.groups;
    return widget.groups
        .where((({String id, String title}) g) => g.title.contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final List<({String id, String title})> filtered = _filtered;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AylaSpacing.sp2, // gap: var(--sp-2)
      children: <Widget>[
        // legend（font-display 12/500 ls .8 secondary）
        Text(
          widget.legend,
          style: TextStyle(
            fontFamily: AylaFonts.display,
            fontFamilyFallback: AylaFonts.cjkFallback,
            fontSize: 12, // font-size: 12px
            fontWeight: FontWeight.w500, // font-weight: 500
            letterSpacing: 0.8, // letter-spacing: 0.8px
            color: AylaColors.textSecondary,
          ),
        ),
        // ---------- 三个大类 ----------
        Wrap(
          spacing: AylaSpacing.sp2, // gap: var(--sp-2)
          runSpacing: AylaSpacing.sp2,
          children: <Widget>[
            _OptionChip(
              label: '公开',
              checked: widget.value.isPublic,
              onChanged: _togglePublic,
              style: t,
            ),
            _OptionChip(
              label: '好友可见',
              checked: widget.value.friends,
              onChanged: _toggleFriends,
              style: t,
            ),
            _OptionChip(
              label: '指定群可见',
              checked: _groupChecked,
              // lockGroup → disabled 但保持选中视觉（.is-locked）
              locked: widget.lockGroup,
              onChanged: _toggleGroup,
              style: t,
            ),
          ],
        ),
        // ---------- 群选择区（仅 groupChecked 时） ----------
        if (_groupChecked) _buildGroupPicker(t, filtered),
      ],
    );
  }

  Widget _buildGroupPicker(AylaTextStyles t, List<({String id, String title})> filtered) {
    final BorderRadius r = BorderRadius.circular(AylaRadii.rInput); // 12
    final bool opaque = GlassConfig.useOpaqueFallback;

    Widget face = Container(
      padding: const EdgeInsets.all(AylaSpacing.sp3), // padding: var(--sp-3)
      constraints: const BoxConstraints(maxHeight: 200), // max-height: 200px
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: AylaSpacing.sp1, // gap: var(--sp-1)
          children: <Widget>[
            // 搜索框：**复用组件库 GlassInput**（2026-09-20 审查 R4——原
            // _GroupSearchField 手搓 `.field`，缺 --glass-inset 内高光、
            // focus 辉光边与 blur(24)+saturate(1.4) 玻璃层）。
            // 位置覆写：`.visibility-selector-groups .field { padding-block: sp2;
            //   min-height: 40px }`（app.css 186–189）。
            GlassInput(
              controller: _query,
              hintText: '搜索群', // placeholder
              minHeight: 40,
              padding: const EdgeInsets.symmetric(
                horizontal: AylaSpacing.sp4,
                vertical: AylaSpacing.sp2,
              ),
              onChanged: (_) => setState(() {}),
            ),
            // 已选群 chips
            if (widget.selectedGroupIds.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AylaSpacing.sp2), // margin-top: sp2
                child: Wrap(
                  spacing: AylaSpacing.sp2,
                  runSpacing: AylaSpacing.sp2,
                  children: <Widget>[
                    for (final String id in widget.selectedGroupIds)
                      _GroupChip(
                        label: widget.groups
                                .where((({String id, String title}) g) => g.id == id)
                                .map((({String id, String title}) g) => g.title)
                                .firstOrNull ??
                            '群 $id',
                        // 锁定本群不显示 ×
                        onRemove: (widget.lockGroup && id == widget.initialGroupId)
                            ? null
                            : () => widget.onSelectedGroupIdsChange?.call(
                                  widget.selectedGroupIds
                                      .where((String x) => x != id)
                                      .toList(),
                                ),
                        style: t,
                      ),
                  ],
                ),
              ),
            // 列表 / 空态
            if (!widget.groupsLoading && filtered.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AylaSpacing.sp1),
                child: Text(
                  '没有匹配的群',
                  style: t.caption.copyWith(color: AylaColors.textSecondary),
                ),
              )
            else
              for (final ({String id, String title}) g in filtered)
                _GroupOption(
                  title: g.title,
                  // 锁定本群：恒勾选且 disabled
                  locked: widget.lockGroup && g.id == widget.initialGroupId,
                  checked: (widget.lockGroup && g.id == widget.initialGroupId) ||
                      widget.selectedGroupIds.contains(g.id),
                  onChanged: () {
                    final bool isSelected =
                        widget.selectedGroupIds.contains(g.id);
                    widget.onSelectedGroupIdsChange?.call(
                      isSelected
                          ? widget.selectedGroupIds
                              .where((String x) => x != g.id)
                              .toList()
                          : <String>[...widget.selectedGroupIds, g.id],
                    );
                  },
                  style: t,
                ),
          ],
        ),
      ),
    );

    Widget layered = face;
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
          face,
        ],
      );
    }

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        // --glass-shadow-compact（含 --glass-inset）——只画形状之外
        // （2026-09-20 审查 R2：裸 boxShadow 会染进半透明玻璃内部）
        Positioned.fill(
          child: IgnorePointer(
            child: AylaGlassShadow.ring(
              radius: r,
              shadows: AylaShadows.compact,
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: GlassConfig.resolveBackground(strong: false),
            borderRadius: r,
            border: Border.all(color: AylaColors.glassBorder),
          ),
          child: ClipRRect(borderRadius: r, child: layered),
        ),
      ],
    );
  }
}

/// `.visibility-selector-options label` —— 胶囊大选项（40 高，选中转粉辉光）。
class _OptionChip extends StatefulWidget {
  const _OptionChip({
    required this.label,
    required this.checked,
    required this.onChanged,
    required this.style,
    this.locked = false,
  });

  final String label;
  final bool checked;
  final ValueChanged<bool> onChanged;
  final AylaTextStyles style;

  /// 锁定（`.is-locked`：保持选中视觉、仅禁点）。
  final bool locked;

  @override
  State<_OptionChip> createState() => _OptionChipState();
}

class _OptionChipState extends State<_OptionChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // 选中态：border glow-500 + rgba(249,176,255,.16) + grape-700
    final Color bg = widget.checked
        ? const Color(0x29F9B0FF) // rgba(249,176,255,.16)
        : (_hovered
            ? const Color(0x1FF9B0FF) // rgba(249,176,255,.12)
            : GlassConfig.resolveBackground(strong: false));
    final Color border =
        widget.checked ? AylaColors.glow500 : AylaColors.glassBorder;
    final Color fg =
        widget.checked ? AylaColors.grape700 : AylaColors.textPrimary;

    return Semantics(
      checked: widget.checked,
      enabled: !widget.locked,
      label: widget.label,
      child: MouseRegion(
        cursor: widget.locked
            ? SystemMouseCursors.forbidden // cursor: not-allowed
            : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.locked ? null : () => widget.onChanged(!widget.checked),
          child: AnimatedContainer(
            duration: AylaDurations.fast, // --dur-fast
            curve: AylaCurves.easeOut,
            constraints: const BoxConstraints(minHeight: 40), // min-height: 40px
            padding: const EdgeInsets.symmetric(
              horizontal: AylaSpacing.sp4, // padding: 0 var(--sp-4)
            ),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: AylaRadii.pill, // radius-pill
              border: Border.all(color: border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: AylaSpacing.sp2, // gap: var(--sp-2)
              children: <Widget>[
                _Checkbox(checked: widget.checked, locked: widget.locked),
                Opacity(
                  // :has(:disabled) → .55；但 .is-locked:has(:checked) → 1
                  opacity: widget.locked && !widget.checked ? 0.55 : 1,
                  child: Text(
                    widget.label,
                    style: widget.style.label.copyWith(
                      fontSize: 14, // font-size: 14px
                      fontWeight: FontWeight.w600, // font-weight: 600
                      color: fg,
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
}

/// 16×16 复选框（`accent-color: var(--glow-500)`）。
class _Checkbox extends StatelessWidget {
  const _Checkbox({required this.checked, this.locked = false});

  final bool checked;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 16, // width: 16px
      height: 16, // height: 16px
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: checked ? AylaColors.glow500 : Colors.transparent, // accent-color
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: checked ? AylaColors.glow500 : AylaColors.textSecondary,
            width: 1.5,
          ),
        ),
        child: checked
            ? const Icon(Icons.check, size: 12, color: Colors.white)
            : null,
      ),
    );
  }
}

/// `.group-create-chip` —— 已选群胶囊（可删）。
class _GroupChip extends StatelessWidget {
  const _GroupChip({
    required this.label,
    required this.onRemove,
    required this.style,
  });

  final String label;

  /// null = 不显示 ×（锁定群）。
  final VoidCallback? onRemove;
  final AylaTextStyles style;

  @override
  Widget build(BuildContext context) {
    return Container(
      // padding: 2px 8px 2px 10px
      padding: const EdgeInsets.fromLTRB(10, 2, 8, 2),
      decoration: BoxDecoration(
        color: AylaColors.ice100, // background: var(--ice-100)
        borderRadius: AylaRadii.pill,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4, // gap: 4px
        children: <Widget>[
          Text(
            label,
            style: style.label.copyWith(
              fontSize: 12, // font-size: 12px
              fontWeight: FontWeight.w600, // font-weight: 600
              color: AylaColors.textPrimary,
            ),
          ),
          if (onRemove != null)
            Semantics(
              button: true,
              label: '取消选择群 $label',
              child: GestureDetector(
                onTap: onRemove,
                child: SizedBox(
                  width: 16, // width: 16px
                  height: 16, // height: 16px
                  child: Center(
                    child: Text(
                      '×',
                      style: style.label.copyWith(
                        fontSize: 13,
                        color: AylaColors.textSecondary, // 静息 secondary
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// `.visibility-group-option` —— 群列表行（40 高、radius-sm、14px）。
class _GroupOption extends StatelessWidget {
  const _GroupOption({
    required this.title,
    required this.checked,
    required this.onChanged,
    required this.style,
    this.locked = false,
  });

  final String title;
  final bool checked;
  final VoidCallback onChanged;
  final AylaTextStyles style;

  /// 锁定（恒勾选 + disabled，视觉保持正常 —— 同 `.is-locked` 语义）。
  final bool locked;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      checked: checked,
      enabled: !locked,
      label: title,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: locked ? null : onChanged,
        child: Container(
          constraints: const BoxConstraints(minHeight: 40), // min-height: 40px
          padding: const EdgeInsets.symmetric(
            horizontal: AylaSpacing.sp2, // padding: 0 var(--sp-2)
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AylaRadii.rSm), // radius-sm 8
          ),
          child: Row(
            spacing: AylaSpacing.sp2, // gap: var(--sp-2)
            children: <Widget>[
              _Checkbox(checked: checked, locked: locked),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style.label.copyWith(
                    fontSize: 14, // font-size: 14px
                    fontWeight: FontWeight.w400, // 行内非加粗（CSS 未设 weight）
                    color: AylaColors.textPrimary,
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

/// VisibilitySelector 三态（互斥关系 / 群选择 / 锁定本群 / 空搜索结果）。
@Preview(
  group: 'Widgets',
  name: 'VisibilitySelector（互斥/群选择/锁定/空态）',
  size: Size(1100, 520),
  wrapper: previewTheme,
)
Widget previewVisibilitySelector() {
  const List<({String id, String title})> groups = <({String id, String title})>[
    (id: 'g1', title: '星海观测站'),
    (id: 'g2', title: '作业互助'),
    (id: 'g3', title: '深夜电台'),
  ];

  Widget cell(String label, Widget child) => SizedBox(
        width: 330,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            child,
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(fontSize: 11)),
          ],
        ),
      );

  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp4),
    child: Wrap(
      spacing: AylaSpacing.sp4,
      runSpacing: AylaSpacing.sp4,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        cell(
          '默认（全不选）',
          AylaVisibilitySelector(
            value: const VisibilitySelection(),
            onChange: (_) {},
            groups: groups,
          ),
        ),
        cell(
          '公开 + 指定群（互斥：好友被取消）',
          AylaVisibilitySelector(
            value: const VisibilitySelection(isPublic: true, group: true),
            onChange: (_) {},
            selectedGroupIds: const <String>['g1', 'g3'],
            onSelectedGroupIdsChange: (_) {},
            groups: groups,
          ),
        ),
        cell(
          '群内创建：锁定本群（恒勾选、不可取消）',
          AylaVisibilitySelector(
            value: const VisibilitySelection(group: true),
            onChange: (_) {},
            lockGroup: true,
            initialGroupId: 'g2',
            selectedGroupIds: const <String>['g2', 'g1'],
            onSelectedGroupIdsChange: (_) {},
            groups: groups,
          ),
        ),
        cell(
          '好友可见（单群白名单未开）',
          AylaVisibilitySelector(
            value: const VisibilitySelection(friends: true),
            onChange: (_) {},
            groups: groups,
          ),
        ),
      ],
    ),
  );
}
