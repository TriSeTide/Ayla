/// 群内帖子子界面 —— web `pages/group/GroupPosts.tsx`（496 行）的等价物。
///
/// ## 逐条对应
/// | 本页 | web tsx |
/// |---|---|
/// | 群内帖子目录（`scope=group:<id>`，首屏 20 + 游标分页） | 97–164（`postsApi.listPosts`） |
/// | 同组件详情往返：`postId` 存在时保留外壳渲染详情 | 358–365 + 382–384 |
/// | 底部输入框发帖（区别于一级 tab 的 FAB 发帖，R-P2） | 477–493 |
/// | 下拉刷新（`PullToRefresh`，列表在顶时才响应） | 398（`isAtTop` 182） |
/// | 刷新后已入场卡片整批重播浮入 | 94–95 + 378–380 |
/// | 卡片入场（`.posts-feed-item` 外层 `opacity 0→1` + `translateY 20→0`，逐条 stagger） | 378–380 + 419–423 |
/// | 从详情返回列表：本次首帧不播入场（`skipRevealRestoreKey === scrollRestoreKey`） | 91–93 / 148–153 / 362–365 / 428–430 |
/// | 加载 / 空态 / 列表三态 + 分页页脚 | 386–447 |
/// | sticky 场景头 + 「我的帖子」尾键 | 391–397 |
/// | **视口浏览上报 → 已读态**（`usePostViewTracking`） | 267–279 + `hooks/usePostViewTracking.ts` 全文 |
/// | **未读帖子跳转标签**（上方/下方两条，点击滚动到最近未读） | 281–356 + 450–476 |
///
/// ## 页面级 WS 热更新（2026-10-11 补齐，web tsx 188–231）
/// web 在 **GroupPosts 页面内**自己挂 `chatWS.onFrame`（tsx 188–231），与全局
/// `ws/chat.ts:766–840` 是**两条独立效应、互不替代**（同一形制见一级帖子页
/// `PostsHubPage.tsx:232–262` / Flutter `posts_hub_page.dart:180–210`）：
/// | 帧 | 页面效应（tsx） | 本页 |
/// |---|---|---|
/// | `post.deleted` | 记入 `owner.deletedIds` + 从本页列表移除（190–196） | [_deletedIds] + `removeWhere` |
/// | `post.created` / `post.updated` | **单条权限 REST 对账** ⇒ 插到列表头（不重拉首页、不丢游标/滚动位，197–217） | [_reconcileFramePost] |
/// | `post.viewed`（本人） | 跨端已读热更新：本页 `groupPosts` 就地标已读（标签实时减少，218–230） | 同 |
///
/// 三条防重入守卫逐条对齐 web：① `owner.active` / `owner.key` 身份校验（tsx 189）；
/// ② `detailRevision` 逐帖版本号 —— REST 往返期间到达的更新帧作废旧响应（tsx 200–204）；
/// ③ `deletedIds` —— 已删帖的迟到响应不得复活它（tsx 204）。
///
/// ## 显示投影 `displayPosts`（web tsx 251–265）
/// 本页 `_posts` 与共享 [aylaPostsStore] 是**两份数据**（web 亦然）：
/// 列表口径取本页分页结果，已读态/浏览量取全局 store 的**单调合并**
/// （`is_viewed || `、`Math.max(...)`）—— 于是别的页面浏览过的帖子回到这里也是已读，
/// 而全局缓存**不会**凭空把不在本页分页里的旧帖塞进列表。
///
/// ## ⚠️ 跳转标签的**定位基准**（2026-10-11 用户实报「跳转键上方位置有误」）
/// web 的两条 `.message-jump-tags` 是 **`.group-posts` 的子级**（tsx 388–476：
/// `<div class="group-posts">` 直接包着 list / tags / input），`.group-posts`
/// 带 `position: relative`（posts.css 942–948）⇒ 上标签 = 容器顶 + 12、下标签 =
/// 容器底 − (12 + 64)。`padding` / `margin` / 滚动容器都不影响：标签的包含块就是
/// 那块"整页"矩形。本页此前把两条标签放在**滚动口（AylaGroupSceneStickyHead）内部**，
/// 那样 `Positioned` 的包含块成了**滚动视口**，于是：
/// ① 上标签落进 `.group-posts-list` 的 `padding: sp4` 内侧（web 是压在 padding 上的 12）；
/// ② 下标签按"视口底 − 76"算，而 web 是"**容器**底 − 76"⇒ 宽屏正好差掉那 12px 底边距。
/// 反例（同库内的正确实现）：`widgets/chat/message_list.dart` 的两条标签在
/// `.message-list`（`position: relative`）这一层的 `Stack` 里，不在滚动容器内部。
///
/// ## 机制差异（登记）
/// 1. **滚动位置记忆**（`useScrollRestore`）未实现（同其它已交付页面的既有登记）。
/// 2. **视口上报的观察器差异**（登记，语义等价）：web 用 `IntersectionObserver`
///    （`rootMargin: "0px 0px -5% 0px"`、阈值取默认 0 ⇒ 任意相交即算进入视口、
///    300ms 去抖批量上报），Flutter 侧由 `AylaPostViewProbe` 监听最近祖先
///    `ScrollPosition` 在帧后量矩形（手法同 `widgets/chat/message_visibility.dart`，
///    但**阈值是 0 而非 0.6** —— 消息域那一件是「看到 60% 才算已读」，本域 web 是
///    「露头即算」，两者不可互抄）。底部 5% 缓冲按同比例从视口矩形扣掉。
/// 3. **未读计数不从本页条数推断**：`totalUnread` 取会话摘要的 `post_unread_count`
///    （后端权威），未加载部分只在 `hasMore` 时按差值计入「下方」——
///    与 `docs/post_views_read_state.md` 的口径一致（**不把未加载误判为已读**）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/posts_api.dart';
import '../core/models/post.dart' show AylaPost, AylaPostDraft;
import '../state/auth_state.dart' show authNotifierProvider;
import '../core/ws/chat_ws.dart' show AylaChatWsClient;
import '../state/chat_providers.dart' show chatStateProvider, chatWsProvider;
import '../state/favorite_status.dart' show AylaFavoriteStatusController;
import '../state/posts_store.dart' show aylaPostsStore;
import '../state/shell_state.dart' show ShellUiNotifier, shellUiProvider;
import '../theme/glass.dart' show AylaGlass, AylaGlassButton, AylaGlassSurface;
import '../theme/app_theme.dart' show AylaTextStyles;
import '../theme/tokens.dart'
    show AylaColors, AylaFonts, AylaRadii, AylaShadows, AylaSpacing;
import '../widgets/base/directory_load_more.dart' show AylaDirectoryLoadMore;
import '../widgets/base/loading.dart' show AylaSkeleton;
import '../widgets/base/media_interaction.dart' show AylaPullToRefresh;
import '../widgets/base/reveal.dart'
    show AylaRevealItem, AylaRevealMotion, AylaRevealScope;
import '../widgets/base/scroll_restore.dart'
    show AylaScrollMemory, AylaScrollRestore;
import '../widgets/base/tooltip.dart' show AylaTooltip;
import '../widgets/group/group_posts_composer.dart' show AylaGroupPostsComposer;
import '../widgets/group/group_scene.dart'
    show AylaGroupSceneHead, AylaGroupScenePlaceholder, AylaGroupSceneStickyHead;
import '../widgets/posts/masonry_grid.dart' show AylaMasonryGrid;
import '../widgets/posts/post_card.dart' show AylaPostCard;
import 'post_detail_page.dart' show PostDetailPage, aylaPostSharePayloadFor;
import 'share_support.dart' show AylaShareController, aylaOpenShareSheet;

/// 每页条数（web tsx 32：`PAGE_SIZE = 20`）。
const int kAylaGroupPostsPageSize = 20;

/// 浏览上报的合并窗口（web `usePostViewTracking.ts:22` 的 `FLUSH_DELAY_MS = 300`）。
const int kAylaPostViewFlushDelayMs = 300;

/// 视口底部缓冲比例（web `rootMargin: "0px 0px -5% 0px"`，`usePostViewTracking.ts:70`）。
const double kAylaPostViewBottomMarginRatio = 0.05;

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

  /// 待上报的浏览 id（web `usePostViewTracking.ts:32` 的 `pending` Set）。
  final Set<int> _pendingViews = <int>{};

  /// 300ms 去抖定时器（web `usePostViewTracking.ts:33` 的 `timer`）。
  Timer? _viewFlushTimer;

  /// 本节浏览上报是否已在途（防重入；完成后按 web 语义清空重建）。
  bool _reportsViews = false;

  /// 滚动序号（web tsx 292 的 `scrollTick`）——用于**重算上/下未读分组**。
  ///
  /// web 在 `onScroll` 里 `setScrollTick(t => t + 1)` 触发 `useMemo` 重算；
  /// Flutter 侧同样需要一个「滚动后重建」的信号（每帧一次，非每像素一次）。
  int _scrollTick = 0;
  bool _scrollScheduled = false;

  List<AylaPost> _posts = <AylaPost>[];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _cursor;
  String? _error;
  int _replayNonce = 0;
  bool _editorExpanded = false;

  /// 页面级 WS 订阅的解绑句柄（web tsx 232–236 的 `unsubscribe`）。
  void Function()? _offFrames;

  /// 本页生命周期标识（web `requestOwner.active`）：dispose 后到达的帧一律丢弃。
  bool _frameOwnerActive = false;

  /// 已删帖 id（web `owner.deletedIds`，tsx 55）：迟到的 `post.created/updated`
  /// REST 响应不得复活它（tsx 204 的守卫）。
  final Set<int> _deletedIds = <int>{};

  /// 逐帖 REST 对账版本号（web `owner.detailRevision`，tsx 57/200–204）：
  /// 同帖连续两次帧 ⇒ 只有最后一次的响应可以落地。
  final Map<int, int> _detailRevision = <int, int>{};

  /// 帧驱动的本地变更版本号（web `owner.mutationRevision`，tsx 55）。
  ///
  /// ⚠️ **在途分页响应的作废判据**：web 在 `requestPage` 开始时记下当时的
  /// `mutationRevision`，响应回来时把「该版本之后才变异过的帖子」按本地版本保留
  /// （tsx 130–141）—— 即「请求期间收到的 WS 变更不能被旧 HTTP 快照推翻」。
  int _mutationRevision = 0;

  /// `postId → 最近一次帧驱动的本地变更`（web `owner.mutations`，tsx 56）。
  final Map<int, _FrameMutation> _mutations = <int, _FrameMutation>{};

  /// 共享帖子 store 是否已订阅（[aylaPostsStore] 是模块级 ChangeNotifier）。
  ///
  /// web 用 `usePostsStore((s) => s.posts)` 订阅（tsx 78）；Flutter 侧同源用
  /// `addListener` + `setState`（先例：`group_page.dart:254`、`home_page.dart:140`）。
  /// `addListener` 返回 void ⇒ 用布尔登记「是否已挂」，dispose 时按此解绑（幂等）。
  bool _subscribedPostsStore = false;

  /// 「本次由详情返回」——等价 web 的
  /// `skipRevealRestoreKey === scrollRestoreKey`（`GroupPosts.tsx:91/149–153/362–365/428–430`）。
  ///
  /// web 语义：进入详情时把 `skipRevealRestoreKey` 置为当前滚动恢复键，于是
  /// `useListEntryMotion` 的 `suppressed` 在**回到列表的首帧**为真（`tsx:378–380`）
  /// ⇒ 已入场的卡片不重播、直接落终态；刷新完成后（`tsx:148–153`）
  /// `setSkipRevealRestoreKey(null)` 才放开 —— 即 suppress 持续到下一次刷新完成，
  /// 期间新卡（含发帖本地插入）同样不播入场。
  bool _skipRevealOnRestore = false;

  /// 「本帧之后到达的新卡**照常播入场**」—— web 的 `revealAfterRefresh`（tsx 93）。
  ///
  /// 它在 [AylaRevealScope] 的 suppress 表达式里是**与项**（tsx 379）：
  /// ```tsx
  /// suppressed = postId != null ||
  ///   ((restoring || skipRevealRestoreKey === scrollRestoreKey) && !revealAfterRefresh)
  /// ```
  /// ⇒ 单独提升它可以**压过**「详情返回」的抑制。三个写 `true` 的点（逐条对应 web）：
  /// - 取页成功后（tsx 148–153：`setSkipRevealRestoreKey(null); setRevealAfterRefresh(true)`）；
  /// - 帧驱动插入新卡（tsx 212：`if (listActive.current) setRevealAfterRefresh(true)`）；
  /// - 发帖成功本地插入（tsx 245）。
  ///
  /// 两个写 `false` 的点：进详情（tsx 363）/ 点卡进详情（tsx 429）—— 否则「刚浏览完
  /// 页面又被跳详情再返回」会误判成「有新卡该播动画」。
  bool _revealAfterRefresh = false;

  String get groupId => widget.groupId;

  /// 滚动位置恢复（web `useScrollRestore(scrollRestoreKey, listRef,
  /// { active: postId == null, ready: displayPosts.length > 0 })`，`GroupPosts.tsx:366–369`）。
  /// 键 = web 的 `scrollRestoreKey`（tsx 88）= `ownerKey`（tsx 73）
  /// = `${userId}:group-posts:${groupId}` —— 按登录人 + 群隔离。
  late AylaScrollRestore _restore;

  /// 滚动恢复键（web `ownerKey`，`GroupPosts.tsx:73`）。
  String get _restoreKey {
    final String user = ref.read(authNotifierProvider).user?.id ?? 'anonymous';
    return '$user:group-posts:$groupId';
  }

  /// 会话摘要里的群未读帖子数（web tsx 286–288 的 `totalUnread`，后端权威）。
  int get _totalUnread =>
      ref.watch(chatStateProvider).byId(groupId)?.postUnreadCount ?? 0;

  /// 列表滚动通知（web tsx 293–301 的 `handleListScroll`）：
  /// 重算上/下未读分组 + 触底加载更多。
  ///
  /// web 每次 `onScroll` 都 `setScrollTick(t => t + 1)`；Flutter 侧换成**每帧最多一次**
  /// 的排帧 setState（每像素 setState 会让整页逐帧重建），分组结果不变。
  bool _onListScroll(ScrollNotification notification) {
    if (!_scrollScheduled) {
      _scrollScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollScheduled = false;
        if (mounted) setState(() => _scrollTick += 1);
      });
    }
    // 触底自动加载由列表尾的 `AylaDirectoryLoadMore` 自行承担
    // （`autoLoadMore` 默认 true，rootMargin 240 与 web 同值）⇒ 这里不重复触发。
    return false;
  }

  @override
  void initState() {
    super.initState();
    _favorites.addListener(_onChanged);
    _frameOwnerActive = true;
    _registerFrameTracking();
    aylaPostsStore.addListener(_onChanged);
    _subscribedPostsStore = true;
    // tsx 366–369：`active: postId == null`（进详情时列表容器不渲染）。
    _restore = AylaScrollRestore(
      key: _restoreKey,
      controller: _scroll,
      active: widget.postId == null,
      ready: false,
    )..attach();
    unawaited(_load());
    _registerRefresh();
  }

  // ======================= 页面级 WS 热更新（web tsx 188–231） =======================

  /// 挂上 chat WS 的帧监听 —— web `GroupPosts.tsx:188–231` 的 `chatWS.onFrame(...)`。
  ///
  /// ⚠️ 与全局 [AylaPostsFramesBridge]（= web `ws/chat.ts:766–840`）是**两条独立效应**：
  /// 全局桥落共享 store / 未读投影，本方法维护**本页的分页快照**。两者都必需
  /// （同一形制见一级帖子页 `PostsHubPage.tsx:232–262`）。
  void _registerFrameTracking() {
    final AylaChatWsClient chat = ref.read(chatWsProvider);
    _offFrames = chat.onFrame(_onFrame);
  }

  void _unregisterFrameTracking() {
    _offFrames?.call();
    _offFrames = null;
  }

  /// 帧分发 —— web tsx 188–231 的 `frame` 分支逐条对应。
  void _onFrame(Map<String, dynamic> frame) {
    // web tsx 189：`if (requestOwner.current !== owner || !owner.active) return`
    if (!_frameOwnerActive || !mounted) return;
    final Object? rawType = frame['type'];
    if (rawType is! String) return;

    // ---- post.deleted（tsx 190–196）：记入 deletedIds + 就地移除；不动游标 ----
    if (rawType == 'post.deleted') {
      final int? id = int.tryParse(frame['post_id']?.toString() ?? '');
      if (id == null) return;
      _deletedIds.add(id);
      _mutations[id] = _FrameMutation(++_mutationRevision, null);
      setState(() {
        _posts = <AylaPost>[
          for (final AylaPost p in _posts)
            if (p.id != id) p,
        ];
      });
      _cardKeys.remove(id);
      return;
    }

    // ---- post.created / post.updated（tsx 197–217）：单条权限 REST 对账 ----
    if (rawType == 'post.created' || rawType == 'post.updated') {
      final Object? rawPost = frame['post'];
      final int? id = rawPost is Map
          ? int.tryParse(
              Map<String, dynamic>.from(rawPost)['id']?.toString() ?? '')
          : null;
      if (id == null || id == 0) return;
      unawaited(_reconcileFramePost(id));
      return;
    }

    // ---- post.viewed（tsx 218–230）：跨端已读热更新（仅本人）----
    if (rawType == 'post.viewed') {
      final Object? rawData = frame['data'];
      if (rawData is! Map) return;
      final Map<String, dynamic> d = Map<String, dynamic>.from(rawData);
      // web tsx 221–223：`const me = useAuthStore.getState().currentUser;
      // if (!me || String(d.viewer_id) !== String(me.id)) return;` —— 未登录 / 非本人跳过。
      final String? me = ref.read(authNotifierProvider).user?.id;
      if (me == null) return;
      if (d['viewer_id']?.toString() != me) return;
      final String postId = d['post_id']?.toString() ?? '';
      final int? viewCount = (d['view_count'] as num?)?.toInt();
      setState(() {
        _posts = <AylaPost>[
          for (final AylaPost p in _posts)
            // web tsx 223–228：`String(p.id) === d.post_id ?
            //   { ...p, is_viewed: true, view_count: d.view_count } : p`
            if ('${p.id}' == postId)
              viewCount == null ? _markViewed(p) : _withViewed(p, viewCount)
            else
              p,
        ];
      });
    }
  }

  /// 单条帖子的**权限 REST 对账** —— web tsx 197–217。
  ///
  /// 三件事按序守卫，与 web 逐行同：
  /// 1. `detailRevision` 自增并快照 ⇒ 响应回来时若已被后续帧顶掉则丢弃（tsx 200–204）；
  /// 2. 响应里 `allowed_group_ids` 不含本群 ⇒ 视为「当前用户不可见」⇒ 记 mutation(null)
  ///    并从列表移除（tsx 205–209）；
  /// 3. 否则记 mutation(post) 并**插到列表头部**（`mergePosts(prev, [post], true)`，
  ///    tsx 210–211）—— 已存在的会原位替换，不重拉首页、不丢游标与滚动位置。
  ///
  /// 失败（403/404/网络）**静默**：web 原话「不可见或已删除的目录提示不成为新卡；
  /// 现有列表仍可继续分页/刷新」（tsx 213–215）。
  Future<void> _reconcileFramePost(int id) async {
    if (!_frameOwnerActive) return;
    final int revision = (_detailRevision[id] ?? 0) + 1;
    _detailRevision[id] = revision;
    final String? actor = ref.read(authNotifierProvider).user?.id;
    try {
      final AylaPost? post = await AylaPostsApi.getPost(id);
      if (!mounted || !_frameOwnerActive) return;
      // 账号守卫（REST 往返期间换账号 ⇒ 丢弃；web 的 `active` 校验等价物）
      if ((ref.read(authNotifierProvider).user?.id) != actor) return;
      // 已删 / 已被更晚的帧顶掉 ⇒ 旧响应作废（tsx 204）
      if (_deletedIds.contains(id)) return;
      if (_detailRevision[id] != revision) return;
      if (post == null) return; // 响应形状非法 ⇒ 不伪造一条帖子
      // 权限判据（tsx 205–208）：白名单不含本群 ⇒ 不是本目录的帖子。
      final bool visibleHere =
          post.allowedGroupIds.any((String gid) => gid == groupId);
      if (!visibleHere) {
        _mutations[id] = _FrameMutation(++_mutationRevision, null);
        setState(() {
          _posts = <AylaPost>[
            for (final AylaPost p in _posts)
              if (p.id != id) p,
          ];
        });
        _cardKeys.remove(id);
        return;
      }
      _mutations[id] = _FrameMutation(++_mutationRevision, post);
      setState(() {
        _posts = _mergeFramePost(_posts, post);
        // web tsx 212：`if (listActive.current) setRevealAfterRefresh(true)` ——
        // 帧带来的新卡要**照常播入场**（即使此前刚从详情返回、抑制还挂着）。
        // `listActive.current` = 列表态（非详情）⇒ 本页此处已在列表分支（详情走早退）。
        _revealAfterRefresh = true;
      });
      _scheduleUnreadRecount();
    } catch (_) {
      // 403/404 / 网络失败：静默（web tsx 213–215）。
    }
  }

  /// `mergePosts(prev, [post], prepend: true)`（web tsx 211 + 35–48）：
  /// 已存在 ⇒ **原位替换**（保留本地更"新"的已读/浏览量）；不存在 ⇒ 插到头部。
  List<AylaPost> _mergeFramePost(List<AylaPost> prev, AylaPost post) {
    final int index = prev.indexWhere((AylaPost p) => p.id == post.id);
    if (index < 0) {
      return <AylaPost>[post, ...prev];
    }
    final AylaPost old = prev[index];
    // web `mergePosts`（tsx 42–43）：`is_viewed: post.is_viewed || update.is_viewed`、
    // `view_count: Math.max(...)` ⇒ **单调**，不被新快照的旧值倒退。
    final List<AylaPost> next = List<AylaPost>.of(prev);
    next[index] = _withViewed(
      post,
      math.max(old.viewCount ?? 0, post.viewCount ?? 0),
      isViewed: old.isViewed || post.isViewed,
    );
    return next;
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
    // web tsx 360–365：`postId != null` 的 effect 里 `setRevealAfterRefresh(false)`
    // —— 进详情同时清掉「有新卡该播动画」标记，否则返回列表会误判。
    if (widget.postId != null) _revealAfterRefresh = false;
    // tsx 366–369 的 `active` 门随 postId 变（进详情 = false，返回 = true）。
    _restore.update(active: widget.postId == null);
    }
  }

  @override
  void dispose() {
    final ShellUiNotifier? notifier = _shell;
    final Future<void> Function()? callback = _refreshCallback;
    if (notifier != null && callback != null) {
      scheduleMicrotask(() => notifier.unregisterRefresh(callback));
    }
    _viewFlushTimer?.cancel(); // web `usePostViewTracking.ts:86` 的 clearTimeout
    // 页面级 WS 订阅解绑（web tsx 232–236 的 cleanup：`owner.active = false` + unsubscribe）
    _frameOwnerActive = false;
    _unregisterFrameTracking();
    if (_subscribedPostsStore) {
      aylaPostsStore.removeListener(_onChanged);
      _subscribedPostsStore = false;
    }
    _favorites.removeListener(_onChanged);
    _favorites.dispose();
    _share.dispose();
    _restore.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// 下拉刷新 / 刷新键共用的刷新动作（web tsx 166–168：`load = requestPage(false)`、
  /// `refresh = load`、`loadMore = requestPage(true)`）。
  ///
  /// 刷新完成后递增 `_replayNonce`（web tsx 152 的 `setReplayNonce`：**仅刷新（非追加）**
  /// 让已入场卡片整批重播浮入），并解除「详情返回」的抑制（tsx 149）。
  Future<void> _refresh() async {
    await _load();
    if (!mounted) return;
    setState(() {
      _skipRevealOnRestore = false;
      _replayNonce += 1;
    });
  }

  // ======================= 视口浏览上报（浏览与已读同源） =======================

  /// 某帖进入视口（web `usePostViewTracking.ts:64–67` 的 `pending.add(id)` + `schedule()`）。
  ///
  /// 作者自己的帖子后端天然已读（`docs/post_views_read_state.md` 「作者自己不计浏览」），
  /// 但 web 的 hook **不做作者过滤** —— 后端 `record_post_views` 跳过 `owner=user`
  /// （同文档），故上报是无害的 no-op ⇒ 这里同样不过滤，保持同一口径。
  void _onPostVisible(AylaPost post) {
    if (_pendingViews.contains(post.id)) return;
    _pendingViews.add(post.id);
    _scheduleViewFlush();
  }

  /// 排一次去抖 flush（web `usePostViewTracking.ts:56–58` 的 `schedule`）。
  void _scheduleViewFlush() {
    _viewFlushTimer ??= Timer(
      const Duration(milliseconds: kAylaPostViewFlushDelayMs),
      () {
        _viewFlushTimer = null;
        unawaited(_flushViews());
      },
    );
  }

  /// 批量上报（web `usePostViewTracking.ts:35–54` 的 `flush`）。
  ///
  /// 成功后：写共享 store 的已读态/浏览量（web `usePostsStore.markViewedBatch`）
  /// **并**同步本页本地副本（web 的 `onViewed` 回调，tsx 270–278）——
  /// 本页的 `_posts` 与全局 store **是两份数据**（web 亦然，见 tsx 251–265 的
  /// `displayPosts` 投影），只写 store 的话未读标签不会实时减少。
  ///
  /// 失败：保持原态（**不伪造已读**），下次进入视口会再次触发（web 同）。
  Future<void> _flushViews() async {
    // 在途时**不丢 id**：把本批放回待上报集，等本次结束后的下一次去抖再合并上报
    // （web 的 `pending` 是同一个 Set，flush 期间新相交的 id 会自然留在里面）。
    if (_reportsViews) {
      _scheduleViewFlush();
      return;
    }
    final List<int> ids = _pendingViews.toList(growable: false);
    if (ids.isEmpty) return;
    _pendingViews.clear();
    _reportsViews = true;
    try {
      final Map<String, int> updated =
          await AylaPostsApi.reportPostViews(ids);
      if (!mounted || updated.isEmpty) return;
      aylaPostsStore.markViewedBatch(updated);
      setState(() {
        _posts = <AylaPost>[
          for (final AylaPost p in _posts)
            if (updated['${p.id}'] != null) _withViewed(p, updated['${p.id}']!) else p,
        ];
      });
    } catch (_) {
      // 上报失败：不标已读（web `usePostViewTracking.ts:51–53` 同）。
      // ⚠️ 失败后**不回填** `_pendingViews`：web 也不回填，靠「下次进入视口再触发」
      // （hook 的 IO 会在重新相交时再次 add）。
    } finally {
      _reportsViews = false;
    }
  }

  /// 跳转到最近的未读帖子（web tsx 327–356 的 `jumpToUnread`）。
  ///
  /// web 直接改 `root.scrollTop`（瞬时）；Flutter 侧用 [ScrollController.jumpTo]
  /// 表达同一「瞬时定位」语义（`animateTo` 是另一档，web 这里没有过渡）。
  /// 找不到目标且方向为下且仍有未加载未读 ⇒ 先加载下一页（web tsx 347–350）。
  void _jumpToUnread(bool above) {
    final _UnreadSplit split = _unreadSplit();
    final int? targetId = above ? split.firstAboveId : split.firstBelowId;
    if (targetId == null) {
      if (!above && split.unloadedUnread > 0) unawaited(_load(append: true));
      return;
    }
    final BuildContext? ctx = _cardKeys[targetId]?.currentContext;
    if (ctx == null || !ctx.mounted) return;
    final RenderObject? object = ctx.findRenderObject();
    if (object is! RenderBox || !object.hasSize) return;
    if (!_scroll.hasClients) return;
    final ScrollPosition pos = _scroll.position;
    if (!pos.hasPixels || !pos.hasViewportDimension) return;
    // web：`root.scrollTop += targetRect.top - elRect.top - root.clientHeight / 2`
    // ⇒ 把目标卡滚到**视口垂直居中**。
    // ⚠️ `elRect` 是**滚动容器的全局矩形**，不是 `scrollTop` —— 本页滚动口上方还有
    // 吸顶玻璃头（`AylaGroupSceneStickyHead`，paint 阶段位移），故容器顶 ≠ 屏幕顶；
    // 用 `pixels` 代替 `elRect.top` 会让定位偏掉一个头部高度。
    final RenderObject? viewportObject =
        pos.context.storageContext.findRenderObject();
    if (viewportObject is! RenderBox || !viewportObject.hasSize) return;
    final Rect viewport =
        viewportObject.localToGlobal(Offset.zero) & viewportObject.size;
    final Offset global = object.localToGlobal(Offset.zero);
    final double delta = global.dy -
        viewport.top -
        pos.viewportDimension / 2;
    final double next =
        (pos.pixels + delta).clamp(0.0, pos.maxScrollExtent);
    _scroll.jumpTo(next);
    setState(() => _scrollTick += 1);
  }

  /// 排一帧后重算未读分组（卡片挂载后 `GlobalKey` 才有 `currentContext`）。
  ///
  /// 只在**尚未排**时登记（`_unreadScheduled`），避免连续 setState 积压多帧回调。
  void _scheduleUnreadRecount() {
    if (_unreadScheduled) return;
    _unreadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _unreadScheduled = false;
      if (mounted) setState(() => _scrollTick += 1);
    });
  }

  /// 每张卡的锚点（未读跳转按 id 反查 DOM ⇒ Flutter 用 GlobalKey 等价，
  /// web tsx 309 的 `root.querySelector('[data-post-id="..."]')`）。
  final Map<int, GlobalKey> _cardKeys = <int, GlobalKey>{};

  /// 未读重算是否已排帧。
  bool _unreadScheduled = false;

  // ======================= 显示投影（web tsx 251–265） =======================

  /// 本页列表 × 共享 store 的**单调合并** —— web tsx 251–265 的 `displayPosts`。

  /// ```tsx
  /// const displayPosts = useMemo(() => {
  ///   const byId = new Map(feedPosts.map((post) => [post.id, post]));
  ///   return groupPosts.map((p) => {
  ///     const existing = byId.get(p.id);
  ///     return existing
  ///       ? { ...p, is_viewed: p.is_viewed || existing.is_viewed,
  ///           view_count: Math.max(p.view_count ?? 0, existing.view_count ?? 0) }
  ///       : p;
  ///   });
  /// }, [dataOwner, feedPosts, groupPosts, ownerKey]);
  /// ```

  /// ⚠️ **只投影本目录已加载卡**（web 注释原话：「共享缓存提供单调已读/浏览量，
  /// 不扩大分页结果」）—— 不能拿 `store.posts` 当列表数据源，否则会把不在本页分页里的
  /// 旧帖塞进群内流，破坏游标与分页边界。
  ///
  /// ⚠️ 另一条 web 守卫（`dataOwner !== ownerKey` ⇒ 空列表，tsx 252）在本页由路由承担：
  /// 切群时本 State 被重建（`_cardKeys` / `_posts` 随 initState 归零）。
  List<AylaPost> _displayPosts() {
    final List<AylaPost> feed = aylaPostsStore.posts;
    if (feed.isEmpty) return _posts;
    final Map<int, AylaPost> byId = <int, AylaPost>{
      for (final AylaPost post in feed) post.id: post,
    };
    bool changed = false;
    final List<AylaPost> out = <AylaPost>[];
    for (final AylaPost post in _posts) {
      final AylaPost? existing = byId[post.id];
      if (existing == null) {
        out.add(post);
        continue;
      }
      final bool viewed = post.isViewed || existing.isViewed;
      final int viewCount = math.max(post.viewCount ?? 0, existing.viewCount ?? 0);
      if (viewed == post.isViewed && viewCount == (post.viewCount ?? 0)) {
        out.add(post);
        continue;
      }
      out.add(_withViewed(post, viewCount, isViewed: viewed));
      changed = true;
    }
    return changed ? List<AylaPost>.unmodifiable(out) : _posts;
  }

  /// 已加载列表里未读帖子的**上/下分组**（web tsx 302–325 的 `aboveUnread` /
  /// `belowUnread` 投影）。
  ///
  /// web 的判据逐条（tsx 312–322）：卡片矩形 `bottom < 容器顶` ⇒ 上方；
  /// `top > 容器底` ⇒ 下方；否则**在视口内** ⇒ 按「卡片中心 vs 视口中心」归入上/下
  /// （注释原话：「上报去抖期间仍可跳转」）。下方另加**未加载未读**
  /// `unloadedUnread = hasMore ? max(0, totalUnread - unreadPosts.length) : 0`（tsx 289）。
  ///
  /// ⚠️ 与 web 的差异（登记）：web 读 DOM `getBoundingClientRect()`（永远是最新布局）；
  /// Flutter 侧在 build 期读 [GlobalKey] 的渲染盒 —— 同一帧内 layout 已完成
  /// （本方法由 build 调用，`_scrollTick` 的排帧 setState 保证滚动后有一帧重建），
  /// 故读到的是当帧几何，语义一致。
  _UnreadSplit _unreadSplit() {
    final _UnreadSplit empty = _UnreadSplit(0, 0, 0, null, null);
    if (!_scroll.hasClients) return empty;
    final ScrollPosition pos = _scroll.position;
    if (!pos.hasPixels || !pos.hasViewportDimension) return empty;

    // ⚠️ 取 **displayPosts 投影**（web tsx 282–285：`displayPosts.filter((p) => !p.is_viewed)`）
    // —— 不是裸 `_posts`：别的页面浏览过的帖子回到这里也该算已读。
    final List<AylaPost> unread = <AylaPost>[
      for (final AylaPost p in _displayPosts())
        if (!p.isViewed) p,
    ];
    // 未加载的未读：只在 hasMore 时按差值计（web tsx 289）——
    // **不能**用本页条数代替全群未读总数（post_views_read_state.md 明文）。
    final int unloadedUnread =
        _hasMore ? math.max(0, _totalUnread - unread.length) : 0;
    if (unread.isEmpty && unloadedUnread == 0) return empty;

    // 滚动容器（viewport）的矩形：单滚动容器 ⇒ 列表口 = 整页滚动口。
    final RenderObject? viewportObject = pos.context.storageContext
        .findRenderObject();
    if (viewportObject is! RenderBox || !viewportObject.hasSize) return empty;
    final Rect viewport = viewportObject.localToGlobal(Offset.zero) &
        viewportObject.size;
    final double viewportCenter = viewport.center.dy;

    int above = 0;
    int below = 0;
    int? firstAboveId;
    int? firstBelowId;
    for (final AylaPost p in unread) {
      final GlobalKey? key = _cardKeys[p.id];
      final RenderObject? object = key?.currentContext?.findRenderObject();
      if (object is! RenderBox || !object.hasSize) continue;
      final Rect r = object.localToGlobal(Offset.zero) & object.size;
      if (r.bottom < viewport.top) {
        above += 1;
        firstAboveId ??= p.id; // 列表顺序中第一个在视口上方的（web tsx 334–341）
      } else if (r.top > viewport.bottom) {
        below += 1;
        firstBelowId ??= p.id; // 同上，下方取第一个（web tsx 342–345）
      } else {
        final double center = r.center.dy;
        if (center <= viewportCenter) {
          above += 1;
          firstAboveId ??= p.id;
        } else {
          below += 1;
          firstBelowId ??= p.id;
        }
      }
    }
    return _UnreadSplit(
      above,
      below + unloadedUnread,
      unloadedUnread,
      firstAboveId,
      firstBelowId,
    );
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
    // ⚠️ 刷新键与下拉刷新**共用同一个 `_load` 动作**（web tsx 167–168：`refresh = load`），
    // 但两者的「完成收尾」写法各自独立（下拉那档走 [_refresh]，本档保留既有内联版本）
    // —— 不合并成一个回调：两者签名不同（`Future<void> Function()`），
    // 且 `_registerRefresh` 的 callback 要登记到 shell store 供刷新键调用。

    _shell = notifier;
    _refreshCallback = callback;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      notifier.registerRefresh(callback);
    });
  }

  /// 合并时用「本地帧变更」压过 REST 结果（web `GroupPosts.tsx:131` 的 `mutations.get(id)`）。
  ///
  /// 若该帖在本次会话里收到过 `post.updated` 帧（`_mutations[id].post != null`），
  /// 就以帧里的版本为准；否则原样返回 REST 条目。
  AylaPost _localMutationWins(AylaPost incoming) {
    final _FrameMutation? m = _mutations[incoming.id];
    final AylaPost? local = m?.post;
    return local ?? incoming;
  }

  /// 取一页（`append` = 追加下一页）。
  Future<void> _load({bool append = false}) async {
    if (append && (_loadingMore || !_hasMore || _cursor == null)) return;
    // ★ 请求发起时的本地变更序号（web `GroupPosts.tsx:140` 的 `mutationRevision` 判据）。
    final int mutationAtStart = _mutationRevision;
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
      // ★ **墓碑 + 本地变更优先**（2026-10-20 全量普查修复 P2-1）。
      //
      // 此前 `_deletedIds` / `_mutations` 只在帧分支里**写**，`_load` 的合并处从不读 ⇒
      // ① 在 `post.deleted` 之前发出的 REST 响应会把**已删帖复活**；
      // ② 早于 WS 帧的旧响应会把**刚更新的帖子内容覆盖回去**。
      // web `GroupPosts.tsx:128/131/140` 正是在合并处消费这两个集合。
      final Map<String, AylaPost> merged = <String, AylaPost>{};
      if (append) {
        for (final AylaPost p in _posts) {
          if (_deletedIds.contains(p.id)) continue;
          merged['${p.id}'] = _localMutationWins(p);
        }
      } else {
        // 首屏：保留「本次请求期间被帧改过」的本地版本（web 的 `preserved`）。
        for (final AylaPost p in _posts) {
          if (_deletedIds.contains(p.id)) continue;
          final _FrameMutation? m = _mutations[p.id];
          if (m != null && m.revision > mutationAtStart) {
            merged['${p.id}'] = p;
          }
        }
      }
      for (final AylaPost p in page.results) {
        if (_deletedIds.contains(p.id)) continue;
        merged['${p.id}'] = _localMutationWins(p);
      }
      setState(() {
        _posts = merged.values.toList(growable: false);
        _cursor = page.nextCursor;
        _hasMore = page.hasMore;
        // web tsx 148–153：列表重新拿到数据后放开「详情返回」的抑制
        //（`wasLoaded` / `listActive` 两个前置条件在本页恒成立：详情态不走本页 load）。
        _skipRevealOnRestore = false;
        _revealAfterRefresh = true;
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
      // ★ 未读分组需要**卡片已挂载**才能量矩形 ⇒ 排一帧后重算一次。
      //
      // 与 web 的差异（登记）：web 的 `aboveUnread` 是 `useMemo`，依赖 `displayPosts`
      // 变化即重算，而它读的 DOM 在同一次提交里已经存在（React 先 commit 再 paint）；
      // Flutter 的 `itemBuilder` 回调在**元素挂载阶段**才执行，`build()` 里拿不到
      // 卡片的 `GlobalKey.currentContext`（首帧必然为空）⇒ 必须补一帧。
      // 这一帧就是「首屏卡片落位后标签出现」，与 web 的观感一致。
      _scheduleUnreadRecount();
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
      // web tsx 245（`handleCreated`）：`setRevealAfterRefresh(true)` ——
      // 自己刚发的帖子照常播入场。
      _revealAfterRefresh = true;
    });
  }

  /// 帖子卡作者头像的点击目标（web `PostCard.tsx:70–79` 的
  /// `goUserProfile(currentUserId, author.id)`；`utils/navigation.ts:24–35`：
  /// 自己 → `/profile`，他人 → `/user/:id`，目标 id 为空 ⇒ 不跳（= null 回调、头像不可点））。
  VoidCallback? _authorTap(AylaPost post) {
    final String? authorId = post.authorId;
    if (authorId == null || authorId.isEmpty) return null;
    return () {
      final String? me = ref.read(authNotifierProvider).user?.id;
      if (me != null && me == authorId) {
        context.go('/profile');
      } else {
        context.push('/user/${Uri.encodeComponent(authorId)}');
      }
    };
  }

  void _openPost(int id) {
    // web tsx 426–431：进详情前先写 `setSkipRevealRestoreKey(scrollRestoreKey)` +
    // `setRevealAfterRefresh(false)`。Flutter 侧由 [didUpdateWidget] 在 `postId`
    // 出现时登记同一事实（无需 setState：紧接着的路由变化必然重建本页）。
    _skipRevealOnRestore = true;
    _revealAfterRefresh = false; // web tsx 429
    AylaScrollMemory.save(_restoreKey, _scroll); // web tsx 430
    // 群帖列表 → 帖子详情：**push**（web tsx 426–431 的 navigate 是 push 语义）。
    context.push(
      '/group/${Uri.encodeComponent(groupId)}/posts/$id',
    );
  }

  @override
  Widget build(BuildContext context) {
    // 详情往返：保留外壳（web tsx 382–384 与 477 之后的输入区）。
    final String? postId = widget.postId;
    if (postId != null) return PostDetailPage(postId: postId);

    final AylaTextStyles t = AylaTextStyles.of(context);
    // web tsx 386：`displayPosts.length === 0 && (loading || dataOwner !== ownerKey)`
    final List<AylaPost> displayPosts = _displayPosts();
    final bool showSkeleton = displayPosts.isEmpty && _loading;
    // tsx 366–369：`ready: displayPosts.length > 0`。
    _restore.update(ready: displayPosts.isNotEmpty);

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
    } else if (displayPosts.isEmpty && _error != null) {
      content = AylaGroupScenePlaceholder(
        description: _error,
        actions: <Widget>[
          AylaGlassButton(label: '重试', onPressed: () => unawaited(_load())),
        ],
      );
    } else if (displayPosts.isEmpty) {
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
        // ⚠️ 完整表达式 = `_skipRevealOnRestore && !_revealAfterRefresh`
        //（web tsx 379 的 `(restoring || skipRevealRestoreKey === scrollRestoreKey) && !revealAfterRefresh`）
        // ⇒ 取页成功 / 帧插卡 / 发帖三处**会提升**它，压过「详情返回」的抑制。
        // 2026-10-17：补上第一项 `restoring`（web tsx 379 的完整表达式
        // `(restoring || skipRevealRestoreKey === scrollRestoreKey) && !revealAfterRefresh`）；
        // 此前只有第二项 —— `useScrollRestore` 的等价物缺失时该项恒假。
        suppress:
            (_restore.restoring || _skipRevealOnRestore) && !_revealAfterRefresh,
        child: AylaMasonryGrid<AylaPost>(
          // 列表口径 = displayPosts 投影（web tsx 372–377 的 `displayPosts`）
          items: displayPosts,
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
            // 未读跳转按 id 反查锚点（web tsx 309 的 `[data-post-id]` 查询）。
            final GlobalKey anchor = _cardKeys.putIfAbsent(post.id, GlobalKey.new);
            return AylaRevealItem(
              fadeGlass: false,
              // `delay = staggerDelay(index) = min(index*50, 300)`
              //（`useRevealOnEnter.ts:48–49`；gap 50 / cap 300 见 `auroraquaMotion.ts:16`）。
              delay: AylaRevealMotion.staggerDelay(index, staggerMs: 50),
              child: Padding(
                padding: const EdgeInsets.only(bottom: AylaSpacing.sp3),
                // 视口浏览上报（web `usePostViewTracking` 挂在 `[data-post-id]` 元素上，
                // 即 tsx 419–423 的 `.posts-feed-item`）⇒ Flutter 侧同层挂探针。
                // ⚠️ 探针必须在 `AylaRevealItem` **内层**：入场动画有 translateY(20→0)，
                // 若探针在外层会按「未位移的布局位」判定，首屏可能把尚未落位的卡算作可见。
                child: AylaPostViewProbe(
                  key: anchor,
                  onVisible: () => _onPostVisible(post),
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
                    // 作者头像 → 个人主页（web `PostCard.tsx:70–79` 的
                    // `goUserProfile(currentUserId, author.id)`；自己 → /profile、他人 → /user/:id）。
                    // 此前本页未接 ⇒ 头像不可点（群内帖子页缺这一处，其余帖子面已接）。
                    onAuthorTap: _authorTap(post),
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

    // ---- 下拉刷新（web tsx 398；**只在列表态**挂，与 web 的三态分支同构） ----
    //
    // web 把 `<PullToRefresh>` 包在**三态之外**（tsx 398–448：加载/空/列表都在里面），
    // Flutter 侧同样包在最外层 —— 空态/错态也能下拉重试（web 亦然，`onRefresh` 就是
    // `load`）。未读标签（tsx 450–476）**在 PullToRefresh 之外**（兄弟节点），
    // 故这里是 `Stack`：内容层挂下拉，标签层浮在其上。
    final Widget scrollArea = AylaPullToRefresh(
      // web tsx 182：`isAtTop = () => (listRef.current?.scrollTop ?? 0) <= 0`
      isAtTop: () => !_scroll.hasClients || _scroll.position.pixels <= 0,
      onRefresh: _refresh,
      child: content,
    );

    final _UnreadSplit unread = _unreadSplit();

    // ---- 未读帖子跳转标签（web tsx 450–476）----
    //
    // ⚠️ **定位基准 = 整个 `.group-posts` 容器**（= 本页的 [AylaGroupPostsComposer]），
    // 不是滚动口、也不是 composer 的 child 槽。web 的 `.group-posts` 是
    // `position: relative`（posts.css 942–948），两条 `.message-jump-tags` 是它的
    // **直接子级**（tsx 388 / 450–476）⇒ 上标签 = 容器顶 + sp3(12)、
    // 下标签 = 容器底 − (sp3 + 64)（posts.css 1084–1086，64 = compact 输入栏高度，
    // 抬到输入栏之上）。滚动口上方的吸顶玻璃头、下方的输入栏**都不参与**该计算。
    //
    // ⇒ 做法：把两条标签放进一个**与 composer 同尺寸的 Stack 覆层**（外层 Stack 的
    // `fit: StackFit.expand`），而不是塞进 composer 的 `child` 槽 —— 后者在收起态只占
    // 「列表」那一格（高度 = 容器高 − 输入栏），下标签会比 web 高出整个输入栏。
    //
    // 复用聊天界面同一套语言：`.message-jump-tags` + `.message-jump-mention`
    // （app.css:911–962）+ 群内帖子的两处覆写（posts.css:1080–1086：`z-index: 60`
    // 高于发帖输入栏 50 与遮罩 45）。
    //
    // 层级：外层 Stack 的 children 顺序即 z 序 —— composer 在前、两条标签在后 ⇒
    // 标签永远压在滚动内容与输入栏之上（等价 `z-index: 60`）。
    final Widget? tagsAbove = unread.above > 0
        ? Positioned(
            left: 0,
            right: 0,
            top: AylaSpacing.sp3, // .message-jump-tags-above { top: var(--sp-3) }
            child: _JumpTag(
              label: '↑ ${unread.above} 条未读帖子',
              ariaLabel: '跳转到上方 ${unread.above} 条未读帖子',
              tooltip: '上方有未读帖子',
              onTap: () => _jumpToUnread(true),
            ),
          )
        : null;
    final Widget? tagsBelow = unread.below > 0
        ? Positioned(
            left: 0,
            right: 0,
            // .group-posts .message-jump-tags-below { bottom: calc(sp3 + 64px) }
            // （posts.css:1084–1086；64 = 输入栏 compact 高度）
            bottom: AylaSpacing.sp3 + 64,
            child: _JumpTag(
              label: '↓ ${unread.below} 条未读帖子',
              ariaLabel: '跳转到下方 ${unread.below} 条未读帖子',
              tooltip: '下方有未读帖子',
              onTap: () => _jumpToUnread(false),
            ),
          )
        : null;
    final Widget composer = AylaGroupPostsComposer(
      groupId: groupId,
      expanded: _editorExpanded,
      onExpandedChange: (bool next) => setState(() => _editorExpanded = next),
      onSubmit: _submit,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: NotificationListener<ScrollNotification>(
              onNotification: _onListScroll,
              child: AylaGroupSceneStickyHead(
                controller: _scroll,
                // ⚠️ **真实生效值 = 四向 sp4 + gap sp4**（2026-10-09 用户实报「标题栏与内容区
                // 之间缺留白」后订正；此前这里传的是 sp3/sp4 + gap 0，是**读错了规则**）。
                //
                // 事实源（web 两档一致，无 @media 差异）：
                //   `group.css:409–417`（选择器 `.group-page .group-posts-list`，特异性 **0-2-0**）
                //     `padding: var(--sp-4); gap: var(--sp-4)`
                //   以特异性压过 `posts.css:975–983`（`.group-posts-list`，**0-1-0**）的
                //     `padding: var(--sp-3) var(--sp-4); gap: 0`
                //   ⇒ 与源码顺序无关，决定权在特异性。
                //   该段注释原话：「三个场景统一四向 16px 外间距；**父容器 gap 明确保证头部与
                //   首个内容块留白**，不让 PullToRefresh 的包裹层改变头部与首张卡的几何关系。」
                //   ⇒ 这就是「标题卡与内容区之间 16px」的**真正来源**；帖子场景与语音/桌游
                //   （`group_voice_page.dart` / `group_games_page.dart`，两者本就是这个值）同档。
                //
                // ⚠️ 本文件 `_load()` 里那条注释（「被 group.css 换成四向 sp4」）当时**已经写对**，
                // 但这里的参数却按 posts.css 的败方写了 ⇒ 注释与代码自相矛盾，即本次的根因。
                padding: const EdgeInsets.all(AylaSpacing.sp4),
                gap: AylaSpacing.sp4,
                head: AylaGroupSceneHead(
                  title: '群内帖子',
                  description: '浏览本群的最新动态',
                  trailing: AylaGlassButton(
                    label: '我的帖子',
                    onPressed: () => context.push('/posts/mine'),
                  ),
                ),
                child: scrollArea,
              ),
            ),
          ),
        ],
      ),
    );

    // ---- `.group-posts` 容器 + 两条跳转标签的覆层（web tsx 388–476 的子级关系） ----
    //
    // ⚠️ **不能把标签直接放进 composer 的 `child` 槽**：那个槽在收起态只占「列表」那一格
    // （高度 = 容器高 − 输入栏），`Positioned.bottom` 的包含块就成了**列表口**而不是
    // `.group-posts` ⇒ 下标签比 web 高出整个输入栏。这里补一层 `fit: StackFit.expand`
    // 让两条标签的包含块 = composer 的完整矩形（= web 的 `.group-posts`）。
    //
    // ⚠️ **必须无条件返回同一个 Stack**：标签是「有未读才出现」的（`?tagsAbove`），
    // 若空档直接返回 composer，则标签首次出现时**根级结构变化** ⇒ composer 子树被
    // remount ⇒ 所有 `AylaRevealItem` 的入场动画从头重播（实测：首屏卡片在未读标签
    // 出现的那一刻闪一次，`group_posts_page_test.dart` 的入场用例因此变红）。
    // web 侧不存在该问题：React 在同一父级里**追加**子节点不改变既有兄弟的身份。
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        composer,
        ?tagsAbove,
        ?tagsBelow,
      ],
    );
  }
}

/// 帧驱动的本地变更记录（web `owner.mutations` 的条目，tsx 56）。
///
/// `post == null` = 该帖**被删除 / 当前用户不可见**（web 里 mutation.post 为 null 的语义）。
class _FrameMutation {
  const _FrameMutation(this.revision, this.post);

  /// 变更序号（web `++owner.mutationRevision`）—— 用于和「分页请求开始时的版本」比大小。
  final int revision;

  /// 变更后的帖子（null = 删除 / 不可见）。
  final AylaPost? post;
}

/// 已读态重建 —— `AylaPost` 是纯 `const` 模型（无 `copyWith`），
/// web 的 `{ ...p, is_viewed: true, view_count }`（tsx 270–278）在这里整条重建。
///
/// ⚠️ 与 `state/posts_store.dart:220–239` 的 `_withViewed` 同形但**不能复用**：
/// 那是 `state/` 的文件私有函数（未导出），且本页改的是**本地副本**而非 store。
///
/// [isViewed] 缺省 = `true`（浏览上报/本人已读两处恒标已读）；只有
/// [_mergeFramePost] 的单调合并档需要传 `old || incoming`（web tsx 42）。
AylaPost _withViewed(AylaPost post, int viewCount, {bool isViewed = true}) => AylaPost(
      id: post.id,
      author: post.author,
      authorId: post.authorId,
      authorNickname: post.authorNickname,
      title: post.title,
      body: post.body,
      visibility: post.visibility,
      groupId: post.groupId,
      groupName: post.groupName,
      allowedGroupIds: post.allowedGroupIds,
      allowedGroupNames: post.allowedGroupNames,
      images: post.images,
      commentCount: post.commentCount,
      isAuthor: post.isAuthor,
      viewCount: viewCount,
      isViewed: isViewed,
      createdAt: post.createdAt,
      updatedAt: post.updatedAt,
    );

/// `view_count` 未知时的「只标已读」重建 —— web tsx 224–228 里
/// `view_count: d.view_count` 是帧字段，缺字段时不该把已有浏览量写坏。
AylaPost _markViewed(AylaPost post) => _withViewed(post, post.viewCount ?? 0);

/// 未读上/下分组投影（web tsx 302–325 的 `{ aboveUnread, belowUnread }` + 两个跳转目标）。
class _UnreadSplit {
  const _UnreadSplit(
    this.above,
    this.below,
    this.unloadedUnread,
    this.firstAboveId,
    this.firstBelowId,
  );

  /// 视口上方未读条数（含视口内上半部分）。
  final int above;

  /// 视口下方未读条数（含未加载未读）。
  final int below;

  /// 未加载的未读条数（= `hasMore ? max(0, totalUnread - unreadPosts.length) : 0`）。
  final int unloadedUnread;

  /// 跳转目标：列表顺序中第一个在视口上方的未读（web tsx 334–341）。
  final int? firstAboveId;

  /// 跳转目标：第一个在视口下方的未读（web tsx 342–345）。
  final int? firstBelowId;
}

/// 未读跳转标签（`.message-jump-mention` 胶囊，app.css:940–962）。
///
/// 与 `widgets/chat/message_list.dart:1178–1230` 的 `_tagRow` 是**同一份 web 规则**
/// （`.message-jump-tags .message-jump-mention` 的定位覆写 + `.message-jump-mention` 本体），
/// 但那一件是消息域的私有方法（未导出）⇒ 这里按同一条 CSS 复刻一份，
/// 数值逐条取自 app.css（非自由发挥）。
class _JumpTag extends StatelessWidget {
  const _JumpTag({
    required this.label,
    required this.ariaLabel,
    required this.tooltip,
    required this.onTap,
  });

  final String label;
  final String ariaLabel;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // `.message-jump-tags { display:flex; flex-direction:column; align-items:center }`
    // ⇒ 胶囊水平居中（单条时即 Center）。
    return AylaTooltip(
      message: tooltip,
      child: Center(
        child: MouseRegion(
          cursor: SystemMouseCursors.click, // `.message-jump-mention { cursor: pointer }`
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Semantics(
              button: true,
              label: ariaLabel,
              // `.message-jump-mention`（app.css:940–958）：
              // `padding: sp1 sp4` + `1px solid var(--glow-500)` + pill +
              // `background: var(--glass-bg-strong)` + `backdrop-filter: blur(18px) saturate(1.4)`
              // + `box-shadow: var(--glow-shadow)` + 13/700 `--grape-700`
              child: AylaGlassSurface(
                strong: true, // --glass-bg-strong
                blur: AylaGlass.blurNav, // blur(18px) saturate(1.4)
                radiusOverride: AylaRadii.pill,
                shadow: AylaShadows.glow, // --glow-shadow
                borderOverride: Border.all(color: AylaColors.glow500),
                padding: const EdgeInsets.symmetric(
                  horizontal: AylaSpacing.sp4,
                  vertical: AylaSpacing.sp1,
                ),
                child: Text(
                  label,
                  style: const TextStyle(
                    fontFamily: AylaFonts.body,
                    fontFamilyFallback: AylaFonts.cjkFallback,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AylaColors.grape700,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 帖子卡视口探针 —— web `usePostViewTracking.ts:60–81` 的 `IntersectionObserver` 等价物。
///
/// ## 与消息域那件的差异（**阈值不可互抄**，登记）
/// `widgets/chat/message_visibility.dart` 的 `AylaMessageVisibilityProbe` 阈值是 **0.6**
/// （消息域的 web 事实源 `MessageList.tsx:912` 明写 `threshold: 0.6`）；
/// 本域的 web 事实源 `usePostViewTracking.ts:70` **没传 threshold**
/// （默认 0 ⇒ **任意相交即算进入视口**），只给了 `rootMargin: "0px 0px -5% 0px"`
/// （底部 5% 缓冲）。两者语义不同 ⇒ 本件按 posts 域口径实现，不复用消息域那件。
///
/// ## 触发语义（对照 IO）
/// 1. 首帧布局后量一次（对应 `observe()` 后立刻投递的初始 entry）；
/// 2. 祖先 [ScrollPosition] 每次 notify 后量一次；
/// 3. 只在**上升沿**（不可见 → 可见）回调 —— 持续可见不重复回调（IO 的「跨越阈值」语义）。
/// **公开件（2026-10-17 起）**：原本是本页私有的 `_AylaPostViewProbe`。帖子域另两页
/// （`posts_hub_page.dart` / `my_posts_page.dart`）的 web 同源 hook
/// （`PostsHubPage.tsx:113` / `MyPostsPage.tsx:68` 都调 `usePostViewTracking`）**此前没接**
/// ⇒ 这两页刷帖不产生浏览上报（红屏/已读不同步）。三页共用同一探针 ⇒ 去下划线转为
/// 公开类，由另两页 import 复用（**不复制第二份**）。
///
/// ⚠️ 待裁决：更合适的归属是 `lib/widgets/posts/post_view_probe.dart`，但该路径不在
/// 本次任务 writeScopes 内；先留在本文件（三处消费点同源，无重复实现）。
class AylaPostViewProbe extends StatefulWidget {
  const AylaPostViewProbe({super.key, required this.child, this.onVisible});

  final Widget child;

  /// 进入视口（上升沿）时回调一次。
  final VoidCallback? onVisible;

  @override
  State<AylaPostViewProbe> createState() => _AylaPostViewProbeState();
}

class _AylaPostViewProbeState extends State<AylaPostViewProbe> {
  ScrollPosition? _position;
  bool _queued = false;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _bind();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
  }

  @override
  void dispose() {
    _position?.removeListener(_schedule);
    super.dispose();
  }

  /// 绑定最近的祖先滚动位置（幂等；换祖先时可见态作废重判）。
  void _bind() {
    if (!mounted) return;
    ScrollPosition? found;
    context.visitAncestorElements((Element element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        found = (element.state as ScrollableState).position;
        return false;
      }
      return true;
    });
    if (!identical(found, _position)) {
      _position?.removeListener(_schedule);
      _position = found;
      _position?.addListener(_schedule);
      _visible = false;
    }
    _schedule();
  }

  void _schedule() {
    if (_queued) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (mounted) _measure();
    });
  }

  void _measure() {
    final RenderObject? object = context.findRenderObject();
    if (object is! RenderBox || !object.hasSize) return;
    final Rect self = object.localToGlobal(Offset.zero) & object.size;
    final RenderObject? viewport = RenderAbstractViewport.maybeOf(object);
    if (viewport is! RenderBox || !viewport.hasSize) return;
    final Rect raw = viewport.localToGlobal(Offset.zero) & viewport.size;
    // rootMargin: "0px 0px -5% 0px" ⇒ 视口矩形底部上收 5%（面积口径的近似：
    // 高度按比例缩，与浏览器把 rootMargin 当作 root 矩形内缩一致）。
    final Rect root = Rect.fromLTRB(
      raw.left,
      raw.top,
      raw.right,
      raw.bottom - raw.height * kAylaPostViewBottomMarginRatio,
    );
    final bool visible = self.overlaps(root);
    if (visible == _visible) return;
    _visible = visible;
    if (visible) widget.onVisible?.call();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
