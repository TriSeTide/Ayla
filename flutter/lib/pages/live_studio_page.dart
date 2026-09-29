/// 主播开播控制台（路由 `/live/start/:channelId`）—— web `pages/LiveStudioPage.tsx`（160 行）的等价物。
///
/// ## 逐条对应
/// | 本页 | web tsx |
/// |---|---|
/// | 侧栏 = **本人拥有的**直播间（`?owner=<me>`，分页 20） | 29（`useOwnedLiveDirectory`） |
/// | 当前频道更新 → 同步进侧栏并按新排序归位 | 53–61（`applyOrdered` + `sortLiveChannels`） |
/// | 删除（仅 owner）：`directory.invalidate` + `removeChannel` + 重拉首页 + 跳到相邻频道 | 73–101 |
/// | 新建：`createLiveChannel("新直播间")` → 插入侧栏头部 → 进新频道 | 103–114 |
/// | 列表空（已加载、无错、无更多）⇒ `live-studio-empty` 空态 + 创建键 | 118–135 |
/// | `showOwnerPanel` 仅 `channel.is_owner` | 147 |
/// | 底栏下滑走 | 67–71 |
///
/// ## 登记（有意偏离）
/// - web 的 `directory.updateItems` 在**当前分页表**内就地改；Flutter 的
///   `AylaPagedList.setItems` 同语义 ⇒ 逐条等价；
/// - web `directory={{...directory, onScroll}}` 是给侧栏注入「距底 240 续读」的滚动回调；
///   Flutter 侧由 `AylaLiveChannelRail` 自己滚动 ⇒ 分页续读挂在页脚槽
///   （`railDirectoryFooter`）上，滚动触发改由页脚可见性承担（同一语义，登记差异）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/chat_api.dart' show AylaChatApi;
import '../core/api/directory_page.dart' show AylaDirectoryPage;
import '../core/api/live_api.dart';
import '../core/media/media_actions.dart' show AylaMediaActions;
import '../core/models/conversation.dart' show AylaConversationSummary;
import '../core/models/share_payload.dart' show AylaSharePayload;
import '../state/auth_state.dart';
import '../state/chat_providers.dart' show chatWsProvider;
import '../state/favorite_status.dart';
import '../state/live_state.dart';
import '../state/paged_list.dart';
import '../state/room_providers.dart';
import '../state/shell_state.dart';
import '../theme/app_theme.dart' show AylaTextStyles;
import '../theme/tokens.dart';
import '../widgets/base/directory_controls.dart'
    show AylaFavoriteState, AylaHistoryControlsData;
import '../widgets/base/directory_load_more.dart' show AylaDirectoryLoadMore;
import '../widgets/base/directory_page.dart' show aylaDirectoryIsNarrow;
import '../widgets/base/resource_image.dart' show mediaContentUrl;
import '../widgets/live/live_channel_snapshot.dart';
import '../widgets/live/live_hall.dart' show AylaLiveCardData;
import '../widgets/live/live_studio.dart' show AylaStudioEmpty;
import '../widgets/live/live_viewers.dart' show AylaLiveViewerItem;
import '../widgets/live/live_owner_panel.dart' show AylaLiveOwnerSaveRequest;
import '../widgets/live/live_room_body.dart';
import '../widgets/motion/gestures.dart' show AylaFullScreenSwipeBack;
import 'hub_support.dart';
import 'live_support.dart';
import 'share_support.dart';

class LiveStudioPage extends ConsumerStatefulWidget {
  const LiveStudioPage({super.key, required this.channelId});

  /// 频道 id（路由 `:channelId`，int 语义；非法值回大厅）。
  final String channelId;

  @override
  ConsumerState<LiveStudioPage> createState() => _LiveStudioPageState();
}

class _LiveStudioPageState extends ConsumerState<LiveStudioPage> {
  /// shell UI notifier（initState 取出；dispose 里 `ref` 不可用）。
  ShellUiNotifier? _shell;
  AylaLiveRoomSession? _session;
  AylaPagedList<AylaDirectoryLiveEntry>? _directory;
  final AylaFavoriteStatusController _favorites = AylaFavoriteStatusController();
  final AylaShareController _share = AylaShareController();
  List<({String id, String title})> _groups = const <({String id, String title})>[];

  /// 最后一次 build 的窄屏判定与「主播控制台」判定（`dispose` 里读不到 MediaQuery /
  /// ref ⇒ 在 build 里记下）。控制台对应 web `useLiveRoom` 的 `isOwnerConsole`
  /// （`LiveRoomBody.tsx:117` `isOwnerConsole: showOwnerPanel`）—— 该档**不触发小窗**。
  bool _narrow = false;
  bool _ownerConsole = true;
  String? _deletingId;
  bool _creating = false;
  String? _actionError;

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
      // 点回直播间（小窗主体）的导航目标（web `LiveStudioPage.tsx:148`）。
      activityRoute: '/live/start/${widget.channelId}',
    )..addListener(_onChanged);
    _directory = AylaPagedList<AylaDirectoryLiveEntry>(
      request: (String? cursor) => AylaLiveApi.listLiveChannelsPage(
        cursor: cursor,
        owner: ref.read(authNotifierProvider).user?.id,
      ),
      keyOf: (AylaDirectoryLiveEntry entry) => entry.card.id,
    )..addListener(_onChanged);
    unawaited(_session!.start());
    unawaited(_directory!.load());
    unawaited(_loadGroups());
    // shell notifier 必须在 initState 取好：`dispose 里 ref 不可用`（见 LiveRoomPage 同注）。
    _shell = ref.read(shellUiProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _shell?.setBottomTabsLeaving(true);
    });
  }

  @override
  void dispose() {
    // ⚠️ 同 LiveRoomPage：会话销毁排进 microtask（在 dispose 内同步清共享状态会命中
    // 已 defunct 的 element —— 见 `live_support.dart` 的 `detachView` 注释）。
    _session?.removeListener(_onChanged);
    final AylaLiveRoomSession? session = _session;
    final bool narrow = _narrow;
    final bool ownerConsole = _ownerConsole;
    _session = null;
    scheduleMicrotask(() {
      // 视图分离：窄屏 + **非**主播控制台 + 直播中 ⇒ 进小窗；控制台档始终完整销毁
      // （web `useLiveRoom` 的 `isOwnerConsole` 语义，见 `live_support.dart` 的 detachView）。
      unawaited(
        session?.detachView(isNarrow: narrow, isOwnerConsole: ownerConsole),
      );
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

  /// 可⻅范围选择器用的群列表（web `LiveOwnerPanel` 的 `groups`；一次性有界读取）。
  Future<void> _loadGroups() async {
    try {
      final AylaDirectoryPage<AylaConversationSummary> page =
          await AylaChatApi.listConversationsPage(type: 'group', limit: 100);
      if (!mounted) return;
      setState(() {
        _groups = <({String id, String title})>[
          for (final AylaConversationSummary item in page.results)
            (id: item.id, title: item.title),
        ];
      });
    } catch (_) {
      // 拉不到群列表 ⇒ 控制台的可见范围选择器仍可用（白名单为空），不阻塞开播。
    }
  }

  /// 统一写入口：套直播新排序后写回侧栏（web `applyOrdered`）。
  void _applyOrdered(List<AylaDirectoryLiveEntry> next) {
    _directory?.setItems(aylaHubSortLive(next));
  }

  List<AylaLiveCardData> _ordered() => <AylaLiveCardData>[
        for (final AylaDirectoryLiveEntry entry
            in _directory?.items ?? const <AylaDirectoryLiveEntry>[])
          entry.card,
      ];

  void _goTo(String id) {
    if (id == widget.channelId) return;
    context.replace('/live/start/$id');
  }

  /// 保存资料（web `LiveOwnerPanel.tsx:83–100`）：换封面先上传，再 PATCH，最后用**后端回显**刷新。
  Future<AylaLiveChannelSnapshot?> _saveOwner(
    AylaLiveOwnerSaveRequest request,
  ) async {
    String? cover;
    if (request.coverFile != null) {
      final String mediaId =
          await AylaMediaActions.uploadImage(request.coverFile!);
      cover = mediaContentUrl(mediaId);
    }
    final AylaLiveChannelSnapshot updated =
        await AylaLiveApi.updateLiveChannel(
      widget.channelId,
      title: request.title,
      description: request.description,
      cover: cover,
      visibility: request.visibility,
      allowedGroupIds: request.allowedGroupIds,
    );
    if (!mounted) return updated;
    ref.read(liveStateProvider).upsertChannel(updated);
    _syncIntoDirectory(updated);
    return updated;
  }

  /// 当前频道快照 → 侧栏（web tsx 53–61：状态/时间戳变化后按新排序归位）。
  void _syncIntoDirectory(AylaLiveChannelSnapshot channel) {
    final bool isOwner = channel.ownerId == ref.read(authNotifierProvider).user?.id;
    final List<AylaDirectoryLiveEntry> items =
        _directory?.items ?? const <AylaDirectoryLiveEntry>[];
    if (!items.any((AylaDirectoryLiveEntry e) => e.card.id == channel.id)) return;
    _applyOrdered(<AylaDirectoryLiveEntry>[
      for (final AylaDirectoryLiveEntry entry in items)
        if (entry.card.id == channel.id)
          aylaHubLiveEntryFromSnapshot(channel, isOwner: isOwner)
        else
          entry,
    ]);
  }

  Future<void> _startLive() async {
    try {
      final AylaLiveChannelSnapshot updated =
          await AylaLiveApi.startLiveChannel(widget.channelId);
      if (!mounted) return;
      ref.read(liveStateProvider).upsertChannel(updated);
      _syncIntoDirectory(updated);
      unawaited(_session?.refreshSrsStatus(retryUntilLive: true));
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error is Exception ? '$error' : '操作失败');
    }
  }

  Future<void> _stopLive() async {
    try {
      final AylaLiveChannelSnapshot updated =
          await AylaLiveApi.stopLiveChannel(widget.channelId);
      if (!mounted) return;
      ref.read(liveStateProvider).upsertChannel(updated);
      _syncIntoDirectory(updated);
      unawaited(_session?.refreshSrsStatus());
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error is Exception ? '$error' : '操作失败');
    }
  }

  /// 删除频道（web tsx 73–101）：删成功后就地重排 + 重拉一页 + 跳到相邻频道。
  Future<void> _deleteChannel(String targetId) async {
    setState(() => _deletingId = targetId);
    try {
      await AylaLiveApi.deleteLiveChannel(targetId);
      if (!mounted) return;
      final AylaPagedList<AylaDirectoryLiveEntry>? directory = _directory;
      final AylaLiveChannelSnapshot? removed =
          ref.read(liveStateProvider).channelOf(targetId);
      ref.read(liveStateProvider).removeChannel(targetId);
      if (removed != null) {
        final List<AylaDirectoryLiveEntry> mine = <AylaDirectoryLiveEntry>[
          for (final AylaDirectoryLiveEntry entry
              in directory?.items ?? const <AylaDirectoryLiveEntry>[])
            if (entry.card.id != targetId) entry,
        ];
        _applyOrdered(mine);
        await directory?.refresh();
      }
      if (!mounted) return;
      if (targetId == widget.channelId) {
        final List<AylaDirectoryLiveEntry> mine =
            _directory?.items ?? const <AylaDirectoryLiveEntry>[];
        if (mine.isNotEmpty) {
          context.replace('/live/start/${mine.first.card.id}');
        }
      }
    } catch (_) {
      // 删除失败静默（web tsx 96–98）
    } finally {
      if (mounted) setState(() => _deletingId = null);
    }
  }

  /// 新建直播间（web tsx 103–114）。
  Future<void> _createChannel() async {
    if (_creating) return;
    setState(() => _creating = true);
    try {
      final AylaLiveChannelSnapshot created =
          await AylaLiveApi.createLiveChannel('新直播间');
      if (!mounted) return;
      ref.read(liveStateProvider).upsertChannel(created);
      _applyOrdered(<AylaDirectoryLiveEntry>[
        aylaHubLiveEntryFromSnapshot(created, isOwner: true),
        for (final AylaDirectoryLiveEntry entry
            in _directory?.items ?? const <AylaDirectoryLiveEntry>[])
          if (entry.card.id != created.id) entry,
      ]);
      if (!mounted) return;
      context.replace('/live/start/${created.id}');
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error is Exception ? '$error' : '创建失败');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_validId) return const SizedBox.shrink();
    final bool narrow = aylaDirectoryIsNarrow(context);
    final AylaLiveRoomSession? session = _session;
    if (session == null) return const SizedBox.shrink();
    final AylaLiveState live = ref.watch(liveStateProvider);
    final String? selfId = ref.watch(
      authNotifierProvider.select((AuthState s) => s.user?.id),
    );
    final AylaLiveChannelSnapshot? channel =
        live.currentChannel ?? live.channelOf(widget.channelId);
    final bool isOwner = channel?.isOwner ?? false;
    _narrow = narrow; // dispose 的视图分离判定（见字段注释）
    _ownerConsole = isOwner;
    final AylaPagedList<AylaDirectoryLiveEntry>? directory = _directory;
    final bool listEmpty = directory != null &&
        directory.loaded &&
        !directory.loading &&
        directory.error == null &&
        !directory.hasMore &&
        directory.items.isEmpty;

    session.syncRealtimeToHistory();

    if (listEmpty) {
      return AylaStudioEmpty(
        onCreateNewChannel: () => unawaited(_createChannel()),
        creating: _creating,
      );
    }

    final Widget body = AylaLiveRoomBody(
      channelId: widget.channelId,
      isNarrow: narrow,
      channels: _ordered(),
      showOwnerPanel: isOwner,
      data: AylaLiveRoomData(
        channel: channel,
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
        hasNewBelow: session.history?.hasNewer ?? false,
        history: session.history == null
            ? null
            : AylaHistoryControlsData(
                loading: session.history!.loading,
                error: session.history!.error,
                hasMore: session.history!.hasMore,
                hasNewer: session.history!.hasNewer,
                loadOlder: session.history!.loadOlder,
                returnLatest: session.history!.returnLatest,
                retry: session.history!.retry,
              ),
      ),
      onSelect: _goTo,
      onBack: () => context.pop(),
      onDeleteChannel: isOwner ? (String id) => unawaited(_deleteChannel(id)) : null,
      onCreateNewChannel: isOwner ? () => unawaited(_createChannel()) : null,
      deletingChannelId: _deletingId,
      onRetryPlayer: () => unawaited(session.retryPlayer()),
      onRefreshPlayer: () => unawaited(session.refreshPlayer()),
      onSendDanmaku: session.sendDanmaku,
      onToggleFavorite: (bool next) =>
          unawaited(_favorites.toggle('live', widget.channelId)),
      // `AylaLiveRoomBody.favoriteState` 是 **bool?**（组件内映射到收藏键的 state 档）。
      favoriteState: _favorites.stateOf('live', widget.channelId) ==
          AylaFavoriteState.favorited,
      onShare: () => unawaited(aylaOpenShareSheet(
        context,
        payload: AylaSharePayload.live(
          id: widget.channelId,
          title: channel?.title ?? '直播间',
          cover: channel?.cover,
          ownerName: channel?.ownerNickname,
          groupId: channel?.group,
        ),
        controller: _share,
        currentUserId: selfId,
      )),
      videoView: session.videoView,
      onOpenProfile: (AylaLiveViewerItem item) =>
          context.go('/user/${Uri.encodeComponent(item.userId)}'),
      onSaveOwner: _saveOwner,
      onStartLive: _startLive,
      onStopLive: _stopLive,
      groups: _groups,
      railDirectoryFooter: AylaDirectoryLoadMore(
        loading: directory?.loading ?? false,
        error: directory?.error,
        hasMore: directory?.hasMore ?? false,
        invalidated: directory?.invalidated ?? false,
        loadMore: directory?.loadMore ?? () async {},
        refresh: directory?.refresh ?? () async {},
      ),
    );

    final Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_actionError != null)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AylaSpacing.sp4,
              vertical: AylaSpacing.sp2,
            ),
            child: Text(_actionError!, style: AylaTextStyles.of(context).body),
          ),
        Expanded(child: body),
      ],
    );

    return narrow
        ? AylaFullScreenSwipeBack(onBack: () => context.pop(), child: content)
        : content;
  }
}
