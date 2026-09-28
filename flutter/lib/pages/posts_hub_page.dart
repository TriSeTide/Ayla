/// 一级帖子 tab（路由 /posts）—— web pages/PostsHubPage.tsx（379 行）的等价物。
///
/// ## 事实源（逐条）
/// - tsx 43–50：五个分类（全部/热门/公开/好友/我的）；?type= 驱动（95/306）；
/// - tsx 54–60：每个分类的后端参数（TAB_QUERY）⇒ [aylaPostTabQuery]；
/// - tsx 109–110：好友集合（useSocialPage("friends")，只取第一页）；
/// - tsx 121–130：瀑布流列数 1/2（≥1025 双列）与分配记忆键 posts-feed:{filter}；
/// - tsx 124–129：分类的前端二次过滤/热门排序 ⇒ [aylaHubVisiblePosts]；
/// - tsx 300–313：目录页三件套（侧栏 Posts/帖子/{total} 条帖子 + 装饰图标 iconPost）；
/// - tsx 314–316：内容区 scope=posts:{account}:{filter}（切 tab 重挂载）；
/// - tsx 317–322：骨架三根 h120（前两根 marginBottom 12）⇒ AylaPostsSkeleton；
/// - tsx 323–327：全空态「还没有帖子」/「点右下角 + 发布第一条帖子」；
/// - tsx 329：PullToRefresh（isAtTop 读内容区 scrollTop）；
/// - tsx 330–334：分类空态「这个分类还没有帖子」/「换个分类看看」；
/// - tsx 336–371：瀑布流 + 页脚（StablePaginationFooter + 三点 / 加载更多 / 重试）；
/// - tsx 346–353：卡片 onOpen → /posts/:id（进详情前保存滚动位置）。
///
/// ## 复用
/// AylaDirectoryPage / AylaDirectoryContent / AylaDirectoryFilters /
/// AylaDirectorySidebarHeader / AylaDirectoryDecorIcon / AylaPostsSkeleton /
/// AylaMasonryGrid / AylaPostCard / AylaPullToRefresh / AylaPageState /
/// AylaStablePaginationFooter / AylaPaginationLoadingDots / AylaGlassButton /
/// AylaRevealScope。
///
/// ## 机制差异（登记）
/// 1. **无 WS 增量**：web 监听 post.created/post.deleted（tsx 232–262）维护列表；
///    Flutter 侧帖子 WS 帧分发未接（全库无 comment.*/post.viewed 落点）⇒ 靠刷新更新；
/// 2. **无跨挂载分页缓存**（web 模块级 postTabPages + 60s 首屏复用）与
///    **无滚动位置记忆**（useScrollRestore）—— 与其他页同登记；
/// 3. **错误通道合并**：web 有 error（列表顶部）与 nextPageError（页脚，且阻止滚动
///    自动重试，tsx 273）两条通道；Flutter 的 AylaPagedList 只有一个 error
///    ⇒ 统一由页脚呈现（滚动不自动重试的行为由 AylaDirectoryLoadMore 的
///    error != null ⇒ 不渲染 表达，用户点刷新键重取）；
/// 4. **分享弹窗接线未做**：卡片转发键已渲染（AylaPostCard.onShare 为 null 时按钮
///    照常可点但无动作）—— 与频道侧栏 ＋/笔 同口径登记；
/// 5. **浏览上报未接**（web usePostViewTracking 的 IntersectionObserver + 300ms 合并）
///    —— 属 WS/媒体批次登记项。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/posts_api.dart';
import '../core/models/post.dart';
import '../state/favorite_status.dart';
import '../state/paged_list.dart';
import '../state/shell_state.dart';
import '../theme/app_icons.dart';
import '../theme/glass.dart' show AylaGlassButton, AylaGlassButtonVariant;
import '../theme/tokens.dart';
import '../widgets/base/directory_page.dart';
import '../widgets/base/media_interaction.dart' show AylaPullToRefresh;
import '../widgets/base/page_state.dart';
import '../widgets/base/pagination_footer.dart';
import '../widgets/base/profile_and_filters.dart' show AylaDirectoryFilters;
import '../widgets/base/reveal.dart';
import '../widgets/posts/masonry_grid.dart';
import '../widgets/posts/post_card.dart';
import '../widgets/posts/post_page_chrome.dart';
import 'hub_support.dart';

class PostsHubPage extends ConsumerStatefulWidget {
  const PostsHubPage({super.key, this.initialType});

  /// ?type=（路由读取；null / 未知值 = 全部）。
  final String? initialType;

  /// 五个分类（tsx 44–50，逐字）。
  static const List<({String key, String label})> filters =
      <({String key, String label})>[
    (key: 'all', label: '全部'),
    (key: 'hot', label: '热门'),
    (key: 'public', label: '公开'),
    (key: 'friends', label: '好友'),
    (key: 'mine', label: '我的'),
  ];

  @override
  ConsumerState<PostsHubPage> createState() => _PostsHubPageState();
}

class _PostsHubPageState extends ConsumerState<PostsHubPage> {
  late String _filter = aylaHubFilterOf(PostsHubPage.filters, widget.initialType);

  final ScrollController _scroll = ScrollController();
  final AylaFavoriteStatusController _favorites = AylaFavoriteStatusController();
  AylaPagedList<AylaPost>? _pager;
  Set<String> _friendIds = const <String>{};
  int _replayNonce = 0;

  ShellUiNotifier? _shellNotifier;
  Future<void> Function()? _refreshCallback;

  @override
  void initState() {
    super.initState();
    _favorites.addListener(_onFavoritesChanged);
    _start();
    _loadFriends();
  }

  @override
  void didUpdateWidget(covariant PostsHubPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialType != oldWidget.initialType) {
      final String next =
          aylaHubFilterOf(PostsHubPage.filters, widget.initialType);
      if (next != _filter) {
        setState(() => _filter = next);
        _start();
      }
    }
  }

  @override
  void dispose() {
    _favorites.removeListener(_onFavoritesChanged);
    _favorites.dispose();
    final ShellUiNotifier? notifier = _shellNotifier;
    final Future<void> Function()? callback = _refreshCallback;
    if (notifier != null && callback != null) {
      scheduleMicrotask(() => notifier.unregisterRefresh(callback));
    }
    _pager?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onFavoritesChanged() {
    if (mounted) setState(() {});
  }

  void _onPagerChanged() {
    if (!mounted) return;
    setState(() {});
    final AylaPagedList<AylaPost>? pager = _pager;
    if (pager == null) return;
    _favorites.load(
      'post',
      <String>[for (final AylaPost p in pager.items) p.id.toString()],
    );
  }

  void _start() {
    final AylaPostTabQuery query = aylaPostTabQuery(_filter);
    final AylaPagedList<AylaPost> pager = AylaPagedList<AylaPost>(
      request: (String? cursor) => AylaPostsApi.listPosts(
        scope: query.scope,
        cursor: cursor,
        visibility: query.visibility,
        friends: query.friends,
      ),
      keyOf: (AylaPost p) => p.id.toString(),
    );
    pager.addListener(_onPagerChanged);
    _pager?.dispose();
    _pager = pager;
    _registerRefresh();
    pager.load();
  }

  Future<void> _loadFriends() async {
    final Set<String> ids = await aylaHubFriendIds();
    if (!mounted || ids.isEmpty) return;
    setState(() => _friendIds = ids);
  }

  void _registerRefresh() {
    final ShellUiNotifier notifier = ref.read(shellUiProvider.notifier);
    Future<void> callback() async {
      final AylaPagedList<AylaPost>? pager = _pager;
      if (pager == null) return;
      await pager.refresh();
      if (mounted) setState(() => _replayNonce++);
    }

    _shellNotifier = notifier;
    _refreshCallback = callback;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      notifier.registerRefresh(callback);
    });
  }

  Future<void> _refresh() async {
    final AylaPagedList<AylaPost>? pager = _pager;
    if (pager == null) return;
    await pager.refresh();
    if (mounted) setState(() => _replayNonce++);
  }

  void _onFilterChange(String next) {
    setState(() => _filter = next);
    _start();
    context.replace(next == 'all' ? '/posts' : '/posts?type=$next');
  }

  bool _isAtTop() => !_scroll.hasClients || _scroll.position.pixels <= 0;

  /// tsx 312：侧栏统计（loading 时与 web 同为「… 条帖子」）。
  String _statsLabel() {
    final AylaPagedList<AylaPost>? pager = _pager;
    if (pager == null || pager.loading) return '… 条帖子';
    return '${pager.total} 条帖子';
  }

  /// tsx 348–352：进详情（滚动位置记忆未实现 ⇒ 只做路由）。
  void _openPost(int id) => context.go('/posts/$id');

  @override
  Widget build(BuildContext context) {
    final bool narrow = aylaDirectoryIsNarrow(context);
    final AylaPagedList<AylaPost>? pager = _pager;
    final List<AylaPost> loaded = pager?.items ?? const <AylaPost>[];
    final List<AylaPost> visible = aylaHubVisiblePosts(
      loaded,
      _filter,
      friendIds: _friendIds,
    );

    Widget content;
    if (pager != null && pager.loading && loaded.isEmpty) {
      // tsx 317–322：三根骨架（前两根间距 12）
      content = const AylaPostsSkeleton(
        // hub 页被目录页组规则归零左右 padding 与限宽（directory-filters.css:171–180）
        centered: false,
        padding: EdgeInsets.symmetric(vertical: AylaSpacing.sp3),
      );
    } else if (loaded.isEmpty) {
      // tsx 323–327
      content = const AylaPageState(
        title: '还没有帖子',
        description: '点右下角 + 发布第一条帖子',
        padding: kAylaPageStateDirectoryPadding,
      );
    } else {
      content = AylaPullToRefresh(
        isAtTop: _isAtTop,
        onRefresh: _refresh,
        child: visible.isEmpty && _filter != 'all'
            ? const AylaPageState(
                title: '这个分类还没有帖子',
                description: '换个分类看看',
                padding: kAylaPageStateDirectoryPadding,
              )
            : AylaRevealScope(
                replayKey: _replayNonce,
                child: AylaMasonryGrid<AylaPost>(
                  items: visible,
                  itemKey: (AylaPost p) => p.id,
                  memoryKey: 'posts-feed:$_filter', // web tsx 130
                  gap: AylaSpacing.sp3, // .posts-feed gap: sp3
                  // hub 页水平内距由 .directory-content 统一提供（posts.css 654–656 注释）
                  padding: const EdgeInsets.symmetric(
                    vertical: AylaSpacing.sp3,
                  ),
                  footer: _footer(pager),
                  // 入场动画挂在 .posts-feed-item（posts.css:20 + useListEntryMotion），
                  // 卡片自身只做 hover/active ⇒ 这里用 AylaRevealItem 逐项挂载
                  itemBuilder: (BuildContext context, AylaPost post, int index) =>
                      AylaRevealItem(
                    delay: AylaRevealMotion.staggerDelay(index, staggerMs: 50),
                    child: _card(post),
                  ),
                ),
              ),
      );
    }

    return AylaDirectoryPage(
      filters: AylaDirectoryFilters(
        label: '帖子分类',
        options: PostsHubPage.filters,
        value: _filter,
        narrow: narrow,
        onChange: _onFilterChange,
        decor: AylaDirectoryDecorIcon(icon: aylaIconByName('iconPost')!),
        header: AylaDirectorySidebarHeader(
          kicker: 'Posts',
          title: '帖子',
          stats: _statsLabel(),
        ),
      ),
      content: AylaDirectoryContent(
        controller: _scroll,
        // web key=posts:{account}:{filter}（tsx 314）—— account 维度在 Flutter 由
        // 页面实例隔离（无跨挂载缓存）⇒ scope 取 filter
        scope: 'posts:$_filter',
        label: aylaHubFilterLabel(PostsHubPage.filters, _filter),
        child: content,
      ),
    );
  }

  Widget _card(AylaPost post) {
    final String key = post.id.toString();
    return AylaPostCard(
      post: post,
      onOpen: () => _openPost(post.id),
      favoriteState: _favorites.stateOf('post', key),
      favoriteBusy: _favorites.busyOf('post', key),
      favoriteError: _favorites.actionErrorOf('post', key),
      onToggleFavorite: (bool _) => _favorites.toggle('post', key),
      onRetryFavoriteStatus: () =>
          _favorites.load('post', <String>[key], force: true),
      onAuthorTap: post.authorId == null
          ? null
          : () => context.go('/user/${post.authorId}'),
    );
  }

  /// tsx 359–370：StablePaginationFooter + 三点 / 加载更多 / 重试。
  Widget _footer(AylaPagedList<AylaPost>? pager) {
    if (pager == null) return const SizedBox.shrink();
    return AylaStablePaginationFooter(
      child: Center(
        child: pager.hasMore
            ? (pager.loading
                ? const AylaPaginationLoadingDots(semanticLabel: '加载更多')
                : AylaGlassButton(
                    label: pager.error == null ? '加载更多' : '重试加载更多',
                    variant: AylaGlassButtonVariant.ghost,
                    onPressed: () {
                      pager.loadMore();
                    },
                  ))
            : const SizedBox.shrink(),
      ),
    );
  }
}
