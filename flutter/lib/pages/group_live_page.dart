/// 群内直播子界面 —— web `pages/group/GroupLive.tsx`（197 行）的等价物。
///
/// ## 逐条对应
/// | 本页 | web tsx |
/// |---|---|
/// | 群内直播间目录（服务端 `group_id` 过滤 + 游标分页） | 27（`useDirectoryPage('live', {groupId})`） |
/// | **直接进该群第一个直播间**（无卡片列表，R-G7） | 32–38 + 61–67 |
/// | 路由频道详情补拉 + 白名单校验（不在本群可见范围则报错态） | 43–59 |
/// | 靠近列表末尾时续读一页 | 61–67 |
/// | 侧栏/上下滑切台只改 `currentId`（不改 URL） | 72–88 |
/// | 加载 / 错误 / 空态（创建群内直播 + 返回聊天） | 113–165 |
/// | 房内：`LiveRoomBody`（无 rail、返回=回聊天、输入框直接显示） | 167–195 |
/// | **「群内开播」浮层**（`CreateSheet title="群内开播"` + `LiveStartSheet` 双分支） | 153–162（空态）+ 185–192（房内） |
/// | 空态「创建群内直播」⇒ 开浮层（不是直接建台） | 141–144（`setCreateError(null); setShowCreate(true)`） |
/// | 房内「新建直播间」（`LiveRoomBody.onCreateNewChannel`）⇒ 同一份浮层 | 179–182 |
/// | 选已有直播间 ⇒ 关浮层 + `/live/start/<id>` | 90–96（`handleLiveStarted`） |
/// | 新建 ⇒ `createLiveChannel('新直播间', groupId)` + 进控制台；失败保留浮层 | 98–111（`handleCreateNewLive`） |
///
/// ## 机制差异（登记）
/// 1. **`fromShare` 分支未接**（同语音页）：web 带 `location.state.fromShare` 免白名单校验。
/// 2. **`inputEntered`（无底栏下滑走的进房动画）**：Flutter 的 `AylaLiveRoomBody` 无该档，
///    由壳层决定底栏显隐（群路由本就不出底栏）⇒ 视觉结果一致。
/// 3. **浮层挂载点**：web 的 `CreateSheet` 是 `createPortal(…, document.body)`（视口级 fixed）；
///    本页把它放进自己的 `Stack` + `Positioned.fill` —— 群场景的内容区**上边界在群内
///    顶栏之下**（`GroupPage` 的 `Column[顶栏, Expanded(场景)]`），因此遮罩覆盖的是
///    场景区而非整视口。这是**既有页面级弹层的同款口径**（`GroupPage` 的建群弹窗也是
///    `Positioned.fill`），群内子界面没有跨场景浮层叠放 ⇒ 不需要 `AylaRootOverlay`。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/live_api.dart'
    show AylaDirectoryLiveEntry, AylaLiveApi, AylaLiveDanmaku, AylaLiveViewer;
import '../core/net/dio_client.dart' show ApiException;
import '../core/api/directory_page.dart' show AylaDirectoryPage;
import '../layout/create_sheet_forms.dart'
    show AylaCreateLiveChannelFn, AylaOwnedLivePageRequest, AylaOwnedLivePicker;
import '../state/cursor_history.dart';
import '../state/live_state.dart';
import '../state/directory_events.dart' show AylaDirectoryKind;
import '../state/directory_store.dart'
    show aylaDirectoryStore, AylaDirectoryController, AylaDirectoryOptions;
import '../state/room_providers.dart' show liveStateProvider, liveWsProvider;
import '../state/chat_providers.dart' show chatWsProvider;
import '../state/auth_state.dart'
    show AuthState, AylaMediaActivityKind, authNotifierProvider;
import '../core/models/share_payload.dart' show AylaSharePayload;
import '../theme/glass.dart' show AylaGlassButton, AylaGlassButtonVariant;
import '../widgets/base/directory_controls.dart' show AylaHistoryControlsData;
import '../widgets/base/directory_load_more.dart' show AylaDirectoryLoadMore;
import '../widgets/base/loading.dart' show AylaSkeleton;
import '../widgets/group/group_scene.dart'
    show
        AylaGroupScenePlaceholder,
        AylaGroupScenePlaceholderRole;
import '../widgets/live/live_channel_snapshot.dart' show AylaLiveChannelSnapshot;
import '../widgets/live/live_hall.dart' show AylaLiveCardData;
import '../widgets/live/live_room_body.dart' show AylaLiveRoomBody, AylaLiveRoomData;
import '../widgets/live/live_viewers.dart' show AylaLiveViewerItem;
import '../theme/tokens.dart' show AylaRadii;
import '../widgets/shell/create_sheet.dart' show AylaCreateSheet;
import 'live_support.dart'
    show AylaLiveRoomSession, AylaLiveViewerSheetController;
import 'share_support.dart' show aylaOpenShareSheet, AylaShareController;

/// **测试注入点**（生产恒为 null ⇒ 走真实 `AylaLiveApi`）。
///
/// 为什么需要它们：P0-3 的教训是「组件单测绿了、页面根本没渲染它」——群内开播的两条
/// 分支（选已有 / 新建）与两处入口（空态 / 房内）都必须在**真实的** [GroupLivePage]
/// 上走一遍，而本页的三个数据出口（群直播目录 / 本人直播间目录 / 建直播间）都是
/// 静态 API、无法从外部替换。形态与 `group_page.dart` 的 [aylaGroupPageSubgroupsLoader]
/// / [aylaGroupPageCreateGroupBuilder] 同款：测试注入的仍是**真实页面**，只换数据出口。
@visibleForTesting
AylaGroupLiveDirectoryLoader? aylaGroupLivePageDirectoryLoader;

/// 见 [aylaGroupLivePageDirectoryLoader]：`(groupId, cursor) → 一页群内直播间`。
@visibleForTesting
typedef AylaGroupLiveDirectoryLoader = Future<AylaDirectoryPage<AylaDirectoryLiveEntry>>
    Function(String groupId, String? cursor);

/// 见 [aylaGroupLivePageOwnedLivePage]：`(cursor, owner) → 一页本人直播间`。
@visibleForTesting
AylaOwnedLivePageRequest? aylaGroupLivePageOwnedLivePage;

/// 见 [aylaGroupLivePageCreateChannel]：`(title, group) → 新建的直播间`。
@visibleForTesting
AylaCreateLiveChannelFn? aylaGroupLivePageCreateChannel;

class GroupLivePage extends ConsumerStatefulWidget {
  const GroupLivePage({
    super.key,
    required this.groupId,
    this.routeChannelId,
    this.onExit,
  });

  final String groupId;

  /// 路由 `:liveChannelId`（存在 ⇒ 优先进入该直播间）。
  final String? routeChannelId;

  /// 「返回聊天」（tsx 148–150 / 187 的 onExit）。
  final VoidCallback? onExit;

  @override
  ConsumerState<GroupLivePage> createState() => _GroupLivePageState();
}

class _GroupLivePageState extends ConsumerState<GroupLivePage> {
  /// 群内直播目录 —— **读共享目录缓存**（web `GroupLive.tsx:27` 的
  /// `useDirectoryPage("live", {groupId})`），不是页面私有分页。
  ///
  /// ⚠️ **2026-10-20 热更新审计 R2 修复**：原实现用私有 `AylaPagedList`，
  /// `live.channel.*` 帧落 store 后本页毫无反应 ⇒ 群内直播列表只能手动刷新。
  /// 换共享缓存后与群外大厅 / 宽屏侧栏走同一条通路（web 三处同一投影）。
  AylaDirectoryController<AylaDirectoryLiveEntry>? _directory;
  AylaLiveRoomSession? _session;
  final AylaShareController _share = AylaShareController();

  /// 在看名单弹层的**权威数据子链**（web 是弹层内部自己拉 —— `LiveViewerSheet.tsx:44–65`
  /// 的 `getLiveChannelViewers` + `:67–79` 的 `getElysiaProfile`；Flutter 侧网络层不进
  /// `lib/widgets` ⇒ 由页面持有、经 [AylaLiveRoomBody.data.viewerSheet] 注入）。
  AylaLiveViewerSheetController? _viewerSheet;

  /// 当前直播间 id（null = 空态）。
  int? _currentId;
  /// 最后一次 build 的窄屏判定（`dispose` 里读不到 MediaQuery ⇒ 在 build 里记下；
  /// 视图分离的「窄屏 + 直播中 ⇒ 进小窗」判定要用它，见 [AylaLiveRoomSession.detachView]）。
  bool _narrow = false;
  /// 路由频道详情错误（web tsx 29）。
  String? _detailError;
  /// 「群内开播」浮层是否打开（web `GroupLive.tsx:39` 的 `showCreate`）。
  bool _showCreate = false;

  /// 浮层内「正在建新直播间」（web tsx 40 `creatingNew`）。
  bool _creating = false;

  /// 浮层内「创建失败」文案（web tsx 41 `createError`）。
  String? _createError;

  @override
  void initState() {
    super.initState();
    _bindDirectoryController();
    _syncRouteChannel();
  }

  @override
  void didUpdateWidget(covariant GroupLivePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.routeChannelId != widget.routeChannelId) _syncRouteChannel();
  }

  @override
  void dispose() {
    _session?.removeListener(_onChanged);
    final AylaLiveRoomSession? session = _session;
    final bool narrow = _narrow;
    _session = null;
    scheduleMicrotask(() {
      // 窄屏 + 直播中 ⇒ 会话所有权移交 AppShell 的小窗宿主（播放器不销毁）；
      // 否则完整销毁并回收会话（web `useLiveRoom` 的 cleanup → `detachView`）。
      unawaited(session?.detachView(isNarrow: narrow));
    });
    _directory?.removeListener(_onChanged);
    _directory?.dispose();
    _viewerSheet?.removeListener(_onChanged);
    _viewerSheet?.dispose();
    _viewerSheet = null;
    _share.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// 绑定群直播目录 controller（web `GroupLive.tsx:27`，options 只有 `{groupId}`）。
  ///
  /// ⚠️ **必须帧后 `load()`**（库里既有五处同源纪律，见 `group_page.dart:316–352`）：
  /// `AylaDirectoryStore.load` 的同步段会立刻 `notifyListeners` 全局 store，
  /// 其它已挂载页面的监听是裸 `setState` ⇒ build 期发起会抛
  /// "setState() or markNeedsBuild() called during build"。
  void _bindDirectoryController() {
    final AylaDirectoryController<AylaDirectoryLiveEntry> controller =
        AylaDirectoryController<AylaDirectoryLiveEntry>(
      store: aylaDirectoryStore,
      kind: AylaDirectoryKind.live,
      options: AylaDirectoryOptions(groupId: widget.groupId),
    )..addListener(_onChanged);
    _directory?.removeListener(_onChanged);
    _directory?.dispose();
    _directory = controller;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(controller.load());
    });
  }

  bool _visibleInGroup(AylaLiveChannelSnapshot item) =>
      item.allowedGroupIds.contains(widget.groupId);

  /// 路由频道 → 详情补拉 + 白名单校验（web tsx 43–59）。
  void _syncRouteChannel() {
    final String? route = widget.routeChannelId;
    if (route == null) return;
    final int? id = int.tryParse(route);
    if (id == null) return;
    unawaited(() async {
      try {
        final AylaLiveChannelSnapshot item =
            await AylaLiveApi.getLiveChannel('$id');
        if (!mounted) return;
        if (!_visibleInGroup(item)) {
          setState(() => _detailError = '该直播间不在本群可见范围内');
          return;
        }
        ref.read(liveStateProvider).upsertChannel(item);
        setState(() {
          _detailError = null;
          _currentId = int.tryParse(item.id) ?? id;
        });
      } catch (error) {
        if (!mounted) return;
        setState(() => _detailError = error.toString());
      }
    }());
  }

  /// 进入房内（懒建会话；切台复用同一会话）。
  void _enterRoom(int channelId) {
    if (_currentId == channelId && _session != null) return;
    _session?.removeListener(_onChanged);
    final AylaLiveRoomSession? previous = _session;
    if (previous != null) {
      scheduleMicrotask(() {
        unawaited(previous.stop());
        previous.dispose();
      });
    }
    final AylaLiveRoomSession session = AylaLiveRoomSession(
      channelId: '$channelId',
      liveState: ref.read(liveStateProvider),
      liveWs: ref.read(liveWsProvider),
      chat: ref.read(chatWsProvider),
      // 点回直播间（小窗主体）的导航目标 = 群场景路由（web `GroupLive.tsx:178`）。
      activityRoute: '/group/${widget.groupId}/live',
      // 活动态索引的两个注入点（web 读 `useAuthStore.getState()`）：当前用户 id 决定
      // 「本会话是否为主播自己的会话」（`tracksOwnerActivity`），媒体活动位写在会话启停处。
      currentUserId: () => ref.read(authNotifierProvider).user?.id,
      onMediaActivity: (AylaMediaActivityKind kind, bool active, String? roomId) =>
          ref.read(authNotifierProvider.notifier).setMediaActivity(
        kind: kind,
        active: active,
        roomId: roomId,
      ),
    )..addListener(_onChanged);
    _session = session;
    setState(() => _currentId = channelId);
    unawaited(session.start());
  }

  /// 选已有直播间开播（web `GroupLive.tsx:90–96` 的 `handleLiveStarted`）：
  /// 关浮层 → 进开播控制台。
  void _startChannel(AylaLiveCardData channel) {
    setState(() => _showCreate = false);
    context.push('/live/start/${Uri.encodeComponent(channel.id)}');
  }

  /// 新建直播间并开播（web `GroupLive.tsx:98–111` 的 `handleCreateNewLive`）：
  /// 群内开播 = `createLiveChannel('新直播间', groupId)`（本群自动勾选，后端兜底落白名单），
  /// 成功后关浮层 + 进新频道的开播控制台；**失败保留浮层**并显示「创建直播间失败：…」。
  Future<void> _createLive() async {
    if (_creating) return;
    setState(() {
      _creating = true;
      _createError = null;
    });
    try {
      // 测试注入点见 [aylaGroupLivePageCreateChannel]（生产恒 null ⇒ 真实 API）。
      final AylaLiveChannelSnapshot created =
          await (aylaGroupLivePageCreateChannel ?? AylaLiveApi.createLiveChannel)(
        '新直播间', // tsx 103 固定标题
        group: widget.groupId, // tsx 103 第二个实参（本群自动勾选）
      );
      if (!mounted) return;
      setState(() => _showCreate = false);
      context.push('/live/start/${Uri.encodeComponent(created.id)}');
    } catch (error) {
      if (!mounted) return;
      // web tsx 107：`e instanceof Error ? e.message : "创建直播间失败"` ⇒ 非 API 异常回退固定串。
      setState(
        () => _createError = error is ApiException ? error.message : '创建直播间失败',
      );
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  /// 打开「群内开播」浮层（web tsx 141–144 / 179–182 的 `setCreateError(null); setShowCreate(true)`）。
  void _openCreate() {
    setState(() {
      _createError = null;
      _showCreate = true;
    });
  }

  /// 「群内开播」浮层（web `GroupLive.tsx:153–162` 空态与 `:185–192` 房内**同一份**）：
  /// `CreateSheet title="群内开播"`（tsx 154 / 186）+ `LiveStartSheet`（选已有 / 新建双分支）。
  ///
  /// 外观与目录数据全部复用 [AylaOwnedLivePicker]（= web `LiveStartSheet` +
  /// `useOwnedLiveDirectory` 的 Flutter 等价物，FAB 的 live 分支同一件）；
  /// **建播/导航状态在本页自己身上**（web tsx 39–41 的 `creatingNew` / `createError`
  /// 就在 `GroupLive` 里，不在 `LiveStartSheet` 里）—— 这正是与 FAB 分支的唯一差别。
  Widget _createSheet() => AylaCreateSheet(
        title: '群内开播', // tsx 154 / 186
        onClose: () => setState(() => _showCreate = false),
        child: AylaOwnedLivePicker(
          listPage: aylaGroupLivePageOwnedLivePage,
          onStart: _startChannel,
          onCreateNew: () => unawaited(_createLive()),
          creatingNew: _creating,
          createError: _createError,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final AylaDirectoryController<AylaDirectoryLiveEntry>? directory = _directory;
    final List<AylaDirectoryLiveEntry> channels =
        directory?.items ?? const <AylaDirectoryLiveEntry>[];
    final String? error = _detailError ?? directory?.error;

    // 空态/首个直播间选择（web tsx 61–67）：无路由频道时自动进第一个。
    int? currentId = _currentId;
    if (currentId == null &&
        widget.routeChannelId == null &&
        channels.isNotEmpty) {
      currentId = int.tryParse(channels.first.card.id);
    }

    if (currentId == null &&
        error == null &&
        ((directory?.loading ?? true) && channels.isEmpty ||
            widget.routeChannelId != null)) {
      // tsx 113–119：房内数据未就绪的骨架。
      return AylaGroupScenePlaceholder(
        role: AylaGroupScenePlaceholderRole.status,
        children: const <Widget>[
          SizedBox(
            width: 320,
            child: AylaSkeleton(height: 160, radius: AylaRadii.rInput),
          ),
        ],
      );
    }

    if (error != null && (_detailError != null || currentId == null)) {
      // tsx 121–129：错误态 + ghost「重试」。
      return AylaGroupScenePlaceholder(
        title: '群内直播加载失败',
        description: error,
        role: AylaGroupScenePlaceholderRole.alert,
        actions: <Widget>[
          AylaGlassButton(
            label: '重试',
            variant: AylaGlassButtonVariant.ghost,
            onPressed: () {
              if (_detailError != null) {
                setState(() => _detailError = null);
                _syncRouteChannel();
              } else {
                unawaited(directory?.refresh());
              }
            },
          ),
        ],
      );
    }

    if (currentId == null) {
      // tsx 131–165：空态 + 「创建群内直播」（btn-glow）+ 「返回聊天」（ghost）；
      // 点「创建群内直播」⇒ **开「群内开播」浮层**（tsx 141–144 的
      // `setCreateError(null); setShowCreate(true)`），不是直接建台。
      return Stack(
        children: <Widget>[
          Positioned.fill(
            child: AylaGroupScenePlaceholder(
              title: '群内还没有直播',
              description: '发起本群的第一场直播吧',
              actions: <Widget>[
                AylaGlassButton(
                  label: '创建群内直播',
                  variant: AylaGlassButtonVariant.glow,
                  onPressed: _openCreate,
                ),
                AylaGlassButton(
                  label: '返回聊天',
                  variant: AylaGlassButtonVariant.ghost,
                  onPressed: widget.onExit,
                ),
              ],
            ),
          ),
          // tsx 153–162：空态下的 CreateSheet（与房内 185–192 **同一份**）
          if (_showCreate) Positioned.fill(child: _createSheet()),
        ],
      );
    }

    _enterRoom(currentId);
    // tsx 167–195：房内 + 同一份 CreateSheet（185–192；`LiveRoomBody` 的窄屏「打开直播间列表」
    // 浮层里「新建直播间」会把它打开 —— `onCreateNewChannel`）。
    return Stack(
      children: <Widget>[
        Positioned.fill(child: _buildRoom(context, currentId, channels)),
        if (_showCreate) Positioned.fill(child: _createSheet()),
      ],
    );
  }

  Widget _buildRoom(
    BuildContext context,
    int channelId,
    List<AylaDirectoryLiveEntry> channels,
  ) {
    final AylaLiveRoomSession? session = _session;
    if (session == null) return const SizedBox.shrink();
    final AylaLiveState live = ref.watch(liveStateProvider);
    // 弹幕历史由会话自己持有（`AylaLiveRoomSession.history`，与一级直播间同源）。
    final AylaCursorHistory<AylaLiveDanmaku>? history = session.history;
    final String selfId = ref.watch(
      authNotifierProvider.select((AuthState s) => s.user?.id ?? ''),
    );
    final List<AylaLiveCardData> cards = <AylaLiveCardData>[
      for (final AylaDirectoryLiveEntry entry in channels) entry.card,
    ];
    // 名单弹层的权威数据（web 由弹层自身在打开时拉：`LiveViewerSheet.tsx:44–79`）
    final AylaLiveViewerSheetController viewerSheet =
        _viewerSheetOf('$channelId');

    final bool narrow = !(MediaQuery.sizeOf(context).width > 768);
    _narrow = narrow; // dispose 的视图分离判定（见字段注释）
    return AylaLiveRoomBody(
      channelId: '$channelId',
      isNarrow: narrow,
      channels: cards,
      hideRail: true, // 群内子界面无侧栏（web tsx 183）
      onSelect: (String id) {
        final int? next = int.tryParse(id);
        if (next != null) _enterRoom(next);
      },
      onBack: widget.onExit ?? () {},
      data: AylaLiveRoomData(
        channel: live.currentChannel ?? live.channelOf('$channelId'),
        srsStatus: live.srsStatus,
        loading: live.currentLoading,
        error: live.currentError,
        playerError: live.currentPlayerError,
        viewerCount: live.viewerCount,
        viewers: <AylaLiveViewerItem>[
          for (final AylaLiveViewer viewer in live.viewers)
            AylaLiveViewerItem(
              userId: viewer.userId,
              nickname: viewer.nickname,
              avatar: viewer.avatar,
            ),
        ],
        danmaku: session.danmakuEntries(),
        sending: session.sending,
        sendError: session.sendError,
        hasNewBelow: history?.hasNewer ?? false,
        history: history == null
            ? null
            : AylaHistoryControlsData(
                loading: history.loading,
                error: history.error,
                hasMore: history.hasMore,
                hasNewer: history.hasNewer,
                loadOlder: history.loadOlder,
                returnLatest: history.returnLatest,
                retry: history.retry,
              ),
        // 权威名单（web 弹层打开时自拉；Flutter 侧由页面持有、经本投影注入）
        viewerSheet: viewerSheet.value,
      ),
      // 弹层打开 → 页面发起同一次拉取（`LiveViewerSheet.tsx:44–65`）
      onOpenViewerSheet: () => viewerSheet.onOpen('$channelId'),
      // 窄屏「打开直播间列表」浮层底部「新建直播间」（web tsx 179–182 的
      // `onCreateNewChannel={() => { setCreateError(null); setShowCreate(true); }}`）
      onCreateNewChannel: _openCreate,
      onRetryPlayer: () => unawaited(session.retryPlayer()),
      onRefreshPlayer: () => unawaited(session.refreshPlayer()),
      onSendDanmaku: session.sendDanmaku,
      // 自给自足档（web `LiveRoomBody.tsx:260/328`）：收藏键自己加载自己，
      // 页面不再需要 pre-load（根因 A 的结构性修复）。
      favoriteTargetType: 'live',
      favoriteTargetId: '$channelId',
      onShare: () => unawaited(aylaOpenShareSheet(
        context,
        payload: AylaSharePayload.live(
          id: '$channelId',
          title: live.currentChannel?.title ?? '直播间',
          cover: live.currentChannel?.cover,
          ownerName: live.currentChannel?.ownerNickname,
          groupId: live.currentChannel?.group,
        ),
        controller: _share,
        currentUserId: selfId.isEmpty ? null : selfId,
      )),
      videoView: session.videoView,
      directoryFooter: AylaDirectoryLoadMore(
        loading: _directory?.loading ?? false,
        error: _directory?.error,
        hasMore: _directory?.hasMore ?? false,
        invalidated: _directory?.invalidated ?? false,
        loadMore: _directory?.loadMore ?? () async {},
        refresh: _directory?.refresh ?? () async {},
      ),
    );
  }

  /// 名单弹层的权威数据（web 由弹层自己拉 —— `LiveViewerSheet.tsx:44–79`）。
  ///
  /// 懒创建一次（`ref` 只在 build / initState 可用 ⇒ 不在字段初始化里取）。
  AylaLiveViewerSheetController _viewerSheetOf(String channelId) =>
      _viewerSheet ??= AylaLiveViewerSheetController()..addListener(_onChanged);
}
