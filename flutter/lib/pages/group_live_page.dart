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
///
/// ## 机制差异（登记）
/// 1. **开播入口**：web 用 `LiveStartSheet`（「选一个已有直播间开播 / 新建直播间」双入口，
///    tsx 153–162）；Flutter 侧该件未建 ⇒ 「创建群内直播」直接走**新建直播间**分支
///    （= web `handleCreateNewLive`，tsx 98–111：`createLiveChannel('新直播间', groupId)`
///    后跳开播控制台）。「选已有直播间」入口缺失，已登记。
/// 2. **`fromShare` 分支未接**（同语音页）：web 带 `location.state.fromShare` 免白名单校验。
/// 3. **`inputEntered`（无底栏下滑走的进房动画）**：Flutter 的 `AylaLiveRoomBody` 无该档，
///    由壳层决定底栏显隐（群路由本就不出底栏）⇒ 视觉结果一致。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/live_api.dart'
    show AylaDirectoryLiveEntry, AylaLiveApi, AylaLiveDanmaku, AylaLiveViewer;
import '../state/cursor_history.dart';
import '../state/favorite_status.dart';
import '../state/live_state.dart';
import '../state/paged_list.dart';
import '../state/room_providers.dart' show liveStateProvider, liveWsProvider;
import '../state/chat_providers.dart' show chatWsProvider;
import '../state/auth_state.dart' show AuthState, authNotifierProvider;
import '../core/models/share_payload.dart' show AylaSharePayload;
import '../theme/glass.dart' show AylaGlassButton, AylaGlassButtonVariant;
import '../widgets/base/directory_controls.dart' show AylaHistoryControlsData;
import '../widgets/base/directory_load_more.dart' show AylaDirectoryLoadMore;
import '../widgets/base/favorite_button.dart' show AylaFavoriteState;
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
import 'live_support.dart' show AylaLiveRoomSession;
import 'share_support.dart' show aylaOpenShareSheet, AylaShareController;

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
  AylaPagedList<AylaDirectoryLiveEntry>? _directory;
  AylaLiveRoomSession? _session;
  final AylaFavoriteStatusController _favorites = AylaFavoriteStatusController();
  final AylaShareController _share = AylaShareController();

  /// 当前直播间 id（null = 空态）。
  int? _currentId;
  /// 路由频道详情错误（web tsx 29）。
  String? _detailError;
  bool _creating = false;
  String? _createError;

  @override
  void initState() {
    super.initState();
    _favorites.addListener(_onChanged);
    _directory = AylaPagedList<AylaDirectoryLiveEntry>(
      request: (String? cursor) => AylaLiveApi.listLiveChannelsPage(
        cursor: cursor,
        groupId: widget.groupId,
      ),
      keyOf: (AylaDirectoryLiveEntry entry) => entry.card.id,
    )..addListener(_onChanged);
    unawaited(_directory!.load());
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
    _session = null;
    scheduleMicrotask(() {
      unawaited(session?.stop());
      session?.dispose();
    });
    _directory?.removeListener(_onChanged);
    _directory?.dispose();
    _favorites.removeListener(_onChanged);
    _favorites.dispose();
    _share.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
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
    )..addListener(_onChanged);
    _session = session;
    setState(() => _currentId = channelId);
    unawaited(session.start());
    _favorites.load('live', <String>['$channelId']);
  }

  Future<void> _createLive() async {
    setState(() {
      _creating = true;
      _createError = null;
    });
    try {
      final AylaLiveChannelSnapshot created =
          await AylaLiveApi.createLiveChannel('新直播间', group: widget.groupId);
      if (!mounted) return;
      context.go('/live/start/${created.id}');
    } catch (error) {
      if (!mounted) return;
      setState(() => _createError = error.toString());
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AylaPagedList<AylaDirectoryLiveEntry>? directory = _directory;
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
      // tsx 131–165：空态 + 「创建群内直播」（btn-glow）+ 「返回聊天」（ghost）。
      return AylaGroupScenePlaceholder(
        title: '群内还没有直播',
        description: '发起本群的第一场直播吧',
        actions: <Widget>[
          AylaGlassButton(
            label: '创建群内直播',
            variant: AylaGlassButtonVariant.glow,
            onPressed: _creating ? null : () => unawaited(_createLive()),
          ),
          AylaGlassButton(
            label: '返回聊天',
            variant: AylaGlassButtonVariant.ghost,
            onPressed: widget.onExit,
          ),
        ],
        children: <Widget>[
          if (_createError != null)
            Text(_createError!, textAlign: TextAlign.center),
        ],
      );
    }

    _enterRoom(currentId);
    return _buildRoom(context, currentId, channels);
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

    return AylaLiveRoomBody(
      channelId: '$channelId',
      isNarrow: !(MediaQuery.sizeOf(context).width > 768),
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
      ),
      onRetryPlayer: () => unawaited(session.retryPlayer()),
      onRefreshPlayer: () => unawaited(session.refreshPlayer()),
      onSendDanmaku: session.sendDanmaku,
      favoriteState: _favorites.stateOf('live', '$channelId') ==
          AylaFavoriteState.favorited,
      onToggleFavorite: (bool next) =>
          unawaited(_favorites.toggle('live', '$channelId')),
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
}
