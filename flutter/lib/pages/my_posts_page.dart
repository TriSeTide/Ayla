/// 「我的帖子 / 他人帖子」（路由 /posts/mine 与 /user/:userId/posts）
/// —— web pages/MyPostsPage.tsx（227 行）的等价物。
///
/// ## 事实源（逐条）
/// - tsx 49：`mine = String(currentUserId) === String(ownerId)`（MinePostsRoute 传当前用户）；
/// - tsx 97–101：mine → `scope=mine`；他人 → 不传 scope、传 `owner=ownerId`；
/// - tsx 155–166：他人模式懒拉昵称做标题（`getUserDetail`；失败 → null）；
///   标题三档：我的帖子 / `{昵称}的帖子` / `帖子`；
/// - tsx 169：窄屏 `FullScreenSwipeBack`（onBack = navigate(-1)）；
/// - tsx 180–185：`.my-posts-head`（返回键 IconBack **20** + `h1.placeholder-title`）；
/// - tsx 186：`.posts-skeleton` **两根** h120、**无间距**；
/// - tsx 187：错误态 `.home-state[role=alert]`（desc = error + `.btn-ghost` 重试）；
/// - tsx 188：空态两档文案（我的：还没有帖子 / 发布的帖子会显示在这里；
///   他人：暂无帖子 / 对方还没有发布帖子）；
/// - tsx 189–212：瀑布流（memoryKey `user-posts:{ownerId}`；feed 保留
///   `padding sp3 sp4`，≥769 起 680 居中、≥1025 起 1200 居中 + `sp4 sp6`）；
/// - tsx 213–221：`.home-load-more` 三态（正在加载更多帖子… / 重试加载更多帖子 /
///   加载更多帖子 / 已加载全部帖子）—— **裸 div，不是 StablePaginationFooter**；
/// - tsx 173–178：触底追加（距底 < 240 且 `hasMore && cursor !== null && !loading &&
///   !loadingMore && !error`）；
/// - tsx 202–203：进详情 `/posts/{id}?from=mine|user`。
///
/// ## 复用
/// AylaMyPostsHead / AylaPostsSkeleton / AylaMasonryGrid / AylaPostCard /
/// AylaPageState / AylaPlaceholderTitle / AylaPlaceholderDesc / AylaGlassButton /
/// AylaFullScreenSwipeBack / AylaRevealScope。
///
/// ## 机制差异（登记）
/// 1. `myPostsMemory`（按 ownerId 隔离的跨挂载快照 + 首屏不重拉）未复刻
///    —— 与其他页的「无跨挂载缓存」同登记；
/// 2. 滚动位置记忆（`useScrollRestore` key `user-posts:{ownerId}`）未实现；
/// 3. `loading` / `loadingMore` 两档由 `AylaPagedList.loading + items.isNotEmpty` 推导
///    （web 是两个独立状态位）；
/// 4. 浏览上报（usePostViewTracking，无 onViewed 回调）与分享弹窗接线未做
///    —— 见 posts_hub_page.dart 同条登记。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/posts_api.dart';
import '../core/api/users_api.dart';
import '../core/models/post.dart';
import '../state/auth_state.dart';
import '../state/favorite_status.dart';
import '../state/paged_list.dart';
import '../theme/glass.dart' show AylaGlassButton, AylaGlassButtonVariant;
import '../theme/tokens.dart';
import '../widgets/base/page_state.dart';
import '../widgets/base/reveal.dart';
import '../widgets/motion/gestures.dart' show AylaFullScreenSwipeBack;
import '../widgets/posts/masonry_grid.dart';
import '../widgets/posts/post_card.dart';
import '../widgets/posts/post_page_chrome.dart';
import 'post_detail_page.dart' show aylaPostSharePayloadFor;
import 'share_support.dart' show AylaShareController, aylaOpenShareSheet;

class MyPostsPage extends ConsumerStatefulWidget {
  const MyPostsPage({super.key, this.ownerId});

  /// 目标用户（null = 我自己的帖子，路由 /posts/mine）。
  final String? ownerId;

  @override
  ConsumerState<MyPostsPage> createState() => _MyPostsPageState();
}

class _MyPostsPageState extends ConsumerState<MyPostsPage> {
  final ScrollController _scroll = ScrollController();
  final AylaFavoriteStatusController _favorites = AylaFavoriteStatusController();

  /// 分享弹窗控制器（用户 2026-10-03 实报「帖子分享键变禁止」的同类修复：
  /// 本页同样没传 `onShare` ⇒ `AylaShareButton` 判禁用）。
  final AylaShareController _share = AylaShareController();
  AylaPagedList<AylaPost>? _pager;
  int _replayNonce = 0;

  /// 他人模式的昵称（tsx 161；失败 → null ⇒ 标题退化为「帖子」）。
  String? _ownerName;

  bool get _mine {
    final String? owner = widget.ownerId;
    if (owner == null) return true;
    return owner == ref.read(authNotifierProvider).user?.id;
  }

  @override
  void initState() {
    super.initState();
    _favorites.addListener(_onFavoritesChanged);
    _start();
    _loadOwnerName();
  }

  @override
  void didUpdateWidget(covariant MyPostsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.ownerId != oldWidget.ownerId) {
      // tsx 132–146：换目标时重置全部状态后重拉
      setState(() => _ownerName = null);
      _start();
      _loadOwnerName();
    }
  }

  @override
  void dispose() {
    _favorites.removeListener(_onFavoritesChanged);
    _favorites.dispose();
    _share.dispose();
    _pager?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onFavoritesChanged() {
    if (mounted) setState(() {});
  }

  void _onPagerChanged() {
    // ⚠️ controller 可能在 **build 期间**通知（panelOwned 路由零时长切换时页面在同一帧挂载
    // ⇒ initState/didChangeDependencies 阶段就 notifyListeners）⇒ 直接 setState 会抛
    // "setState() or markNeedsBuild() called during build"。统一挪到帧后（下一帧刷新，等价）。
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) setState(() {});
    });
    final AylaPagedList<AylaPost>? pager = _pager;
    if (pager == null) return;
    _favorites.load(
      'post',
      <String>[for (final AylaPost p in pager.items) p.id.toString()],
    );
  }

  void _start() {
    final String? owner = _mine ? null : widget.ownerId;
    final AylaPagedList<AylaPost> pager = AylaPagedList<AylaPost>(
      request: (String? cursor) => AylaPostsApi.listPosts(
        scope: owner == null ? 'mine' : null,
        owner: owner,
        cursor: cursor,
      ),
      keyOf: (AylaPost p) => p.id.toString(),
    );
    pager.addListener(_onPagerChanged);
    _pager?.dispose();
    _pager = pager;
    // 换目标 / 首挂载 ⇒ 入场动画重播（web tsx 189 的 reveal 重挂载语义）
    _replayNonce += 1;
    pager.load();
  }

  /// tsx 155–164：他人模式拉昵称（失败 → null，不伪造昵称）。
  Future<void> _loadOwnerName() async {
    if (_mine) return;
    final String owner = widget.ownerId ?? '';
    try {
      final AylaUserDetail detail = await AylaUsersApi.getUserDetail(owner);
      if (!mounted) return;
      setState(() => _ownerName = detail.user.displayName);
    } catch (_) {
      if (!mounted) return;
      setState(() => _ownerName = null);
    }
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/group');
    }
  }

  /// tsx 202–203：进详情并带上来源（`?from=mine|user`）。
  void _openPost(int id) {
    context.go('/posts/$id?from=${_mine ? 'mine' : 'user'}');
  }

  /// tsx 173–178：触底追加（**error 时不自动追加** —— 必须点页脚重试）。
  bool _onScroll(ScrollNotification n) {
    final AylaPagedList<AylaPost>? pager = _pager;
    if (pager == null) return false;
    if (n.metrics.axis != Axis.vertical) return false;
    if (!pager.hasMore ||
        pager.items.isEmpty ||
        pager.loading ||
        pager.error != null) {
      return false;
    }
    // ⚠️ web 还要求 `cursor !== null`（首页游标未推进）；Flutter 的
    // AylaPagedList.load(append:true) 内部已守卫 `_nextCursor == null` 与游标未推进
    // 两种情形（paged_list.dart:95–96）⇒ 不重复表达。
    if (n.metrics.extentAfter < 240) pager.loadMore();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final bool narrow = AylaBreakpoints.isNarrow(MediaQuery.sizeOf(context).width);
    final AylaPagedList<AylaPost>? pager = _pager;
    final List<AylaPost> posts = pager?.items ?? const <AylaPost>[];
    final bool loading = pager == null || (pager.loading && posts.isEmpty);
    // web 的两档：loading（首屏骨架）与 loadingMore（页脚文案）
    final bool loadingMore = pager != null && pager.loading && posts.isNotEmpty;
    final String title = _mine
        ? '我的帖子'
        : (_ownerName != null ? '$_ownerName的帖子' : '帖子');

    Widget body;
    if (loading) {
      // tsx 186：两根骨架、无间距
      body = const AylaPostsSkeleton(count: 2, itemGap: 0);
    } else if (pager.error != null && posts.isEmpty) {
      // tsx 187：错误态（desc = error + 重试）
      body = _stateWithAction(
        description: pager.error!,
        actionLabel: '重试',
        onAction: () => pager.load(),
        liveRegion: true,
      );
    } else if (posts.isEmpty) {
      // tsx 188
      body = _stateWithAction(
        title: _mine ? '还没有帖子' : '暂无帖子',
        description: _mine ? '发布的帖子会显示在这里' : '对方还没有发布帖子',
        padding: const EdgeInsets.symmetric(
          horizontal: AylaSpacing.sp6,
          vertical: AylaSpacing.sp12,
        ),
      );
    } else {
      body = _feed(pager, posts);
    }

    final Widget footer = (posts.isNotEmpty && !loading)
        ? _footer(pager, loadingMore)
        : const SizedBox.shrink();

    // .posts-hub.my-posts-page：height 100% / flex column / overflow-y auto
    final Widget root = NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: SingleChildScrollView(
        controller: _scroll,
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewPaddingOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AylaMyPostsHead(title: title, onBack: _back),
            body,
            footer,
          ],
        ),
      ),
    );

    return AylaFullScreenSwipeBack(
      enabled: narrow, // tsx 169：窄屏才跟手右滑返回
      onBack: _back,
      child: root,
    );
  }

  /// tsx 189–212：瀑布流（≥769 起 680 居中、≥1025 起 1200 居中 + `sp4 sp6` 内距）。
  Widget _feed(AylaPagedList<AylaPost> pager, List<AylaPost> posts) {
    final double w = MediaQuery.sizeOf(context).width;
    final bool lg = w >= AylaBreakpoints.lg; // 1025
    final bool sm = w >= 769;
    Widget grid = AylaRevealScope(
      replayKey: _replayNonce,
      child: AylaMasonryGrid<AylaPost>(
        items: posts,
        itemKey: (AylaPost p) => p.id,
        memoryKey: 'user-posts:${widget.ownerId ?? 'mine'}', // web tsx 82
        gap: AylaSpacing.sp3,
        padding: const EdgeInsets.symmetric(
          horizontal: AylaSpacing.sp4,
          vertical: AylaSpacing.sp3,
        ),
        // ≥1025：padding sp4 sp6（posts.css 664–668）
        masonryPadding: EdgeInsets.symmetric(
          horizontal: lg ? AylaSpacing.sp6 : AylaSpacing.sp4,
          vertical: lg ? AylaSpacing.sp4 : AylaSpacing.sp3,
        ),
        itemBuilder: (BuildContext context, AylaPost post, int index) =>
            AylaRevealItem(
          fadeGlass: false,
          delay: AylaRevealMotion.staggerDelay(index, staggerMs: 50),
          child: _card(post),
        ),
      ),
    );
    if (sm) {
      grid = Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: lg ? 1200 : 680),
          child: SizedBox(width: double.infinity, child: grid),
        ),
      );
    }
    return grid;
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
      // ★ 分享键（同 `group_posts_page` 的修复）。
      onShare: () => unawaited(aylaOpenShareSheet(
        context,
        payload: aylaPostSharePayloadFor(post),
        controller: _share,
        currentUserId: ref.read(authNotifierProvider).user?.id,
      )),
    );
  }

  /// tsx 213–221：`.home-load-more` 三态（裸 div，无 min-height 80）。
  Widget _footer(AylaPagedList<AylaPost> pager, bool loadingMore) {
    const TextStyle textStyle = TextStyle(
      fontFamily: AylaFonts.body,
      fontFamilyFallback: AylaFonts.cjkFallback,
      fontSize: 14,
      color: AylaColors.textSecondary,
    );
    Widget child;
    if (loadingMore) {
      child = Semantics(
        liveRegion: true,
        label: '正在加载更多帖子…',
        child: const Text('正在加载更多帖子…', style: textStyle),
      );
    } else if (pager.error != null) {
      child = Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Semantics(
            liveRegion: true,
            child: Text(pager.error!, style: textStyle),
          ),
          const SizedBox(height: AylaSpacing.sp2),
          AylaGlassButton(
            label: '重试加载更多帖子',
            variant: AylaGlassButtonVariant.ghost,
            onPressed: () {
              pager.loadMore();
            },
          ),
        ],
      );
    } else if (pager.hasMore) {
      child = AylaGlassButton(
        label: '加载更多帖子',
        variant: AylaGlassButtonVariant.ghost,
        onPressed: () {
          pager.loadMore();
        },
      );
    } else {
      child = const Text('已加载全部帖子', style: textStyle);
    }
    // .home-load-more { display:flex; justify-content:center; gap:6px; padding: sp3 }
    return Padding(
      padding: const EdgeInsets.all(AylaSpacing.sp3),
      child: Center(child: child),
    );
  }

  /// `.home-state` 的两档装配（title 可选 ⇒ 错误态只有 desc）。
  Widget _stateWithAction({
    String? title,
    required String description,
    String? actionLabel,
    VoidCallback? onAction,
    bool liveRegion = false,
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(
      horizontal: AylaSpacing.sp6,
      vertical: AylaSpacing.sp12,
    ),
  }) {
    Widget column = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (title != null) ...<Widget>[
          AylaPlaceholderTitle(title),
          const SizedBox(height: AylaSpacing.sp1),
        ],
        AylaPlaceholderDesc(description),
        if (actionLabel != null && onAction != null) ...<Widget>[
          const SizedBox(height: AylaSpacing.sp4),
          AylaGlassButton(
            label: actionLabel,
            variant: AylaGlassButtonVariant.ghost,
            onPressed: onAction,
          ),
        ],
      ],
    );
    if (liveRegion) column = Semantics(liveRegion: true, child: column);
    return Padding(padding: padding, child: Center(child: column));
  }
}

/// `UserPostsRoute`（`UserPostsRoute.tsx` 72 行）—— 他人帖子路由的**守卫 + 渲染**。
///
/// ## 逐条对应
/// - tsx 14/35–42：`getUserDetail(userId)` 成功且 `show_content` ⇒ ok，
///   否则 / 失败 ⇒ blocked；无 userId ⇒ `/group`（web 是 `navigate("/")`，
///   而 Flutter 的 `/` 重定向到 `/group` ⇒ 等价）；
/// - tsx 46–55：loading = `.posts-hub.my-posts-page` + 两根骨架（**无页头**）；
/// - tsx 57–69：blocked = `.home-state[role=alert]`（「对方未开启内容展示」/
///   「对方关闭了「向他人展示内容」，暂时无法查看其帖子」+ `.btn-ghost` 返回主页
///   → `/user/:userId`）；
/// - tsx 71：ok ⇒ `<MyPostsPage ownerId>`。
class UserPostsPage extends ConsumerStatefulWidget {
  const UserPostsPage({super.key, required this.userId});

  /// 路径参数 :userId。
  final String userId;

  @override
  ConsumerState<UserPostsPage> createState() => _UserPostsPageState();
}

enum _UserPostsState { loading, blocked, ok }

class _UserPostsPageState extends ConsumerState<UserPostsPage> {
  _UserPostsState _state = _UserPostsState.loading;

  @override
  void initState() {
    super.initState();
    _guard();
  }

  @override
  void didUpdateWidget(covariant UserPostsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.userId != oldWidget.userId) {
      setState(() => _state = _UserPostsState.loading);
      _guard();
    }
  }

  Future<void> _guard() async {
    final String userId = widget.userId;
    if (userId.isEmpty) {
      if (mounted) context.go('/group');
      return;
    }
    try {
      final AylaUserDetail detail = await AylaUsersApi.getUserDetail(userId);
      if (!mounted) return;
      setState(() => _state =
          detail.showContent ? _UserPostsState.ok : _UserPostsState.blocked);
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = _UserPostsState.blocked);
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_state) {
      case _UserPostsState.loading:
        // tsx 46–55：无页头的两根骨架
        return const SingleChildScrollView(
          child: AylaPostsSkeleton(count: 2, itemGap: 0),
        );
      case _UserPostsState.blocked:
        // tsx 57–69
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AylaSpacing.sp6,
              vertical: AylaSpacing.sp12,
            ),
            child: Semantics(
              liveRegion: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const AylaPlaceholderTitle('对方未开启内容展示'),
                  const SizedBox(height: AylaSpacing.sp1),
                  const AylaPlaceholderDesc('对方关闭了「向他人展示内容」，暂时无法查看其帖子'),
                  const SizedBox(height: AylaSpacing.sp4),
                  AylaGlassButton(
                    label: '返回主页',
                    variant: AylaGlassButtonVariant.ghost,
                    onPressed: () => context.go(
                      '/user/${Uri.encodeComponent(widget.userId)}',
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      case _UserPostsState.ok:
        return MyPostsPage(ownerId: widget.userId);
    }
  }
}
