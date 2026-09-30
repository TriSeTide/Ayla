/// 主页（路由 /group）—— web pages/HomePage.tsx（223 行）的等价物。
///
/// ## 事实源（逐条）
/// - tsx 35–47：首屏骨架 6 张（.home-grid 两列、卡内 4:3 封面占位 + 60% 标题条）
///   ⇒ [aylaHomeSkeletonGrid]；
/// - tsx 49–56：群会话分页（useSocialPage("conversations", { type: "group" })）
///   + layout / recentGroupId（stores/home.ts）；
/// - tsx 64–67：只收 type === "group"；
/// - tsx 73–80：排序（置顶 > 新内容 > 稳定）⇒ [aylaSortGroupsByActivity]；
/// - tsx 83–93：宽屏「最近群」单独校验（不在当前页里就去查该会话摘要）；
/// - tsx 95–101：进群 = 记 recentGroupId + /group/:id；
/// - tsx 104–118：下拉刷新 / 刷新键共用同一回调（重拉会话列表 + 重播入场）；
/// - tsx 124–151：宽屏：重定向到最近群 / 轻量加载指示 / 空群引导（.home-wide-empty）；
/// - tsx 153–222：窄屏：.home-toolbar（.home-title 群聊 + LayoutSwitch）
///   → 骨架 / .home-state 空态 / PullToRefresh（卡片或列表）+ DirectoryLoadMore；
/// - tsx 163–166 + home.css 18–30：.home-toolbar padding sp3 sp4、
///   .home-title Display 28 / w600 / text-primary。
///
/// ## 复用（不另起一套）
/// AylaGroupCard / AylaGroupList / AylaGroupListItem / AylaGroupGrid /
/// AylaLayoutSwitch / AylaPullToRefresh / AylaDirectoryLoadMore /
/// AylaGroupCreateDialog / AylaGlassButton / AylaRevealScope。
///
/// ## 机制差异（登记）
/// 1. 宽屏重定向目标 /group/:id（三列群聊界面）属第 5 批（GroupPage 五场景）
///    ⇒ 本批窄屏形态完整可用，宽屏重定向在该批交付前落到占位页（web 行为逐条保留，
///    不因下游未交付而改动路由语义）；
/// 2. useIsPresent()（AnimatePresence 的在场判定）无 Flutter 等价物 ⇒ 路由一律
///    NoTransitionPage（时长 0、旧页立即卸载），页面在场上即 present，不另设判定；
/// 3. 群活动四份目录（live / voice / boardgame / posts）在 web 由登录预加载 + WS 维护，
///    Flutter 侧本批按 appInit.ts 的同一组请求在进入/刷新时并发取第一页
///    （无 WS 增量，见 home_support.dart 文件头）；
/// 4. 滚动位置记忆（useScrollRestore）未实现（与其他页同登记）；
/// 5. web 的 getConversationSummary(?metadata=directory) 在 Flutter 无消费者
///    （本页只需判「是不是群」）⇒ 宽屏「最近群」校验走不可用分支（见
///    [_resolveRecentForWide] 的注释），行为等价于 web 的 catch 分支。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/boardgame_api.dart';
import '../core/api/chat_api.dart';
import '../core/api/directory_page.dart' show AylaDirectoryPage;
import '../core/api/live_api.dart';
import '../core/api/posts_api.dart';
import '../core/api/users_api.dart';
import '../core/api/voice_api.dart';
import '../core/models/conversation.dart';
import '../core/models/game_room.dart' show AylaGameRoom;
import '../core/models/post.dart' show AylaPost;
import '../core/models/user_public.dart' show AylaUserPublic;
import '../state/auth_state.dart';
import '../state/directory_events.dart' show AylaDirectoryKind;
import '../state/directory_store.dart';
import '../state/home_prefs.dart';
import '../state/posts_store.dart';
import '../state/social_store.dart';
import '../state/shell_state.dart';
import '../theme/glass.dart' show AylaGlassButton, AylaGlassButtonVariant;
import '../theme/tokens.dart';
import '../widgets/base/avatar_status_badges.dart' show AylaAvatarStatus;
import '../widgets/base/directory_load_more.dart';
import '../widgets/base/loading.dart' show AylaLoadingSpinner;
import '../widgets/base/media_interaction.dart' show AylaPullToRefresh;
import '../widgets/base/reveal.dart';
import '../widgets/group/group_card.dart';
import '../widgets/group/group_create_dialog.dart' show AylaGroupCreateDialog;
import '../widgets/group/home_toolbar.dart' show AylaHomeToolbar;
import 'home_support.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  final ScrollController _scroll = ScrollController();
  final AylaHomePrefsController _prefs = AylaHomePrefsController();

  AylaSocialController<AylaConversationSummary>? _pager;
  AylaHomeCatalogs _catalogs = const AylaHomeCatalogs();
  AylaHomeActivityMap? _activity;
  int _replayNonce = 0;
  bool _creatingGroup = false;

  /// 宽屏「最近群」的独立校验结果（web resolvedRecent）：
  /// undefined（未校验）用 [_recentResolved] 表达，校验出的值放 [_resolvedRecent]
  /// （null = 已校验但不是群 / 取不到 ⇒ 不再等待）。
  bool _recentResolved = false;
  String? _resolvedRecent;

  /// 当前页注册到 shell 的刷新回调（web useShellStore.registerRefresh）。
  ShellUiNotifier? _shellNotifier;
  Future<void> Function()? _refreshCallback;

  // ---- 建群弹窗的成员搜索（web GroupCreateDialog.tsx:29 的 useSocialPage("users")）----
  List<AylaUserPublic> _memberResults = const <AylaUserPublic>[];
  bool _memberLoading = false;
  String? _memberError;
  bool _memberHasMore = false;
  String? _memberCursor;
  String _memberQuery = '';
  int _memberRevision = 0;

  @override
  void initState() {
    super.initState();
    _prefs.addListener(_onPrefsChanged);
    _start();
    _prefs.load();
    _loadCatalogs();
  }

  @override
  void dispose() {
    _prefs.removeListener(_onPrefsChanged);
    _prefs.dispose();
    final ShellUiNotifier? notifier = _shellNotifier;
    final Future<void> Function()? callback = _refreshCallback;
    if (notifier != null && callback != null) {
      // 引用守卫注销（web cleanup 的等价物）：延迟到生命周期之外执行，
      // 否则触发 Riverpod 的「生命周期内修改 provider」断言。
      scheduleMicrotask(() => notifier.unregisterRefresh(callback));
    }
    _pager?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onPrefsChanged() {
    if (mounted) setState(() {});
  }

  void _onPagerChanged() {
    if (!mounted) return;
    setState(() {
      _activity = AylaHomeActivityMap(
        conversations: _pager?.items ?? const <AylaConversationSummary>[],
        catalogs: _catalogs,
      );
    });
    _resolveRecentForWide();
  }

  /// tsx 83–93：宽屏「最近群」不在当前页里时，web 会单独问该会话摘要校验。
  ///
  /// Flutter 侧本页只需要判「它是不是群」，而唯一能取单条会话的接口
  /// （?metadata=directory）在本批没有别的消费者 ⇒ 按 web 的失败分支处理
  /// （catch 里 setResolvedRecent(null)）：校验不到就视为不可用，落到「第一个群」。
  Future<void> _resolveRecentForWide() async {
    final String? recent = _prefs.recentGroupId;
    if (recent == null || _recentResolved) return;
    if (_groups().any((AylaConversationSummary g) => g.id == recent)) {
      if (mounted) {
        setState(() {
          _recentResolved = true;
          _resolvedRecent = recent;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _recentResolved = true;
      _resolvedRecent = null;
    });
  }

  void _start() {
    // 数据归**共享 store**（web `useSocialPage("conversations", { type: "group" })`）：
    // `appInit` 已按 `appInit.ts:35` 预取同一组合 ⇒ 命中 60 秒缓存（`social.ts:150`）
    // ⇒ `loading == false` ⇒ **主页不显示自己的骨架**（用户实报项）。
    final AylaSocialController<AylaConversationSummary> pager =
        AylaSocialController<AylaConversationSummary>(
      store: aylaSocialStore,
      kind: AylaSocialKind.conversations,
      options: const AylaSocialOptions(type: 'group'),
    );
    pager.addListener(_onPagerChanged);
    _pager?.dispose();
    _pager = pager;
    _registerRefresh();
    unawaited(pager.load());
  }

  /// 四份目录的第一页（web appInit.ts:41–48 的同一组请求；失败各自兜底为空 ——
  /// 与 web「失败不阻断流程」同）。
  Future<void> _loadCatalogs() async {
    final List<Object?> results = await Future.wait<Object?>(<Future<Object?>>[
      _live(),
      _voice(),
      _game(),
      _posts(),
    ]);
    if (!mounted) return;
    final List<AylaDirectoryLiveEntry> live =
        (results[0] as List<AylaDirectoryLiveEntry>?) ??
            const <AylaDirectoryLiveEntry>[];
    final List<AylaDirectoryVoiceEntry> voice =
        (results[1] as List<AylaDirectoryVoiceEntry>?) ??
            const <AylaDirectoryVoiceEntry>[];
    final List<AylaDirectoryGameEntry> game =
        (results[2] as List<AylaDirectoryGameEntry>?) ??
            const <AylaDirectoryGameEntry>[];
    final List<AylaPost> posts =
        (results[3] as List<AylaPost>?) ?? const <AylaPost>[];
    setState(() {
      _catalogs = AylaHomeCatalogs(
        liveChannels: live,
        voiceChannels: voice,
        gameRooms: <AylaGameRoom>[
          for (final AylaDirectoryGameEntry e in game) e.room,
        ],
        posts: posts,
      );
      _activity = AylaHomeActivityMap(
        conversations: _pager?.items ?? const <AylaConversationSummary>[],
        catalogs: _catalogs,
      );
    });
  }

  /// 直播目录第一页 —— **读共享 store 的「全部档」record**（正是 `appInit` 预取的那条，
  /// `appInit.ts:37` 的 `loadDirectory("live")`）：命中 60 秒缓存 ⇒ **不发请求**
  /// （`stores/directory.ts:274`）；失败时 store 里是空 items ⇒ 与 web「兜底为空」同。
  Future<Object?> _live() async {
    // 与 `appInit` 预取**同 key**（`filter: 'all'`）⇒ 命中即不发请求。
    await aylaDirectoryStore.load(
      AylaDirectoryKind.live,
      const AylaDirectoryOptions(filter: 'all'),
    );
    return aylaDirectoryStore.itemsAs<AylaDirectoryLiveEntry>(
      AylaDirectoryKind.live,
      const AylaDirectoryOptions(filter: 'all'),
    );
  }

  /// 语音目录第一页 —— 同 [_live]（`appInit.ts:36` 的 `loadDirectory("voice")`）。
  Future<Object?> _voice() async {
    // 与 `appInit` 预取**同 key**（`filter: 'all'`）⇒ 命中即不发请求。
    await aylaDirectoryStore.load(
      AylaDirectoryKind.voice,
      const AylaDirectoryOptions(filter: 'all'),
    );
    return aylaDirectoryStore.itemsAs<AylaDirectoryVoiceEntry>(
      AylaDirectoryKind.voice,
      const AylaDirectoryOptions(filter: 'all'),
    );
  }

  /// 桌游目录第一页 —— 同 [_live]（`appInit.ts:39` 的 `loadDirectory("game")`）。
  Future<Object?> _game() async {
    // 与 `appInit` 预取**同 key**（`filter: 'all'`）⇒ 命中即不发请求。
    await aylaDirectoryStore.load(
      AylaDirectoryKind.game,
      const AylaDirectoryOptions(filter: 'all'),
    );
    return aylaDirectoryStore.itemsAs<AylaDirectoryGameEntry>(
      AylaDirectoryKind.game,
      const AylaDirectoryOptions(filter: 'all'),
    );
  }

  /// 帖子信息流第一页 —— 读共享 [aylaPostsStore]（`appInit.ts:38·42` 的
  /// `listPosts({scope:"feed", limit:20})` + `setPage`）：新鲜则**不发请求**
  /// （`isPostsStale`，`stores/posts.ts:146–151`）。
  Future<Object?> _posts() async {
    try {
      if (!aylaPostsStore.loaded || aylaPostsStore.isStale()) {
        final AylaDirectoryPage<AylaPost> page =
            await AylaPostsApi.listPosts(scope: 'feed', limit: 20);
        aylaPostsStore.setScope('feed');
        aylaPostsStore.setPage(page.results, page.nextCursor, page.hasMore);
      }
    } catch (_) {
      // 失败兜底为空 —— web `appInit.ts:43–45`「失败不阻断流程」的同一语义
      // （主页四份快照各自兜底，任一失败不影响其余三份）。
    }
    return aylaPostsStore.posts;
  }

  void _registerRefresh() {
    final ShellUiNotifier notifier = ref.read(shellUiProvider.notifier);
    Future<void> callback() async {
      final AylaSocialController<AylaConversationSummary>? pager = _pager;
      if (pager == null) return;
      await pager.refresh();
      await _loadCatalogs();
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
    final AylaSocialController<AylaConversationSummary>? pager = _pager;
    if (pager == null) return;
    await pager.refresh();
    await _loadCatalogs();
    if (mounted) setState(() => _replayNonce++);
  }

  bool _isAtTop() => !_scroll.hasClients || _scroll.offset <= 0;

  /// tsx 64–67：只收群会话。
  List<AylaConversationSummary> _groups() => <AylaConversationSummary>[
        for (final AylaConversationSummary c
            in _pager?.items ?? const <AylaConversationSummary>[])
          if (c.isGroup) c,
      ];

  void _openGroup(String id) {
    _prefs.setRecentGroup(id);
    context.go('/group/$id');
  }

  void _openCreateGroup() => setState(() => _creatingGroup = true);

  @override
  Widget build(BuildContext context) {
    final bool narrow =
        AylaBreakpoints.isNarrow(MediaQuery.sizeOf(context).width);
    if (!narrow) return _buildWide(context);
    return _buildNarrow(context);
  }

  // ------------------------------------------------------- 宽屏（tsx 124–151）

  Widget _buildWide(BuildContext context) {
    final AylaSocialController<AylaConversationSummary>? pager = _pager;
    final List<AylaConversationSummary> groups = _groups();
    final String? recent = _prefs.recentGroupId;
    final bool recentValid = recent != null &&
        groups.any((AylaConversationSummary g) => g.id == recent);
    // tsx 128：recentValid → recent；否则已出结果 → resolvedRecent；
    // 仍在校验（recentGroupId 非空且尚未出结果）⇒ 先不跳；否则第一个群。
    final String? target = recentValid
        ? recent
        : (_recentResolved
            ? _resolvedRecent
            : (recent != null
                ? null
                : (groups.isEmpty ? null : groups.first.id)));

    if (target != null) {
      // web 是 <Navigate to={/group/target} replace />：构建期不能跳 ⇒ 首帧后 replace。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.replace('/group/$target');
      });
      return const SizedBox.shrink();
    }

    // tsx 132–140：跳转前不铺骨架，用轻量加载指示（.home-loading + .home-load-text）
    if ((pager == null || pager.loading) || (recent != null && !_recentResolved)) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // tsx 136：`.loading-spinner.loading-spinner--md`
            const AylaLoadingSpinner(size: 28),
            const SizedBox(height: AylaSpacing.sp3),
            Text(
              '正在加载群聊…', // tsx 137
              style: TextStyle(
                fontFamily: AylaFonts.body,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 13, // base.css:578–586 .home-load-text
                color: AylaColors.textSecondary,
                height: 1.4,
              ),
            ),
          ],
        ),
      );
    }

    // tsx 141–150：.home-wide-empty（home.css 673–682）
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AylaSpacing.sp6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '还没有加入群聊', // tsx 143
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: AylaFonts.display,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 28, // .placeholder-title
                fontWeight: FontWeight.w600,
                color: AylaColors.textPrimary,
              ),
            ),
            const SizedBox(height: AylaSpacing.sp1),
            Text(
              '创建或加入一个群聊，这里是你的「家」', // tsx 144
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: AylaFonts.body,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 14, // .placeholder-desc
                color: AylaColors.textSecondary,
                height: 1.45,
              ),
            ),
            const SizedBox(height: AylaSpacing.sp4),
            AylaGlassButton(
              label: '创建你的第一个群', // tsx 146
              variant: AylaGlassButtonVariant.glow,
              onPressed: _openCreateGroup,
            ),
            if (_creatingGroup) _createGroupDialog(),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------- 窄屏（tsx 153–222）

  Widget _buildNarrow(BuildContext context) {
    final AylaSocialController<AylaConversationSummary>? pager = _pager;
    final List<AylaConversationSummary> groups = _groups();
    final AylaHomeActivityMap? activity = _activity;
    final bool loading = (pager == null || pager.loading) && groups.isEmpty;

    Widget body;
    if (loading) {
      body = aylaHomeSkeletonGrid(); // SkeletonCards（tsx 168–169）
    } else if (groups.isEmpty) {
      // tsx 170–180：.home-state（home.css 622–629：column / gap sp4 / padding sp12 sp6）
      body = Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AylaSpacing.sp6,
          vertical: AylaSpacing.sp12,
        ),
        child: Column(
          children: <Widget>[
            Text(
              '创建你的第一个群', // tsx 172
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: AylaFonts.display,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 28,
                fontWeight: FontWeight.w600,
                color: AylaColors.textPrimary,
              ),
            ),
            const SizedBox(height: AylaSpacing.sp1),
            Text(
              '和朋友们聚在一起，从这里开始', // tsx 173
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: AylaFonts.body,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 14,
                color: AylaColors.textSecondary,
                height: 1.45,
              ),
            ),
            const SizedBox(height: AylaSpacing.sp4),
            // tsx 174–179：两键（主 .btn-glow + 次 .btn-ghost）
            Wrap(
              alignment: WrapAlignment.center,
              spacing: AylaSpacing.sp2,
              runSpacing: AylaSpacing.sp2,
              children: <Widget>[
                AylaGlassButton(
                  label: '创建群聊',
                  variant: AylaGlassButtonVariant.glow,
                  onPressed: _openCreateGroup,
                ),
                AylaGlassButton(
                  label: '搜索发现群',
                  variant: AylaGlassButtonVariant.ghost,
                  onPressed: () => context.go('/search'),
                ),
              ],
            ),
          ],
        ),
      );
    } else {
      final List<AylaConversationSummary> sorted =
          aylaSortGroupsByActivity<AylaConversationSummary>(
        groups,
        (AylaConversationSummary g) =>
            activity?.activityFor(g.id, g.lastMessage) ?? kAylaNoActivity,
        pinnedOf: (AylaConversationSummary g) => g.isPinned ?? false,
      );
      // tsx 182–218：下拉刷新包住列表；页脚自动触底加载（AylaDirectoryLoadMore）
      body = AylaPullToRefresh(
        isAtTop: _isAtTop,
        onRefresh: _refresh,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AylaRevealScope(
              replayKey: _replayNonce,
              child: _prefs.layout == AylaHomeLayout.card
                  ? AylaGroupGrid(
                      children: <Widget>[
                        for (int i = 0; i < sorted.length; i += 1)
                          _card(sorted[i], i, activity),
                      ],
                    )
                  : AylaGroupList(
                      children: <Widget>[
                        for (int i = 0; i < sorted.length; i += 1)
                          _listItem(sorted[i], i, activity),
                      ],
                    ),
            ),
            if (pager != null)
              AylaDirectoryLoadMore(
                loading: pager.loading,
                error: pager.error,
                hasMore: pager.hasMore,
                invalidated: pager.invalidated,
                loadMore: pager.loadMore,
                refresh: pager.refresh,
              ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      controller: _scroll,
      // .home-page { padding-bottom: 68px }（home.css 15）+ 安全区
      padding: EdgeInsets.only(
        bottom: 68 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // .home-toolbar（home.css 18–30）—— 已提升为库内件（19 号 §7.5 B 类）
          AylaHomeToolbar(
            isCard: _prefs.layout == AylaHomeLayout.card,
            onLayoutChanged: (bool isCard) => _prefs.setLayout(
              isCard ? AylaHomeLayout.card : AylaHomeLayout.list,
            ),
          ),
          body,
          if (_creatingGroup) _createGroupDialog(),
        ],
      ),
    );
  }

  /// tsx 187–195：卡片（slides = carouselFor(id, unread_count)、unread = 未读 + 帖子未读）。
  Widget _card(
    AylaConversationSummary g,
    int index,
    AylaHomeActivityMap? activity,
  ) {
    return AylaGroupCard(
      groupId: g.id,
      title: g.title,
      avatarUrl: g.avatar.isEmpty ? null : g.avatar,
      slides: activity?.carouselFor(
            g.id,
            g.unreadCount,
            postUnreadCount: g.postUnreadCount,
          ) ??
          const <AylaGroupCarouselSlide>[],
      unread: g.unreadCount + (g.postUnreadCount ?? 0),
      isPinned: g.isPinned ?? false,
      revealDelay: AylaRevealMotion.staggerDelay(index, staggerMs: 80),
      onOpen: () => _openGroup(g.id),
    );
  }

  /// tsx 200–215：列表项（status = 未读 + 帖未读 + 群存在性；sub = 最近事件描述）。
  Widget _listItem(
    AylaConversationSummary g,
    int index,
    AylaHomeActivityMap? activity,
  ) {
    final AylaGroupActivity act =
        activity?.activityFor(g.id, g.lastMessage) ?? kAylaNoActivity;
    return AylaGroupListItem(
      groupId: g.id,
      title: g.title,
      avatarUrl: g.avatar.isEmpty ? null : g.avatar,
      status: activity?.avatarStatusFor(g) ??
          AylaAvatarStatus(
            unread: g.unreadCount + (g.postUnreadCount ?? 0),
          ),
      newEventText: act.lastEvent?.text,
      memberCount: g.memberCount,
      isPinned: g.isPinned ?? false,
      revealDelay: AylaRevealMotion.staggerDelay(index, staggerMs: 80),
      onOpen: () => _openGroup(g.id),
    );
  }

  /// 建群弹窗（web `HomePage.tsx:148/220` 的 `<GroupCreateDialog onClose/>`。
  ///
  /// web 由组件内部直接调 chatApi + navigate；Flutter 侧该件按「装配口径」把
  /// 搜索与建群注入给页面（见 group_create_dialog.dart 文件头）⇒ 这里接上：
  /// 成员搜索 = web `GroupCreateDialog.tsx:29` 的 `useSocialPage("users", { q })`
  /// （`GET /users/search/`），建群 = `chatApi.createGroupConversation`，
  /// 跳转 = `onDone`（成功 → 关闭 + 进群）。
  Widget _createGroupDialog() {
    return AylaGroupCreateDialog(
      onClose: () => setState(() => _creatingGroup = false),
      currentUserId: ref.read(authNotifierProvider).user?.id,
      searchResults: _memberResults,
      searchLoading: _memberLoading,
      searchError: _memberError,
      searchHasMore: _memberHasMore,
      onSearchChanged: _onMemberSearch,
      onLoadMoreResults: _loadMembers,
      onRefreshResults: _refreshMembers,
      onSubmit: (String title, List<String> memberIds) =>
          AylaChatApi.createGroupConversation(
        title: title,
        memberIds: memberIds,
      ),
      onOpenPrivate: (String userId) =>
          AylaUsersApi.openPrivateConversation(userId),
      onDone: (String id) {
        setState(() => _creatingGroup = false);
        _openGroup(id);
      },
    );
  }

  Future<void> _refreshMembers() => _loadMembers(refresh: true);

  void _onMemberSearch(String query) {
    _memberQuery = query;
    _memberCursor = null;
    _memberHasMore = false;
    if (query.isEmpty) {
      setState(() {
        _memberResults = const <AylaUserPublic>[];
        _memberLoading = false;
        _memberError = null;
      });
      return;
    }
    _loadMembers(refresh: true);
  }

  /// 拉取搜索结果（web `stores/social.ts` 的 users kind；失败只置错误文案）。
  Future<void> _loadMembers({bool refresh = false}) async {
    if (_memberQuery.isEmpty) return;
    final int revision = ++_memberRevision;
    setState(() {
      _memberLoading = true;
      if (refresh) _memberError = null;
    });
    try {
      final AylaDirectoryPage<AylaUserPublic> page =
          await AylaUsersApi.searchUsersPage(
        _memberQuery,
        cursor: refresh ? null : _memberCursor,
      );
      if (!mounted || revision != _memberRevision) return;
      final Map<String, AylaUserPublic> merged = <String, AylaUserPublic>{};
      if (!refresh) {
        for (final AylaUserPublic u in _memberResults) {
          merged[u.id] = u;
        }
      }
      for (final AylaUserPublic u in page.results) {
        merged[u.id] = u;
      }
      setState(() {
        _memberResults = merged.values.toList(growable: false);
        _memberCursor = page.nextCursor;
        _memberHasMore = page.hasMore;
        _memberLoading = false;
        _memberError = null;
      });
    } catch (_) {
      if (!mounted || revision != _memberRevision) return;
      setState(() {
        _memberLoading = false;
        _memberError = '搜索失败';
      });
    }
  }
}
