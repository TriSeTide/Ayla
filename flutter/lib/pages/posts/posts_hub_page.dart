/// 帖子流页面（web `pages/PostsHubPage.tsx` 1–379 的 Flutter 复刻；路由 `/posts`）。
///
/// 事实源：`PostsHubPage.tsx`（结构/分页/过滤）、`useMasonryColumns.ts`（列分配 →
/// `widgets/masonry_columns.dart`）、`PostCard.tsx`（→ `widgets/post_card.dart`）、
/// `api/posts.ts`（→ `core/api/posts_api.dart`）。
///
/// ## 本轮范围（B5 页面层，2026-09-20）
/// **已做**：分类选项卡（每 tab 独立缓存与游标、账号隔离）、游标分页（滚到底 240px 自动加载、
/// footer 手动「加载更多 / 重试」）、>1024px 双列瀑布 / ≤1024 单列、骨架 / 空态 / 分类空态 /
/// 错误态、下拉刷新、卡片渲染 +（详情 / 作者 / 收藏 / 分享）注入口。
/// **未做（下一批接线）**：详情路由、收藏请求、分享弹层数据、浏览上报、`post.created` 帧补全、
/// 滚动位置恢复、shell 刷新 FAB 注册。
library;

import 'package:flutter/material.dart';

import '../../core/api/posts_api.dart';
import '../../core/models/post.dart';
import '../../core/net/dio_client.dart' show ApiException;
import '../../theme/app_theme.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import '../../widgets/directory_controls.dart'
    show FavoriteState, PaginationLoadingDots;
import '../../widgets/loading.dart' show AylaSkeleton;
import '../../widgets/masonry_columns.dart';
import '../../widgets/media_interaction.dart' show AylaPullToRefresh;
import '../../widgets/post_card.dart';
import '../../widgets/profile_and_filters.dart' show AylaDirectoryFilters;

/// 分类选项卡（web `FILTERS` 44–50）。
const List<({String key, String label})> aylaPostFilters =
    <({String key, String label})>[
  (key: 'all', label: '全部'),
  (key: 'hot', label: '热门'),
  (key: 'public', label: '公开'),
  (key: 'friends', label: '好友'),
  (key: 'mine', label: '我的'),
];

/// 每 tab 的后端查询（web `TAB_QUERY` 54–60）。
({String? scope, String? visibility, bool friends}) aylaPostTabQuery(String filter) =>
    switch (filter) {
      'public' => (scope: 'feed', visibility: 'public', friends: false),
      'friends' => (scope: 'feed', visibility: null, friends: true),
      'mine' => (scope: 'mine', visibility: null, friends: false),
      _ => (scope: 'feed', visibility: null, friends: false), // all / hot
    };

/// 一个 tab 的分页状态（web `PostTabState` 62–75；字段一一对应）。
class AylaPostsTabState {
  const AylaPostsTabState({
    this.posts = const <AylaPost>[],
    this.cursor,
    this.hasMore = false,
    this.loaded = false,
    this.loading = false,
    this.total = 0,
    this.error,
    this.nextPageError,
    this.updatedAt = 0,
  });

  final List<AylaPost> posts;
  final String? cursor;
  final bool hasMore;
  final bool loaded;
  final bool loading;

  /// 后端返回的当前 tab 过滤后总数（header 统计用，不随分页进度变化）。
  final int total;

  /// 首屏 / 刷新错误（列表顶部提示）。
  final String? error;

  /// 追加错误（footer 提示；不自动重试）。
  final String? nextPageError;
  final int updatedAt;

  /// 复制并显式清空错误（**不用 null 表达清空** —— null 与「未传」在本类语义不同）。
  AylaPostsTabState clearedErrors({bool? loading}) => AylaPostsTabState(
        posts: posts,
        cursor: cursor,
        hasMore: hasMore,
        loaded: loaded,
        loading: loading ?? this.loading,
        total: total,
        updatedAt: updatedAt,
      );
}

/// 每 tab 独立分页缓存（web `postTabPages` 77：模块级、跨挂载保留）。
final Map<String, AylaPostsTabState> _postsTabPages =
    <String, AylaPostsTabState>{};

/// 清空分页缓存（账号切换 / 测试隔离；对齐 web `clearPostTabMemory`）。
void aylaClearPostTabMemory() => _postsTabPages.clear();

/// 每页条数（web `limit: 20`）与触底余量（web 240px）。
const int aylaPostsPageSize = 20;
const double aylaPostsLoadMoreMargin = 240;

/// 帖子流页面。
class AylaPostsHubPage extends StatefulWidget {
  const AylaPostsHubPage({
    super.key,
    this.accountKey = 'anonymous',
    this.initialFilter = 'all',
    this.friendIds = const <String>{},
    this.onOpenPost,
    this.onAuthorTap,
    this.favoriteStateOf,
    this.onToggleFavorite,
    this.onShare,
  });

  /// 账号键（缓存隔离；web `postTabAccount()`）。
  final String accountKey;

  /// 初始分类。
  final String initialFilter;

  /// 好友集合（web `useSocialPage('friends')` 投影；空 = 好友 tab 无可见内容）。
  final Set<String> friendIds;

  /// 打开详情（注入；详情路由下一批接）。
  final ValueChanged<AylaPost>? onOpenPost;

  /// 点作者头像。
  final ValueChanged<AylaPost>? onAuthorTap;

  /// 收藏状态（注入；null = 未收藏）。
  final FavoriteState Function(AylaPost post)? favoriteStateOf;

  /// 切换收藏（注入；页面不发请求）。
  final void Function(AylaPost post, bool next)? onToggleFavorite;

  /// 分享入口（注入：打开 ShareSheet）。
  final ValueChanged<AylaPost>? onShare;

  @override
  State<AylaPostsHubPage> createState() => _AylaPostsHubPageState();
}

class _AylaPostsHubPageState extends State<AylaPostsHubPage> {
  late String _filter = widget.initialFilter;
  AylaPostsTabState _state = const AylaPostsTabState();
  final ScrollController _scroll = ScrollController();
  int _revision = 0;
  bool _busy = false;

  /// 追加失败后不再重复请求同一 cursor（web `requestOwner.nextFailed`）。
  bool _nextFailed = false;

  String get _cacheKey => 'posts:${widget.accountKey}:$_filter';

  @override
  void initState() {
    super.initState();
    _state = _postsTabPages[_cacheKey] ?? const AylaPostsTabState();
    _loadFirst();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _persist(AylaPostsTabState next) {
    _state = next;
    _postsTabPages[_cacheKey] = next;
    while (_postsTabPages.length > 14) {
      _postsTabPages.remove(_postsTabPages.keys.first); // web：缓存上限 14
    }
    if (mounted) setState(() {});
  }

  /// 切 tab：写回旧 tab 缓存 → 读新 tab 缓存 → 使在途请求失效（web 141–152）。
  void _switchFilter(String filter) {
    if (filter == _filter) return;
    _filter = filter;
    _revision += 1;
    _busy = false;
    _nextFailed = false;
    setState(() {
      _state = _postsTabPages[_cacheKey] ?? const AylaPostsTabState();
    });
    _loadFirst();
  }

  /// 首屏 / 切 tab：加载该 tab 第一页；已加载且 60s 内不重拉（web 220–226）。
  void _loadFirst() {
    if (_busy) return;
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (_state.loaded && now - _state.updatedAt < 60000) return;
    _request('first');
  }

  Future<void> _refresh() async {
    await _request('refresh');
  }

  /// 分页请求：`first` / `refresh` / `append`（web 155–218）。
  Future<void> _request(String kind) async {
    final AylaPostsTabState current = _state;
    if (kind == 'append' && (_busy || !current.hasMore)) return;
    final String? cursor = kind == 'append' ? current.cursor : null;
    if (kind == 'append' && (cursor == null || cursor.isEmpty)) {
      // 游标缺失（防御）：静默降级并阻止滚动重复请求（web 170）
      _nextFailed = true;
      return;
    }
    final int revision = ++_revision;
    _busy = true;
    _nextFailed = false;
    _persist(current.clearedErrors(loading: true));
    try {
      final ({String? scope, String? visibility, bool friends}) query =
          aylaPostTabQuery(_filter);
      final AylaPostPage page = await AylaPostsApi.listPosts(
        scope: query.scope,
        cursor: cursor,
        limit: aylaPostsPageSize,
        visibility: query.visibility,
        friends: query.friends,
      );
      if (!mounted || revision != _revision) return;
      // has_more 但游标未推进（防御）：阻止重复请求同一页（web 173）
      if (page.hasMore && (page.nextCursor == null || page.nextCursor == cursor)) {
        _nextFailed = true;
        return;
      }
      if (kind == 'append') {
        final Set<int> existing = <int>{
          for (final AylaPost post in _state.posts) post.id,
        };
        final List<AylaPost> incoming = <AylaPost>[
          for (final AylaPost post in page.results)
            if (existing.add(post.id)) post,
        ];
        _persist(AylaPostsTabState(
          posts: <AylaPost>[..._state.posts, ...incoming],
          cursor: page.nextCursor,
          hasMore: page.hasMore,
          loaded: true,
          total: page.total ?? _state.total,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ));
      } else {
        _persist(AylaPostsTabState(
          posts: page.results,
          cursor: page.nextCursor,
          hasMore: page.hasMore,
          loaded: true,
          total: page.total ?? _state.total,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }
    } catch (error) {
      if (!mounted || revision != _revision) return;
      final String message =
          error is ApiException ? error.message : '加载失败';
      if (kind == 'append') {
        _nextFailed = true;
        _persist(AylaPostsTabState(
          posts: _state.posts,
          cursor: _state.cursor,
          hasMore: _state.hasMore,
          loaded: _state.loaded,
          total: _state.total,
          nextPageError: message,
          updatedAt: _state.updatedAt,
        ));
      } else {
        _persist(AylaPostsTabState(
          posts: _state.posts,
          cursor: _state.cursor,
          hasMore: _state.hasMore,
          loaded: _state.loaded,
          total: _state.total,
          error: message,
          updatedAt: _state.updatedAt,
        ));
      }
    } finally {
      if (mounted && revision == _revision) {
        _busy = false;
        _persist(AylaPostsTabState(
          posts: _state.posts,
          cursor: _state.cursor,
          hasMore: _state.hasMore,
          loaded: _state.loaded,
          total: _state.total,
          error: _state.error,
          nextPageError: _state.nextPageError,
          updatedAt: _state.updatedAt,
        ));
      }
    }
  }

  /// 滚到底自动加载更多（web 271–277）。
  bool _onScroll(ScrollNotification notification) {
    if (_nextFailed) return false;
    final ScrollMetrics metrics = notification.metrics;
    if (metrics.axis != Axis.vertical) return false;
    if (metrics.maxScrollExtent <= 0) return false;
    if (metrics.pixels >=
        metrics.maxScrollExtent - aylaPostsLoadMoreMargin) {
      _request('append');
    }
    return false;
  }

  /// 前端过滤/排序（web 124–129）：热门按浏览数降序，公开/好友按字段过滤，其余原序。
  List<AylaPost> _visiblePosts() {
    switch (_filter) {
      case 'hot':
        final List<AylaPost> sorted = <AylaPost>[..._state.posts];
        sorted.sort((AylaPost a, AylaPost b) =>
            (b.viewCount ?? 0).compareTo(a.viewCount ?? 0));
        return sorted;
      case 'public':
        return <AylaPost>[
          for (final AylaPost post in _state.posts)
            if (post.visibility == AylaPostVisibility.public) post,
        ];
      case 'friends':
        return <AylaPost>[
          for (final AylaPost post in _state.posts)
            if (post.authorId != null && widget.friendIds.contains(post.authorId))
              post,
        ];
      default:
        return _state.posts;
    }
  }

  Widget _filterHeader(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text('Posts', style: t.timestamp.copyWith(color: AylaColors.textSecondary)),
        Text('帖子', style: t.cardTitle),
        Text(
          _state.loaded ? '${_state.total} 条帖子' : '… 条帖子',
          style: t.timestamp.copyWith(color: AylaColors.textSecondary),
        ),
      ],
    );
  }

  Widget _stateBox(AylaTextStyles t, String title, String desc) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AylaSpacing.sp8),
        child: Column(
          children: <Widget>[
            Text(title, style: t.cardTitle),
            const SizedBox(height: AylaSpacing.sp2),
            Text(
              desc,
              style: t.body.copyWith(color: AylaColors.textSecondary),
            ),
          ],
        ),
      );

  Widget _card(AylaPost post) => AylaPostCard(
        post: post,
        onOpen: () => widget.onOpenPost?.call(post),
        onAuthorTap: widget.onAuthorTap == null
            ? null
            : () => widget.onAuthorTap!(post),
        favoriteState:
            widget.favoriteStateOf?.call(post) ?? FavoriteState.notFavorited,
        onToggleFavorite: widget.onToggleFavorite == null
            ? null
            : (bool next) => widget.onToggleFavorite!(post, next),
        onShare: widget.onShare == null ? null : () => widget.onShare!(post),
      );

  Widget _footer(AylaTextStyles t) {
    if (!_state.hasMore) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: AylaSpacing.sp4),
      child: Column(
        children: <Widget>[
          if (_state.nextPageError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AylaSpacing.sp2),
              child: Text(
                _state.nextPageError!,
                style: t.body.copyWith(color: AylaColors.destructive),
              ),
            ),
          if (_state.loading)
            const PaginationLoadingDots()
          else
            GlassButton(
              label: _state.nextPageError != null ? '重试加载更多' : '加载更多',
              variant: GlassButtonVariant.ghost,
              onPressed: () => _request('append'),
            ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context, int columnCount) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    if (_state.loading && _state.posts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AylaSpacing.sp4),
        child: Column(
          children: <Widget>[
            for (int i = 0; i < 3; i++) ...<Widget>[
              const AylaSkeleton(height: 120),
              if (i < 2) const SizedBox(height: 12),
            ],
          ],
        ),
      );
    }
    if (_state.posts.isEmpty) {
      return _stateBox(t, '还没有帖子', '点右下角 + 发布第一条帖子');
    }
    final List<AylaPost> visible = _visiblePosts();
    return AylaPullToRefresh(
      onRefresh: _refresh,
      isAtTop: () => !_scroll.hasClients || _scroll.offset <= 0,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.all(AylaSpacing.sp4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (_state.error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: AylaSpacing.sp3),
                  child: Text(
                    _state.error!,
                    style: t.body.copyWith(color: AylaColors.destructive),
                  ),
                ),
              if (visible.isEmpty && _filter != 'all')
                _stateBox(t, '这个分类还没有帖子', '换个分类看看')
              else
                AylaMasonryColumns(
                  itemCount: visible.length,
                  columnCount: columnCount,
                  memoryKey: 'posts-feed:$_filter',
                  keyOf: (int index) => visible[index].id,
                  itemBuilder: (BuildContext context, int index) =>
                      _card(visible[index]),
                ),
              _footer(t),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Size viewport = MediaQuery.of(context).size;
    final bool narrow = viewport.width <= 768;
    // web `MASONRY_QUERY = (min-width: 1025px)`：>1024 才双列
    final int columnCount = viewport.width > 1024 ? 2 : 1;
    final Widget content = _content(context, columnCount);
    if (narrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AylaDirectoryFilters(
            label: '帖子分类',
            options: aylaPostFilters,
            value: _filter,
            onChange: _switchFilter,
            narrow: true,
          ),
          Expanded(child: content),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: AylaDirectoryFilters.sidebarWidth,
          child: AylaDirectoryFilters(
            label: '帖子分类',
            options: aylaPostFilters,
            value: _filter,
            onChange: _switchFilter,
            header: _filterHeader(context),
          ),
        ),
        const SizedBox(width: AylaSpacing.sp3),
        Expanded(child: content),
      ],
    );
  }
}
