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
import '../state/display_status.dart' show presenceOnline;
import '../core/models/elysia_profile.dart' show AylaElysiaProfile;
import '../core/models/user_public.dart' show AylaUserPublic;
import '../state/presence_providers.dart' show presenceStateProvider;
import '../state/presence_state.dart' show AylaPresenceState;
import '../state/chat_providers.dart'
    show chatWsProvider, elysiaProfileProvider;
import '../state/cursor_history.dart';
import '../state/live_state.dart';
import '../state/paged_list.dart';
import '../state/room_providers.dart';
import '../state/shell_state.dart';
import '../widgets/base/directory_controls.dart'
    show AylaHistoryControlsData;
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
  final AylaShareController _share = AylaShareController();

  /// 在看名单弹层的**权威数据子链**（web 是弹层内部自己拉 —— `LiveViewerSheet.tsx:44–65`
  /// 的 `getLiveChannelViewers` + `:67–79` 的 `getElysiaProfile`；Flutter 侧网络层不进
  /// `lib/widgets` ⇒ 由页面持有、经 [AylaLiveRoomBody.data.viewerSheet] 注入）。
  AylaLiveViewerSheetController? _viewerSheet;

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
      // 点回直播间（小窗主体）的导航目标（web `LiveRoomBody` 的 activityRoute 缺省值）。
      activityRoute: '/live/${widget.channelId}',
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
      request: (String? cursor) =>
          AylaLiveApi.listLiveChannelsPage(cursor: cursor),
      keyOf: (AylaDirectoryLiveEntry entry) => entry.card.id,
    )..addListener(_onChanged);
    unawaited(_session!.start());
    unawaited(_directory!.load());
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
    _viewerSheet?.removeListener(_onChanged);
    _viewerSheet?.dispose();
    _viewerSheet = null;
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
    // 弹幕头像的**实时在线**判定（web `DanmakuList.tsx:40–46` 的
    // `presenceOnline(users, withLiveStatus(statuses, senderUser))`）。
    // 实报「头像的在线光环也不是正常显示在线的」：此前页面不传 `senderOnline` ⇒
    // `danmakuEntries()` 的默认 false 让所有弹幕头像恒灰环。
    // presence store 在 Riverpod 域 ⇒ 页面 watch 后把纯取值器注给会话。
    final AylaPresenceState presence = ref.watch(presenceStateProvider);
    bool senderOnlineOf(String userId) =>
        presenceOnline(presence.users, AylaUserPublic(id: userId));
    session.syncRealtimeToHistory();
    // 消费会话层的「贴底」请求：必须等**本帧布局完成**（新弹幕已在 items 里，
    // 但 maxScrollExtent 要下一次布局才更新）—— 见 `AylaLiveRoomSession.pumpScroll`。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) session.pumpScroll();
    });
    final AylaCursorHistory<AylaLiveDanmaku>? history = session.history;

    // 名单弹层的权威数据（web 由弹层自身在打开时拉：`LiveViewerSheet.tsx:44–79`）
    final AylaLiveViewerSheetController viewerSheet =
        _viewerSheetOf(widget.channelId);

    final Widget body = AylaLiveRoomBody(
      channelId: widget.channelId,
      isNarrow: narrow,
      channels: _ordered(),
      // 弹层打开 → 页面发起同一次拉取（`LiveViewerSheet.tsx:44–65`）
      onOpenViewerSheet: () => viewerSheet.onOpen(widget.channelId),
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
        danmaku: session.danmakuEntries(senderOnlineOf: senderOnlineOf),
        sending: session.sending,
        sendError: session.sendError,
        hasNewBelow: history?.hasNewer ?? false,
        // 贴底跟随 + 滚动上报 + 「有新弹幕 ↓」（web `useCursorHistory` 的
        // listRef / handleScroll / scrollToBottom 三件）。此前三件全未接线 ⇒
        // 新弹幕进了窗口但列表不动（2026-10-26 用户实报「大图弹幕后刷新不出来」）。
        danmakuController: session.danmakuScroll,
        onDanmakuScroll: session.handleDanmakuScroll,
        onScrollToBottom: () => unawaited(session.scrollDanmakuToBottom()),
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
      onSelect: _goTo,
      // 返回：能回退就 pop（进房是 push），栈底回大厅。
      onBack: () => context.canPop() ? context.pop() : context.go('/live'),
      onRetryPlayer: () => unawaited(session.retryPlayer()),
      onRefreshPlayer: () => unawaited(session.refreshPlayer()),
      onSendDanmaku: session.sendDanmaku,
      // 自给自足档（web `LiveRoomBody.tsx:260/328`：只给 targetType/targetId）——
      // 收藏键自己 retain + load + toggle；本页原先把这三个接线都写在页面里
      // （含 `initState` 的显式 `load`），随结构性修复一并删除 ——
      // web 的页面层**没有**收藏状态，只有收藏键自带的那一份。
      favoriteTargetType: 'live',
      favoriteTargetId: widget.channelId,
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
          context.push('/user/${Uri.encodeComponent(item.userId)}'),
      // 头像导航（web `DanmakuList.tsx:52–58` 弹幕发送者 + `LiveHostAvatar.tsx:44–49` 主播）：
      // 语义 = `utils/navigation.ts:24–35` 的 goUserProfile（自己 → /profile，
      // 他人 → /user/:id，空 id 不跳）—— 直接复用名单弹层已实现的同一静态方法。
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
            // 返回：能回退就 pop（进房是 push），栈底回大厅。
            onBack: () =>
                context.canPop() ? context.pop() : context.go('/live'),
            child: body,
          )
        : body;
  }
}
