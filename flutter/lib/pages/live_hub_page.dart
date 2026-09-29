/// 一级直播 tab（路由 /live）—— web pages/LiveHubPage.tsx 170 行的等价物。
///
/// ## 事实源（逐条）
/// - tsx 26–33：六个分类（全部/在播/公开/好友/停播/我的）；?type= 驱动（tsx 130–133）；
/// - tsx 46–52：后端过滤参数（visibility / friends / status(live|offline) / owner）；
/// - tsx 63–75：前端二次过滤（live → status=="live"；offline → status!="live"；
///   public → visibility；friends → 好友集合；mine → is_owner）；
/// - tsx 85–93：缺 owner_nickname 的频道按 ensureUser(owner_id) 懒拉主播名；
/// - tsx 108–120：爱莉 profile → elysiaUserId（启用才标注）；
/// - tsx 135–139：统计行「N 直播间 · M 在播」（M = 已加载数据里 status=="live" 的条数，tsx 123）；
/// - tsx 143–147：加载态两根 96 高骨架（live.css:607–614 grid gap sp4；
///   窄屏 618–622 加 padding sp3 sp4）；
/// - tsx 148：错误且无内容 ⇒ 只渲染 DirectoryLoadMore；
/// - tsx 150–154：分类空态「这个分类还没有直播间」/「换个分类看看」（h3）；
/// - tsx 156–161：LiveHall（卡件已交付）。
///
/// ## 与 web 的机制差异（登记）
/// - 滚动位置记忆（useScrollRestore）未实现（同语音页登记）；
/// - 收藏五档**全部注入**（2026-09-28 总控裁决落实）：`LiveHall.tsx:39–42` 不传
///   `action` ⇒ 卡片自渲 `<FavoriteButton compact>`（`LiveChannelCard.tsx:51`），
///   该组件自带 busy / error / retry 语义 ⇒ 大厅等价能力 = 五档；
///   `AylaLiveHall` 原有转发缺口已由 `favoriteBusyBuilder` / `favoriteErrorBuilder` /
///   `onRetryFavoriteStatus` 三个**纯增量**参数补齐（默认 null ⇒ 既有调用点不变）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/elysia_api.dart';
import '../core/api/live_api.dart';
import '../core/api/users_api.dart';
import '../core/models/visibility.dart' show AylaPostVisibility;
import '../state/auth_state.dart';
import '../state/favorite_status.dart';
import '../state/paged_list.dart';
import '../state/shell_state.dart';
import '../theme/app_icons.dart';
import '../theme/tokens.dart';
import '../widgets/base/directory_load_more.dart';
import '../widgets/base/directory_page.dart';
import '../widgets/base/media_interaction.dart' show AylaPullToRefresh;
import '../widgets/base/page_state.dart';
import '../widgets/base/profile_and_filters.dart' show AylaDirectoryFilters;
import '../widgets/base/reveal.dart';
import '../widgets/live/live_hall.dart';
import 'hub_support.dart';

class LiveHubPage extends ConsumerStatefulWidget {
  const LiveHubPage({super.key, this.initialType});

  /// ?type=（路由读取；null / 未知值 = 全部）。
  final String? initialType;

  /// 六个分类（tsx 26–33，逐字）。
  static const List<({String key, String label})> filters =
      <({String key, String label})>[
    (key: 'all', label: '全部'),
    (key: 'live', label: '在播'),
    (key: 'public', label: '公开'),
    (key: 'friends', label: '好友'),
    (key: 'offline', label: '停播'),
    (key: 'mine', label: '我的'),
  ];

  @override
  ConsumerState<LiveHubPage> createState() => _LiveHubPageState();
}

class _LiveHubPageState extends ConsumerState<LiveHubPage> {
  late String _filter = aylaHubFilterOf(LiveHubPage.filters, widget.initialType);

  final ScrollController _scroll = ScrollController();
  final AylaFavoriteStatusController _favorites = AylaFavoriteStatusController();
  AylaPagedList<AylaDirectoryLiveEntry>? _pager;
  Set<String> _friendIds = const <String>{};
  String? _elysiaUserId;

  /// owner_id → 展示名（tsx 55：列表不带主播名时的兜底）。
  Map<String, String> _ownerNames = const <String, String>{};

  /// 已发起懒拉的 owner id（避免每次列表变化重复请求）。
  final Set<String> _ownerFetched = <String>{};

  /// 刷新后整批重播入场（web replayNonce）。
  int _replayNonce = 0;

  /// 当前页注册到 shell 的刷新回调（web `useShellStore.registerRefresh`）。
  ShellUiNotifier? _shellNotifier;
  Future<void> Function()? _refreshCallback;

  @override
  void initState() {
    super.initState();
    _favorites.addListener(_onFavoritesChanged);
    _start();
    _loadFriends();
    _loadElysia();
  }

  @override
  void didUpdateWidget(covariant LiveHubPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialType != oldWidget.initialType) {
      final String next =
          aylaHubFilterOf(LiveHubPage.filters, widget.initialType);
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
    if (!mounted) return;
    setState(() {});
    final AylaPagedList<AylaDirectoryLiveEntry>? pager = _pager;
    if (pager == null) return;
    _favorites.load(
      'live',
      <String>[for (final AylaDirectoryLiveEntry e in pager.items) e.card.id],
    );
    _ensureOwnerNames(pager.items);
  }

  void _start() {
    final String? owner =
        _filter == 'mine' ? ref.read(authNotifierProvider).user?.id : null;
    final String? status = _filter == 'live'
        ? 'live'
        : _filter == 'offline'
            ? 'offline'
            : null;
    final AylaPagedList<AylaDirectoryLiveEntry> pager =
        AylaPagedList<AylaDirectoryLiveEntry>(
      request: (String? cursor) => AylaLiveApi.listLiveChannelsPage(
        cursor: cursor,
        owner: owner,
        friends: _filter == 'friends',
        visibility: _filter == 'public' ? AylaPostVisibility.public : null,
        status: status,
      ),
      keyOf: (AylaDirectoryLiveEntry entry) => entry.card.id,
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

  Future<void> _loadElysia() async {
    try {
      final profile = await AylaElysiaApi.getProfile();
      final String? userId = profile?.userId;
      if (!mounted || profile == null || !profile.enabled) return;
      if (userId == null || userId.isEmpty) return;
      setState(() => _elysiaUserId = userId);
    } catch (_) {
      // 爱莉入口静默降级（tsx 114–116）
    }
  }

  /// tsx 85–93：缺主播名的频道按 owner_id 懒拉（web ensureUser 带缓存；
  /// 这里用页面内 _ownerFetched 去重，失败静默）。
  void _ensureOwnerNames(List<AylaDirectoryLiveEntry> items) {
    final List<String> ids = <String>[
      for (final AylaDirectoryLiveEntry entry in items)
        if ((entry.card.ownerNickname ?? '').isEmpty &&
            entry.ownerId.isNotEmpty &&
            !_ownerFetched.contains(entry.ownerId))
          entry.ownerId,
    ];
    if (ids.isEmpty) return;
    _ownerFetched.addAll(ids);
    for (final String id in ids) {
      AylaUsersApi.getUserDetail(id).then((AylaUserDetail detail) {
        if (!mounted) return;
        final String? name = detail.user.displayName;
        if (name == null || name.isEmpty) return;
        setState(() {
          _ownerNames = <String, String>{..._ownerNames, id: name};
        });
      }).catchError((Object _) {
        // 懒拉失败静默（web 的 ensureUser 也返回 null）
      });
    }
  }

  void _registerRefresh() {
    final ShellUiNotifier notifier = ref.read(shellUiProvider.notifier);
    Future<void> callback() async {
      final AylaPagedList<AylaDirectoryLiveEntry>? pager = _pager;
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
    final AylaPagedList<AylaDirectoryLiveEntry>? pager = _pager;
    if (pager == null) return;
    await pager.refresh();
    if (mounted) setState(() => _replayNonce++);
  }

  void _onFilterChange(String next) {
    setState(() => _filter = next);
    _start();
    context.replace(next == 'all' ? '/live' : '/live?type=$next');
  }

  List<AylaDirectoryLiveEntry> _visible(List<AylaDirectoryLiveEntry> items) {
    if (_filter == 'all') return items;
    return <AylaDirectoryLiveEntry>[
      for (final AylaDirectoryLiveEntry entry in items)
        if (_matches(entry)) entry,
    ];
  }

  /// tsx 63–75 的前端二次过滤（判据在 hub_support 的纯函数里，便于定向测试）。
  bool _matches(AylaDirectoryLiveEntry entry) =>
      aylaHubMatchLive(entry, _filter, friendIds: _friendIds);

  /// tsx 138：合计直播间数 · 已加载里在播条数。
  String _statsLabel() {
    final AylaPagedList<AylaDirectoryLiveEntry>? pager = _pager;
    // web tsx 138：判定用的是 loading
    if (pager == null || pager.loading) {
      return '… 直播间 · … 在播';
    }
    final int liveCount = pager.items
        .where((AylaDirectoryLiveEntry e) =>
            e.card.status == AylaLiveStatus.live)
        .length;
    final int total = pager.total;
    return '$total 直播间 · $liveCount 在播';
  }

  @override
  Widget build(BuildContext context) {
    final bool narrow = aylaDirectoryIsNarrow(context);
    final AylaPagedList<AylaDirectoryLiveEntry>? pager = _pager;

    Widget content;
    if (pager == null || (!pager.loaded && pager.loading)) {
      // tsx 143–147：两根 96 高骨架 · gap sp4 · 窄屏 padding sp3 sp4
      content = aylaHubSkeletonGrid(
        context,
        skeletonHeight: 96,
        gap: AylaSpacing.sp4,
        padding: narrow
            ? const EdgeInsets.symmetric(
                horizontal: AylaSpacing.sp4,
                vertical: AylaSpacing.sp3,
              )
            : EdgeInsets.zero,
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
    } else {
      final List<AylaDirectoryLiveEntry> visible = _visible(pager.items);
      content = AylaPullToRefresh(
        isAtTop: _isAtTop,
        onRefresh: _refresh,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (visible.isEmpty && _filter != 'all')
              const AylaPageState(
                title: '这个分类还没有直播间',
                description: '换个分类看看',
                padding: kAylaPageStateDirectoryPadding,
              )
            else
              AylaRevealScope(
                replayKey: _replayNonce,
                child: AylaLiveHall(
                  channels: <AylaLiveCardData>[
                    for (final AylaDirectoryLiveEntry entry in visible)
                      entry.card,
                  ],
                  elysiaUserId: _elysiaUserId,
                  ownerNames: _ownerNames,
                  revealItems: true,
                  onEnter: _enter,
                  favoriteStateBuilder: (AylaLiveCardData channel) =>
                      _favorites.stateOf('live', channel.id),
                  favoriteBusyBuilder: (AylaLiveCardData channel) =>
                      _favorites.busyOf('live', channel.id),
                  favoriteErrorBuilder: (AylaLiveCardData channel) =>
                      _favorites.actionErrorOf('live', channel.id),
                  onToggleFavorite: (AylaLiveCardData channel, bool next) =>
                      _favorites.toggle('live', channel.id),
                  // 状态未知/出错 ⇒ 点击重新拉取（FavoriteButton.tsx:35–38）
                  onRetryFavoriteStatus: (AylaLiveCardData channel) =>
                      _favorites.load('live', <String>[channel.id], force: true),
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
        label: '直播分类',
        options: LiveHubPage.filters,
        value: _filter,
        narrow: narrow,
        onChange: _onFilterChange,
        decor: AylaDirectoryDecorIcon(icon: aylaIconByName('iconVideo')!),
        header: AylaDirectorySidebarHeader(
          kicker: 'Live',
          title: '直播间',
          stats: _statsLabel(),
        ),
      ),
      content: AylaDirectoryContent(
        fadeGlass: false,
        controller: _scroll,
        scope: 'live-hub:$_filter', // web key={scope}（tsx 140）
        label: aylaHubFilterLabel(LiveHubPage.filters, _filter),
        child: content,
      ),
    );
  }

  bool _isAtTop() => !_scroll.hasClients || _scroll.position.pixels <= 0;

  /// 进直播间（tsx 160：navigate('/live/:id')）。房内页属第 3 批，此处只做路由。
  void _enter(String channelId) {
    final String encoded = Uri.encodeComponent(channelId);
    context.go('/live/$encoded');
  }
}
