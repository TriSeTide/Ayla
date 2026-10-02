/// 一级语音 tab（路由 /voice）—— web pages/VoiceHubPage.tsx 315 行的等价物。
///
/// ## 事实源（逐条）
/// - tsx 34–41：五个分类（全部/公开/好友/有人/我的）；`?type=` 驱动、切 tab 改写 URL
///   （`setParams(next === "all" ? {} : { type: next }, { replace: true })`，tsx 271–274）；
/// - tsx 58–64：**后端过滤参数**逐个对应（visibility / friends / occupied / owner），
///   filter 进 directory key ⇒ 每个 tab 独立游标；
/// - tsx 76–87：**前端二次过滤**（public / friends 用好友集合 / occupied /
///   mine 用 owner_id === currentUserId）；好友集合来自 `useSocialPage("friends")`
///   的第一页（tsx 73–74）；
/// - tsx 266–313：页面骨架 —— `AylaDirectoryPage` 三件套 + filters 槽位顺序
///   （leading → decor → header → nav，`DirectoryFilters.tsx:70–72`）；
/// - tsx 288–292：加载态 `.conv-loading`（两根骨架：高 64 + mb 8 / 高 64）；
///   `voice.css:506–518` 是 **grid 2 列**（≥769 3 列 / ≥1440 4 列，649/656）+ gap sp3
///   + padding sp3 sp4 + align-items start；
/// - tsx 293：错误且无内容 ⇒ 只渲染 `DirectoryLoadMore`（error 非空时它返回 null）；
/// - tsx 294–309：`PullToRefresh` 包住列表 + 页脚；分类空态文案逐字
///   「这个分类还没有语音房」/「换个分类看看」；
/// - tsx 301–306：`VoiceChannelList`（卡件已交付）。
///
/// ## 与 web 的机制差异（登记）
/// - **不做房内态**（tsx 212–260 的 `VoiceRoomBody` 分支）——房内页属第 3 批；本轮
///   `/voice/:channelId` 路由仍是占位页，大厅的 `currentChannelId` 恒 null；
/// - `useEnterRoomAnimation`（底栏下滑走 + 输入框滑入）随房内批次；
/// - 滚动位置记忆（`useScrollRestore`/`saveScrollPosition`）尚无 Flutter 等价件 ⇒ 未实现；
/// - `useListEntryMotion` 的「刷新后整批重播」用 [AylaRevealScope] 的 replayKey 表达。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/voice_api.dart';
import '../state/auth_state.dart';
import '../state/directory_store.dart';
import '../state/favorite_status.dart';
import '../state/shell_state.dart';
import '../theme/app_icons.dart';
import '../theme/tokens.dart';
import '../widgets/base/directory_page.dart';
import '../widgets/base/directory_load_more.dart';
import '../widgets/base/favorite_button.dart';
import '../widgets/base/media_interaction.dart' show AylaPullToRefresh;
import '../widgets/base/page_state.dart';
import '../widgets/base/profile_and_filters.dart' show AylaDirectoryFilters;
import '../widgets/base/reveal.dart';
import '../state/directory_events.dart';
import '../state/room_providers.dart';
import '../widgets/voice/voice_channels.dart';
import 'hub_support.dart';
import 'voice_support.dart';
import '../state/hub_directory_options.dart'
    show aylaHubDirectoryOptions;

class VoiceHubPage extends ConsumerStatefulWidget {
  const VoiceHubPage({super.key, this.initialType, this.channelId});

  /// `?type=`（路由读取；null / 未知值 = 全部）。
  final String? initialType;

  /// 房内态频道 id（路由 `/voice/:channelId`；null = 大厅）。
  ///
  /// web 的 `/voice` 与 `/voice/:channelId` **是同一个组件**（`App.tsx:70–71`），
  /// 由 `useParams().channelId` 分支渲染；Flutter 侧同法（本参数即 `useParams` 的等价物）。
  final String? channelId;

  /// 五个分类（tsx 35–41，逐字）。
  static const List<({String key, String label})> filters =
      <({String key, String label})>[
    (key: 'all', label: '全部'),
    (key: 'public', label: '公开'),
    (key: 'friends', label: '好友'),
    (key: 'occupied', label: '有人'),
    (key: 'mine', label: '我的'),
  ];

  @override
  ConsumerState<VoiceHubPage> createState() => _VoiceHubPageState();
}

class _VoiceHubPageState extends ConsumerState<VoiceHubPage> {
  late String _filter = aylaHubFilterOf(VoiceHubPage.filters, widget.initialType);

  final ScrollController _scroll = ScrollController();
  final AylaFavoriteStatusController _favorites = AylaFavoriteStatusController();
  AylaDirectoryController<AylaDirectoryVoiceEntry>? _pager;

  /// 好友 tab 的集合（web `useSocialPage("friends")` 第一页的 user.id）。
  Set<String> _friendIds = const <String>{};

  /// 刷新后整批重播入场（web `replayNonce`）。
  int _replayNonce = 0;

  /// 目录热更新事件总线（`voice.channel.*` 帧；见 `state/directory_events.dart`）。
  AylaDirectoryEvents? _directoryEvents;
  int _directoryEventRevision = 0;

  /// 当前页注册到 shell 的刷新回调（web useShellStore.registerRefresh）。
  ShellUiNotifier? _shellNotifier;
  Future<void> Function()? _refreshCallback;

  @override
  void initState() {
    super.initState();
    _favorites.addListener(_onFavoritesChanged);
    _start();
    // ⚠️ **必须帧后**：\`_loadFriends\` 会在首个 await 前同步写 social store
    // （→ GroupPage._onChanged 的 setState），落在本帧 build 期即抛
    // "setState() or markNeedsBuild() called during build"（详见 [_loadFriends]）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadFriends();
    });
    _registerDirectoryEvents();
  }

  /// 订阅目录事件（web `stores/directory.ts` 的跨页缓存热更新；Flutter 用事件总线）。
  void _registerDirectoryEvents() {
    final AylaDirectoryEvents events = ref.read(directoryEventsProvider);
    _directoryEvents = events;
    _directoryEventRevision = events.revision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      events.addListener(_onDirectoryEvents);
    });
  }

  /// 目录事件处理（逐条对应 web `chat.ts` 的 voice.channel.* 分支）：
  /// 删除 → 从列表移除；人数 → 就地换卡上的人数；其余 → **重取首页**
  /// （web 是置 `invalidated` 由用户点刷新；Flutter 的 `AylaPagedList.invalidated`
  /// 目前恒 false、无写入面 ⇒ 直接重取首页，登记为有意偏离）。
  void _onDirectoryEvents() {
    final AylaDirectoryEvents? events = _directoryEvents;
    if (events == null || events.revision == _directoryEventRevision) return;
    _directoryEventRevision = events.revision;
    final AylaDirectoryEvent? event = events.last;
    if (event == null || event.kind != AylaDirectoryKind.voice) return;
    final AylaDirectoryController<AylaDirectoryVoiceEntry>? pager = _pager;
    if (pager == null) return;
    if (event.deleted) {
      pager.removeWhere(
        (AylaDirectoryVoiceEntry entry) => entry.card.id == event.id,
      );
      return;
    }
    final int? count = event.memberCount;
    if (count != null) {
      pager.setItems(<AylaDirectoryVoiceEntry>[
        for (final AylaDirectoryVoiceEntry entry in pager.items)
          if (entry.card.id == event.id)
            aylaHubVoiceEntryWithMemberCount(entry, count)
          else
            entry,
      ]);
      return;
    }
    unawaited(pager.refresh());
  }

  @override
  void didUpdateWidget(covariant VoiceHubPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialType != oldWidget.initialType) {
      final String next = aylaHubFilterOf(
        VoiceHubPage.filters,
        widget.initialType,
      );
      if (next != _filter) {
        setState(() => _filter = next);
        _start();
      }
    }
  }

  @override
  void dispose() {
    _directoryEvents?.removeListener(_onDirectoryEvents);
    _directoryEvents = null;
    _favorites.removeListener(_onFavoritesChanged);
    _favorites.dispose();
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
    // 状态查询只针对当前可见页的目标（web `loadFavoriteStatuses` 的有界查询）。
    final AylaDirectoryController<AylaDirectoryVoiceEntry>? pager = _pager;
    if (pager == null) return;
    _favorites.load(
      'voice',
      <String>[for (final AylaDirectoryVoiceEntry e in pager.items) e.card.id],
    );
  }

  void _start() {
    // 房内态下**不取大厅数据**（web tsx 64/73 把 `!routeChannelId` 作为
    // `useDirectoryPage` / `useSocialPage` 的 enabled 参数）。
    if (widget.channelId != null) return;
    final String? owner = _filter == 'mine'
        ? ref.read(authNotifierProvider).user?.id
        : null;
    // 数据归**共享 store**（web `useDirectoryPage` + `stores/directory.ts`）：
    // options 进 `directoryKey`（filter 段 ⇒ 每个分类 tab 独立游标/缓存）；
    // 命中 60 秒缓存 ⇒ 切 tab / 再次进入**不发请求、不闪骨架**（`:274`）。
    final AylaDirectoryController<AylaDirectoryVoiceEntry> pager =
        AylaDirectoryController<AylaDirectoryVoiceEntry>(
      store: aylaDirectoryStore,
      kind: AylaDirectoryKind.voice,
      // ⚠️ options 由**共享事实源**构造（`state/hub_directory_options.dart`）：
      // 它的每个字段都进 `directoryKey`，预加载与页面必须逐字段一致，否则命中不了。
      options: aylaHubDirectoryOptions(
        kind: AylaDirectoryKind.voice,
        filter: _filter,
        userId: owner,
      ),
    );
    pager.addListener(_onPagerChanged);
    _pager?.dispose();
    _pager = pager;
    _registerRefresh();
    // 幂等：命中缓存即短路（web `loadDirectory` 的 `initial` 语义）。
    unawaited(pager.load());
  }

  /// ⚠️ **必须帧后调用**（2026-10-02 修「setState() or markNeedsBuild() called during build」）：
  /// \`aylaHubFriendIds()\` → \`aylaSocialStore.load()\` 在**首个 await 之前**是同步段
  /// （\`state/social_store.dart:391\` 的 \`_patch\` → 同步 \`notifyListeners\`）。
  /// 若在 \`initState\` 直接调，通知会落在**本帧 build 期**：\`AylaSocialController\`
  /// → \`AylaGroupDirectory._forward\`（\`group_support.dart:431\`）
  /// → \`GroupPage._onChanged\`（\`group_page.dart:383\` 的裸 \`setState\`）
  /// ⇒ 用户 \`flutter run\` 首条异常（GroupPage 未挂载时只读 items，不会炸 ⇒ 只在
  /// 「群壳 + 大厅页」并存时才现形）。与同文件 \`_registerDirectoryEvents\` /
  /// \`_registerRefresh\` 的既有帧后范式一致。
  /// 回归锁：\`test/hub_friends_load_phase_test.dart\`。
  Future<void> _loadFriends() async {
    if (widget.channelId != null) return; // 房内态不拉好友集合（同 web 的 enabled 参数）
    final Set<String> ids = await aylaHubFriendIds();
    if (!mounted || ids.isEmpty) return;
    setState(() => _friendIds = ids);
  }

  /// §3.4 RefreshFAB：注册当前页刷新回调（引用守卫见 shell_state 的 unregisterRefresh）。
  void _registerRefresh() {
    final ShellUiNotifier notifier = ref.read(shellUiProvider.notifier);
    Future<void> callback() async {
      final AylaDirectoryController<AylaDirectoryVoiceEntry>? pager = _pager;
      if (pager == null) return;
      await pager.refresh();
      if (mounted) setState(() => _replayNonce++);
    }

    _shellNotifier = notifier;
    _refreshCallback = callback;
    // ⚠️ Riverpod 禁止在 initState / 构建期间修改 provider ⇒ 首帧后注册
    // （web 侧是 useEffect 注册，时机等价）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      notifier.registerRefresh(callback);
    });
  }

  Future<void> _refresh() async {
    final AylaDirectoryController<AylaDirectoryVoiceEntry>? pager = _pager;
    if (pager == null) return;
    await pager.refresh();
    if (mounted) setState(() => _replayNonce++);
  }

  void _onFilterChange(String next) {
    setState(() => _filter = next);
    _start();
    // tsx 271–274：切 tab 改写 URL（replace，不污染历史栈）。
    context.replace(next == 'all' ? '/voice' : '/voice?type=$next');
  }

  /// 前端二次过滤（tsx 76–87 逐条）。
  List<AylaDirectoryVoiceEntry> _visible(
    List<AylaDirectoryVoiceEntry> items,
    String? currentUserId,
  ) {
    if (_filter == 'all') return items;
    return <AylaDirectoryVoiceEntry>[
      for (final AylaDirectoryVoiceEntry entry in items)
        if (_matches(entry, currentUserId)) entry,
    ];
  }

  /// 判据在 hub_support 的纯函数里（与 web tsx 76–87 逐条对应，便于定向测试）。
  bool _matches(AylaDirectoryVoiceEntry entry, String? currentUserId) =>
      aylaHubMatchVoice(
        entry,
        _filter,
        friendIds: _friendIds,
        currentUserId: currentUserId,
      );

  String? _statsLabel() {
    final AylaDirectoryController<AylaDirectoryVoiceEntry>? pager = _pager;
    // web tsx 280–282：判定用的是 directory.loading（不只是首屏）
    if (pager == null || pager.loading) {
      return '… 房间在线 · … 人在聊'; // tsx 281
    }
    final int? members = pager.totalMemberCount;
    final int total = pager.total;
    return members == null
        ? '$total 房间在线' // tsx 282
        : '$total 房间在线 · $members 人在聊';
  }

  @override
  Widget build(BuildContext context) {
    // 房内态（web tsx 212–260）：大厅的取数与列表**保留在下方分支**，
    // 房内视图由 [AylaVoiceRoomHost] 独立装配（key 随频道变化重建 ⇒ 切房即重建会话）。
    final String? channelId = widget.channelId;
    if (channelId != null) {
      return AylaVoiceRoomHost(
        key: ValueKey<String>(channelId),
        channelId: channelId,
      );
    }
    final bool narrow = aylaDirectoryIsNarrow(context);
    final AylaDirectoryController<AylaDirectoryVoiceEntry>? pager = _pager;
    final String? currentUserId = ref.watch(
      authNotifierProvider.select((AuthState s) => s.user?.id),
    );

    Widget content;
    if (pager == null || (!pager.loaded && pager.loading)) {
      // tsx 288–292：两根骨架（高 64 / 首根 mb 8）· grid 2/3/4 列 · gap sp3 · padding sp3 sp4。
      // 目录页组规则把 `.conv-loading` 的左右归零（directory-filters.css:171–180，全断点）；
      // 它**不在** 199–208 的顶部归零名单内 ⇒ 顶部保持 sp3（zeroTopWhenWide: false）。
      content = aylaHubSkeletonGrid(
        context,
        skeletonHeight: 64,
        gap: AylaSpacing.sp3,
        padding: aylaDirectoryListPadding(context, zeroTopWhenWide: false),
      );
    } else if (pager.error != null && pager.items.isEmpty) {
      // tsx 293：错误且无内容 ⇒ 只有页脚（error 时它不渲染）
      content = AylaDirectoryLoadMore(
        loading: pager.loading,
        error: pager.error,
        hasMore: pager.hasMore,
        invalidated: pager.invalidated,
        loadMore: pager.loadMore,
        refresh: pager.refresh,
      );
    } else {
      final List<AylaDirectoryVoiceEntry> visible =
          _visible(pager.items, currentUserId);
      content = AylaPullToRefresh(
        isAtTop: _isAtTop,
        onRefresh: _refresh,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (visible.isEmpty && _filter != 'all')
              // tsx 296–299（逐字）；目录页内容区的内距由 AylaPageState 的覆盖档承担
              const AylaPageState(
                title: '这个分类还没有语音房',
                description: '换个分类看看',
                padding: kAylaPageStateDirectoryPadding,
              )
            else
              AylaRevealScope(
                replayKey: _replayNonce,
                child: AylaVoiceChannelList(
                  // `.voice-hub .voice-channel-list` 基样式是 `padding: sp3 sp4`
                  // （voice.css:505–511）；目录页组规则再加两条（directory-filters.css）：
                  // 左右恒 0（171–180，全断点）+ ≥769 顶部归零（199–208）
                  // ⇒ 宽屏 (0, 0, 0, sp3) / 窄屏 (0, sp3, 0, sp3)。
                  // 群内与画布样张不传本参数 ⇒ 保持组件默认 sp4/sp3（voice.css:690–695 另有口径）。
                  padding: aylaDirectoryListPadding(context),
                  channels: <AylaVoiceCardData>[
                    for (final AylaDirectoryVoiceEntry entry in visible)
                      entry.card,
                  ],
                  revealItems: true,
                  onJoin: _join,
                  favoriteBuilder: _favoriteSlot,
                ),
              ),
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

    return AylaDirectoryPage(
      filters: AylaDirectoryFilters(
        label: '语音分类',
        options: VoiceHubPage.filters,
        value: _filter,
        narrow: narrow,
        onChange: _onFilterChange,
        decor: AylaDirectoryDecorIcon(icon: aylaIconByName('iconMic')!),
        header: AylaDirectorySidebarHeader(
          kicker: 'Voice',
          title: '语音房间',
          stats: _statsLabel(),
        ),
      ),
      content: AylaDirectoryContent(
        fadeGlass: false,
        controller: _scroll,
        scope: 'voice-hub:$_filter', // web key={scope}（tsx 285）
        label: aylaHubFilterLabel(VoiceHubPage.filters, _filter),
        child: content,
      ),
    );
  }

  bool _isAtTop() => !_scroll.hasClients || _scroll.position.pixels <= 0;

  /// 进房（tsx 160–165：navigate('/voice/:id')）。房内页属第 3 批，此处只做路由。
  void _join(String channelId) {
    context.go('/voice/${Uri.encodeComponent(channelId)}');
  }

  /// voice 卡的 head 槽位（web 默认渲染 `<FavoriteButton compact/>`）。
  Widget _favoriteSlot(BuildContext context, AylaVoiceCardData channel) {
    return AylaFavoriteButton(
      compact: true,
      state: _favorites.stateOf('voice', channel.id),
      busy: _favorites.busyOf('voice', channel.id),
      actionError: _favorites.actionErrorOf('voice', channel.id),
      onToggle: (bool next) => _favorites.toggle('voice', channel.id),
      onRetryStatus: () =>
          _favorites.load('voice', <String>[channel.id], force: true),
    );
  }
}
