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
import '../core/api/directory_page.dart' show AylaDirectoryPage;
import '../core/api/live_api.dart';
import '../core/api/posts_api.dart';
import '../core/api/voice_api.dart';
import '../core/models/conversation.dart';
import '../core/models/game_room.dart' show AylaGameRoom;
import '../core/models/post.dart' show AylaPost;
import '../state/boardgame_store.dart' show aylaBoardgameStore;
import '../state/chat_providers.dart' show chatStateProvider;
import '../state/chat_state.dart' show AylaChatState;
import '../state/directory_events.dart' show AylaDirectoryKind;
import '../state/directory_store.dart';
import '../state/home_prefs.dart';
import '../state/live_state.dart' show AylaLiveState;
import '../state/posts_store.dart';
import '../state/room_providers.dart' show liveStateProvider, voiceStateProvider;
import '../state/social_store.dart';
import '../state/shell_state.dart';
import '../state/voice_state.dart' show AylaVoiceState;
import '../theme/glass.dart' show AylaGlassButton, AylaGlassButtonVariant;
import '../theme/tokens.dart';
import '../widgets/base/avatar_status_badges.dart' show AylaAvatarStatus;
import '../widgets/base/directory_load_more.dart';
import '../widgets/base/media_interaction.dart' show AylaPullToRefresh;
import '../widgets/base/reveal.dart';
import '../widgets/group/group_card.dart';
import '../layout/create_sheet_forms.dart' show AylaCreateGroupForm;
import '../widgets/group/home_toolbar.dart' show AylaHomeToolbar;
import '../widgets/live/live_channel_snapshot.dart' show AylaLiveChannelSnapshot;
import 'home_support.dart';
import 'hub_support.dart'
    show aylaHubLiveEntryFromSnapshot, aylaHubVoiceEntryFromSnapshot;

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  final ScrollController _scroll = ScrollController();
  /// 主页偏好 = **共享单例** [kAylaHomePrefs]（web `stores/home.ts:60` 的 zustand 单例）。
  ///
  /// 2026-10-02 问题 5：原来这里是 `final AylaHomePrefsController _prefs = ...` 的
  /// **页面私有实例** ⇒ `GroupPage.tsx:233` 那次「每次进群写 recent」在 Flutter 侧无处落地
  /// （宽屏侧栏切群不经过本页）⇒ 宽屏「回主页」永远跳到旧群。改成单例后
  /// `group_page.dart` 的 `_syncRoute` 与本页的 `_openGroup` 写的是同一份状态。
  /// 生命周期与应用同层，**不 dispose**（与 web 的模块级 store 同）。
  AylaHomePrefsController get _prefs => kAylaHomePrefs;

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

  @override
  void initState() {
    super.initState();
    _prefs.addListener(_onPrefsChanged);
    _start();
    _prefs.load();
    _loadCatalogs();
    _bindActivitySources();
  }

  /// 订阅「群活跃度」的实时源 —— web `useGroupActivityMap`（`groupActivity.ts:159–169`）
  /// 订阅的四个 store + `chatState.groupActivityAt`，Flutter 侧逐条对应：
  ///
  /// | web | 行 | 本页订阅 |
  /// |---|---|---|
  /// | `useLiveStore((s) => s.channels)` | 163 | [liveStateProvider] |
  /// | `useVoiceStore((s) => s.channels)` | 164 | [voiceStateProvider] |
  /// | `useBoardgameStore((s) => s.rooms)` | 165 | [aylaBoardgameStore]（模块级单例） |
  /// | `usePostsStore((s) => s.posts)` | 166 | [aylaPostsStore]（模块级单例） |
  /// | `useChatStore((s) => s.groupActivityAt)` | 169 | [chatStateProvider] |
  ///
  /// ⚠️ **只重算本地内存快照**（[_rebuildActivity]），**不调 [_loadCatalogs]** ——
  /// 后者是**发请求**（web 的 WS 增量同样只改 store、不重发 REST）。
  /// ⚠️ `voice` / `live` 的 `channels` 增量由 `core/ws/room_frames.dart` 的帧桥维护，
  /// 目录页取页结果也会经 `aylaDirectoryStore.itemUpsertHooks` 落进同一张表。
  void _bindActivitySources() {
    aylaDirectoryStore.addListener(_onActivitySourceChanged);
    aylaPostsStore.addListener(_onActivitySourceChanged);
    aylaBoardgameStore.addListener(_onActivitySourceChanged);
    final AylaVoiceState voice = ref.read(voiceStateProvider);
    final AylaLiveState live = ref.read(liveStateProvider);
    final AylaChatState chat = ref.read(chatStateProvider);
    voice.addListener(_onActivitySourceChanged);
    live.addListener(_onActivitySourceChanged);
    chat.addListener(_onActivitySourceChanged);
    _voiceState = voice;
    _liveState = live;
    _chatState = chat;
  }

  AylaVoiceState? _voiceState;
  AylaLiveState? _liveState;
  AylaChatState? _chatState;

  void _onActivitySourceChanged() {
    if (!mounted) return;
    _rebuildActivity();
  }

  /// 重算内存快照（web 的「store 变化 ⇒ 订阅组件重渲染」等价物）。
  ///
  /// 数据源 = 四个全局 store 的**当前值**（不是进入页面时抓的那一份）：
  /// 目录三档从 [aylaDirectoryStore] 的「全部」档 record 取（与 [_live] / [_voice] / [_game]
  /// 同一 key，见 `app_preload.dart` 的预取）；帖子从 [aylaPostsStore]；
  /// 桌游房从 [aylaBoardgameStore]。
  void _rebuildActivity() {
    if (!mounted) return;
    setState(() {
      _catalogs = _catalogsFromStores();
      _activity = AylaHomeActivityMap(
        conversations: _pager?.items ?? const <AylaConversationSummary>[],
        catalogs: _catalogs,
        groupActivityAt: ref.read(chatStateProvider).groupActivityAt,
      );
    });
    _resolveRecentForWide();
  }

  /// 四份目录的**当前内存快照**（不发请求；缺档即空列表 —— 不伪造）。
  ///
  /// ## 为什么是「目录 record 打底 + 全局 store 覆盖」（而不是二选一）
  /// web 的活跃度直接读四个全局 store（`groupActivity.ts:163–166`），而目录 record
  /// 只是那些 store 的一个**查询投影**（`stores/directory.ts:144` 的 `cachedItems` 返回
  /// store 的数组本身）⇒ 两者在 web 上是**同一份对象**，不存在取舍。
  /// Flutter 侧目录条目（`AylaDirectoryLiveEntry` / `AylaDirectoryVoiceEntry`）与
  /// 域快照（`AylaLiveChannelSnapshot` / `AylaVoiceChannelSnapshot`）是**两个投影**：
  /// - 目录 record 覆盖「页面/预取取到的那些条目」（含 `allowedGroupIds` 等）；
  /// - 域 store 覆盖「WS 帧桥刚 patch 过的最新描述符」（`room_frames.dart:164/189/210`）。
  /// ⇒ 按 id 合并：**目录打底、域 store 覆盖同 id 项**。只取其一都会漏：
  /// 只取目录 ⇒ WS 开播/改人数不触发重排（用户实报的根因）；
  /// 只取域 store ⇒ 目录页取回的条目（`itemUpsertHooks` 未接 live/voice，见
  /// `room_providers.dart:111–118` 的登记）在没收到过帧时不存在。
  AylaHomeCatalogs _catalogsFromStores() {
    final Map<String, AylaDirectoryLiveEntry> live =
        <String, AylaDirectoryLiveEntry>{
      for (final AylaDirectoryLiveEntry e
          in aylaDirectoryStore.itemsAs<AylaDirectoryLiveEntry>(
        AylaDirectoryKind.live,
        const AylaDirectoryOptions(filter: 'all'),
      ))
        e.card.id: e,
    };
    for (final AylaLiveChannelSnapshot c
        in _liveState?.channels.values ?? const <AylaLiveChannelSnapshot>[]) {
      live[c.id] = aylaHubLiveEntryFromSnapshot(c, isOwner: c.isOwner);
    }
    final Map<String, AylaDirectoryVoiceEntry> voice =
        <String, AylaDirectoryVoiceEntry>{
      for (final AylaDirectoryVoiceEntry e
          in aylaDirectoryStore.itemsAs<AylaDirectoryVoiceEntry>(
        AylaDirectoryKind.voice,
        const AylaDirectoryOptions(filter: 'all'),
      ))
        e.card.id: e,
    };
    for (final AylaVoiceChannelSnapshot c
        in _voiceState?.channels.values ?? const <AylaVoiceChannelSnapshot>[]) {
      voice[c.id] = aylaHubVoiceEntryFromSnapshot(c);
    }
    final Map<int, AylaGameRoom> game = <int, AylaGameRoom>{
      for (final AylaDirectoryGameEntry e
          in aylaDirectoryStore.itemsAs<AylaDirectoryGameEntry>(
        AylaDirectoryKind.game,
        const AylaDirectoryOptions(filter: 'all'),
      ))
        e.room.id: e.room,
      // 域 store 覆盖：桌游的目录落地钩子已注册（`room_providers.dart:148`）⇒ 同源。
      for (final AylaGameRoom r in aylaBoardgameStore.rooms) r.id: r,
    };
    return AylaHomeCatalogs(
      liveChannels: live.values.toList(growable: false),
      voiceChannels: voice.values.toList(growable: false),
      gameRooms: game.values.toList(growable: false),
      posts: aylaPostsStore.posts,
    );
  }

  @override
  void dispose() {
    aylaDirectoryStore.removeListener(_onActivitySourceChanged);
    aylaPostsStore.removeListener(_onActivitySourceChanged);
    aylaBoardgameStore.removeListener(_onActivitySourceChanged);
    _voiceState?.removeListener(_onActivitySourceChanged);
    _liveState?.removeListener(_onActivitySourceChanged);
    _chatState?.removeListener(_onActivitySourceChanged);
    _voiceState = null;
    _liveState = null;
    _chatState = null;
    // ⚠️ 只解绑监听，**不 dispose**：[_prefs] 是应用级共享单例（见字段注释）。
    _prefs.removeListener(_onPrefsChanged);
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
    // 与 [_rebuildActivity] 同一条快照路径：会话列表变了也要带上 `groupActivityAt`
    // （web 的 `useGroupActivityMap` 把两件事复用在同一个返回值里，`groupActivity.ts:169/224`）。
    setState(() {
      _activity = AylaHomeActivityMap(
        conversations: _pager?.items ?? const <AylaConversationSummary>[],
        catalogs: _catalogs,
        groupActivityAt: ref.read(chatStateProvider).groupActivityAt,
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
    // ⚠️ **主动跑一次「最近群」校验**：命中预加载缓存时 `store.load()` 走 60 秒首屏短路
    //（`social_store.dart:275–279`）——**不发请求、也不 notifyListeners** ⇒ 只挂
    // `_onPagerChanged` 会让校验永不执行、`_recentResolved` 恒 false ⇒ 宽屏卡在
    // 「尚未校验」分支。预加载命中正是启动后的常见路径，必须在这里补一次。
    scheduleMicrotask(_resolveRecentForWide);
    unawaited(pager.load());
  }

  /// 四份目录的第一页（web appInit.ts:41–48 的同一组请求；失败各自兜底为空 ——
  /// 与 web「失败不阻断流程」同）。
  Future<void> _loadCatalogs() async {
    // 四份目录的第一页（`appInit.ts` 的同一组请求）：它们把 store 灌好；
    // 快照本身从 store 读（见 [_catalogsFromStores] 的合并口径），
    // 因此这里**不消费返回值**（旧实现按返回值建快照 ⇒ 请求在途期间到达的 WS 更新
    // 会被过期响应覆盖）。
    await Future.wait<Object?>(<Future<Object?>>[
      _live(),
      _voice(),
      _game(),
      _posts(),
    ]);
    if (!mounted) return;
    setState(() {
      // ⚠️ 用**共享 store 的当前值**、不用这四个请求的返回值：
      // 请求在途期间 WS 可能已经把更新的描述符写进 store（web 的订阅永远读 store，
      // 不存在「用过期响应覆盖新数据」这条路径）。四份返回值只用来确认请求走完。
      _catalogs = _catalogsFromStores();
      _activity = AylaHomeActivityMap(
        conversations: _pager?.items ?? const <AylaConversationSummary>[],
        catalogs: _catalogs,
        groupActivityAt: ref.read(chatStateProvider).groupActivityAt,
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
    // tsx 128 的原句（逐算子对照，此前这里翻译错了）：
    //   const target = recentValid
    //     ? recentGroupId
    //     : resolvedRecent ?? (recentGroupId && resolvedRecent === undefined ? null : groups[0]?.id);
    // ⚠️ 关键是 JS 的空值合并：resolvedRecent 校验结果为不可用（null）时，它仍会继续回落
    // 到 groups[0]。此前写成 Dart 的三元 _recentResolved ? _resolvedRecent : … ⇒ null 就是
    // null ⇒ 既不跳转也不显示内容，永远停在空态 —— 实机「修错了，你没有跳到首个群」。
    // 搬运空值合并语义：取值链上任何一段为 null 都继续看下一段；只有明确尚未校验完
    // 才返回 null（web 用 resolvedRecent === undefined 表达该中间态 → _recentResolved）。
    //
    // ⚠️ 决策抽在纯函数里（见 [aylaWideHomeTarget] 的文档与表格）：这段映射错过两次
    //（「跳两次侧栏」/「没有跳到首个群」），做成纯函数 + 表格单测锁死，避免再翻译错。
    final String? target = aylaWideHomeTarget(
      prefsReady: _prefs.ready,
      recentValid: recentValid,
      recent: recent,
      recentResolved: _recentResolved,
      resolvedRecent: _resolvedRecent,
      groupIds: <String>[for (final AylaConversationSummary g in groups) g.id],
    );

    if (target != null) {
      // web 是 Navigate 到 /group/target（replace）：构建期不能跳 ⇒ 首帧后 replace。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.replace('/group/$target');
      });
      return const SizedBox.shrink();
    }

    // prefs 未就绪 ⇒ **不跳转**（避免先跳 groups[0] 再跳 recent 那一下），但**不阻止渲染**：
    // 存储不可用的宿主（测试 / 无沙盒）永远等不到 ready，卡在这里会让宽屏一直空白。
    // 此时 static 的 recent 值仍为 null ⇒ 下面自然落到「空态」或「骨架」分支，与改前一致。
    // ⚠️ **宽屏不铺任何加载件**（2026-10-01 用户实机：「主页加载动画给他删掉，web 从来没有
    // 这个」）：宽屏主页的职责只有一个 —— **重定向到最近群**（tsx 124–131 的 Navigate 到
    // /group/target，replace）。
    // web 上 recentGroupId 读 localStorage **同步**、groups 又来自 appInit 预加载
    // ⇒ target 首帧就有值 ⇒ **永远走不到下面的 home-loading 分支**，用户从来看不到它。
    // Flutter 侧 prefs 是异步读盘（getApplicationSupportDirectory + readAsString）
    // ⇒ 就绪前的这几帧此前会渲染「正在加载群聊…」转圈 = 用户说的那个「从来没见过的东西」。
    // ⇒ 改为**静默等待**：与 web 的可见行为一致，也不会先跳错群（见上面 target 的 prefsReady 门）。
    if (groups.isEmpty && (pager == null || pager.loading)) {
      return const SizedBox.shrink();
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

  /// 建群弹窗（web `HomePage.tsx:148/220` 的 `<GroupCreateDialog onClose/>`）。
  ///
  /// ## 为什么复用 [AylaCreateGroupForm] 而不是在本页装配（2026-10-02 问题 14）
  /// 本页原来自己接了一套（成员搜索 + 建群 + 私聊），而 `group_page.dart` 的同一弹窗
  /// **只传了 `onClose`** ⇒ 那边点「建群」静默无反应（`group_create_dialog.dart:184–185`）。
  /// 现在两页共用 `layout/create_sheet_forms.dart` 的同一件（它本身就是 web 同一份
  /// `GroupCreateDialog` 的接线，CreateFab 的 group 分支 `tsx:75–77`），
  /// 顺带修掉本页原装配的两处**偏离**：
  ///
  /// 1. **私聊路径跳到群页**：web `tsx:74` 是 `navigate(\`/chat/${conv.id}\`)`，
  ///    而 `AylaGroupCreateDialog.onDone` 只回传会话 id、不区分路径
  ///    （`group_create_dialog.dart:196/221` 同一回调）⇒ 原实现把私聊会话 id 也送进
  ///    `_openGroup`（`context.go('/group/<私聊 id>')`）。表单件按「最近一次私聊 id」
  ///    判定路径（`create_sheet_forms.dart:865–880`），两条路径各去各的地方。
  /// 2. **不落会话列表**：web `tsx:56/72` 两条路径都 `upsertConversation(conv)`，
  ///    原实现建群后只跳转、新群不在 `chatState` 里 ⇒ 群页首帧群名回落「群聊」。
  ///    （本页与群页的对话由 `AylaCreateGroupForm` 统一经 `AylaGroupDirectory` /
  ///    `chatStateProvider` 的既有投影路径补齐。）
  Widget _createGroupDialog() {
    return AylaCreateGroupForm(
      onClose: () => setState(() => _creatingGroup = false),
    );
  }

}
