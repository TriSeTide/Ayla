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
///
/// ## ⚠️ 切台 = **就地换会话**，不是重挂载（2026-11-02 用户实报「侧栏切换直播间跳变」）
/// 路由层的 Page key 已把 `/live/:id` 归一（`app_router.dart` 的
/// [kAylaLiveRoomPageKey]，等价 web `resolvePageKey('/live/:id') === '/live/room'`）
/// ⇒ 切台时本页**同一个 State 实例**被复用，只换 [LiveRoomPage.channelId]。
/// 于是「页面生命周期」这一层必须自己承担 web 里 `useLiveRoom` effect 的职责：
/// 旧会话完整销毁（`stop()` + `dispose()`，**不走 detachView 的小窗分支** ——
/// web 的 `enter()` 在切频道时先 `leave()` 完整销毁，再建新会话）、新会话 `start()`。
///
/// 不这么做会露出两处回归：① 会话仍是旧频道 ⇒ 画面/弹幕/在看人数全部不换；
/// ② 侧栏 `_directory` 若跟着页面重建 ⇒ 切一次台就重新拉一页目录（用户可见的「跳」）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/live_api.dart';
import '../core/platform/detached_live.dart' show aylaDetachedLivePlatformSupported;
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
    _session = _createSession(widget.channelId)..addListener(_onChanged);
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

  /// 新建一个直播会话（`initState` 与 `didUpdateWidget` 的切台路径共用）。
  ///
  /// 事实源：web `hooks/useLiveRoom.ts:71–84` 的 effect —— 会话参数取自
  /// `channelId` / `activityRoute`，两者任一变化就「cleanup 旧 + setup 新」。
  AylaLiveRoomSession _createSession(String channelId) => AylaLiveRoomSession(
    channelId: channelId,
    liveState: ref.read(liveStateProvider),
    liveWs: ref.read(liveWsProvider),
    chat: ref.read(chatWsProvider),
    // 点回直播间（小窗主体）的导航目标（web `LiveRoomBody` 的 activityRoute 缺省值）。
    activityRoute: '/live/$channelId',
    // 活动态索引的两个注入点（web 读 `useAuthStore.getState()`）：当前用户 id 决定
    // 「本会话是否为主播自己的会话」（`tracksOwnerActivity`），媒体活动位写在会话启停处。
    currentUserId: () => ref.read(authNotifierProvider).user?.id,
    onMediaActivity: (AylaMediaActivityKind kind, bool active, String? roomId) =>
        ref.read(authNotifierProvider.notifier).setMediaActivity(
      kind: kind,
      active: active,
      roomId: roomId,
    ),
  );

  /// 切台（路由 Page key 已归一 ⇒ **本方法**才是 web `useLiveRoom` effect 的等价物）。
  ///
  /// ## 为什么必须是「完整销毁 + 重建」，而不是 `detachView`
  /// web `liveSessionRuntime.enter()`（`:179–255`）在**切频道**分支先 `this.leave()`
  /// 完整销毁旧会话（播放器 / WS / store 全清），再建新会话；只有**同频道**重挂载才
  /// 保留会话（那条路径走 `putIsNarrow` 的小窗接管）。`detachView` 是「离开页面」
  /// （`:319–337`：窄屏直播中 ⇒ 进小窗），语义完全不同 —— 切台用它会弹出小窗。
  ///
  /// ## 为什么旧会话的销毁必须**排进 microtask**（2026-11-02 实测）
  /// `stop()` 的同步段就会 `liveStateProvider.clearCurrent()` ⇒ 那个 provider 的
  /// `notifyListeners`。而本方法由 [didUpdateWidget] 调用 —— 那时**正在 build** ⇒
  /// Riverpod 直接抛「Tried to modify a provider while the widget tree was building」
  /// （与 `dispose` 里把 `detachView` 排进 microtask 是同一个坑，见那边的注释）。
  /// 排进 microtask 后：本帧先用**新会话**重建完（`session` 已是新的），旧会话在
  /// 帧后的 microtask 里才清状态 —— 那时它已经不被任何人引用，清的是它自己留下的
  /// 那份旧投影，新会话的 `start()` 也有 `await Future.delayed(Duration.zero)` 让位，
  /// 因此不会互踩（与 web「cleanup 早于 setup」的顺序等价：都是旧会话先让出）。
  void _switchChannel(String channelId) {
    final AylaLiveRoomSession? previous = _session;
    previous?.removeListener(_onChanged);
    final AylaLiveRoomSession next = _createSession(channelId)..addListener(_onChanged);
    _session = next;
    // 旧会话：**不进小窗**，完整销毁（web `enter` 切频道分支的 `this.leave()` 同款）。
    if (previous != null) {
      scheduleMicrotask(() {
        unawaited(previous.stop().whenComplete(previous.dispose));
      });
    }
    // 名单弹层的缓存属于**上一个频道**（web 弹层卸载重挂后按 `[channelId]` 重新拉）
    // ⇒ 这里同样按新频道重建。它的 dispose 只摘监听、不碰 provider，可同步。
    _viewerSheet?.removeListener(_onChanged);
    _viewerSheet?.dispose();
    _viewerSheet = null;
    // `start()` 的同步段只置 `_alive` / `_epoch`（第一个语句就是
    // `await Future.delayed(Duration.zero)`）⇒ 在 didUpdateWidget 里调用安全。
    unawaited(next.start());
  }

  @override
  void didUpdateWidget(covariant LiveRoomPage old) {
    super.didUpdateWidget(old);
    // 侧栏切台 = 同一个页面实例换 `channelId`（路由 Page key 已归一，见文件头）。
    // ⚠️ 这里**不调用 setState**：本次 build 本来就会读到新的 `_session` 字段；
    // 在 didUpdateWidget 里再 setState 只会多排一帧。
    if (old.channelId != widget.channelId && _validId) _switchChannel(widget.channelId);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// 当前频道快照：**只认本页 `channelId` 那一份**，绝不回落到「别的频道」。
  ///
  /// ## 为什么不能用 `?? current`（2026-11-02 审计指出的 P1，已实测确认）
  /// 切台那一刻的事实与直觉相反：`live.currentChannel` **不是 null，而是上一个频道**。
  /// 因为旧会话的 `stop()` 被排进 microtask（见 [_switchChannel]），而新会话的
  /// `start()` 第一个语句就是 `await Future<void>.delayed(Duration.zero)`
  /// （`live_support.dart:383–433`：先让位再 `clearCurrent()`）
  /// ⇒ **didUpdateWidget 之后的那次 build 里，store 里躺的还是旧频道**。
  /// 写成 `channelOf(id) ?? current` 就会把旧快照递给头部/分享 ⇒ 标题、封面、主播、
  /// 来源标签先显示旧频道再跳成新的 —— 正是用户报的「跳一下」。
  ///
  /// 正确口径 = 优先 store 的 current（**但必须同 id**，它是最新的详情），否则用目录里
  /// 该频道的快照（用户就是从侧栏点进来的，目录里必然有）；两者都没有就返回 null，
  /// 让头部走「加载中…」档 —— 宁可短暂空档，也不显示别的直播间。
  AylaLiveChannelSnapshot? _channelOf(AylaLiveState live) {
    final AylaLiveChannelSnapshot? current = live.currentChannel;
    if (current != null && current.id == widget.channelId) return current;
    return live.channelOf(widget.channelId);
  }

  /// store 里「在看人数/预览」这份读数属于哪个频道（web `LiveRoomBody.tsx:125`）。
  String? _viewerOwnerId(AylaLiveState live) => live.currentChannel?.id;

  /// 侧栏列表：当前频道置顶（web tsx 32–33）。
  ///
  /// ⚠️ **只读 `channelOf(channelId)`**（之前多了一句 `?? currentChannel`）：切台后的
  /// 首次 build 里 `currentChannel` 仍是**上一个频道**（旧会话的 `stop()` 排在 microtask，
  /// 见 [_channelOf] 的说明）⇒ 会把旧频道当成当前项插到侧栏首位，切台后侧栏多出一个
  /// 不属于这里的条目、高亮也跟着错位。web 侧同样只认 `channel?.id === channelId`
  /// （`LiveRoomPage.tsx:32–33`）。
  List<AylaLiveCardData> _ordered() {
    final List<AylaDirectoryLiveEntry> items =
        _directory?.items ?? const <AylaDirectoryLiveEntry>[];
    final AylaLiveChannelSnapshot? current =
        ref.read(liveStateProvider).channelOf(widget.channelId);
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
    // ⚠️ 这里**不再**排帧贴底：消费 `pendingScrollToBottom` 的唯一 owner 是会话内的
    // `AylaHistoryScrollBinding`（见 `live_support.dart` 的 `danmakuScroll` 注释）。
    // 旧写法 `addPostFrameCallback(pumpScroll)` 有两个真错：① 页面不重建就没有下一次；
    // ② `pumpScroll` 先消费后判 `hasClients` ⇒ 列表未挂载时请求被吞（「永不滚底」根因）。
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
        channel: _channelOf(live),
        srsStatus: live.srsStatus,
        loading: live.currentLoading,
        error: live.currentError,
        playerError: live.currentPlayerError,
        // ⚠️ 切台后 `live.currentChannel` / `viewerCount` / `viewers` 都会有一个
        // 「旧会话已清、新会话详情未回」的窗口。web `LiveRoomBody.tsx:125–130` 给的
        // 口径是**按 id 校验**：`viewerOwnerId === channelId` 才用 store 的读数，否则
        // 退到 descriptor 里的快照值。原样照搬 —— 不校验会把上一个直播间的人数/头像
        // 短暂显示在新直播间上（同一类「跳变」）。
        viewerCount: _viewerOwnerId(live) == widget.channelId
            ? live.viewerCount
            : _channelOf(live)?.viewerCount,
        viewers: <AylaLiveViewerItem>[
          if (_viewerOwnerId(live) == widget.channelId)
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
        // `onDanmakuScroll` 不再需要：`AylaHistoryScrollBinding` 已直接监听同一个
        // `danmakuScroll`（web `useCursorHistory` 自己持 listRef ⇒ 天然同源）。
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
      // 「小窗」键：只在桌面端渲染 —— 用户原话「电脑需要点按钮使直播变为悬浮小窗，
      // 但手机退出直播间自动续直播悬浮小窗」⇒ 移动端保持既有的自动续接路径。
      onEnterMiniPlayer: aylaDetachedLivePlatformSupported &&
              defaultTargetPlatform == TargetPlatform.windows
          ? () => unawaited(session.enterDetachedPresentation())
          : null,
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
          // ⚠️ 用按 id 取的那份，不直接读 `currentChannel`：切台窗口期内它可能还是
          // 上一个直播间的标题/封面（web `LiveRoomBody.tsx:262–269` 用的也是外层
          // 传入的 `channel` prop，不是 store 的 current）。
          title: _channelOf(live)?.title ?? '直播间',
          cover: _channelOf(live)?.cover,
          ownerName: _channelOf(live)?.ownerNickname,
          groupId: _channelOf(live)?.group,
        ),
        controller: _share,
        currentUserId: selfId,
      )),
      videoView: session.videoView,
      videoAspectRatio: session.videoAspectRatio,
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

    // ⚠️⚠️ **必须是「恒包一层 + enabled 开关」，不能写成 narrow ? 包 : 不包**
    // —— 这是手机端「点全屏 ⇒ 横屏显示直播间页面 ⇒ 又回到竖屏」的**根因**（2026-10 实测）。
    //
    // 失败链（widget test 已复现：旋转前后 identical(state) 为 false）：
    //   ① 点全屏 ⇒ AylaLivePlayer 插 root Overlay 并 setPreferredOrientations(landscape)；
    //   ② 系统旋转 ⇒ MediaQuery 宽 > 768 ⇒ narrow 翻成 false；
    //   ③ 三元表达式在这一帧返回**类型不同的 Widget**（AylaFullScreenSwipeBack → body）
    //      ⇒ Flutter 无法复用 Element，**整棵 subtree 被销毁重建**；
    //   ④ _AylaLivePlayerState.dispose ⇒ _fsEntry.remove() + _unlockOrientation()
    //      ⇒ 全屏层被摘掉、屏幕解锁回竖屏 ⇒ 用户看到的正是「横屏一瞬 + 直播间页面 + 回竖屏」。
    //
    // web 侧不存在该缺陷：LiveRoomPage.tsx:66–75 是
    //   <FullScreenSwipeBack onBack enabled={isNarrow}><LiveRoomBody/></FullScreenSwipeBack>
    // —— **恒挂载**，只切 enabled（useEdgeSwipeBack 内部按它决定是否挂手势）
    // ⇒ React 始终复用同一个组件实例，旋转只改 props、不换类型。
    // Flutter 侧照抄同一形状即可：AylaFullScreenSwipeBack 的 build 在 !enabled 时
    // 直接返回 Transform.translate（等价无包裹），**语义与 web 完全一致**。
    return AylaFullScreenSwipeBack(
      // enabled={isNarrow}（tsx 66）：宽屏不挂右滑返回手势。
      enabled: narrow,
      // 返回：能回退就 pop（进房是 push），栈底回大厅。
      onBack: () => context.canPop() ? context.pop() : context.go('/live'),
      child: body,
    );
  }
}
