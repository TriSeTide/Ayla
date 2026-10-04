/// 群内帖子子界面 —— web `pages/group/GroupPosts.tsx`（496 行）的等价物。
///
/// ## 逐条对应
/// | 本页 | web tsx |
/// |---|---|
/// | 群内帖子目录（`scope=group:<id>`，首屏 20 + 游标分页） | 97–164（`postsApi.listPosts`） |
/// | 同组件详情往返：`postId` 存在时保留外壳渲染详情 | 358–365 + 382–384 |
/// | 底部输入框发帖（区别于一级 tab 的 FAB 发帖，R-P2） | 477–493 |
/// | 刷新后已入场卡片整批重播浮入 | 94–95 + 378–380 |
/// | 卡片入场（`.posts-feed-item` 外层 `opacity 0→1` + `translateY 20→0`，逐条 stagger） | 378–380 + 419–423 |
/// | 从详情返回列表：本次首帧不播入场（`skipRevealRestoreKey === scrollRestoreKey`） | 91–93 / 148–153 / 362–365 / 428–430 |
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
import '../state/auth_state.dart' show authNotifierProvider;
import '../state/favorite_status.dart' show AylaFavoriteStatusController;
import '../state/shell_state.dart' show ShellUiNotifier, shellUiProvider;
import '../theme/glass.dart' show AylaGlassButton;
import '../theme/app_theme.dart' show AylaTextStyles;
import '../theme/tokens.dart' show AylaRadii, AylaSpacing;
import '../widgets/base/directory_load_more.dart' show AylaDirectoryLoadMore;
import '../widgets/base/loading.dart' show AylaSkeleton;
import '../widgets/base/reveal.dart'
    show AylaRevealItem, AylaRevealMotion, AylaRevealScope;
import '../widgets/group/group_posts_composer.dart' show AylaGroupPostsComposer;
import '../widgets/group/group_scene.dart'
    show AylaGroupSceneHead, AylaGroupScenePlaceholder, AylaGroupSceneStickyHead;
import '../widgets/posts/masonry_grid.dart' show AylaMasonryGrid;
import '../widgets/posts/post_card.dart' show AylaPostCard;
import 'post_detail_page.dart' show PostDetailPage, aylaPostSharePayloadFor;
import 'share_support.dart' show AylaShareController, aylaOpenShareSheet;

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

  /// 分享弹窗控制器（用户 2026-10-03 实报「帖子分享键鼠标悬停直接变禁止」）。
  ///
  /// 根因：本页调 `AylaPostCard` 时**没传 `onShare`** ⇒ `AylaShareButton.onPressed == null`
  /// ⇒ 共享件按 `onPressed == null` 判为禁用（鼠标变禁止符号、点击无效）。
  /// 范本：`post_detail_page.dart:767–776`（同一个 `aylaOpenShareSheet` +
  /// `aylaPostSharePayloadFor`，已在本轮为帖子详情接线）。
  final AylaShareController _share = AylaShareController();
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

  /// 「本次由详情返回」——等价 web 的
  /// `skipRevealRestoreKey === scrollRestoreKey`（`GroupPosts.tsx:91/149–153/362–365/428–430`）。
  ///
  /// web 语义：进入详情时把 `skipRevealRestoreKey` 置为当前滚动恢复键，于是
  /// `useListEntryMotion` 的 `suppressed` 在**回到列表的首帧**为真（`tsx:378–380`）
  /// ⇒ 已入场的卡片不重播、直接落终态；刷新完成后（`tsx:148–153`）
  /// `setSkipRevealRestoreKey(null)` 才放开 —— 即 suppress 持续到下一次刷新完成，
  /// 期间新卡（含发帖本地插入）同样不播入场。
  bool _skipRevealOnRestore = false;

  String get groupId => widget.groupId;

  @override
  void initState() {
    super.initState();
    _favorites.addListener(_onChanged);
    unawaited(_load());
    _registerRefresh();
  }

  @override
  void didUpdateWidget(covariant GroupPostsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 路由 `:postId` 出现/消失 = 进/出详情。两个方向都登记（web 的同一守卫有两处：
    // 进详情时写在卡片 onOpen（tsx 428–430），返回时由 tsx 362–365 的 effect 兜底
    // —— 后者覆盖「不经卡片、直接改路由」的入口）。
    // ⚠️ 这两条路径下本 State 被路由原地复用（同型 + 无 key ⇒ `Page.canUpdate` 为真，
    // 见 `app_router.dart:340–347` 的注释）⇒ 字段跨详情往返保留，正是 suppress 的载体。
    if (widget.postId != oldWidget.postId) {
      _skipRevealOnRestore = widget.postId != null || oldWidget.postId != null;
    }
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
    _share.dispose();
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
      if (!mounted) return;
      // web tsx 148–153：刷新完成后 `setSkipRevealRestoreKey(null)` ⇒ 抑制随之解除；
      // 重播（replayNonce）不受抑制影响（useListEntryMotion 注释 13–18）。
      setState(() {
        _skipRevealOnRestore = false;
        _replayNonce += 1;
      });
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
        // web tsx 148–153：列表重新拿到数据后放开「详情返回」的抑制
        //（`wasLoaded` / `listActive` 两个前置条件在本页恒成立：详情态不走本页 load）。
        _skipRevealOnRestore = false;
      });
      // ★ 拉取本页帖子的收藏状态（用户 2026-10-03 实报「收藏键无法点击，显示正在加载收藏状态」）。
      //
      // 根因：本页此前**只在 `onRetryFavoriteStatus`（重试）里**调 `_favorites.load` ⇒
      // 卡片一进列表就永远是 `AylaFavoriteState.unknown` ⇒ `AylaFavoriteButton` 按 web
      // 语义 `disabled = busy || (unknown && !error)` **永久禁用** + 文案停在「正在加载收藏状态」，
      // 用户观感就是「点不动」。
      //
      // 同口径范本：`posts_hub_page.dart:183–188`（分页数据到达后按当前 items 批量查询）、
      // `my_posts_page` / `favorites_page` 同款。web 亦然（`PostsHubPage` 在列表 ready 后调
      // `loadFavoriteStatuses`）。
      //
      // ⚠️ 放在 `setState` **之后**（`_posts` 已更新）且不需要 `await`：
      // controller 自己有 60s 新鲜期与在途去重（`favorite_status.dart:133–138`），
      // 翻页重复调用不会产生多余请求。
      unawaited(_favorites.load(
        'post',
        <String>[for (final AylaPost p in merged.values) '${p.id}'],
      ));
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
    // web tsx 426–431：进详情前先写 `setSkipRevealRestoreKey(scrollRestoreKey)` +
    // `setRevealAfterRefresh(false)`。Flutter 侧由 [didUpdateWidget] 在 `postId`
    // 出现时登记同一事实（无需 setState：紧接着的路由变化必然重建本页）。
    _skipRevealOnRestore = true;
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
        // web `GroupPosts.tsx:378–380`：`suppressed = postId != null ||
        // ((restoring || skipRevealRestoreKey === scrollRestoreKey) && !revealAfterRefresh)`
        // ⇒ 「本次由详情返回」期间**新入场被抑制、已入场项不重播**
        //（`useListEntryMotion.ts:73`：suppressed 只阻止启动新的入场动画，不取消已开始的）。
        // Flutter 侧 `postId != null` 时整页换详情、列表被卸载，故只需表达第二个析取项。
        suppress: _skipRevealOnRestore,
        child: AylaMasonryGrid<AylaPost>(
          items: _posts,
          itemKey: (AylaPost post) => post.id,
          memoryKey: 'group-posts:$groupId',
          // 卡片留白口径（问题 6 真根因，同 games/voice）：web 群内流是
          // `.posts-feed.group-posts-feed`，而 `.group-posts-feed { padding: 0 }`
          // （**posts.css:989–992**，原注释「群内流复用全站帖子列与响应式瀑布流，
          // 仅由外层滚动区提供 gutter，**避免双重 padding**」）以同特异性按**源码顺序**
          // 压掉 `.posts-feed` 基样式 `padding: var(--sp-3) var(--sp-4)`（posts.css:607–612）
          // 与 ≥1025 档 `padding: var(--sp-4) var(--sp-6)`（posts.css:664–668）
          // ⇒ 瀑布流自身 **padding 0（左右 / 上下全是 0）**。
          // 左右留白只由外层 `.group-posts-list` 给（posts.css:975–983 的 `sp3 sp4`，
          // 被 group.css:413–417 的 `.group-page .group-posts-list { padding: var(--sp-4) }`
          // 0-2-0 换成四向 sp4）—— Flutter 侧即本页 `AylaGroupSceneStickyHead` 的 padding。
          // 修前这里再叠一层 `sp4` ⇒ **左右各 32**（与群内桌游/语音同一条根因）。
          padding: EdgeInsets.zero,
          // 入场动画挂在**每卡外层**（web tsx 419–423 的 `.posts-feed-item` 由
          // useListEntryMotion 驱动，`tsx:378`），不是卡本体 ⇒ Flutter 侧同款结构。
          // ⚠️ `fadeGlass: false` 必需：`AylaPostCard` 用 `AylaGlassCard`（玻璃子树），
          // 整层 Opacity 会被 Impeller 拒绝（`reveal.dart` 文件头「玻璃子树」段）。
          // 范本：`posts_hub_page.dart:312–317` / `my_posts_page.dart:282–287`。
          itemBuilder: (BuildContext context, AylaPost post, int index) {
            final String key = '${post.id}';
            return AylaRevealItem(
              fadeGlass: false,
              // `delay = staggerDelay(index) = min(index*50, 300)`
              //（`useRevealOnEnter.ts:48–49`；gap 50 / cap 300 见 `auroraquaMotion.ts:16`）。
              delay: AylaRevealMotion.staggerDelay(index, staggerMs: 50),
              child: Padding(
                padding: const EdgeInsets.only(bottom: AylaSpacing.sp3),
                child: AylaPostCard(
                  post: post,
                  onOpen: () => _openPost(post.id),
                  favoriteState: _favorites.stateOf('post', key),
                  favoriteBusy: _favorites.busyOf('post', key),
                  favoriteError: _favorites.actionErrorOf('post', key),
                  onToggleFavorite: (bool _) =>
                      unawaited(_favorites.toggle('post', key)),
                  onRetryFavoriteStatus: () => unawaited(
                    _favorites.load('post', <String>[key], force: true),
                  ),
                  // ★ 分享键（用户 2026-10-03 实报「鼠标悬停直接变禁止，仍无法点击」）：
                  // 此前没传 ⇒ `AylaShareButton.onPressed == null` ⇒ 禁用。
                  // 与帖子详情页同口径（`post_detail_page.dart:767–776`）。
                  onShare: () => unawaited(aylaOpenShareSheet(
                    context,
                    payload: aylaPostSharePayloadFor(post),
                    controller: _share,
                    currentUserId: ref.read(authNotifierProvider).user?.id,
                  )),
                ),
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
