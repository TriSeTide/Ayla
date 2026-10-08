/// 一级桌游 tab（路由 /games）—— web pages/GamesHubPage.tsx 224 行的等价物
/// （**本轮只做大厅**，见下方「与 web 的机制差异」）。
///
/// ## 事实源（逐条）
/// - tsx 27–35：六个分类（全部/公开/好友/我的/等待中/对局中）；?type= 驱动（tsx 171–174）；
/// - tsx 49–55：后端过滤参数（visibility / friends / status(waiting|playing) / owner）；
/// - tsx 70–82：前端二次过滤（public / friends / mine → is_owner /
///   waiting → status=="waiting" / playing → status=="playing"）；
/// - tsx 176–180：统计行「N 个房间」（loading 时「… 个房间」）；
/// - tsx 184–193：加载态 AylaGamesGridSkeleton（文案「正在加载桌游室…」）；
/// - tsx 194：错误且无内容 ⇒ 只渲染 DirectoryLoadMore；
/// - tsx 195–198：**全部为空**的空态（在 PullToRefresh 之外，h2）
///   「还没有桌游室」/「点右下角 + 建一个房间」；
/// - tsx 200–219：PullToRefresh 包住网格 + 页脚；分类空态（h2）
///   「这个分类还没有桌游室」/「换个分类看看」；
/// - tsx 207–215：AylaGamesGrid + GameRoomCard（卡件已交付）。
///
/// ## WS 热更新（2026-10-08 按 web 收口）
/// 本页**不订阅任何 WS 帧 / 事件总线**：数据来自 [AylaDirectoryStore] 的跨页缓存，
/// 帧由 `core/ws/room_frames.dart` 落域 store、再由 `state/directory_tracking.dart`
/// 的 store 订阅通路 patch 进缓存（web `stores/directory.ts:143–146 / 205–219` 的同构）
/// ⇒ 建房 / 开桌 / 结束 / 人数变化 / 新建 / 删除**自动反映**。
///
/// ## 与 web 的机制差异（登记）
/// - **房内占位态未做**（tsx 105–164：/games/:roomId 的自动 join + GameRoomPlaceholder）：
///   web 的同一组件按 roomId 分支渲染房内；Flutter 侧房内页需要 members 分页
///   （GameRoom.members 在 Flutter 的 AylaGameRoom 里未承载）+ 成员管理/分享/收藏一整套，
///   属第 3 批「房内页装配」⇒ 本轮 /games/:roomId 仍是占位路由，与 /voice/:channelId 同口径；
/// - 滚动位置记忆（useScrollRestore）未实现（同语音/直播页登记）；
/// - 收藏的 busy / error / retry：AylaGameRoomCard 支持三档（本页已逐卡注入 ✅）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/boardgame_api.dart';
import '../core/models/game_room.dart' show AylaGameRoom;
import '../state/directory_events.dart' show AylaDirectoryKind;
import 'game_support.dart';
import '../state/auth_state.dart';
import '../state/directory_store.dart';
import '../state/favorite_status.dart';
import '../state/shell_state.dart';
import '../theme/app_icons.dart';
import '../widgets/base/directory_load_more.dart';
import '../widgets/base/directory_page.dart';
import '../widgets/base/media_interaction.dart' show AylaPullToRefresh;
import '../widgets/base/page_state.dart';
import '../widgets/base/profile_and_filters.dart' show AylaDirectoryFilters;
import '../widgets/base/reveal.dart';
import '../widgets/game/game_room_card.dart';
import '../widgets/game/games_grid.dart';
import 'hub_support.dart';
import '../state/hub_directory_options.dart'
    show aylaHubDirectoryOptions;

class GamesHubPage extends ConsumerStatefulWidget {
  const GamesHubPage({super.key, this.initialType, this.roomId});

  /// ?type=（路由读取；null / 未知值 = 全部）。
  final String? initialType;

  /// 房内态房间 id（路由 `/games/:roomId`；null = 大厅）。
  ///
  /// web 的 `/games` 与 `/games/:roomId` **是同一个组件**（`App.tsx:78–79`），
  /// 由 `useParams().roomId` 分支渲染；Flutter 侧同法（本参数即 `useParams` 的等价物）。
  final String? roomId;

  /// 六个分类（tsx 27–35，逐字）。
  static const List<({String key, String label})> filters =
      <({String key, String label})>[
    (key: 'all', label: '全部'),
    (key: 'public', label: '公开'),
    (key: 'friends', label: '好友'),
    (key: 'mine', label: '我的'),
    (key: 'waiting', label: '等待中'),
    (key: 'playing', label: '对局中'),
  ];

  @override
  ConsumerState<GamesHubPage> createState() => _GamesHubPageState();
}

class _GamesHubPageState extends ConsumerState<GamesHubPage> {
  late String _filter =
      aylaHubFilterOf(GamesHubPage.filters, widget.initialType);

  final ScrollController _scroll = ScrollController();
  final AylaFavoriteStatusController _favorites = AylaFavoriteStatusController();
  AylaDirectoryController<AylaDirectoryGameEntry>? _pager;
  Set<String> _friendIds = const <String>{};
  int _replayNonce = 0;

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
  }

  /// 大厅列表里已知的房间（web tsx 127–129：命中则不重复拉详情）。
  AylaGameRoom? _knownRoom(String roomId) {
    final int? id = int.tryParse(roomId);
    if (id == null) return null;
    for (final AylaDirectoryGameEntry entry
        in _pager?.items ?? const <AylaDirectoryGameEntry>[]) {
      if (entry.room.id == id) return entry.room;
    }
    return null;
  }

  /// 退出房内（离开/删除/返回都汇到这里；web tsx 142–145）。
  void _exitRoom() {
    if (!mounted) return;
    context.go('/games');
    unawaited(_pager?.refresh() ?? Future<void>.value());
  }

  @override
  void didUpdateWidget(covariant GamesHubPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialType != oldWidget.initialType) {
      final String next =
          aylaHubFilterOf(GamesHubPage.filters, widget.initialType);
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
    final AylaDirectoryController<AylaDirectoryGameEntry>? pager = _pager;
    if (pager == null) return;
    _favorites.load(
      'game',
      <String>[for (final AylaDirectoryGameEntry e in pager.items) e.card.id],
    );
  }

  void _start() {
    final String? owner =
        _filter == 'mine' ? ref.read(authNotifierProvider).user?.id : null;
    // 数据归**共享 store**（web `useDirectoryPage` + `stores/directory.ts`）：
    // options（含 filter 段）进 `directoryKey` ⇒ 每个分类 tab 独立游标；
    // 命中 60 秒缓存 ⇒ 切 tab / 再次进入**不发请求、不闪骨架**（`:274`）。
    final AylaDirectoryController<AylaDirectoryGameEntry> pager =
        AylaDirectoryController<AylaDirectoryGameEntry>(
      store: aylaDirectoryStore,
      kind: AylaDirectoryKind.game,
      // ⚠️ options 由**共享事实源**构造（`state/hub_directory_options.dart`）：
      // 它的每个字段都进 `directoryKey`，预加载与页面必须逐字段一致，否则命中不了。
      options: aylaHubDirectoryOptions(
        kind: AylaDirectoryKind.game,
        filter: _filter,
        userId: owner,
      ),
    );
    pager.addListener(_onPagerChanged);
    _pager?.dispose();
    _pager = pager;
    _registerRefresh();
    // ⚠️ **必须帧后**（2026-10-08 回归修复）：`AylaDirectoryStore.load` 的同步段
    // 会立刻通知**全局** store 的全部订阅者（本页 `_pager` 只是其一；
    // `GroupPage._onChanged` / `HomePage._rebuildActivity` 等裸 `setState` 回调
    // 也在其中）⇒ 在 build 期发起会抛 "setState() or markNeedsBuild() called
    // during build"。回归锁：`test/hub_friends_load_phase_test.dart`。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 幂等：命中缓存即短路（web `loadDirectory` 的 `initial` 语义）。
      unawaited(pager.load());
    });
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
    final Set<String> ids = await aylaHubFriendIds();
    if (!mounted || ids.isEmpty) return;
    setState(() => _friendIds = ids);
  }

  void _registerRefresh() {
    final ShellUiNotifier notifier = ref.read(shellUiProvider.notifier);
    Future<void> callback() async {
      final AylaDirectoryController<AylaDirectoryGameEntry>? pager = _pager;
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
    final AylaDirectoryController<AylaDirectoryGameEntry>? pager = _pager;
    if (pager == null) return;
    await pager.refresh();
    if (mounted) setState(() => _replayNonce++);
  }

  void _onFilterChange(String next) {
    setState(() => _filter = next);
    _start();
    context.replace(next == 'all' ? '/games' : '/games?type=$next');
  }

  List<AylaDirectoryGameEntry> _visible(List<AylaDirectoryGameEntry> items) {
    if (_filter == 'all') return items;
    return <AylaDirectoryGameEntry>[
      for (final AylaDirectoryGameEntry entry in items)
        if (_matches(entry)) entry,
    ];
  }

  /// tsx 70–82 的前端二次过滤（判据在 hub_support 的纯函数里，便于定向测试）。
  bool _matches(AylaDirectoryGameEntry entry) =>
      aylaHubMatchGame(entry, _filter, friendIds: _friendIds);

  /// tsx 179：合计房间数。
  String _statsLabel() {
    final AylaDirectoryController<AylaDirectoryGameEntry>? pager = _pager;
    // web tsx 179：判定用的是 loading
    if (pager == null || pager.loading) {
      return '… 个房间';
    }
    final int total = pager.total;
    return '$total 个房间';
  }

  @override
  Widget build(BuildContext context) {
    // 房内态（web tsx 105–164）：大厅的取数与列表保留在下方分支。
    final String? roomId = widget.roomId;
    if (roomId != null) {
      return AylaGameRoomHost(
        key: ValueKey<String>(roomId),
        roomId: roomId,
        initialRoom: _knownRoom(roomId),
        onExit: _exitRoom,
      );
    }
    final bool narrow = aylaDirectoryIsNarrow(context);
    final AylaDirectoryController<AylaDirectoryGameEntry>? pager = _pager;

    Widget content;
    if (pager == null || (!pager.loaded && pager.loading)) {
      // tsx 184–193：两张 120 高骨架卡 + 跨列文案（件已交付）。
      // web 骨架容器同时带 `.games-grid`（tsx 185）⇒ 目录页组规则同样命中：
      // 左右恒 0（directory-filters.css:171–180）+ ≥769 顶部归零（199–208）。
      content = AylaGamesGridSkeleton(
        padding: aylaDirectoryListPadding(context),
      );
    } else if (pager.error != null && pager.items.isEmpty) {
      content = AylaDirectoryLoadMore(
        loading: pager.loading,
        error: pager.error,
        hasMore: pager.hasMore,
        invalidated: pager.invalidated,
        loadMore: pager.loadMore,
        refresh: pager.refresh,
      );
    } else if (pager.items.isEmpty) {
      // tsx 195–198：**全部为空**的空态（在 PullToRefresh 之外、无页脚）
      content = const AylaPageState(
        title: '还没有桌游室',
        description: '点右下角 + 建一个房间',
        padding: kAylaPageStateDirectoryPadding,
      );
    } else {
      final List<AylaDirectoryGameEntry> visible = _visible(pager.items);
      content = AylaPullToRefresh(
        isAtTop: _isAtTop,
        onRefresh: _refresh,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (visible.isEmpty && _filter != 'all')
              const AylaPageState(
                title: '这个分类还没有桌游室',
                description: '换个分类看看',
                padding: kAylaPageStateDirectoryPadding,
              )
            else
              AylaRevealScope(
                replayKey: _replayNonce,
                child: AylaGamesGrid(
                  // `.games-grid` 基样式是 `padding: sp3 sp4`（boardgame.css:232–237）；
                  // 目录页组规则再加两条（directory-filters.css）：左右恒 0（171–180，全断点）
                  // + ≥769 顶部归零（199–208）⇒ 宽屏 (0, 0, 0, sp3) / 窄屏 (0, sp3, 0, sp3)。
                  // 群内与画布样张不传本参数 ⇒ 保持组件默认（boardgame.css:247–252 另有口径）。
                  padding: aylaDirectoryListPadding(context),
                  children: <Widget>[
                    for (int i = 0; i < visible.length; i += 1)
                      AylaGameRoomCard(
                        room: visible[i].card,
                        onEnter: () => _enter(visible[i].card.id),
                        revealDelay: AylaRevealMotion.staggerDelay(i),
                        // 网格等高：web `boardgame.css:232–237` 的 `.games-grid { display:grid }`
                        // 默认 `align-items: stretch` ⇒ 同一行卡片恒等高（网格把最矮的拉到该行最高）。
                        // Flutter 无 stretch 且卡片内含 LayoutBuilder（不支持 intrinsics，
                        // 见 `game_room_card.dart:85–92`）⇒ 用件内既有开关 `reserveSpace`
                        // 让「状态行 / 房主行 / meta 行」恒占位，高度由构造决定。
                        // ⚠️ 取向差异（登记）：web 是「最矮卡被拉高到该行最高卡」，
                        // `reserveSpace` 是「每卡固定占满四行」—— 同批都缺行时结果一致；
                        // 混排（部分卡有状态/房主行）时本档会略高。不得为此引入
                        // `IntrinsicHeight`（受 `AylaGlassButton` / LayoutBuilder 限制）。
                        // 搜索页等「单卡使用」场景**不传**（保持 web 的条件渲染，卡底不留空白）。
                        reserveSpace: true,
                        favoriteState:
                            _favorites.stateOf('game', visible[i].card.id),
                        favoriteBusy: _favorites.busyOf('game', visible[i].card.id),
                        favoriteError:
                            _favorites.actionErrorOf('game', visible[i].card.id),
                        onToggleFavorite: (bool next) =>
                            _favorites.toggle('game', visible[i].card.id),
                        onRetryFavoriteStatus: () => _favorites.load(
                          'game',
                          <String>[visible[i].card.id],
                          force: true,
                        ),
                      ),
                  ],
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
        label: '桌游分类',
        options: GamesHubPage.filters,
        value: _filter,
        narrow: narrow,
        onChange: _onFilterChange,
        decor: AylaDirectoryDecorIcon(icon: aylaIconByName('iconGame')!),
        header: AylaDirectorySidebarHeader(
          kicker: 'Games',
          title: '桌游室',
          stats: _statsLabel(),
        ),
      ),
      content: AylaDirectoryContent(
        fadeGlass: false,
        controller: _scroll,
        scope: 'games-hub:$_filter', // web key={scope}（tsx 181）
        label: aylaHubFilterLabel(GamesHubPage.filters, _filter),
        child: content,
      ),
    );
  }

  bool _isAtTop() => !_scroll.hasClients || _scroll.position.pixels <= 0;

  /// 进房（tsx 105–112：navigate('/games/:roomId')）。房内态属第 3 批，此处只做路由。
  void _enter(String roomId) {
    final String encoded = Uri.encodeComponent(roomId);
    context.go('/games/$encoded');
  }
}
