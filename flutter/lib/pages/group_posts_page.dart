/// 群内帖子子界面 —— web `pages/group/GroupPosts.tsx`（496 行）的等价物。
///
/// ## 逐条对应
/// | 本页 | web tsx |
/// |---|---|
/// | 群内帖子目录（`scope=group:<id>`，首屏 20 + 游标分页） | 97–164（`postsApi.listPosts`） |
/// | 同组件详情往返：`postId` 存在时保留外壳渲染详情 | 358–365 + 382–384 |
/// | 底部输入框发帖（区别于一级 tab 的 FAB 发帖，R-P2） | 477–493 |
/// | 刷新后已入场卡片整批重播浮入 | 94–95 + 378–380 |
/// | 加载 / 空态 / 列表三态 + 分页页脚 | 386–447 |
/// | sticky 场景头 + 「我的帖子」尾键 | 391–397 |
///
/// ## 机制差异（登记）
/// 1. **未读帖子跳转标签**（tsx 450–476）未接：它依赖 `usePostViewTracking` 的视口上报与
///    `data-post-id` 的 DOM 反查，Flutter 侧该能力属帖子域批次（帖子域已交付的页面同样未接）。
/// 2. **滚动位置记忆**（`useScrollRestore`）未实现（同其它已交付页面的既有登记）。
/// 3. **`post.*` 四条 WS 帧仍未转正**（`kAylaChatWsOutOfBatchFrames`）：web 用它们做
///    单条 REST 对账 + 目录增删；Flutter 侧帖子域全局缓存尚未收敛 ⇒ 本页靠下拉刷新与
///    发帖后的本地插入（**不伪造实时**）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/posts_api.dart';
import '../core/models/post.dart' show AylaPost, AylaPostDraft;
import '../state/favorite_status.dart' show AylaFavoriteStatusController;
import '../state/shell_state.dart' show ShellUiNotifier, shellUiProvider;
import '../theme/glass.dart' show AylaGlassButton;
import '../theme/app_theme.dart' show AylaTextStyles;
import '../theme/tokens.dart' show AylaRadii, AylaSpacing;
import '../widgets/base/directory_load_more.dart' show AylaDirectoryLoadMore;
import '../widgets/base/loading.dart' show AylaSkeleton;
import '../widgets/base/reveal.dart' show AylaRevealScope;
import '../widgets/group/group_posts_composer.dart' show AylaGroupPostsComposer;
import '../widgets/group/group_scene.dart'
    show AylaGroupSceneHead, AylaGroupScenePlaceholder, AylaGroupSceneStickyHead;
import '../widgets/posts/masonry_grid.dart' show AylaMasonryGrid;
import '../widgets/posts/post_card.dart' show AylaPostCard;
import 'post_detail_page.dart' show PostDetailPage;

/// 每页条数（web tsx 32：`PAGE_SIZE = 20`）。
const int kAylaGroupPostsPageSize = 20;

class GroupPostsPage extends ConsumerStatefulWidget {
  const GroupPostsPage({
    super.key,
    required this.groupId,
    this.postId,
    this.onExit,
  });

  final String groupId;

  /// 路由 `:postId`（存在 ⇒ 保留外壳渲染详情）。
  final String? postId;

  /// 「返回聊天」（空态键；web tsx 409–411）。
  final VoidCallback? onExit;

  @override
  ConsumerState<GroupPostsPage> createState() => _GroupPostsPageState();
}

class _GroupPostsPageState extends ConsumerState<GroupPostsPage> {
  final AylaFavoriteStatusController _favorites = AylaFavoriteStatusController();
  final ScrollController _scroll = ScrollController();
  ShellUiNotifier? _shell;
  Future<void> Function()? _refreshCallback;

  List<AylaPost> _posts = <AylaPost>[];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _cursor;
  String? _error;
  int _replayNonce = 0;
  bool _editorExpanded = false;

  String get groupId => widget.groupId;

  @override
  void initState() {
    super.initState();
    _favorites.addListener(_onChanged);
    unawaited(_load());
    _registerRefresh();
  }

  @override
  void dispose() {
    final ShellUiNotifier? notifier = _shell;
    final Future<void> Function()? callback = _refreshCallback;
    if (notifier != null && callback != null) {
      scheduleMicrotask(() => notifier.unregisterRefresh(callback));
    }
    _favorites.removeListener(_onChanged);
    _favorites.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _registerRefresh() {
    final ShellUiNotifier notifier = ref.read(shellUiProvider.notifier);
    Future<void> callback() async {
      await _load();
      if (mounted) setState(() => _replayNonce += 1);
    }

    _shell = notifier;
    _refreshCallback = callback;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      notifier.registerRefresh(callback);
    });
  }

  /// 取一页（`append` = 追加下一页）。
  Future<void> _load({bool append = false}) async {
    if (append && (_loadingMore || !_hasMore || _cursor == null)) return;
    setState(() {
      if (append) {
        _loadingMore = true;
      } else {
        _loading = true;
      }
      _error = null;
    });
    try {
      final page = await AylaPostsApi.listPosts(
        scope: 'group:$groupId',
        limit: kAylaGroupPostsPageSize,
        cursor: append ? _cursor : null,
      );
      if (!mounted) return;
      // 游标未推进（防御性检查，正常不触发）：静默降级（web tsx 122–123）。
      if (page.hasMore &&
          (page.nextCursor == null || page.nextCursor == (append ? _cursor : null))) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
        return;
      }
      final Map<String, AylaPost> merged = <String, AylaPost>{
        if (append) for (final AylaPost p in _posts) '${p.id}': p,
        for (final AylaPost p in page.results) '${p.id}': p,
      };
      setState(() {
        _posts = merged.values.toList(growable: false);
        _cursor = page.nextCursor;
        _hasMore = page.hasMore;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  /// 发帖（web `PostEditor` 的 submit → `postsApi.createPost`）。
  Future<void> _submit(AylaPostDraft draft) async {
    final AylaPost? created = await AylaPostsApi.createPost(
      title: draft.title.isEmpty ? null : draft.title,
      body: draft.body,
      group: groupId,
      visibility: draft.visibility.wire,
      images: draft.mediaIds,
    );
    if (!mounted || created == null) return;
    // 本地插入（web tsx 239–248 的 `handleCreated`）。
    setState(() {
      _posts = <AylaPost>[created, ..._posts];
      _editorExpanded = false;
    });
  }

  void _openPost(int id) {
    context.go(
      '/group/${Uri.encodeComponent(groupId)}/posts/$id',
    );
  }

  @override
  Widget build(BuildContext context) {
    // 详情往返：保留外壳（web tsx 382–384 与 477 之后的输入区）。
    final String? postId = widget.postId;
    if (postId != null) return PostDetailPage(postId: postId);

    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool showSkeleton = _posts.isEmpty && _loading;

    Widget content;
    if (showSkeleton) {
      content = Column(
        children: <Widget>[
          for (int i = 0; i < 2; i += 1)
            const Padding(
              padding: EdgeInsets.only(bottom: AylaSpacing.sp3),
              child: AylaSkeleton(height: 120, radius: AylaRadii.rCard),
            ),
          Text('正在加载帖子…', style: t.timestamp),
        ],
      );
    } else if (_posts.isEmpty && _error != null) {
      content = AylaGroupScenePlaceholder(
        description: _error,
        actions: <Widget>[
          AylaGlassButton(label: '重试', onPressed: () => unawaited(_load())),
        ],
      );
    } else if (_posts.isEmpty) {
      content = AylaGroupScenePlaceholder(
        title: '群内还没有帖子',
        description: '在下方输入框发第一条帖子',
        actions: <Widget>[
          AylaGlassButton(label: '返回聊天', onPressed: widget.onExit),
        ],
      );
    } else {
      content = AylaRevealScope(
        replayKey: _replayNonce,
        child: AylaMasonryGrid<AylaPost>(
          items: _posts,
          itemKey: (AylaPost post) => post.id,
          memoryKey: 'group-posts:$groupId',
          padding: const EdgeInsets.fromLTRB(
            AylaSpacing.sp4,
            AylaSpacing.sp3,
            AylaSpacing.sp4,
            AylaSpacing.sp3,
          ),
          itemBuilder: (BuildContext context, AylaPost post, int index) {
            final String key = '${post.id}';
            return Padding(
              padding: const EdgeInsets.only(bottom: AylaSpacing.sp3),
              child: AylaPostCard(
                post: post,
                onOpen: () => _openPost(post.id),
                favoriteState: _favorites.stateOf('post', key),
                favoriteBusy: _favorites.busyOf('post', key),
                favoriteError: _favorites.actionErrorOf('post', key),
                onToggleFavorite: (bool _) =>
                    unawaited(_favorites.toggle('post', key)),
                onRetryFavoriteStatus: () =>
                    unawaited(_favorites.load('post', <String>[key], force: true)),
              ),
            );
          },
          footer: AylaDirectoryLoadMore(
            loading: _loadingMore || _loading,
            error: _error,
            hasMore: _hasMore,
            invalidated: false,
            loadMore: () => _load(append: true),
            refresh: _load,
          ),
        ),
      );
    }

    return AylaGroupPostsComposer(
      groupId: groupId,
      expanded: _editorExpanded,
      onExpandedChange: (bool next) => setState(() => _editorExpanded = next),
      onSubmit: _submit,
      child: AylaGroupSceneStickyHead(
        controller: _scroll,
        // .group-posts-list { padding: sp3 sp4; gap: 0 }（posts.css 960/963）。
        padding: const EdgeInsets.symmetric(
          horizontal: AylaSpacing.sp4,
          vertical: AylaSpacing.sp3,
        ),
        gap: 0,
        head: AylaGroupSceneHead(
          title: '群内帖子',
          description: '浏览本群的最新动态',
          trailing: AylaGlassButton(
            label: '我的帖子',
            onPressed: () => context.go('/posts/mine'),
          ),
        ),
        child: content,
      ),
    );
  }
}
