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
import '../state/display_status.dart' show presenceOnline;
import '../core/models/elysia_profile.dart' show AylaElysiaProfile;
import '../core/models/user_public.dart' show AylaUserPublic;
import '../state/presence_providers.dart' show presenceStateProvider;
import '../state/presence_state.dart' show AylaPresenceState;
import '../state/chat_providers.dart'
    show chatWsProvider, elysiaProfileProvider;
import '../state/live_state.dart';
import '../state/paged_list.dart';
import '../state/session_activity_state.dart';
import '../state/room_providers.dart';
import '../state/shell_state.dart';
import '../theme/app_theme.dart' show AylaTextStyles;
import '../theme/tokens.dart';
import '../widgets/base/directory_controls.dart'
    show AylaHistoryControlsData;
import '../widgets/base/directory_load_more.dart' show AylaDirectoryLoadMore;
import '../widgets/base/directory_page.dart' show aylaDirectoryIsNarrow;
import '../widgets/base/resource_image.dart' show mediaContentUrl;
import '../widgets/live/live_channel_snapshot.dart';
import '../widgets/live/live_hall.dart' show AylaLiveCardData, AylaLiveStatus;
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
  final AylaShareController _share = AylaShareController();

  /// 在看名单弹层的**权威数据子链**（web 是弹层内部自己拉 —— `LiveViewerSheet.tsx:44–65`
  /// 的 `getLiveChannelViewers` + `:67–79` 的 `getElysiaProfile`；Flutter 侧网络层不进
  /// `lib/widgets` ⇒ 由页面持有、经 [AylaLiveRoomBody.data.viewerSheet] 注入）。
  AylaLiveViewerSheetController? _viewerSheet;
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
    _session = AylaLiveRoomSession(
      channelId: widget.channelId,
      liveState: ref.read(liveStateProvider),
      liveWs: ref.read(liveWsProvider),
      chat: ref.read(chatWsProvider),
      // 点回直播间（小窗主体）的导航目标（web `LiveStudioPage.tsx:148`）。
      activityRoute: '/live/start/${widget.channelId}',
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
    _viewerSheet?.removeListener(_onChanged);
    _viewerSheet?.dispose();
    _viewerSheet = null;
    _share.dispose();
    scheduleMicrotask(() => _shell?.setBottomTabsLeaving(false));
    super.dispose();
  }

  /// 爱莉档案（web `LiveViewerSheet.tsx:67–79` 的 `getElysiaProfile()`；**失败静默**）。
  AylaElysiaProfile? _readElysiaProfile() =>
      ref.read(elysiaProfileProvider).valueOrNull;

  /// 名单弹层的权威数据（web 由弹层自己拉 —— `LiveViewerSheet.tsx:44–79`）。
  ///
  /// 懒创建一次（`ref` 只在 build / initState 可用 ⇒ 不在字段初始化里取）。
  AylaLiveViewerSheetController _viewerSheetOf(String channelId) =>
      _viewerSheet ??=
          AylaLiveViewerSheetController(elysiaReader: _readElysiaProfile)
            ..addListener(_onChanged);

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
      _syncLiveActivity(updated);
      unawaited(_session?.refreshSrsStatus(retryUntilLive: true));
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error is Exception ? '$error' : '操作失败');
    }
  }

  /// 开播/下播后的活动态同步（web `LiveOwnerPanel.tsx:44–68` 的 `run()`）。
  ///
  /// 逐条对齐 web：`active = updated.status === "live"`；
  /// - 开播 ⇒ 媒体活动位置真 + 索引 upsert（`sourceRoute` **沿用索引里已有的**，
  ///   否则用 `window.location.pathname`，Flutter 侧即本控制台路由）；
  /// - 下播 ⇒ 媒体活动位复位 + `clear("live", "idle")`（记录整条置空）。
  ///
  /// ⚠️ 这是**独立于** `AylaLiveRoomSession` 的第二条写入路径（web 同构）：
  /// 控制台的开播键不重建会话，会话的 `tracksOwnerActivity` 分支不覆盖它。
  void _syncLiveActivity(AylaLiveChannelSnapshot updated) {
    final bool active = updated.status == AylaLiveStatus.live;
    ref.read(authNotifierProvider.notifier).setMediaActivity(
          kind: AylaMediaActivityKind.live,
          active: active,
          roomId: active ? updated.id : null,
        );
    if (active) {
      final AylaActivityRecord? current = aylaSessionActivity.liveSession;
      aylaSessionActivity.upsert(
        AylaActivityRecord(
          kind: AylaActivityKind.live,
          sessionId: updated.id,
          sourceRoute:
              current?.sourceRoute ?? '/live/start/${widget.channelId}',
          owner: updated.ownerId,
          title: updated.title,
          status: AylaActivityStatus.connected, // web: status: "connected"
          lastError: null,
        ),
      );
    } else {
      aylaSessionActivity.clear(AylaActivityKind.live, AylaActivityStatus.idle);
    }
  }

  Future<void> _stopLive() async {
    try {
      final AylaLiveChannelSnapshot updated =
          await AylaLiveApi.stopLiveChannel(widget.channelId);
      if (!mounted) return;
      ref.read(liveStateProvider).upsertChannel(updated);
      _syncIntoDirectory(updated);
      _syncLiveActivity(updated);
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

  /// 返回键（web `LiveStudioPage.tsx:145` 的 `onBack={() => navigate(-1)}`）。
  ///
  /// ⚠️ **不得裸 `context.pop()`**（2026-10 收口）：`navigate(-1)` 在没有历史时是 no-op，
  /// 而 `GoRouter.pop()` 在栈底会抛 `GoError: There is nothing to pop`
  ///（`go_router-14.8.1/lib/src/delegate.dart:98–104`）—— 而本回调跑在按钮/手势里，
  /// 异常被吞掉 ⇒ 键看起来完全没反应。开播台可从「创建直播间」直接落进来
  /// （`_createChannel` 末尾 `context.replace('/live/start/${created.id}')`，**替换**当前路由
  /// ⇒ 栈只有一层），也可以从直播大厅 push 进来 ⇒ 两种栈深都要能正确返回。
  ///
  /// 栈底兜底 `/live`（直播大厅）：与同域 `live_room_page.dart:237 / :289–291` 一字不差
  /// （观看态返回键的同一口径），本页是直播域的页面，不回一级主页。
  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/live');
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

    // 弹幕头像实时在线（同 `live_room_page.dart` 的说明；web DanmakuList.tsx:40–46）。
    final AylaPresenceState presence = ref.watch(presenceStateProvider);
    bool senderOnlineOf(String userId) =>
        presenceOnline(presence.users, AylaUserPublic(id: userId));
    session.syncRealtimeToHistory();
    // 消费会话层的「贴底」请求（见 `AylaLiveRoomSession.pumpScroll` 的根因说明）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) session.pumpScroll();
    });

    if (listEmpty) {
      return AylaStudioEmpty(
        onCreateNewChannel: () => unawaited(_createChannel()),
        creating: _creating,
      );
    }

    // 名单弹层的权威数据（web 由弹层自身在打开时拉：`LiveViewerSheet.tsx:44–79`）
    final AylaLiveViewerSheetController viewerSheet =
        _viewerSheetOf(widget.channelId);

    final Widget body = AylaLiveRoomBody(
      channelId: widget.channelId,
      isNarrow: narrow,
      channels: _ordered(),
      showOwnerPanel: isOwner,
      // 弹层打开 → 页面发起同一次拉取（`LiveViewerSheet.tsx:44–65`）
      onOpenViewerSheet: () => viewerSheet.onOpen(widget.channelId),
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
        // 权威名单（web 弹层打开时自拉；Flutter 侧由页面持有、经本投影注入）
        viewerSheet: viewerSheet.value,
        danmaku: session.danmakuEntries(senderOnlineOf: senderOnlineOf),
        sending: session.sending,
        sendError: session.sendError,
        hasNewBelow: session.history?.hasNewer ?? false,
        danmakuController: session.danmakuScroll,
        onDanmakuScroll: session.handleDanmakuScroll,
        onScrollToBottom: () => unawaited(session.scrollDanmakuToBottom()),
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
      // 返回：能回退就 pop，栈底回直播大厅（见 [_back]）。
      onBack: _back,
      onDeleteChannel: isOwner ? (String id) => unawaited(_deleteChannel(id)) : null,
      onCreateNewChannel: isOwner ? () => unawaited(_createChannel()) : null,
      deletingChannelId: _deletingId,
      onRetryPlayer: () => unawaited(session.retryPlayer()),
      onRefreshPlayer: () => unawaited(session.refreshPlayer()),
      onSendDanmaku: session.sendDanmaku,
      // ⚠️ 根因 A（2026-10-08 修）：本页此前**建了页面级 `_favorites` 却从不调 `load`**
      // ⇒ 头部收藏键永远停在 unknown（禁用 +「正在加载收藏状态」），正是用户实报的
      // 「部分收藏键仍然无法点击…点刷新键又能点了」（刷新从别的路径把状态带进来）。
      // web 侧不存在这类接线缺口：`LiveRoomBody.tsx:260/328` 只给
      // `<FavoriteButton targetType="live" targetId={channel.id} compact />`，
      // 加载由收藏键自己和 `useFavoriteStatuses.ts:12–16` 承担。
      // ⇒ Flutter 侧同样改为**自给自足档**：收藏键自己 retain + load + toggle，
      // 页面级 `_favorites` 已随之删除（web 没有对应的页面级收藏状态）。
      favoriteTargetType: 'live',
      favoriteTargetId: widget.channelId,
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
          context.push('/user/${Uri.encodeComponent(item.userId)}'),
      // 头像导航（web `DanmakuList.tsx:52–58` 弹幕发送者 + `LiveHostAvatar.tsx:44–49` 主播）：
      // 语义 = `utils/navigation.ts:24–35` 的 goUserProfile（自己 → /profile，
      // 他人 → /user/:id，空 id 不跳）—— 复用名单弹层已实现的同一静态方法。
      onOpenSenderProfile: (String userId) =>
          AylaLiveViewerSheetController.openProfile(
            context,
            currentUserId: selfId,
            targetUserId: userId,
          ),
      onOpenHostProfile: (String ownerId) =>
          AylaLiveViewerSheetController.openProfile(
            context,
            currentUserId: selfId,
            targetUserId: ownerId,
          ),
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
        ? AylaFullScreenSwipeBack(onBack: _back, child: content)
        : content;
  }
}
