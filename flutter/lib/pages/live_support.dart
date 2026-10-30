/// 直播会话层 —— web `runtime/liveSessionRuntime.ts`（589 行）+ `hooks/useLiveRoom.ts`（123 行）
/// + `hooks/useDanmaku.ts`（105 行）的 Flutter 等价物。
///
/// ## 小窗宿主（2026-09-29 接线：窄屏小窗宿主批次）
/// 「窄屏离开直播间页且直播中 ⇒ 开小窗」与「直播结束 / 主动关闭 ⇒ 清小窗」两条语义落在本文件：
/// - [detachView] 判定窄屏 + 非主播控制台 + SRS = live + 无播放器 fatal ⇒ [AylaLiveRoomSession._enterMiniPlayer]
///   （web `liveSessionRuntime.ts:299–317`）；会话所有权移交全局小窗宿主 [aylaMiniPlayerOwner]，
///   由 `layout/app_shell.dart` 渲染的 `AylaLiveMiniPlayer` 继续持有（不销毁播放器）；
/// - [AylaLiveRoomSession.refreshSrsStatus] 在小窗模式下读到非 live ⇒ 完整销毁
///   （web `:533–537`）；[aylaCloseLiveMiniPlayer] = 小窗关闭键的完整销毁（web
///   `LiveMiniPlayer.tsx:93–96` → `liveSessionRuntime.leave()`），幂等。
///
/// ## 与 web 的结构差异（**有意偏离，登记**）
/// web 的会话资源（HLS 播放器 / SRS 状态 / 弹幕 WS / **video 元素**）挂在全局单例上，
/// video 是**同一个 DOM 元素**在容器间原子迁移 ⇒ 大窗↔小窗零黑屏、不断流。
/// Flutter 的平台视图（`video_player` / `media_kit`）不能跨树迁移 ⇒ 本类仍是**页面级**实例：
/// - 离开房间页进小窗 = 同一会话实例被小窗宿主继续持有（播放器不 destroy、不重新 attach）；
/// - 「点回直播间」在 Flutter 侧必然新建页面级会话（web 是同频道幂等复用同一会话）⇒
///   小窗让位时旧会话被完整销毁、播放器重新 attach（**登记偏离**：这一段切换会有一次重连）。
///
/// ## 保留的 web 语义（逐条）
/// | 本类 | web |
/// |---|---|
/// | [start] 拉详情 + SRS 判定 + 连弹幕 WS + 补一次在看人数 | `liveSessionRuntime.ts:237–291` |
/// | [refreshSrsStatus] 事件驱动补拉 + 开播后**有界退避**（2s→4s→8s，最多 3 次） | `498–584` |
/// | [refreshViewers] 只在"还没读到"时写（不让人数倒退） | `548–565` |
/// | 弹幕帧 → 队列；在看人数帧 → 人数 + 预览 | `194–216` |
/// | `live.channel.status.changed` → 补拉 `/status/` | `509–522` |
/// | WS 重连 → 历史失效 + 补拉 SRS + 补拉人数 | `224–230` |
/// | 发送**不乐观插入**（等 WS 回帧，单一数据流） | `useDanmaku.ts:4–5 / 90–93` |
/// | `playerError` 冷却期外**自动重建**（黑屏自愈） | `404–417` + `hls_player.dart` 的自愈状态机 |
/// | [detachView] 窄屏 + 直播中 ⇒ 进小窗；否则完整销毁 | `299–317` |
/// | [refreshSrsStatus] 小窗模式下非 live ⇒ 自动关闭小窗 | `533–537` |
/// | [aylaCloseLiveMiniPlayer] 关闭键 = 完整销毁（幂等） | `LiveMiniPlayer.tsx:93–96` |
library;

import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../core/api/elysia_api.dart' show AylaElysiaApi;
import '../core/api/live_api.dart';
import '../core/models/elysia_profile.dart' show AylaElysiaProfile;
import '../core/net/dio_client.dart' show ApiException;
import '../core/net/live_play_url.dart' show aylaNormalizeLivePlayUrl;
import '../core/platform/detached_live.dart';
import '../core/ws/chat_ws.dart';
import '../core/ws/live_ws.dart';
import '../player/hls_player.dart';
import '../player/platforms/hls_platform.dart';
import '../state/auth_state.dart' show AylaMediaActivityKind;
import '../state/cursor_history.dart';
import '../widgets/base/history_scroll_binding.dart'
    show AylaHistoryScrollBinding;
import '../state/live_state.dart';
import '../state/session_activity_state.dart';
import '../widgets/live/danmaku.dart' show AylaDanmakuEntry;
import '../widgets/live/live_viewers.dart'
    show AylaLiveViewerItem, AylaLiveViewerSheetData;
import '../widgets/live/live_hall.dart' show AylaLiveStatus;
import '../widgets/live/live_channel_snapshot.dart';
import '../widgets/live/live_player.dart' show AylaLiveSrsStatus;

/// 开播事件后 SRS 状态补拉的退避基数（web `SRS_RETRY_BASE_MS`）。
const int kLiveSrsRetryBaseMs = 2000;

/// 补拉次数上限（web `SRS_RETRY_MAX`）。
const int kLiveSrsRetryMax = 3;

/// 进房快照写入的预览上限（web `LIVE_VIEWER_PREVIEW` = 12）。
const int kLiveViewerPreview = 12;

/// 频道详情读取（注入点；默认 [AylaLiveApi.getLiveChannel]）。
typedef AylaLiveChannelFetcher = Future<AylaLiveChannelSnapshot> Function(
  String channelId,
);

/// SRS 实时判定读取（注入点；默认 [AylaLiveApi.getLiveChannelStatus]）。
typedef AylaLiveStatusFetcher = Future<AylaLiveStatusResult> Function(
  String channelId,
);

/// 在看人数快照读取（注入点；默认 [AylaLiveApi.getLiveChannelViewers]）。
typedef AylaLiveViewersFetcher = Future<AylaLiveViewersResult> Function(
  String channelId,
);

/// 「进入脱离态」的平台动作签名（默认实现 = [aylaEnterDetachedLive]）。
typedef AylaDetachedEnterFn = Future<bool> Function({
  required String channelId,
  required String title,
  String? playUrl,
  Rect? videoRect,
});

/// 「关闭脱离呈现」的平台动作签名（默认实现 = [aylaCloseDetachedLive]）。
typedef AylaDetachedCloseFn = Future<void> Function();

/// 「同步是否在直播中」的平台动作签名（默认实现 = [aylaSetLivePipSessionActive]）。
typedef AylaDetachedSessionActiveFn = Future<void> Function(bool active);

/// 「当前是否在系统画中画里」的探测签名（默认实现 = [aylaIsInLivePip]）。
typedef AylaDetachedInPipFn = Future<bool> Function();

/// 直播「脱离应用」的三个平台动作（**唯一**默认实现 = `core/platform/detached_live.dart`）。
///
/// 抽出这一层的唯一理由是**可测**：会话语义（何时进/出脱离态、何时必须撤销原生武装）
/// 必须能用假实现断言，而不是真的去调 MethodChannel。生产代码不要注入别的实现。
class AylaDetachedLivePresenter {
  const AylaDetachedLivePresenter({
    this.enter = aylaEnterDetachedLive,
    this.close = aylaCloseDetachedLive,
    this.setSessionActive = aylaSetLivePipSessionActive,
    this.isInPip = aylaIsInLivePip,
  });

  final AylaDetachedEnterFn enter;
  final AylaDetachedCloseFn close;
  final AylaDetachedSessionActiveFn setSessionActive;
  final AylaDetachedInPipFn isInPip;
}

/// 直播会话 owner（页面级；见文件头「与 web 的结构差异」）。
class AylaLiveRoomSession extends ChangeNotifier {
  AylaLiveRoomSession({
    required this.channelId,
    required AylaLiveState liveState,
    required AylaLiveWsClient liveWs,
    AylaChatWsClient? chat,
    HlsPlaybackController Function()? playerFactory,
    String? activityRoute,
    AylaLiveChannelFetcher? channelFetcher,
    AylaLiveStatusFetcher? statusFetcher,
    AylaLiveViewersFetcher? viewersFetcher,
    /// 当前用户 id（web `useAuthStore.getState().currentUser?.id`；用于
    /// `tracksOwnerActivity = channel.owner_id === currentUser.id`）。
    ///
    /// 注入式而不是在会话层引 Riverpod：本类被既有测试与画布样张直接构造，
    /// 且 web 侧读的就是 auth store 的**当前值**（非订阅）。默认 null = 恒不追踪
    /// ⇒ 不写活动态索引（既有测试因此不受影响，索引也不会被造出来）。
    String? Function()? currentUserId,
    /// 媒体活动位写入（web `useAuthStore.getState().setMediaActivity`）。默认 null = 不写。
    void Function(AylaMediaActivityKind kind, bool active, String? roomId)?
        onMediaActivity,
    /// 「脱离应用」的平台动作（默认走真实通道；测试注入假实现）。
    AylaDetachedLivePresenter detached = const AylaDetachedLivePresenter(),
  })  : _detachedPresenter = detached,
        _live = liveState,
        _ws = liveWs,
        _chat = chat,
        _currentUserId = currentUserId,
        _onMediaActivity = onMediaActivity,
        activityRoute = activityRoute ?? '/live/$channelId',
        _fetchChannel = channelFetcher ?? AylaLiveApi.getLiveChannel,
        _fetchStatus = statusFetcher ?? AylaLiveApi.getLiveChannelStatus,
        _fetchViewers = viewersFetcher ?? AylaLiveApi.getLiveChannelViewers {
    // ⚠️ `HlsPlayerCallbacks` 是**字段式回调容器**（先建实例再挂回调；同 PoC 形态）。
    _player = (playerFactory ?? _defaultPlayerFactory)();
  }

  /// 频道 id（int 语义，字符串传输以对齐 Flutter 全链路的 id 类型）。
  final String channelId;

  /// 点回直播间时导航的目标路由（web `LiveRoomBody` 的 `activityRoute` prop：
  /// 一级直播 `/live/:id`、群内直播 `/group/:id/live`、开播控制台 `/live/start/:id`）。
  final String activityRoute;

  final AylaLiveState _live;
  final AylaLiveWsClient _ws;
  final AylaChatWsClient? _chat;

  /// 当前用户 id 读取（见构造参数）；null = 不追踪活动态。
  final String? Function()? _currentUserId;

  /// 媒体活动位写入（见构造参数）；null = 不写。
  final void Function(AylaMediaActivityKind kind, bool active, String? roomId)?
      _onMediaActivity;

  /// 「脱离应用」的平台动作（见构造参数）。
  final AylaDetachedLivePresenter _detachedPresenter;

  /// 活动态索引归属：本会话是否为**频道 owner 的会话**（web `tracksOwnerActivity`）。
  ///
  /// web `liveSessionRuntime.ts:243` 在进房详情返回后判定
  /// `channel.owner_id === useAuthStore.getState().currentUser?.id`，
  /// **只有主播自己的会话**才 upsert / setStatus / clear 活动态索引（观众不进悬浮球）。
  bool _tracksOwnerActivity = false;

  /// 三个数据读取注入点（默认走 [AylaLiveApi] 的真实端点）。
  final AylaLiveChannelFetcher _fetchChannel;
  final AylaLiveStatusFetcher _fetchStatus;
  final AylaLiveViewersFetcher _fetchViewers;

  late final HlsPlaybackController _player;

  /// 弹幕可见历史窗口（web `useDanmaku` 的 `useCursorHistory`）。
  AylaCursorHistory<AylaLiveDanmaku>? _history;

  int _epoch = 0;
  bool _alive = false;
  /// 视图分离是否已处理（[detachView] 幂等）。
  bool _viewDetached = false;
  Timer? _srsRetry;
  int _srsRetryCount = 0;
  bool _sending = false;
  String? _sendError;
  final Set<String> _renderedFrameIds = <String>{};
  void Function()? _frameOff;
  void Function()? _chatOff;

  /// 播放器当前是否已挂载（`/status/` = live 时才挂）。
  bool _playerAttached = false;

  bool get alive => _alive;
  int get epoch => _epoch;

  /// 缺省播放器工厂（注入点见构造参数 [playerFactory]）。
  HlsPlaybackController _defaultPlayerFactory() {
    final HlsPlayerCallbacks callbacks = HlsPlayerCallbacks();
    callbacks.onStateChange = _onPlayerState;
    callbacks.onError = (String detail) {
      // web `liveSessionRuntime.ts:470–474`：播放错误 ⇒ 写 playerError + 补拉一次
      // SRS 判定（可能 degraded/idle）；黑屏/卡死的**重建**由 `hls_player.dart`
      // 的自愈状态机承担（kStallTimeoutMs / kRebuildCooldownMs）。
      _live.setCurrentPlayerError(detail);
      unawaited(refreshSrsStatus());
    };
    return HlsPlaybackController(createHlsPlatformPlayer, callbacks);
  }

  /// 播放器状态变化 → 重新投影（`videoView` 由播放器状态驱动）。
  void _onPlayerState(HlsState state) {
    if (_disposed) return;
    notifyListeners();
  }
  HlsPlaybackController get player => _player;

  /// 视频视图（页面注入 [AylaLiveRoomBody.videoView]）。
  Widget? get videoView => _playerAttached ? _player.videoView : null;

  /// 弹幕历史窗口（页面装配 [AylaHistoryControlsData] 用）。
  AylaCursorHistory<AylaLiveDanmaku>? get history => _history;

  /// 弹幕历史窗口的变更是否已转发给本会话的监听者（幂等守卫）。
  bool _historyRelayed = false;

  /// 把 [AylaCursorHistory] 的通知**转发到会话本体**。
  ///
  /// ## 为什么必须转发（2026-10-26 第二轮实报的真正根因）
  /// 用户复报「还是刷不出来，而且**已经出现『有新弹幕』和『返回最新消息』，
  /// 点它们却完全没反应**」—— 这条现象直接锁定根因：
  ///
  /// `AylaCursorHistory` 是 `ChangeNotifier`，`returnLatest()` / `append()` 都会
  /// `notifyListeners()`，**但三个直播页面全都没有 `addListener` 它**
  /// （页面只监听 `_session` / `_directory` / `_viewerSheet`）。
  /// ⇒ 数据确实更新了，**却没有任何人触发重绘** ⇒ 界面永远停在旧快照上：
  /// 1. 新弹幕 append 后列表不动（`hasNewer` 还亮起，因为那一次 notify 也没人接）；
  /// 2. 点「返回最新消息」→ `returnLatest()` 成功、`items` 已替换、`hasNewer` 已清，
  ///    **但页面不重建** ⇒ 视觉上「点了没反应」，且提示条因为不重绘而仍挂在那里。
  ///
  /// 转发到会话本体即可：页面本来就 `_session.addListener(_onChanged)`，
  /// 一处转发同时喂饱三个页面（一级直播间 / 开播控制台 / 群内直播）。
  void _relayHistory() {
    final AylaCursorHistory<AylaLiveDanmaku>? history = _history;
    if (history == null || _historyRelayed) return;
    _historyRelayed = true;
    history.addListener(_onHistoryChanged);
  }

  void _onHistoryChanged() {
    if (!_disposed) notifyListeners();
  }

  /// 弹幕列表滚动控制器（页面注入给 [AylaDanmakuList.controller]）。
  ///
  /// ## 为什么需要它（2026-10-26 用户实报「直播间弹幕新消息不自动滚底」+
  /// 「返回底部和有新消息的跳转不工作」）
  ///
  /// web 的 `useCursorHistory` **同时持有数据与滚动容器**（`listRef`），并在
  /// `useLayoutEffect` 里消费 `pendingScroll` 贴底（`useCursorHistory.ts:67–78`）；
  /// 滚动时用 `handleScroll` 维护 `following`（同文件 159–164）。
  ///
  /// Flutter 侧 [AylaCursorHistory] 只有数据（`pendingScrollToBottom` 只置位）⇒
  /// 消费端必须由 owner 提供。此前这里是**手写的 `pumpScroll()`**，有两个真错：
  /// 1. **先 `consumeScrollToBottom()` 再判 `hasClients`** —— 列表尚未挂载
  ///    （进房 loading / 播放器占位）时请求被**吞掉**，之后没有任何东西再触发
  ///    ⇒ 表现为「永远不自动滚底，退出重进才好」；
  /// 2. 消费时机挂在**页面 build 的 post-frame**（三个页面各写一份）—— 页面不重建
  ///    就没有下一次消费；且 `returnLatest()` 返回时本帧布局还是旧高度，
  ///    立刻 `jumpTo(max)` 跳的是旧 max ⇒ 「点了返回最新没反应」。
  ///
  /// ⇒ 现在统一交给 [AylaHistoryScrollBinding]（唯一 owner，见该文件头）：
  /// 它监听 history + controller，列表未挂载时**保留** pending，贴底后连跟几帧
  /// 覆盖「旧高度」窗口。页面不再需要 `addPostFrameCallback(pumpScroll)`。
  final ScrollController danmakuScroll = ScrollController();

  /// 弹幕历史窗口 ↔ 滚动控制器的绑定（web `useCursorHistory` 的 listRef 三件套）。
  AylaHistoryScrollBinding<AylaLiveDanmaku>? _scrollBinding;

  /// 建 history 后立刻绑定（见 [start]）；重复调用幂等。
  void _bindScroll() {
    final AylaCursorHistory<AylaLiveDanmaku>? history = _history;
    if (history == null) return;
    _scrollBinding ??= AylaHistoryScrollBinding<AylaLiveDanmaku>(
      history: history,
      controller: danmakuScroll,
    )..bind();
  }

  /// 卸载绑定（[dispose] 用；控制器本身也归会话，一并释放）。
  void _unbindScroll() {
    _scrollBinding?.dispose();
    _scrollBinding = null;
  }

  /// 点「有新弹幕 ↓」= web `useDanmaku.ts:62–67` 的 `scrollToBottom`：
  /// 有更新（窗口脱挂）⇒ 重新读最新一页；否则直接贴底 + 重新跟随。
  Future<void> scrollDanmakuToBottom() async {
    final AylaCursorHistory<AylaLiveDanmaku>? history = _history;
    if (history == null) return;
    if (history.hasNewer) {
      // 窗口已脱挂：重新读最新一页（成功后 hasNewer 清除、items 替换，
      // 且 `_load(older:false)` 会置 `pendingScrollToBottom`）。
      final bool ok = await history.returnLatest();
      if (!ok || !_alive) return;
    }
    // ⚠️ 不能在 `returnLatest()` 后立刻手算 `jumpTo(max)`：此刻 items 已换但
    // **本帧布局仍是旧高度** ⇒ 跳到旧 max、新内容留在视口下方
    // （用户实报「点了『有新弹幕』还是停在旧位置」）。
    // `jumpToBottom()` 内部会连跟 [kAylaHistorySettleFrames] 帧，覆盖这个窗口。
    _scrollBinding?.jumpToBottom();
  }

  /// 列表是否**当前**贴底（web `useCursorHistory.ts:159–164`）。
  /// 未挂载/未布局 ⇒ `false`（不伪造）。
  bool get danmakuAtBottom => _scrollBinding?.isAtBottom ?? false;
  bool get sending => _sending;
  String? get sendError => _sendError;

  /// 进房（幂等：同频道重复调用只重建 epoch；web `enter` 的等价物）。
  Future<void> start() async {
    _alive = true;
    _epoch += 1;
    // ⚠️ **先让出一轮事件循环**：页面在 `initState` 里调本方法，而下面第一件事就是
    // 清共享状态 —— Riverpod 禁止在 build/initState/dispose 期间修改 provider
    // （实测 “Tried to modify a provider while the widget tree was building”）。
    await Future<void>.delayed(Duration.zero);
    // 小窗让位（web `enter` 的同频道分支 + `LiveMiniPlayer` 卸载）：本会话接管前，先完整
    // 销毁仍挂在 AppShell 上的旧小窗会话 —— Flutter 的平台视图不能跨树迁移、复用不了旧 session
    // （文件头「与 web 的结构差异」已登记该偏离）。
    await _retireMiniPlayerOwner();
    // 本会话接管页面视图（[detachView] 的代际防御用：迟到的旧会话不得再进小窗）。
    _activeViewSession = this;
    final AylaLiveState store = _live;
    store.clearCurrent();
    store.setCurrentLoading(true);
    store.setCurrentError(null);
    store.setCurrentPlayerError(null);

    // 弹幕历史窗口（owner = live-history:<uid>:<channelId> 由页面注入 selfId？——
    // 这里用频道 id 单段（Flutter 侧页面重建即重置，无跨 uid 复用面）。
    _history = AylaCursorHistory<AylaLiveDanmaku>(
      owner: 'live-history:$channelId',
      fetchPage: (String? cursor, String? beforeId) =>
          AylaLiveApi.listDanmakuPage(
        channelId,
        cursor: cursor,
        beforeId: beforeId,
      ),
      idOf: (AylaLiveDanmaku item) => item.id,
      createdAtOf: (AylaLiveDanmaku item) => item.createdAt,
    );
    // ⚠️ **必须**把历史窗口的通知转发到会话本体（本文件 [_relayHistory] 的根因说明）。
    // 漏这一步 ⇒ 数据更新但页面不重绘 ⇒ 「新弹幕不刷」「点返回最新没反应」两个实报。
    _relayHistory();
    // 绑定滚动控制器：此后「新弹幕贴底」由 binding 独占消费（web useCursorHistory 的
    // listRef + useLayoutEffect 同构）。⚠️ 必须在 reset() **之前**绑定 ——
    // reset() 会先置 pendingScrollToBottom（首屏贴底），binding 若晚建就错过那一次
    // （虽然 binding.bind() 会补排一次消费，但先绑语义更直白）。
    _bindScroll();
    unawaited(_history!.reset());

    // 弹幕 / 在看人数帧 → 状态（web `liveSessionRuntime.ts:194–216`）。
    _frameOff = _ws.onFrame(_onFrame);
    _ws.onConnectionChange = (AylaLiveWsConnection conn) =>
        _live.setWsConnection(conn);
    _ws.onClosedByServer = (AylaLiveWsCloseReason reason) {
      if (!_alive) return;
      if (reason == AylaLiveWsCloseReason.unauthorized) {
        _live.setCurrentError('登录已过期，请重新登录');
      } else if (reason == AylaLiveWsCloseReason.channelNotFound) {
        _live.setCurrentError('直播间不存在');
      }
    };
    // WS 无补发语义：重连后提示历史补读 + 补拉 SRS 判定与在看人数。
    _ws.onReconnected = () {
      if (!_alive) return;
      _history?.invalidate();
      unawaited(refreshSrsStatus());
      unawaited(refreshViewers());
    };
    // `live.channel.status.changed` → 补拉 SRS 实时判定（web `subscribeStatusEvents`）。
    _chatOff = _chat?.onFrame((Map<String, dynamic> frame) {
      if (frame['type'] != 'live.channel.status.changed') return;
      final Object? raw = frame['data'];
      if (raw is! Map) return;
      final Map<String, dynamic> data = Map<String, dynamic>.from(raw);
      if (data['channel_id']?.toString() != channelId) return;
      unawaited(refreshSrsStatus(
        retryUntilLive: data['status']?.toString() == 'live',
      ));
    });

    await _enterAsync();
  }

  Future<void> _enterAsync() async {
    final AylaLiveState store = _live;
    try {
      final AylaLiveChannelSnapshot channel = await _fetchChannel(channelId);
      if (!_alive) return;
      store.setCurrentChannel(channel);
      // 归属判定（web `liveSessionRuntime.ts:243`）：只有**主播自己**的会话维护活动态索引。
      _tracksOwnerActivity =
          _currentUserId?.call() != null && channel.ownerId == _currentUserId?.call();
      // 活动态索引 upsert（web `:244–255`）。`sourceRoute` 的既有分支逐条照抄：
      // 已经在索引里且是同一频道 ⇒ 沿用**原来的** sourceRoute（用户是从哪个入口进的
      // 就回哪个入口），否则用本会话的 `activityRoute`（群内直播 = 群场景路由）。
      if (_tracksOwnerActivity) {
        final AylaActivityRecord? existing = aylaSessionActivity.liveSession;
        final String activityTarget = existing != null &&
                existing.sessionId == channel.id
            ? existing.sourceRoute
            : activityRoute;
        aylaSessionActivity.upsert(
          AylaActivityRecord(
            kind: AylaActivityKind.live,
            sessionId: channel.id,
            sourceRoute: activityTarget,
            owner: channel.ownerId,
            title: channel.title,
            status: AylaActivityStatus.connecting, // web: status: "connecting"
            lastError: null,
          ),
        );
      }
      final AylaLiveStatusResult status = await _fetchStatus(channelId);
      if (!_alive) return;
      store.setSrsStatus(status.status);
      // 「开播即武装」：把在播事实同步给原生，API 31+ 才能按 Home 自动进画中画。
      await _syncPipSessionActive();
      // 活动态索引状态改写（web `:270–277`）：
      // `status.status === "live" || current.channel?.status === "live" ? "connected" : "ended"`
      // —— 两个判据是**或**关系（SRS 实时判定与频道描述里的乐观状态，任一为 live 即算接通）。
      if (_tracksOwnerActivity) {
        final bool connected = status.status == AylaLiveSrsStatus.live ||
            store.currentChannel?.status == AylaLiveStatus.live;
        aylaSessionActivity.setStatus(
          AylaActivityKind.live,
          connected ? AylaActivityStatus.connected : AylaActivityStatus.ended,
        );
      }
      _ws.connect(channelId);
      // 在看人数权威快照（必须晚于 setCurrentChannel —— setViewers 只认当前直播间）。
      unawaited(refreshViewers());
      if (status.status == AylaLiveSrsStatus.live) {
        await _attachPlayer();
      }
      store.setCurrentLoading(false);
    } catch (error) {
      if (!_alive) return;
      final String message = error is Exception ? '$error' : '加载直播间失败';
      store.setCurrentError(message);
      // 活动态索引：进房失败 ⇒ failed + 原因（web `:282–287`）。无该 kind 记录时
      // `setStatus` 静默返回（web 同款）。
      if (_tracksOwnerActivity) {
        aylaSessionActivity.setStatus(
          AylaActivityKind.live,
          AylaActivityStatus.failed,
          lastError: message,
        );
      }
      store.setCurrentLoading(false);
    }
  }

  void _onFrame(Map<String, dynamic> frame) {
    final Object? rawType = frame['type'];
    if (rawType == 'viewers') {
      final String id = frame['channel_id']?.toString() ?? '';
      if (id.isNotEmpty && id != channelId) return; // 切台竞态防御
      final int count = (frame['count'] as num?)?.toInt() ?? 0;
      final List<AylaLiveViewer> viewers = <AylaLiveViewer>[
        for (final Object? item
            in (frame['viewers'] as List<Object?>? ?? const <Object?>[]))
          if (AylaLiveViewer.fromJson(item) case final AylaLiveViewer v) v,
      ];
      _live.setViewers(channelId, count, viewers);
      return;
    }
    if (rawType != 'danmaku') return;
    final AylaLiveDanmaku? item = AylaLiveDanmaku.fromFrameJson(frame);
    if (item == null) return;
    _live.appendDanmaku(item);
  }

  /// 实时弹幕队列 → 历史窗口（页面渲染用；页面在监听里调用）。
  ///
  /// web `useDanmaku.ts:56–60`：把实时队列里**本批没见过的** id append 进历史
  /// （历史本身不写回 overlay 队列）。
  void syncRealtimeToHistory() {
    final AylaCursorHistory<AylaLiveDanmaku>? history = _history;
    if (history == null) return;
    for (final AylaLiveDanmaku item in _live.danmaku) {
      if (_renderedFrameIds.add(item.id)) history.append(item);
    }
  }

  /// 补拉一次 SRS 实时判定（事件触发；**非周期轮询**）。
  Future<void> refreshSrsStatus({bool retryUntilLive = false}) async {
    try {
      final AylaLiveStatusResult status = await _fetchStatus(channelId);
      if (!_alive) return;
      _live.setSrsStatus(status.status);
      // 实时判定变了 ⇒ 同步原生「按 Home 是否该自动进画中画」（幂等；非 Android 平台 no-op）。
      await _syncPipSessionActive();
      // 小窗模式下直播结束 → **自动关闭小窗**（完整销毁，避免小窗挂着已结束的流）。
      // 逐条对照 web `liveSessionRuntime.ts:533–537`：`if (miniPlayer && status !== "live") leave()`。
      // 判定用「本会话是否即小窗宿主」（Flutter 侧 owner 的唯一性由 [aylaMiniPlayerOwner] 保证）。
      if (_ownsMiniPlayer && status.status != AylaLiveSrsStatus.live) {
        await stop();
        dispose();
        return;
      }
      if (status.status == AylaLiveSrsStatus.live) {
        _clearSrsRetry();
        await _attachPlayer();
      } else {
        await _detachPlayer();
        if (retryUntilLive) _scheduleSrsRetry();
      }
    } catch (_) {
      // 补拉失败不打断（下次事件再试）；SRS 不可用时后端自身返回 degraded
    }
  }

  /// 在看人数快照（进房 / WS 重连各读一次，非周期轮询）。
  ///
  /// presence 存储不可用（503）⇒ 保持"未知"（**不写 0**）—— 读不到 ≠ 没人在看。
  Future<void> refreshViewers() async {
    try {
      final AylaLiveViewersResult page = await _fetchViewers(channelId);
      if (!_alive) return;
      final AylaLiveState store = _live;
      if (store.currentChannel?.id == channelId && store.viewerCount != null) {
        return;
      }
      store.setViewers(
        channelId,
        page.count,
        page.viewers.take(kLiveViewerPreview).toList(growable: false),
      );
    } catch (_) {
      // 503（presence 不可用）/ 403 / 404：保持未知
    }
  }

  void _scheduleSrsRetry() {
    if (_srsRetry != null || _srsRetryCount >= kLiveSrsRetryMax) return;
    final int delay = kLiveSrsRetryBaseMs * (1 << _srsRetryCount);
    _srsRetryCount += 1;
    _srsRetry = Timer(Duration(milliseconds: delay), () {
      _srsRetry = null;
      unawaited(refreshSrsStatus(retryUntilLive: true));
    });
  }

  void _clearSrsRetry() {
    _srsRetry?.cancel();
    _srsRetry = null;
    _srsRetryCount = 0;
  }

  /// 挂载播放器（幂等：同 URL 不重建，见 `hls_player.dart` 的 attach 幂等）。
  Future<void> _attachPlayer() async {
    final AylaLiveChannelSnapshot? channel = _live.currentChannel;
    final String? raw = channel?.hlsUrl;
    if (raw == null || raw.isEmpty) return;
    // 播放地址归一到 API 同源（快照层已归一；这里再兜一次，防注入快照绕过）。
    // 背景见 `core/net/live_play_url.dart`：后端下发的独立拉流入口在部分网络下
    // TLS 握手被中间设备重置 ⇒ 原生播放器黑屏（web 走浏览器栈不受影响）。
    final String url = aylaNormalizeLivePlayUrl(raw);
    _live.setCurrentPlayerError(null);
    _playerAttached = true;
    await _player.attach(url);
    if (!_disposed) notifyListeners();
  }

  Future<void> _detachPlayer() async {
    if (!_playerAttached) return;
    _playerAttached = false;
    await _player.destroy();
    if (!_disposed) notifyListeners();
  }

  /// 播放失败重试（web `retryPlayer` = 重建播放器）。
  Future<void> retryPlayer() async {
    _live.setCurrentPlayerError(null);
    final String? raw = _live.currentChannel?.hlsUrl;
    if (raw == null || raw.isEmpty) return;
    final String url = aylaNormalizeLivePlayUrl(raw);
    _playerAttached = true;
    // 用人手重试路径（`retry` 会重置自动重建计数；否则封顶后手动重试也会立刻报错）。
    await _player.retry(url);
    if (!_disposed) notifyListeners();
  }

  /// 左下角刷新键：健康播放**跳边**、黑屏/实例缺失重建兜底（web `refreshPlayer`）。
  Future<void> refreshPlayer() async {
    if (_playerAttached && _player.state == HlsState.playing) {
      await _player.refreshToLiveEdge();
      return;
    }
    await retryPlayer();
  }

  /// 发送弹幕（**成功不乐观插入** —— 等服务端广播的 WS 回帧，单一数据流）。
  Future<bool> sendDanmaku(String content, String? mediaId) async {
    final String trimmed = content.trim();
    if (trimmed.isEmpty && (mediaId == null || mediaId.isEmpty)) {
      _sendError = '弹幕不能为空';
      notifyListeners();
      return false;
    }
    if (trimmed.length > 200) {
      _sendError = '弹幕长度不能超过 200 字';
      notifyListeners();
      return false;
    }
    _sending = true;
    _sendError = null;
    notifyListeners();
    try {
      await AylaLiveApi.sendDanmaku(
        channelId,
        content: trimmed.isEmpty ? '图片' : trimmed,
        mediaId: mediaId,
      );
      return _alive;
    } catch (error) {
      _sendError = error is Exception ? '$error' : '发送失败';
      notifyListeners();
      return false;
    } finally {
      if (_alive) {
        _sending = false;
        notifyListeners();
      }
    }
  }

  // ==================== 脱离应用（Android PiP / Windows 独立小窗）====================

  /// 是否已进入「脱离应用」的呈现态（原生已接管画面）。
  bool _detached = false;
  bool get detached => _detached;

  /// 是否值得让**原生侧**武装「按 Home 自动进画中画」。
  ///
  /// 判据与 web/Flutter 的「在播」语义同源：会话存活 + SRS 判定为 live。
  /// 不用 `_playerAttached` 作判据 —— 播放器可能因黑屏自愈重建，而观看登记不该跟着抖。
  bool get _wantsAutoPip => _alive && _live.srsStatus == AylaLiveSrsStatus.live;

  /// 把「是否在直播中」同步给原生（幂等；Dart 侧非 Android 平台自动 no-op）。
  ///
  /// ⚠️ **漏传 false 是这个特性唯一的失败模式**：原生若一直武装着
  /// `setAutoEnterEnabled`，用户在任何页面按 Home 都会弹出画中画。
  /// 因此 [stop]/[dispose] 两条路径都必须调用 [clearDetachedPresentation]。
  Future<void> _syncPipSessionActive() async {
    await _detachedPresenter.setSessionActive(_wantsAutoPip);
  }

  /// 请求进入「脱离应用」的呈现（小窗上的脱离键 / 会话菜单的入口都会走这里）。
  ///
  /// - Android：进系统画中画。**必须由用户手势调用**（`enterPictureInPictureMode()`
  ///   只在 Activity RESUMED 时可用，从生命周期回调里调必抛 IllegalStateException）；
  /// - Windows：打开独立置顶小窗（task-4 的原生实现）。
  ///
  /// 返回 true = 原生已接管；false = 本平台不支持 / 原生失败 ⇒ **调用方必须回落到
  /// App 内小窗**，不能静默什么都不做。
  ///
  /// ⚠️ 这里**不销毁会话**：脱离态下弹幕 WS / HLS 继续跑（Android PiP 是同一 Activity、
  /// 同一 engine），所以「小窗观看直播也算观看人」天然成立。
  /// [videoRect]：视频画面在屏幕上的全局矩形（小窗自己知道自己画在哪，比页面注入更准）。
  /// 传 null 时退回 [attachVideoRectProvider] 注入的读取器，仍为 null 则由原生自己猜转场起点。
  Future<bool> enterDetachedPresentation({Rect? videoRect}) async {
    if (!_alive) return false;
    if (_detached) return true; // 幂等：已经在脱离态
    // 「第二个窗口」从 2026-11-01 起 **Android 也有**：直播小窗改成系统叠加层里的
    // 第二引擎（用户：「新的删掉，用我原来的窗口」），不再是同一 Activity 的 PiP。
    // ⇒ 两边都要订阅窗口生命周期，也都要停掉主引擎那一路播放（避免同一路流解两遍：
    //   流量翻倍 + 音频叠两个）。
    final bool secondWindow = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.android);
    if (secondWindow) _bindDetachedWindowLifecycle();
    final bool ok = await _detachedPresenter.enter(
      channelId: channelId,
      title: _live.currentChannel?.title ?? '直播间',
      // 归一后的 HLS 地址（带鉴权 query）：Windows 的第二个 engine 没有登录态，
      // 只能靠 URL 自证；Android 侧当前用不到，但同一个契约入口必须给它。
      playUrl: _detachedPlayUrl(),
      videoRect: videoRect ?? detachedVideoRect(),
    );
    if (ok) {
      _detached = true;
      // ⚠️ **两个平台都要停主窗口那一路播放**（2026-11-01 起 Android 也是第二引擎）：
      // 小窗现在是**独立叠加层里的第二个 Flutter engine + 第二个 HLS 播放器**
      // （Windows = media_kit，Android = video_player），不停就会两路音频叠在一起。
      //
      // 历史（已作废，勿照旧注释改回去）：2026-10 之前 Android 走系统 PiP，
      // 画中画显示的就是**本 Activity 本 engine** 的那张画面，那时绝不能停；
      // 现在 Android 不再走 PiP，那条约束不再成立。
      //
      // 弹幕 WS / 在看登记**不受影响**（它们不依赖播放器实例）⇒ 小窗观看仍算观看人。
      if (secondWindow) await _suspendMainPlayerForDetached();
      // 原生已接管：把「在播」事实再同步一次（进入 PiP 后 onResume 不会再走一遍武装）。
      await _syncPipSessionActive();
      if (!_disposed) notifyListeners();
    }
    return ok;
  }

  /// 关闭「脱离应用」的呈现（回到 App 内小窗）。幂等。
  ///
  /// Android 的 PiP 只能由系统收起（用户点 × / 上滑消失），这里只复位本会话的投影；
  /// Windows 会真的关掉那个独立窗口。**不销毁会话**。
  Future<void> closeDetachedPresentation() async {
    if (!_detached) return;
    _detached = false;
    await _detachedPresenter.close();
    // ⚠️ **不能只 close 就走**：原生侧「被 Dart 要求关闭」的那条路径**故意不回调**
    // `onLiveWindowClosed`（关窗是 Dart 自己发起的，回传只会绕一圈）。
    // 于是 [_resumeMainPlayerAfterDetached] 就没人调 —— 主窗口这一路播放器会一直停在
    // 被挂起的状态，直到会话结束都是黑屏。所以这里必须自己把交接做完。
    if (_alive) await _resumeMainPlayerAfterDetached();
    if (!_disposed) notifyListeners();
  }

  /// 彻底撤销「脱离应用」相关的原生状态（[stop] / [dispose] 的收尾，幂等）。
  ///
  /// 两件事都必须做：① 会话结束 ⇒ 原生**必须**撤销自动进 PiP 的武装；
  /// ② 若仍在脱离态，关掉那个呈现（Windows 的独立窗口 / 复位 PiP 投影）。
  Future<void> clearDetachedPresentation() async {
    _detached = false;
    await _detachedPresenter.setSessionActive(false);
    await _detachedPresenter.close();
    // 与 [closeDetachedPresentation] 同理：原生不会回 `onLiveWindowClosed`，
    // 若不复位「已挂起」标志，下一次 [enterDetachedPresentation] 会带着错的基线
    // 去判断「要不要恢复」，恢复路径就永远不被触发（会话重启后第一次脱离即黑屏）。
    _resetDetachedWindowBridge();
  }

  // ---- Windows 独立窗口 ↔ 主窗口的画面所有权移交 -----------------------------

  /// 是否已挂上「独立窗口关闭」的监听（幂等）。
  bool _detachedLifecycleBound = false;

  /// 主窗口这一路播放器是否被「脱离态」主动停掉（用于回来时精确恢复）。
  bool _playerSuspendedForDetached = false;

  StreamSubscription<AylaDetachedLiveEvent>? _detachedEventsSub;

  /// 监听原生事件里的窗口生命周期（只消费 `liveWindowClosed`）。
  void _bindDetachedWindowLifecycle() {
    if (_detachedLifecycleBound) return;
    _detachedLifecycleBound = true;
    _detachedEventsSub = AylaDetachedLiveEvents.instance.stream
        .listen(_onDetachedLiveEvent);
  }

  void _onDetachedLiveEvent(AylaDetachedLiveEvent event) {
    if (event.kind != AylaDetachedLiveEventKind.liveWindowClosed) return;
    if (_disposed) return;
    _onDetachedWindowClosed();
  }

  /// 独立直播窗口没了（用户关掉 / 点画面回主窗口）⇒ 主窗口重新接管画面。
  ///
  /// **不销毁会话**（弹幕 WS / 观看登记一直在跑）；页面已卸载时顺带登记 App 内小窗。
  void _onDetachedWindowClosed() {
    final bool wasDetached = _detached;
    _detached = false;
    // Android 的「小窗」就是那个系统叠加层窗口本身（2026-11-01 起不再走 PiP），
    // **没有**「App 内小窗」这个承接面：重新登记小窗投影只会让 AppShell 把
    // 叠加层窗口立刻再开一遍（关不掉）。⇒ 窗口关掉 == 用户不看了，按 web
    // `LiveMiniPlayer.tsx:93–96` 的口径完整销毁会话（X 键与点卡片回 App 同一条路径）。
    final bool overlayOnly = !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android;
    if (_alive) {
      if (overlayOnly) {
        if (wasDetached) {
          unawaited(stop().whenComplete(dispose));
          return;
        }
      } else {
        unawaited(_resumeMainPlayerAfterDetached());
        // Windows：「回到 App 内小窗」复用既有路径。只在**页面已经卸载**时登记小窗投影：
        // 用户就站在直播间页里时画面由页面自己的 videoView 接管，再挂一层小窗
        // 投影会多出一个盖在页面上的浮层。
        if (wasDetached && !identical(_activeViewSession, this)) {
          _enterMiniPlayer();
        }
      }
    }
    if (!_disposed) notifyListeners();
  }

  /// 停掉主窗口这一路播放（Windows 进入脱离态时）。
  ///
  /// 只动播放器，不动 `_alive` / WS / 历史窗口 ⇒ 在看名单与心跳不受影响。
  Future<void> _suspendMainPlayerForDetached() async {
    // App 内小窗的投影也要收起：独立窗口已经在放同一路直播，主窗口再挂一个
    // 黑框小窗只会挡视线（而且它的 videoView 随下面的 destroy 变 null）。
    if (_ownsMiniPlayer) {
      _miniPlayerOwner = null;
      if (!_live.isDisposed) _live.setMiniPlayer(null);
    }
    if (!_playerAttached) return;
    _playerSuspendedForDetached = true;
    _playerAttached = false;
    await _player.destroy();
  }

  /// 独立窗口关闭后重新接管（只在确实被 [enterDetachedPresentation] 停过时才重建）。
  ///
  /// 幂等：没挂起过就什么都不做（Android PiP 路径根本不会进入这里 ——
  /// 那边 `_suspendMainPlayerForDetached()` 从不被调用，标志恒为 false）。
  Future<void> _resumeMainPlayerAfterDetached() async {
    if (!_playerSuspendedForDetached) return;
    _playerSuspendedForDetached = false;
    if (!_alive || _playerAttached) return;
    if (_live.currentPlayerError != null) return;
    await _attachPlayer();
  }

  /// 复位「独立窗口」的桥接状态（终止路径调用；随会话一起作废）。
  ///
  /// ⚠️ 标志不清会让复用同一会话的下一次脱离带着错的基线：
  /// `_playerSuspendedForDetached` 残留 true ⇒ 下次进脱离态时
  /// `_suspendMainPlayerForDetached` 的 `_playerAttached` 判定与恢复路径互相打架。
  void _resetDetachedWindowBridge() {
    _playerSuspendedForDetached = false;
    _detachedEventsSub?.cancel();
    _detachedEventsSub = null;
    _detachedLifecycleBound = false;
  }

  /// 传给原生小窗的播放入口（归一后；无地址时 null）。
  String? _detachedPlayUrl() {
    final String? raw = _live.currentChannel?.hlsUrl;
    if (raw == null || raw.isEmpty) return null;
    return aylaNormalizeLivePlayUrl(raw);
  }

  /// 视频画面在**屏幕上的全局矩形**（Android 的 `sourceRectHint`：转场动画从画面处
  /// 长出来，不传的话系统会自己猜、动画很难看）。
  ///
  /// 拿不到就返回 null（契约允许），由调用方通过 [attachVideoRectProvider] 注入；
  /// 会话层自己不持有 RenderObject，也不去 `context.findRenderObject()`。
  Rect? detachedVideoRect() => _videoRectProvider?.call();

  /// 视频 global rect 的取值器（页面注入；null = 未知，原生自己猜转场起点）。
  Rect? Function()? _videoRectProvider;

  /// 注入视频 global rect 读取器（幂等；页面在首帧后接上）。
  void attachVideoRectProvider(Rect? Function() provider) {
    _videoRectProvider = provider;
  }

  /// 本会话当前是否为小窗宿主（唯一 owner 判定）。
  bool get _ownsMiniPlayer => identical(_miniPlayerOwner, this);

  /// 视图分离（页面卸载）：**窄屏 + 普通观看 + 直播中** ⇒ 进入小窗（会话所有权移交小窗宿主，
  /// 播放器不销毁、不重新 attach）；否则完整销毁并回收本会话。
  ///
  /// 逐条对照 web `liveSessionRuntime.ts:299–317`（`detachView`）：
  /// `isNarrow && !isOwnerConsole && channelId !== null && current.srsStatus === "live"
  /// && currentPlayerError === null` ⇒ `enterMiniPlayer()`，否则 `leave()`。
  /// 宽屏不开小窗（web 只在 `AppShell.tsx:132` 的 `isNarrow` 渲染小窗）。
  ///
  /// ⚠️ **调用时机**：页面必须把它排进 microtask（见 `live_room_page.dart` 的 dispose）。
  /// 为什么：本方法（非小窗路径）会清共享状态并 notify，而直播间页面正是
  /// `liveStateProvider` 的监听者 —— 在 `State.dispose()` 内**同步** notify 会在
  /// 已 defunct 的 element 上 `markNeedsBuild`（实测断言：
  /// `_lifecycleState != _ElementLifecycle.defunct`）。microtask 在整棵树的卸载
  /// 同步段之后执行，那时 Riverpod 已把监听注销，清状态即安全。
  ///
  /// `viewEpoch`：调用方持有的会话代际（`enter` 返回值）；与当前不一致 ⇒ 会话已被更新的
  /// 视图接管，**既不销毁也不进小窗**（web 同款代际防御）。
  Future<void> detachView({
    int? viewEpoch,
    bool isNarrow = false,
    bool isOwnerConsole = false,
  }) async {
    if (viewEpoch != null && viewEpoch != _epoch) return;
    // 会话已被更晚的 start 接管 / 已销毁（小窗让位、切台）⇒ 迟到的视图分离不得再动作。
    if (!_alive) return;
    if (_viewDetached) return; // 视图分离只处理一次（幂等）
    _viewDetached = true;
    // 代际防御（全局版）：切台 / 路由替换会让新旧页面并存，新页面 start 之后旧页面才
    // 跑 detachView。此时旧会话**不得**进小窗（会把刚接管的视图挤掉），直接完整销毁。
    if (!identical(_activeViewSession, this)) {
      await stop();
      dispose();
      return;
    }
    final bool enterMiniPlayer = isNarrow &&
        !isOwnerConsole &&
        _live.srsStatus == AylaLiveSrsStatus.live &&
        _live.currentPlayerError == null;
    if (enterMiniPlayer) {
      _enterMiniPlayer();
      return; // 会话交小窗宿主继续持有：**不 stop、不 dispose**
    }
    await stop();
    dispose();
  }

  /// 进入小窗（web `enterMiniPlayer`，`liveSessionRuntime.ts:321–328`）。
  ///
  /// 把「频道 id + 频道快照 + 回房路由」投影进 store（UI 侧只读 [AylaLiveState.miniPlayer]），
  /// 并把本会话登记为小窗宿主 —— **唯一 owner**：已有别的会话挂着小窗时先完整销毁它。
  void _enterMiniPlayer() {
    // 先取快照：销毁旧 owner 的 `stop()` 会 `clearCurrent()`（否则这里读到 null）。
    final AylaLiveChannelSnapshot? channel = _live.currentChannel;
    final AylaLiveRoomSession? previous = _miniPlayerOwner;
    if (previous != null && !identical(previous, this)) {
      unawaited(previous.stop().whenComplete(previous.dispose));
    }
    // 转为小窗宿主：不再是页面级活跃会话（代际防御的「active」位让给下一个 start）。
    if (identical(_activeViewSession, this)) _activeViewSession = null;
    _miniPlayerOwner = this;
    _live.setMiniPlayer(
      AylaLiveMiniPlayerState(
        channelId: channelId,
        sourceRoute: activityRoute,
        channel: channel,
      ),
    );
  }

  /// 小窗让位（本会话接管视图前）：完整销毁仍挂在小窗上的旧会话。
  Future<void> _retireMiniPlayerOwner() async {
    final AylaLiveRoomSession? owner = _miniPlayerOwner;
    if (owner == null || identical(owner, this)) return;
    await owner.stop();
    owner.dispose();
  }

  /// 完整销毁（幂等）：HLS → WS → 弹幕帧 → 清状态（web `leave`）。
  ///
  /// ⚠️ **清状态是同步的**、只有播放器销毁是异步：dispose 之后 `_live` 可能已被
  /// ProviderScope 回收（实测 "A AylaLiveState was used after being disposed"）⇒
  /// 同步段必须在 `await` 之前跑完，且 `_disposed` 时不再写共享状态。
  /// 进入后台：**只断开弹幕 WS**（= 退出在看名单 + 停心跳），保留会话与播放器。
  ///
  /// 与 [stop] 的区别：本方法**不**清 store、不销毁播放器、不释放小窗所有权 ——
  /// 回前台由 [resumeViewerPresence] 续上，用户无感（web 无此概念，属按常理补齐）。
  void pauseViewerPresence() {
    if (!_alive) return;
    _backgroundPaused = true;
    _ws.disconnect();
  }

  /// 回到前台：重新连上弹幕 WS（重新登记在看、恢复心跳）。
  void resumeViewerPresence() {
    if (!_alive || !_backgroundPaused) return;
    _backgroundPaused = false;
    _ws.connect(channelId);
    unawaited(refreshViewers());
  }

  /// 是否因 App 进后台而暂停了观看登记（[resumeViewerPresence] 的守卫）。
  bool _backgroundPaused = false;

  /// 对外只读投影：[pauseViewerPresence] 是否真的生效过。
  ///
  /// 供 UI/测试断言「现在算不算在看」。PiP 守卫（[aylaHandleLiveViewingLifecycle]）
  /// 的正确性就落在它身上：人在画中画里看直播时，本值必须保持 false。
  bool get backgroundPaused => _backgroundPaused;
  Future<void> stop() async {
    _alive = false;
    // 活动态索引收尾（web `:351–356`）：
    // `shouldKeepActivity = tracksOwnerActivity && current.channel?.status === "live"`
    // —— **直播中**离开控制台保留悬浮球入口；否则清索引（"idle" ⇒ 记录整条置空）。
    // ⚠️ 必须在下面的 `clearCurrent()` **之前**读 `currentChannel`（那一步会把它清掉）。
    final bool shouldKeepActivity = _tracksOwnerActivity &&
        _live.currentChannel?.status == AylaLiveStatus.live;
    if (_tracksOwnerActivity && !shouldKeepActivity) {
      _onMediaActivity?.call(AylaMediaActivityKind.live, false, null);
      aylaSessionActivity.clear(AylaActivityKind.live, AylaActivityStatus.idle);
    }
    _tracksOwnerActivity = false;
    _frameOff?.call();
    _frameOff = null;
    _chatOff?.call();
    _chatOff = null;
    _ws.onConnectionChange = null;
    _ws.onClosedByServer = null;
    _ws.onReconnected = null;
    _ws.disconnect();
    _clearSrsRetry();
    _playerAttached = false;
    _history?.removeListener(_onHistoryChanged);
    _historyRelayed = false;
    _history?.dispose();
    _history = null;
    _renderedFrameIds.clear();
    // 小窗宿主释放（**唯一 owner**）：本会话是小窗时先摘牌，清 UI 投影放在下面的
    // 「页面卸载完成后」同步段里（web `leave` 末尾的 `setMiniPlayer(null)`）。
    final bool ownsMiniPlayer = _ownsMiniPlayer;
    if (ownsMiniPlayer) _miniPlayerOwner = null;
    if (identical(_activeViewSession, this)) _activeViewSession = null;
    // ⚠️ 清共享状态必须在**页面真正卸载完成之后**才安全（见 [detachView] 的注释）；
    // 本方法由页面在 microtask 里调用（那时 Riverpod 已注销该页面的监听）。
    // 且容器可能**先一步**回收了状态 ⇒ 先问 `isDisposed`（实测 "used after being
    // disposed" 就是这一步漏了判定）。
    if (!_live.isDisposed) {
      _live.clearCurrent();
      _live.setCurrentLoading(false);
      _live.setCurrentError(null);
      _live.setCurrentPlayerError(null);
      // 退出小窗模式（完整销毁路径）：清 UI 投影 ⇒ AppShell 卸载小窗（web `setMiniPlayer(null)`）。
      if (ownsMiniPlayer) _live.setMiniPlayer(null);
    }
    if (!_disposed) notifyListeners();
    // 会话结束 ⇒ **必须**撤销原生的「按 Home 自动进画中画」武装，否则用户在任何页面
    // 按 Home 都会误进 PiP（这是本特性唯一的失败模式）；顺带关掉仍挂着的脱离呈现。
    // 放在 destroy 之前：clearDetachedPresentation 独立于播放器，顺序不影响语义。
    await clearDetachedPresentation();
    await _player.destroy();
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    // 原生事件订阅随会话终结（它引用 this，漏摘会让已 dispose 的会话继续收事件）。
    unawaited(_detachedEventsSub?.cancel() ?? Future<void>.value());
    _detachedEventsSub = null;
    // 兜底：异常路径可能绕过 [stop]（例如页面直接 dispose），原生武装不能因此漏撤销。
    // 不阻塞 UI；[clearDetachedPresentation] 内部幂等。
    unawaited(clearDetachedPresentation());
    // 先解绑（它会从 history / danmakuScroll 上摘监听），再释放控制器 ——
    // 顺序反了会在已 dispose 的 ChangeNotifier 上 removeListener。
    _unbindScroll();
    // 滚动控制器随**会话实例**终结：`stop()` 可重入（小窗让位后会再 start），
    // 只有 `dispose()` 是终态 —— 在 stop() 里 dispose 会让复用的会话拿到已销毁的控制器。
    danmakuScroll.dispose();
    super.dispose();
  }

  /// 弹幕展示投影（页面装配 [AylaLiveRoomData.danmaku] 用）。
  ///
  /// 映射写在页面层（不在 `AylaLiveDanmaku` 上开 `toEntry`）：数据投影在 `core/api`、
  /// 展示投影 `AylaDanmakuEntry` 在 `widgets/live` ⇒ 由页面做跨层映射，
  /// 避免 `core/api` 反向依赖渲染类型。
  /// [senderOnlineOf]：弹幕发送者的**实时**在线判定（页面注入 presence 求值器）。
  ///
  /// ⚠️ 2026-10-26 第二轮实报修复：此前签名是 `bool senderOnline = false` 且
  /// **三个页面都不传** ⇒ 所有弹幕头像恒为灰环（用户原话「头像的在线光环也不是
  /// 正常显示在线的」）。web 口径 `DanmakuList.tsx:40–46` 是逐条用 presence store
  /// 实时求值（`presenceOnline(users, withLiveStatus(statuses, senderUser))`），
  /// 不是一个静态 bool ⇒ 改为按 userId 求值的注入点。
  List<AylaDanmakuEntry> danmakuEntries({
    bool Function(String userId)? senderOnlineOf,
  }) {
    final List<AylaLiveDanmaku> source = _history?.items ?? _live.danmaku;
    return <AylaDanmakuEntry>[
      for (final AylaLiveDanmaku item in source)
        AylaDanmakuEntry(
          id: item.id,
          senderNickname: item.senderNickname,
          senderUserId: item.senderUserId,
          senderAvatarUrl: item.senderAvatar,
          senderOnline:
              senderOnlineOf?.call(item.senderUserId) ?? false,
          content: item.content,
          mediaId: item.mediaId,
          media: item.media,
        ),
    ];
  }
}

// ======================= 小窗宿主（全局，唯一 owner） =======================

/// 小窗宿主会话（**唯一 owner**）。
///
/// web 侧这份所有权天然在模块级单例 `liveSessionRuntime` 上（`videoEl` 也由它持有）；
/// Flutter 的会话由页面创建 ⇒ 在 [AylaLiveRoomSession.detachView] 判定「窄屏 + 直播中」时
/// 登记到这里，由 `AppShell` 渲染的 `AylaLiveMiniPlayer` 继续持有，
/// 在 [AylaLiveRoomSession.stop] / [aylaCloseLiveMiniPlayer] 里释放。
AylaLiveRoomSession? _miniPlayerOwner;

/// 当前**页面级**活跃会话（最后一次 [AylaLiveRoomSession.start] 的那个）。
///
/// web 的 `liveSessionRuntime.epoch` 是全局代际；Flutter 的会话由页面创建 ⇒ 用本变量表达
/// 同一件事：切台 / 路由替换时新旧页面并存，**只有活跃会话**的 [detachView] 可以进小窗，
/// 被接管的旧会话必须完整销毁。
AylaLiveRoomSession? _activeViewSession;

/// 当前小窗宿主（null = 无小窗）。
///
/// AppShell 只用它取 `videoView` 与订阅播放器状态；**渲染条件只认
/// [AylaLiveState.miniPlayer] 非空**（web `AppShell.tsx:131–132`）。
AylaLiveRoomSession? get aylaMiniPlayerOwner => _miniPlayerOwner;


/// App 生命周期 → 直播观看登记的收口（`main.dart` 的 `didChangeAppLifecycleState` 只转发到这里）。
///
/// ## 语义（逐条，勿凭印象改）
/// | 生命周期档 | 行为 |
/// |---|---|
/// | `resumed` | 续上观看登记（重连弹幕 WS、重拉在看人数） |
/// | `paused` / `hidden` / `detached` | **先问原生是否在画中画**：在 PiP 里 ⇒ **什么都不做**（仍算在看人）；否则暂停观看登记 |
/// | `inactive` | 不动（来电/通知横幅/切控制中心都只是短暂失焦） |
///
/// ## 为什么需要 PiP 守卫（用户明确要求「小窗观看直播时也算作观看人」）
/// Android 进画中画后引擎只给 `inactive`（不会 `paused`），所以 WS 本来就不会断；
/// 但 **stashed PiP / 部分 OEM 会真的走到 paused** ⇒ 若照旧执行「进后台 = 离开观看」，
/// PiP 里看直播的观众会被后端移出在看名单（正是用户实报过的同类问题）。
/// 所以这里必须先问原生 [AylaDetachedLivePresenter.isInPip] 再决定。
///
/// 通道不存在（Windows / iOS / 单元测试环境）时 `aylaIsInLivePip()` 恒 false
/// ⇒ 行为与改动前**完全一致**，没有任何回归面。
Future<void> aylaHandleLiveViewingLifecycle(
  AppLifecycleState state, {
  AylaDetachedLivePresenter detached = const AylaDetachedLivePresenter(),
}) async {
  switch (state) {
    case AppLifecycleState.resumed:
      await aylaResumeLiveViewingFromBackground();
    case AppLifecycleState.paused:
    case AppLifecycleState.hidden:
    case AppLifecycleState.detached:
      if (await _livePipGuardSaysStillWatching(detached)) return;
      await aylaPauseLiveViewingForBackground();
    case AppLifecycleState.inactive:
      // 短暂失焦不算离开，**不动**。
      break;
  }
}

/// 画中画守卫：true = 人还在 PiP 里看 ⇒ 不许退观看。
///
/// 探测本身不抛异常（契约保证），这里再兜一层 —— 生命周期回调里崩掉会连带断掉整条
/// 前后台收口，代价远大于「多停一次心跳」。
Future<bool> _livePipGuardSaysStillWatching(
  AylaDetachedLivePresenter detached,
) async {
  try {
    return await detached.isInPip();
  } catch (_) {
    return false;
  }
}

/// App 进入后台时的直播观看收口（web 无对应实现 —— 这是**按常理补齐**）。
///
/// ## 为什么需要（2026-10-26 用户实报）
/// 「手机退出直播间后，电脑仍看到手机账号在观看；但电脑退出，手机立刻看不到」。
/// 实测定位（线上 redis）：残留观众的活跃分**仍在刷新** ⇒ 心跳还在跑 ⇒
/// **WS 连接根本没断**。而 `disconnect` 触发时后端会立刻移除观众（已实测：
/// 连上→断开，`zrange` 从 [me] 变 []）。
///
/// 根因：Flutter 侧**没有任何 App 生命周期处理**（全仓无 `WidgetsBindingObserver`）。
/// 手机用户「退出直播间」后若 App 进后台/锁屏，页面虽已 dispose，但进程常驻、
/// 系统允许连接继续存活到被杀为止；PC 上关页面即断。
///
/// ## 语义选择
/// 进入后台 ⇒ 视为**离开观看**（停心跳、退出在看名单、断开 WS）。
/// 回到前台且仍在直播间 ⇒ 页面自身会重新 `start()`；若在**小窗**则重连继续播。
/// 这样「别人看你」永远反映真实前台观看状态。
Future<void> aylaPauseLiveViewingForBackground() async {
  final AylaLiveRoomSession? active = _activeViewSession;
  final AylaLiveRoomSession? mini = _miniPlayerOwner;
  // 只断 WS（退出在看名单、停心跳），**不销毁会话**：回前台可无缝续上。
  for (final AylaLiveRoomSession? s in <AylaLiveRoomSession?>[active, mini]) {
    s?.pauseViewerPresence();
  }
}

/// App 回到前台时的恢复（与 [aylaPauseLiveViewingForBackground] 配对）。
Future<void> aylaResumeLiveViewingFromBackground() async {
  final AylaLiveRoomSession? active = _activeViewSession;
  final AylaLiveRoomSession? mini = _miniPlayerOwner;
  for (final AylaLiveRoomSession? s in <AylaLiveRoomSession?>[active, mini]) {
    s?.resumeViewerPresence();
  }
}

/// 关闭小窗并**完整销毁**会话（web `LiveMiniPlayer.tsx:93–96` →
/// `liveSessionRuntime.leave()`：hls → WS → 清 store → 活动态；含 `setMiniPlayer(null)`）。
///
/// 幂等：无小窗（或已被关闭）时静默返回，重入不产生任何副作用。
Future<void> aylaCloseLiveMiniPlayer() async {
  final AylaLiveRoomSession? owner = _miniPlayerOwner;
  if (owner == null) return;
  await owner.stop();
  owner.dispose();
}

// ======================= 在看名单弹层的数据投影 =======================

/// 名单弹层一次最多渲染多少行（web `LiveViewerSheet.tsx:23–24`：后端已按 200 截断并给
/// `has_more`，前端不再重复限制）。
const int kLiveViewerSheetRowCap = 200;

/// 弹层当前的权威投影（页面持有；[AylaLiveViewerSheetData] 本身是纯值）。
class AylaLiveViewerSheetController extends ChangeNotifier {
  AylaLiveViewerSheetController({
    this.fetcher,
    this.errorMessage,
    this.elysiaReader,
  });

  /// 名单读取（null → [AylaLiveApi.getLiveChannelViewers]；测试可注入 fake）。
  final AylaLiveViewersFetcher? fetcher;

  /// 失败文案的取值口径（web tsx 54–60 的 `reason instanceof Error && reason.message`）。
  final String Function(Object error)? errorMessage;

  /// 爱莉档案读取（null → [AylaElysiaApi.getProfile]；测试可注入）。
  final AylaElysiaProfile? Function()? elysiaReader;

  AylaLiveViewerSheetData _value = const AylaLiveViewerSheetData();

  /// 当前投影（`viewers == null` = 骨架态）。
  AylaLiveViewerSheetData get value => _value;

  bool _loading = false;

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// 打开弹层或点「重试」→ 拉一次权威名单（web `LiveViewerSheet.tsx:44–65` 的
  /// `useEffect(..., [channelId, reloadToken])`）：
  /// - 拉取前 `setError(null)`，但**保留上一份名单**（`setViewers` 只在成功时调用）；
  /// - 失败：`reason instanceof Error && reason.message`，否则回落「暂时读不到在看名单」
  ///   （tsx 54–60）—— **不回落空名单冒充「没人看」**；
  /// - 成功：`viewers` / `count` / `has_more` 三件一起写（tsx 50–52）。
  Future<void> load(String channelId) async {
    if (_loading) return;
    _loading = true;
    _value = _value.copyWith(error: null);
    notifyListeners();
    try {
      final AylaLiveViewersResult page =
          await (fetcher ?? AylaLiveApi.getLiveChannelViewers)(channelId);
      if (_disposed) return;
      final List<AylaLiveViewerItem> rows = <AylaLiveViewerItem>[
        for (final AylaLiveViewer v in page.viewers.take(kLiveViewerSheetRowCap))
          AylaLiveViewerItem(
            userId: v.userId,
            nickname: v.nickname,
            avatar: v.avatar,
          ),
      ];
      _value = AylaLiveViewerSheetData(
        viewers: rows,
        count: page.count,
        hasMore: page.hasMore,
        elysiaUserId: _value.elysiaUserId,
        onRetry: _value.onRetry,
        onOpenProfile: _value.onOpenProfile,
      );
    } catch (error) {
      // presence 存储不可用（503）/ 403 / 404：**明示读不到**，不回落空名单冒充「没人看」
      // （web tsx 8–9 的产品口径）。
      final String message =
          errorMessage?.call(error) ??
              (error is ApiException && error.message.isNotEmpty
                  ? error.message
                  : '暂时读不到在看名单');
      _value = _value.copyWith(error: message);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// 补上爱莉标记（web `LiveViewerSheet.tsx:67–79`：`getElysiaProfile()` →
  /// `profile.enabled ? profile.user.id : null`；**失败静默** —— 名单照常展示，
  /// 只是不标注爱莉光环）。
  Future<void> loadElysiaUserId() async {
    if (_value.elysiaUserId != null) return;
    try {
      final AylaElysiaProfile? profile =
          elysiaReader != null ? elysiaReader!() : await AylaElysiaApi.getProfile();
      if (profile == null || !profile.enabled || profile.userId == null) return;
      _value = _value.copyWith(elysiaUserId: profile.userId);
      notifyListeners();
    } catch (_) {
      // 爱莉档案不可用：不标注
    }
  }

  /// 打开弹层（`AylaLiveViewerStrip.onOpen` 的接收端）。
  ///
  /// 幂等：已经有权威名单或已有错误时**不重复拉**（弹层关掉再开不闪骨架）；
  /// 点「重试」走 [retry]。`preview`（弹幕 WS 的预览名单）由组件自身打底，
  /// web `LiveViewerSheet.tsx:81` 的 `rows = viewers ?? (error ? [] : preview)`。
  void onOpen(String channelId) {
    if (_value.viewers != null || _value.error != null) return;
    unawaited(load(channelId));
    unawaited(loadElysiaUserId());
  }

  /// 打开弹层时的重试回调（web tsx 97 的「重试」→ `reloadToken + 1`）。
  VoidCallback retry(String channelId) => () {
        unawaited(load(channelId));
      };

  /// 点名单行（web tsx 121–124：`goUserProfile(me, user_id)` + `onClose()`）。
  ///
  /// `utils/navigation.ts:24–35`：自己 → `/profile`；他人 → `/user/:id`；
  /// `targetUserId` 为空 → 不跳。弹层自身负责关闭（见 `AylaLiveViewerSheet._body`）。
  static void openProfile(
    BuildContext context, {
    required String? currentUserId,
    required String targetUserId,
  }) {
    if (targetUserId.isEmpty) return;
    if (currentUserId != null && currentUserId == targetUserId) {
      // web goUserProfile 的 navigateTo('/profile') = **push** ⇒ 返回回原页面
      //（2026-10-23 返回键修复：go 会替换掉直播间 ⇒ 返回直接回主页）。
      context.push('/profile');
    } else {
      context.push('/user/${Uri.encodeComponent(targetUserId)}');
    }
  }
}
