/// 直播间页（路由 `/live/:channelId`）—— web `pages/LiveRoomPage.tsx`（75 行）的等价物。
///
/// ## 逐条对应
/// | 本页 | web tsx |
/// |---|---|
/// | 非法 id 回大厅 | 36–38（`replace: true`） |
/// | 底栏下滑走 | 41–45 |
/// | 侧栏范围 = **全部可见**直播间（分页 20）+ 当前频道置顶 | 31–33 |
/// | 靠近列表末尾时续读一页 | 47–50 |
/// | 切台 = `replace` 到 `/live/:id` | 52–55 |
/// | `FullScreenSwipeBack`（窄屏） | 61 |
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/live_api.dart';
import '../core/models/share_payload.dart' show AylaSharePayload;
import '../state/auth_state.dart';
import '../state/chat_providers.dart' show chatWsProvider;
import '../state/cursor_history.dart';
import '../state/favorite_status.dart';
import '../state/live_state.dart';
import '../state/paged_list.dart';
import '../state/room_providers.dart';
import '../state/shell_state.dart';
import '../widgets/base/directory_controls.dart'
    show AylaFavoriteState, AylaHistoryControlsData;
import '../widgets/base/directory_load_more.dart' show AylaDirectoryLoadMore;
import '../widgets/base/directory_page.dart' show aylaDirectoryIsNarrow;
import '../widgets/live/live_channel_snapshot.dart';
import '../widgets/live/live_hall.dart' show AylaLiveCardData;
import '../widgets/live/live_room_body.dart';
import '../widgets/live/live_viewers.dart' show AylaLiveViewerItem;
import '../widgets/motion/gestures.dart' show AylaFullScreenSwipeBack;
import 'live_support.dart';
import 'share_support.dart';

class LiveRoomPage extends ConsumerStatefulWidget {
  const LiveRoomPage({super.key, required this.channelId});

  /// 频道 id（路由 `:channelId`，int 语义；非法值回大厅）。
  final String channelId;

  @override
  ConsumerState<LiveRoomPage> createState() => _LiveRoomPageState();
}

class _LiveRoomPageState extends ConsumerState<LiveRoomPage> {
  /// shell UI notifier（initState 取出；dispose 里 `ref` 不可用）。
  ShellUiNotifier? _shell;
  AylaLiveRoomSession? _session;
  AylaPagedList<AylaDirectoryLiveEntry>? _directory;

  /// 最后一次 build 的窄屏判定（`dispose` 里读不到 MediaQuery ⇒ 在 build 里记下；
  /// 视图分离的「窄屏 + 直播中 ⇒ 进小窗」判定要用它，见 [AylaLiveRoomSession.detachView]）。
  bool _narrow = false;
  final AylaFavoriteStatusController _favorites = AylaFavoriteStatusController();
  final AylaShareController _share = AylaShareController();

  bool get _validId {
    final int? value = int.tryParse(widget.channelId);
    return value != null && value > 0;
  }

  @override
  void initState() {
    super.initState();
    if (!_validId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go('/live');
      });
      return;
    }
    _favorites.addListener(_onChanged);
    _session = AylaLiveRoomSession(
      channelId: widget.channelId,
      liveState: ref.read(liveStateProvider),
      liveWs: ref.read(liveWsProvider),
      chat: ref.read(chatWsProvider),
      // 点回直播间（小窗主体）的导航目标（web `LiveRoomBody` 的 activityRoute 缺省值）。
      activityRoute: '/live/${widget.channelId}',
    )..addListener(_onChanged);
    _directory = AylaPagedList<AylaDirectoryLiveEntry>(
      request: (String? cursor) =>
          AylaLiveApi.listLiveChannelsPage(cursor: cursor),
      keyOf: (AylaDirectoryLiveEntry entry) => entry.card.id,
    )..addListener(_onChanged);
    unawaited(_session!.start());
    unawaited(_directory!.load());
    _favorites.load('live', <String>[widget.channelId]);
    // shell notifier 必须在 initState 取好：`dispose 里 ref 不可用`
    // （实测 Riverpod 直接抛 “Cannot use ref after the widget was disposed”）。
    _shell = ref.read(shellUiProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _shell?.setBottomTabsLeaving(true);
    });
  }

  @override
  void dispose() {
    // ⚠️ 视图分离排进 microtask：`detachView` 的非小窗路径会清 `liveStateProvider`，
    // 而本页正是它的监听者 —— 在 dispose 内同步 notify 会打到已 defunct 的 element（见
    // `live_support.dart` 的 `detachView` 注释）。microtask 里 ref 已不可用 ⇒
    // 先把对象与窄屏判定取出来。
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
    _favorites.removeListener(_onChanged);
    _favorites.dispose();
    _share.dispose();
    scheduleMicrotask(() => _shell?.setBottomTabsLeaving(false));
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// 侧栏列表：当前频道置顶（web tsx 32–33）。
  List<AylaLiveCardData> _ordered() {
    final List<AylaDirectoryLiveEntry> items =
        _directory?.items ?? const <AylaDirectoryLiveEntry>[];
    final AylaLiveChannelSnapshot? current =
        ref.read(liveStateProvider).channelOf(widget.channelId) ??
            ref.read(liveStateProvider).currentChannel;
    final List<AylaLiveCardData> cards = <AylaLiveCardData>[
      for (final AylaDirectoryLiveEntry entry in items) entry.card,
    ];
    if (current != null && !cards.any((AylaLiveCardData c) => c.id == current.id)) {
      return <AylaLiveCardData>[current.card, ...cards];
    }
    return cards;
  }

  void _goTo(String id) {
    if (id == widget.channelId) return;
    context.replace('/live/$id');
  }

  @override
  Widget build(BuildContext context) {
    if (!_validId) return const SizedBox.shrink();
    final bool narrow = aylaDirectoryIsNarrow(context);
    _narrow = narrow; // dispose 的视图分离判定（见字段注释）
    final AylaLiveRoomSession? session = _session;
    if (session == null) return const SizedBox.shrink();
    final AylaLiveState live = ref.watch(liveStateProvider);
    final String? selfId = ref.watch(
      authNotifierProvider.select((AuthState s) => s.user?.id),
    );
    session.syncRealtimeToHistory();
    final AylaCursorHistory<AylaLiveDanmaku>? history = session.history;

    final Widget body = AylaLiveRoomBody(
      channelId: widget.channelId,
      isNarrow: narrow,
      channels: _ordered(),
      data: AylaLiveRoomData(
        channel: live.currentChannel ?? live.channelOf(widget.channelId),
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
      onSelect: _goTo,
      onBack: () => context.go('/live'),
      onRetryPlayer: () => unawaited(session.retryPlayer()),
      onRefreshPlayer: () => unawaited(session.refreshPlayer()),
      onSendDanmaku: session.sendDanmaku,
      onToggleFavorite: (bool next) =>
          unawaited(_favorites.toggle('live', widget.channelId)),
      // `AylaLiveRoomBody.favoriteState` 是 **bool?**（组件内映射到收藏键的 state 档）。
      favoriteState: _isFavorited(),
      onShare: () => unawaited(aylaOpenShareSheet(
        context,
        payload: AylaSharePayload.live(
          id: widget.channelId,
          title: live.currentChannel?.title ?? '直播间',
          cover: live.currentChannel?.cover,
          ownerName: live.currentChannel?.ownerNickname,
          groupId: live.currentChannel?.group,
        ),
        controller: _share,
        currentUserId: selfId,
      )),
      videoView: session.videoView,
      onOpenProfile: (AylaLiveViewerItem item) =>
          context.go('/user/${Uri.encodeComponent(item.userId)}'),
      directoryFooter: AylaDirectoryLoadMore(
        loading: _directory?.loading ?? false,
        error: _directory?.error,
        hasMore: _directory?.hasMore ?? false,
        invalidated: _directory?.invalidated ?? false,
        loadMore: _directory?.loadMore ?? () async {},
        refresh: _directory?.refresh ?? () async {},
      ),
    );

    return narrow
        ? AylaFullScreenSwipeBack(
            onBack: () => context.go('/live'),
            child: body,
          )
        : body;
  }

  /// 是否已收藏（web 收藏键 compact 的 state 档；unknown ⇒ false，与组件内映射一致）。
  bool _isFavorited() =>
      _favorites.stateOf('live', widget.channelId) ==
      AylaFavoriteState.favorited;
}
