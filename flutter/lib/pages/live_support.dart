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
/// 直播**画面槽位**：当前是哪一路在持有那块画面（开发文档 §3 B6）。
///
/// ## 为什么需要（需求 §3.1 B6 / §5.1 S6「任何时刻只能有一个画面槽位持有播放器」）
/// [AylaLiveRoomSession.refreshSrsStatus] 读到 SRS = live 就无条件 `_attachPlayer()`，
/// **没有判断当前画面归谁**。于是「小窗 / 脱离态期间收到一次 SRS 状态更新」就会把页面
/// 那一路播放器重新拉起来：两路同时拉同一个 HLS 流会抢流（表现为主窗口黑屏），
/// 而小窗那边也可能被挤掉（用户实报「小窗和主窗口互相抢」）。
///
/// ## 取值语义
/// | 值 | 谁在画 | 页面能不能 attach |
/// |---|---|---|
/// | [none] | 没人（未进房 / 已退出） | 否 |
/// | [inline] | 页面内嵌播放器 | **是** |
/// | [fullscreen] | 页面播放器的全屏层（同一个控制器） | **是**（全屏仍归页面持有） |
/// | [desktopMini] | 窗口外独立小窗（第二引擎 + 第二个播放器） | 否 |
/// | [mobileMini] | App 内小窗 / 系统画中画 | 否 |
///
/// ⚠️ **全屏不改变画面归属**：`AylaLivePlayer` 的全屏只是把同一个 `videoView` 挂到
/// root Overlay（见 `widgets/live/live_player.dart` 文件头），播放器仍由本会话持有 ⇒
/// 进 / 退全屏**不切换槽位**（切换反而会让 refreshSrsStatus 误判）。
enum AylaPictureSlot { none, inline, fullscreen, desktopMini, mobileMini }

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

  /// 当前画面槽位（B6；见 [AylaPictureSlot] 的语义表）。
  ///
  /// 默认 [AylaPictureSlot.none]：会话刚构造、还没进房 ⇒ 任何 `_attachPlayer()`
  /// 都该被挡住（那时 `currentChannel.hlsUrl` 还没拿到）。
  AylaPictureSlot _pictureSlot = AylaPictureSlot.none;

  /// 当前画面槽位（只读；测试与 UI 可用）。
  AylaPictureSlot get pictureSlot => _pictureSlot;

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

  /// 画面宽高比（页面注入 [AylaLiveRoomBody.videoAspectRatio]）。
  ///
  /// 用于把播放面收成等比盒（= `object-fit: contain`）：全屏时容器是整块屏幕，
  /// 不知道比例就只能拉伸（2026-11-01 用户实报「不要拉伸屏幕，多余的留黑」）。
  /// 未知 ⇒ null（调用方不套等比盒，与 web `<video>` 尚无元数据时一致）。
  double? get videoAspectRatio =>
      _playerAttached ? _player.videoAspectRatio : null;

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
    // 回到直播间 ⇒ 窗口外小窗必须消失（用户实报「回到直播间时小窗应该消失」）。
    //
    // `_retireMiniPlayerOwner()` 只销毁**别的**会话，不会清本会话写下的 miniPlayer 投影；
    // 而 AppShell 的同步器只认 `miniPlayer != null` ⇒ 不清就永远留着那个小窗。
    //
    // ⚠️ 只清投影**不够**：清投影只让「壳层下次 build 时去关窗」，而进直播间这一刻
    // 壳层未必还会 build（同一路径重进时路由没变），窗口可能继续挂着并和主窗口抢流。
    // 所以这里直接把窗口关掉（幂等），保证「进直播间」之后不会有两个 HLS 播放器。
    _miniPlayerFromBackground = false;
    // 重新进直播间 = 新一轮观看：把「用户点掉过小窗」的抑制清掉。
    _miniWindowDismissedByUser = false;
    if (!_live.isDisposed) _live.setMiniPlayer(null);
    if (!kIsWeb && aylaDetachedLivePlatformSupported) {
      await closeDetachedWindow();
    }
    // 窗口外小窗也要让位：它是第二个引擎 + 第二个 HLS 播放器，
    // 本会话要往主窗口挂画面，两路同时播会抢同一个流（表现：主窗口黑屏）。
    // 用户定稿的「退出直播间不关小窗」只约束**退出**方向，进入新直播间时应当让位。
    //
    // ⚠️⚠️ **Android 也必须走这条**（2026-11-01 用户实报「点击小窗回到直播间
    // 会导致直播间加载不出来」）。此前这里硬编码成「只有 Windows」，理由是
    // 「Android 没有第二引擎小窗」——**那个理由已经过期**：1.0.41 起 Android 的
    // 脱离态就是 `LiveMiniWindowHost.kt` 的第二引擎 + 第二个 HLS 播放器，
    // 与 Windows 是同一套机制。于是从安卓小窗点回房时：小窗窗口不关、第二个
    // 播放器继续拉着同一路 HLS，主窗口那一路抢不到流 ⇒ 页面一直转圈/黑屏。
    //
    // 让位语义两端一致：关掉窗口外小窗（幂等，本来没开就是 no-op），再挂主窗口。
    if (!kIsWeb && aylaDetachedLivePlatformSupported) {
      await _retireDetachedWindow();
    }
    // 本会话接管页面视图（[detachView] 的代际防御用：迟到的旧会话不得再进小窗）。
    _activeViewSession = this;
    // B6：进房 = 画面归**页面**（见 [AylaPictureSlot]）。此后的 `_attachPlayer()`
    // （进房拉状态读到 live / 状态事件补拉 / 脱离态恢复 / 小窗恢复）才被允许执行。
    _pictureSlot = AylaPictureSlot.inline;
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

  /// 挂载播放器（幂等：同 URL 且实例健康不重建，见 `hls_player.dart` 的 attach）。
  ///
  /// ## B6：只有**页面槽位**才能挂（开发文档 §3 B6；需求 §3.1 B6 / §5.1 S6）
  /// 这个方法此前是「只要被调用就挂」——而 [refreshSrsStatus] 在读到 SRS = live 时
  /// 无条件调它。于是小窗 / 脱离态期间收到一次状态更新，页面那一路播放器就被重新
  /// 拉起来，与窗口外小窗的第二个播放器抢同一路流（主窗口黑屏）。
  ///
  /// 守卫放在**这里**而不是只放在 refreshSrsStatus：
  /// `_attachPlayer` 有 4 个调用点（进房、refreshSrsStatus、脱离态恢复、小窗恢复），
  /// 只要有一个漏判就会退回旧 bug；放在唯一出口上不可能漏。
  ///
  /// 允许的槽位只有 [AylaPictureSlot.inline]；[AylaPictureSlot.fullscreen] 在当前实现
  /// 下不出现（全屏不改变归属），保留该枚举值是为了语义完整与将来扩展。
  Future<void> _attachPlayer() async {
    if (_pictureSlot != AylaPictureSlot.inline) {
      // 小窗 / 脱离态 / 未进房 ⇒ 画面不归页面，绝不抢流。
      return;
    }
    // 主窗口要放画面 ⇒ 之前的「脱离态挂起」到此结束。
    //
    // 场景：小窗开着时又进了直播间。播放器在进入脱离态时被 destroy 过，
    // 标志若不在这里清掉，之后 resume 逻辑会一直认为「还挂在脱离态」，
    // 退出直播间时也不会恢复 —— 表现就是主窗口直播一直黑着。
    _playerSuspendedForDetached = false;
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
    // 独立窗口的生命周期只存在于 Windows（第二引擎那个窗口）。
    // Android PiP 是**同一 Activity 同一 engine**，系统不会给「窗口关闭」事件 ——
    // 订阅了也永远收不到，但订阅本身会多一条流引用，故只在桌面订阅。
    final bool secondWindow = !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.windows;
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
      // B6：画面交给原生呈现（窗口外小窗 / PiP）⇒ 页面槽位让出，
      // 此后 refreshSrsStatus 读到 live 也不许把页面播放器再拉起来（会抢流）。
      _pictureSlot = AylaPictureSlot.desktopMini;
      // ⚠️ **只有 Windows 需要停主窗口那一路播放**：那边是第二个 Flutter engine +
      // 第二个 HLS 播放器，不停就会两路音频叠在一起（独立小窗旁边还能听见主窗口回声）。
      //
      // ❌ **Android 绝对不能停**：PiP 显示的就是**本 Activity 本 engine** 的这张画面，
      // 一旦把 `_player.destroy()` 掉，画中画里就是一个纯黑窗口（功能表面成功、实际全黑）。
      // 这也是「PiP 里继续算观看人」的前提：同一路 HLS / 同一条弹幕 WS 原样继续跑。
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
    // B6：脱离呈现结束 ⇒ 画面交回页面槽位。
    // ⚠️ 必须在这里（不是只靠下面的 _resumeMainPlayerAfterDetached）：那个方法以
    // `_playerSuspendedForDetached` 为开关，而 Android PiP 那条路径**从不挂起**
    // 主播放器（PiP 显示的就是本 engine 这张画面）⇒ 开关恒为 false ⇒ 若只在那里
    // 恢复槽位，Android 上退出 PiP 后槽位永远停在 desktopMini，页面再也 attach 不了。
    if (_alive) _pictureSlot = AylaPictureSlot.inline;
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
    // ⚠️ 不再关闭「窗口外直播小窗」。
    //
    // 用户定稿：「应用内退出直播间不应该退出小窗」—— 小窗要一直播到用户
    // 亲自点它自己的关闭键为止。这里曾经无条件 close()，于是每次退出直播间
    // 都会连带把小窗关掉（会话 stop ⇒ clearDetachedPresentation ⇒ close）。
    //
    // 关闭时机只剩两个：用户点小窗的关闭键（原生回 `liveWindowClosed`），
    // 或宿主进程结束。Android PiP 仍由系统自己收起，[setSessionActive] 已
    // 撤销自动进 PiP 的武装，不需要额外关窗。
    //
    // ⚠️ 但**必须把画面还给主窗口**：进入脱离态时主窗口那一路播放器被主动停掉
    // 以把画面所有权交给第二引擎（见 _suspendMainPlayerForDetached）。
    // 原实现是靠 close() 触发的交接把它恢复回来；现在不关窗了，若在这里直接
    // 返回，主窗口就永远停在挂起状态 —— 表现正是「电脑端直播一直黑着」。
    if (_playerSuspendedForDetached) {
      await _resumeMainPlayerAfterDetached();
    }
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
    // Windows：独立窗口没了 ⇒ 主窗口重新接管画面（旧语义）。
    _onDetachedWindowClosed();
  }

  /// Android 窗口外小窗是否已挂上「被关闭」的监听（幂等）。
  bool _miniWindowLifecycleBound = false;

  /// 挂上「窗口外小窗被关掉了」的监听（Android）。
  ///
  /// 为什么只有小窗 owner 才挂：这条事件是**窗口级别的**，谁开过小窗谁负责收尾
  /// （`onLiveWindowClosed` 由原生在窗口移除时发，见 `LiveMiniWindowHost.hide`）。
  /// 不挂的后果是：用户点了小窗的关闭键，窗口没了，而**会话还在后台播**
  /// （HLS 音频继续响、心跳继续刷「在看」），且 `miniPlayer` 投影永远非空 ⇒
  /// 再也打不开第二次小窗。
  void _bindMiniWindowLifecycle() {
    if (!_ownsMiniPlayer) return;
    if (_miniWindowLifecycleBound) return;
    _miniWindowLifecycleBound = true;
    _miniWindowEventsSub ??= AylaDetachedLiveEvents.instance.stream
        .listen(_onMiniWindowEvent);
  }

  StreamSubscription<AylaDetachedLiveEvent>? _miniWindowEventsSub;

  /// 解开「窗口外小窗被关掉」的监听（摘牌 / 会话结束时调用；幂等）。
  void _unbindMiniWindowLifecycle() {
    if (!_miniWindowLifecycleBound) return;
    _miniWindowLifecycleBound = false;
    unawaited(_miniWindowEventsSub?.cancel() ?? Future<void>.value());
    _miniWindowEventsSub = null;
  }

  void _onMiniWindowEvent(AylaDetachedLiveEvent event) {
    if (event.kind != AylaDetachedLiveEventKind.liveWindowClosed) return;
    if (_disposed || !_alive) return;
    if (!_ownsMiniPlayer) return;
    // ⚠️ 「关掉小窗」≠「退出观看」：必须看用户现在在哪。
    //
    // · 用户**就站在直播间里**（本会话仍是页面级活跃会话）⇒ 他只是收起小窗，
    //   页面还要继续播。这里若照 web 的 leave() 语义销毁会话，页面会连带被弄死
    //   （2026-11-01 实报：「退不出直播间了」，因为会话被 dispose、页面拿到的
    //   播放器与 store 状态全空，画面永远停在加载态）。⇒ 只摘牌 + 记抑制。
    // · 用户**已经离开直播间**（页面已卸载，`_viewDetached`）：小窗是他唯一的
    //   观看面，关掉就是不想看了 ⇒ 完整销毁（web `LiveMiniPlayer.tsx:93–96`）。
    final bool stillOnRoomPage =
        identical(_activeViewSession, this) && !_viewDetached;
    _miniWindowDismissedByUser = true;
    if (stillOnRoomPage) {
      _miniPlayerOwner = null;
      _miniPlayerFromBackground = false;
      _unbindMiniWindowLifecycle();
      if (!_live.isDisposed) _live.setMiniPlayer(null);
      // B6：用户收起小窗但人就站在直播间里 ⇒ 画面还给页面（槽位恢复由
      // _resumeMainPlayerAfterDetached 统一处理，它在 attach 之前置 inline）。
      unawaited(_resumeMainPlayerAfterDetached());
      if (!_disposed) notifyListeners();
      return;
    }
    unawaited(stop().whenComplete(dispose));
  }

  /// 独立直播窗口没了（用户关掉 / 点画面回主窗口）⇒ 主窗口重新接管画面。
  ///
  /// **不销毁会话**（弹幕 WS / 观看登记一直在跑）；页面已卸载时顺带登记 App 内小窗。
  void _onDetachedWindowClosed() {
    final bool wasDetached = _detached;
    _detached = false;
    debugPrint('[AYLA-DETACH] windowClosed alive=$_alive'
        ' wasDetached=$wasDetached viewDetached=$_viewDetached'
        ' isActiveView=${identical(_activeViewSession, this)}'
        ' suspended=$_playerSuspendedForDetached attached=$_playerAttached');
    if (_alive) {
      // ⚠️⚠️ **必须区分「页面还在」与「页面已卸载」**（2026-11-01 实报：
      // 「进直播间 → 点小窗 → 切换页面 → 关闭小窗 → 声音还在」）。
      //
      // · 页面还在（用户就站在直播间里）：恢复主窗口那一路播放，画面回到页面；
      // · 页面已卸载（用户切到别的页面去了）：**没有人要这个画面了** ⇒
      //   必须完整停播并销毁会话。旧实现无条件 `_resumeMainPlayerAfterDetached()`，
      //   在页面已卸载时会把播放器重新 attach 起来、却没有任何可见面 ⇒
      //   用户听到「关了小窗声音还在」，而且再也没有入口关掉它。
      final bool pageStillAlive =
          identical(_activeViewSession, this) && !_viewDetached;
      if (!pageStillAlive) {
        // 页面没了：小窗是唯一观看面，关掉即「不想看了」⇒ 完整收尾。
        unawaited(stop().whenComplete(dispose));
        return;
      }
      unawaited(_resumeMainPlayerAfterDetached());
      // 「回到 App 内小窗」复用既有路径。只在**页面已经卸载**时登记小窗投影：
      // 用户就站在直播间页里时画面由页面自己的 videoView 接管，再挂一层小窗
      // 投影会多出一个盖在页面上的浮层。
      //
      // ⚠️ 用户亲手点掉了小窗 ⇒ **不得**在这里重新登记（否则就是「关不掉的自动出现」）。
      if (wasDetached &&
          !identical(_activeViewSession, this) &&
          !_miniWindowDismissedByUser) {
        _enterMiniPlayer();
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
    debugPrint('[AYLA-DETACH] suspend: attached=$_playerAttached '
        'suspended=$_playerSuspendedForDetached');
    if (!_playerAttached) return;
    _playerSuspendedForDetached = true;
    _playerAttached = false;
    await _player.destroy();
    debugPrint('[AYLA-DETACH] suspend: player destroyed');
  }

  /// 独立窗口关闭后重新接管（只在确实被 [enterDetachedPresentation] 停过时才重建）。
  ///
  /// 幂等：没挂起过就什么都不做（Android PiP 路径根本不会进入这里 ——
  /// 那边 `_suspendMainPlayerForDetached()` 从不被调用，标志恒为 false）。
  Future<void> _resumeMainPlayerAfterDetached() async {
    debugPrint('[AYLA-DETACH] resume: suspended=$_playerSuspendedForDetached '
        'alive=$_alive attached=$_playerAttached slot=$_pictureSlot');
    if (!_playerSuspendedForDetached) return;
    _playerSuspendedForDetached = false;
    // B6：画面回到页面手里 ⇒ 槽位恢复 inline。
    // ⚠️ 必须**在** `_attachPlayer()` 之前：否则下面那一句会被自己的槽位守卫挡掉，
    // 主窗口永远黑着（这正是「从脱离态回来不恢复」会呈现的形态）。
    _pictureSlot = AylaPictureSlot.inline;
    if (!_alive || _playerAttached) return;
    if (_live.currentPlayerError != null) return;
    await _attachPlayer();
  }

  /// 把「小窗所有权 + miniPlayer 投影」摘掉，**但不销毁会话**。
  ///
  /// 与 [aylaCloseLiveMiniPlayer] 的区别：那个是「用户不要这个小窗了」（完整销毁）；
  /// 本方法是「App 回到前台、页面重新接管画面」，会话与观看登记都要继续。
  void releaseMiniPlayerForForeground() {
    final bool wasBackgroundAuto = _miniPlayerFromBackground;
    // B6：小窗让位 ⇒ 画面回到页面（回前台的恢复路径随后会 `_attachPlayer()`，
    // 那一步要能通过槽位守卫）。
    if (_alive) _pictureSlot = AylaPictureSlot.inline;
    if (!_ownsMiniPlayer) return;
    _miniPlayerOwner = null;
    _miniPlayerFromBackground = false;
    // 摘牌 ⇒ 不再是小窗宿主，小窗关闭事件也就不该再消费（下次进小窗会重新挂）。
    _unbindMiniWindowLifecycle();
    if (!_live.isDisposed) _live.setMiniPlayer(null);
    // 「页面级活跃会话」的牌子还给它：切后台时没被摘掉（见 [_enterMiniPlayer]），
    // 这里只是把它重新标成当前视图的 owner，保证之后「退出直播间」仍能正常进小窗。
    if (wasBackgroundAuto && _alive && !_viewDetached) {
      _activeViewSession = this;
    }
  }

  /// 回到前台、后台自动小窗让位后，把画面还给页面播放器。
  ///
  /// 与 [enterMiniPlayerOnBackground] 配对：进后台时页面那一路被挂起
  /// （`_suspendMainPlayerForDetached`），回前台必须重新挂上，否则用户回到直播间
  /// 看到的是黑屏。幂等：没挂起过就什么都不做。
  Future<void> resumePagePlayerAfterMini() async {
    if (!_alive || _disposed) return;
    if (!_playerSuspendedForDetached) return;
    if (_live.currentPlayerError != null) return;
    await _resumeMainPlayerAfterDetached();
    if (!_disposed) notifyListeners();
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

  /// 用户**自己点掉了**小窗 ⇒ 本会话在「切后台」时不再自动弹（用户实报：
  /// 「我点了小窗的关闭键，过一会小窗又自动会出现，你写死了他会自动出现但没写怎么关」）。
  ///
  /// 这是「用户意图」而不是「窗口状态」：窗口状态由投影表达，意图必须单独记，
  /// 否则下一次 `paused` 又会按「还在播 + 没有小窗」重新弹出来。
  bool _miniWindowDismissedByUser = false;

  /// 当前这个小窗是不是「App 切后台时自动弹出」的。
  ///
  /// 用途只有一条：App 回到前台时**只有这种小窗**要自动消失
  /// （用户规格：「回到直播间时小窗应该消失」，而「退出直播间」得到的那个小窗
  /// 要一直留着）。两条路径共用 [AylaLiveMiniPlayerState] 投影，靠这个位区分。
  bool _miniPlayerFromBackground = false;

  /// 只读投影（[aylaHandleLiveViewingLifecycle] 回前台时判定用）。
  bool get miniWindowIsBackgroundAuto =>
      _ownsMiniPlayer && _miniPlayerFromBackground;

  /// 这个会话是否仍是**某个页面正在使用**的会话（页面没卸载、也没被接管）。
  ///
  /// 判断「能不能销毁」的唯一依据：页面级会话被 dispose 会让页面拿到的播放器
  /// 与共享状态全空（画面卡在加载态）。小窗让位、关闭、回前台一律只摘牌。
  bool get isPageAlive => _alive && !_viewDetached;

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
    //
    // ⚠️ 唯一的例外 = 用户亲手点掉了小窗（[AylaLiveRoomSession._miniWindowDismissedByUser]）。
    // 那一刻 `_activeViewSession` 可能已是 null（小窗登记时摘过牌），若照旧销毁，
    // 会把仍在页面上的会话打死 ⇒ 画面卡在加载态、「退不出直播间」（2026-11-01 实报）。
    if (!identical(_activeViewSession, this) && !_miniWindowDismissedByUser) {
      await stop();
      dispose();
      return;
    }
    // ⚠️⚠️ **脱离态（桌面小窗 / Android PiP）必须让位，不能销毁会话**
    //（2026-11-01 用户实报：「进直播间 → 点小窗键 → 切换页面 → 关闭小窗 → 声音还在」）。
    //
    // 那一刻的事实是：用户点了「小窗」，画面已经在**窗口外**播着，然后他离开直播间页面
    // 去别的页面。此时：
    //   · 会话若被 stop()+dispose()，第二引擎的窗口还在放；
    //   · 关掉小窗时 _onDetachedWindowClosed 看到 _alive == false ⇒ 直接 return；
    //   · 结果：窗口没了、会话没了，但**没有任何人停过那一路播放** ⇒ 声音一直响。
    //
    // 正确语义：脱离态下离开页面 = 「小窗继续播，会话继续持有」，页面只是不再显示画面。
    // 真正的结束由用户关小窗（_onDetachedWindowClosed）或退播触发。
    if (_detached) {
      return;
    }
    // ⚠️ `!_miniWindowDismissedByUser`：用户亲手点掉过小窗 ⇒ 本次会话不再自动弹。
    // 少了这条就是「写死了会自动出现但没写怎么关」（2026-11-01 用户实报）。
    final bool enterMiniPlayer = isNarrow &&
        !isOwnerConsole &&
        !_miniWindowDismissedByUser &&
        _live.srsStatus == AylaLiveSrsStatus.live &&
        _live.currentPlayerError == null;
    if (enterMiniPlayer) {
      _enterMiniPlayer();
      return; // 会话交小窗宿主继续持有：**不 stop、不 dispose**
    }
    await stop();
    dispose();
  }

  /// App 切后台时进小窗（用户实报「从直播间离开 app，把 Ayla 放后台没有出现小窗」）。
  ///
  /// 与 [detachView] 的区别：
  ///   · [detachView] 是「离开直播间页面」（路由级，带 `_viewDetached` 幂等位）；
  ///   · 本方法是「App 进后台但页面还在」（生命周期级，可反复进出）。
  /// 所以不能复用 [detachView] —— 它会把这个会话标记成已分离，回到前台就再也接不回来。
  ///
  /// 条件与 [detachView] 的 `enterMiniPlayer` 判定一致：直播进行中、无播放器错误、
  /// 且当前不在主播控制台（主播自己的控制台不该被小窗顶掉）。
  Future<void> enterMiniPlayerOnBackground() async {
    if (!_alive || _viewDetached) return;
    if (_ownsMiniPlayer) return; // 已经在小窗里了，幂等
    // 用户亲手点掉过小窗 ⇒ 本次会话不再自动弹（这是唯一的「怎么关」）。
    if (_miniWindowDismissedByUser) return;
    if (_live.srsStatus != AylaLiveSrsStatus.live) return;
    if (_live.currentPlayerError != null) return;
    // ⚠️ 先把主窗口（页面）这一路播放器停掉，再弹小窗。
    //
    // 小窗是**第二个引擎 + 第二个 HLS 播放器**（`LiveMiniWindowHost.kt`），
    // 与页面那一路是两条独立的解码链：同时播同一个直播流会双声道叠加、互相错相
    // （听着像回声/颤动）。页面此刻已经在后台、看不见，没必要继续解码。
    // 这与 Windows 独立窗口的交接是同一条纪律（`_suspendMainPlayerForDetached`）。
    await _suspendMainPlayerForDetached();
    if (!_alive) return;
    _enterMiniPlayer(fromBackground: true);
    // ⚠️ **必须在这里直接开窗**，不能等 `AppShell` 的同步器。
    //
    // 同步器靠 `build` 里的 `addPostFrameCallback` 触发，而进后台后主引擎
    // **不再出帧**（`scheduler/binding.dart` 的 `handleAppLifecycleStateChanged`：
    // hidden/paused/detached ⇒ `_setFramesEnabledState(false)`）⇒ 那一帧永远不会来
    // ⇒ 小窗要等用户切回前台才出现（等于「切后台不出现小窗」没修）。
    // 小窗本身跑在**第二个引擎**里，开窗这一步不依赖主引擎出帧。
    await _openDetachedWindowDirect();
  }

  /// 关掉「窗口外小窗」这件事的平台动作（**走注入的 presenter**，便于测试断言）。
  ///
  /// 为什么不直接调模块级 `aylaCloseDetachedLive()`：会话的平台动作统一从
  /// [_detachedPresenter] 出，测试才能在不碰 MethodChannel 的情况下验证
  /// 「到底有没有真的去关窗」（同 `enter` 的理由）。
  Future<void> closeDetachedWindow() async {
    try {
      await _detachedPresenter.close();
    } catch (_) {
      // 关窗失败不该打断生命周期收口（原生侧 hide 本身幂等且不抛）。
    }
  }

  /// 直接调平台「开窗口外小窗」（不进 [_detached] 记录：那不是 Windows 那种脱离态）。
  ///
  /// 幂等由原生保证（同频道同地址重复 `show` 直接返回 true，不重建引擎）。
  Future<void> _openDetachedWindowDirect() async {
    if (!aylaDetachedLivePlatformSupported) return;
    final String? url = _detachedPlayUrl();
    if (url == null) return;
    try {
      await _detachedPresenter.enter(
        channelId: channelId,
        title: _live.currentChannel?.title ?? '直播间',
        playUrl: url,
      );
    } catch (_) {
      // 开窗失败不打断生命周期收口（接下来照常暂停观看登记）。
    }
  }

  /// 进入小窗（web `enterMiniPlayer`，`liveSessionRuntime.ts:321–328`）。
  ///
  /// 把「频道 id + 频道快照 + 回房路由」投影进 store（UI 侧只读 [AylaLiveState.miniPlayer]），
  /// 并把本会话登记为小窗宿主 —— **唯一 owner**：已有别的会话挂着小窗时先完整销毁它。
  void _enterMiniPlayer({bool fromBackground = false}) {
    _miniPlayerFromBackground = fromBackground;
    // B6：画面交给 App 内小窗 / 系统画中画 ⇒ 页面槽位让出（见 [AylaPictureSlot]）。
    // 两条入口（离开直播间页面 / App 切后台）都汇到这里，所以只在这里改一次。
    _pictureSlot = AylaPictureSlot.mobileMini;
    // 先取快照：销毁旧 owner 的 `stop()` 会 `clearCurrent()`（否则这里读到 null）。
    final AylaLiveChannelSnapshot? channel = _live.currentChannel;
    final AylaLiveRoomSession? previous = _miniPlayerOwner;
    if (previous != null && !identical(previous, this)) {
      unawaited(previous.stop().whenComplete(previous.dispose));
    }
    // 转为小窗宿主：不再是页面级活跃会话（代际防御的「active」位让给下一个 start）。
    //
    // ⚠️ **切后台那条路径不能清**：页面还挂在树上、用户就在直播间里，只是 App 被
    // 放到后台了。清掉之后「回到前台再退出直播间」会走到 [detachView] 的代际防御
    // 分支（`!_activeViewSession` ⇒ 直接销毁），小窗就再也不出现了。
    if (!fromBackground && identical(_activeViewSession, this)) {
      _activeViewSession = null;
    }
    _miniPlayerOwner = this;
    // ⚠️ 必须在 `_miniPlayerOwner = this` **之后**才挂监听：
    // `_bindMiniWindowLifecycle` 用 `_ownsMiniPlayer` 做前置判定，早挂会被自己挡掉
    // ⇒ 用户点小窗关闭键时没人收事件 ⇒ 窗口关了、投影还在、还继续自动出现。
    _bindMiniWindowLifecycle();
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

  /// 窗口外小窗让位（本会话往主窗口挂画面前）。
  ///
  /// 窗口外小窗是第二个 Flutter engine + 第二个 HLS 播放器。若它还在播，
  /// 主窗口再挂一路就是两路抢同一个流，主窗口表现为一直黑屏。
  /// （用户定稿「退出直播间不关小窗」只约束退出方向，进入直播间时应当让位。）
  Future<void> _retireDetachedWindow() async {
    if (_detached) {
      _detached = false;
    }
    // 无论 `_detached` 标志如何都要真的关一次窗口：
    // 「切后台自动弹出小窗」那条路径**不走** `_detached`（它不是 Windows 的脱离态语义，
    // 见 `_openDetachedWindowDirect`），只认标志就会漏关 ⇒ 两路抢流 ⇒ 主窗口黑屏。
    // 原生 `hide` 幂等（没有窗口时什么也不做），重复调用没有代价。
    await closeDetachedWindow();
    // 无论之前是否处于脱离态，都把桥接标志复位，避免陈旧的「已挂起」认知
    // 影响下一次进入脱离态时的判定。
    _resetDetachedWindowBridge();
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

  /// 回到前台：重新连上弹幕 WS（重新登记在看、恢复心跳）+ 让画面继续播。
  ///
  /// ## 【B5 移动端那一半】（开发文档 §3 B5 / 需求 §5.1 S5、G3）
  /// Windows 侧由 media_kit `Video` 的 `resumeUponEnteringForegroundMode` 自动恢复
  /// （见 `media_kit_impl.dart` 的 buildView）。**移动端没有等价参数**：
  /// `video_player` 的 `VideoPlayer` widget 不接受生命周期配置，而 App 进后台时
  /// 系统会停下 ExoPlayer / AVPlayer 并可能回收 surface ⇒ 回到前台是黑画面。
  /// `main.dart` 的生命周期收口（[aylaHandleLiveViewingLifecycle]）本来就会在
  /// resumed 时调到这里 ⇒ 在这里补一次「继续播」即可，**不动平台插件**。
  ///
  /// ⚠️ 只在**页面持有画面**时做（B6 的槽位守卫）：小窗 / 脱离态期间画面归别人，
  /// 这里再 play 一次会与第二路播放器抢流。
  void resumeViewerPresence() {
    if (!_alive || !_backgroundPaused) return;
    _backgroundPaused = false;
    _ws.connect(channelId);
    unawaited(refreshViewers());
    if (_pictureSlot == AylaPictureSlot.inline && _playerAttached) {
      unawaited(_player.resumePlayback());
    }
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
    // B6：会话结束 ⇒ 画面槽位归零（此后任何迟到的生命周期/状态事件都不该再挂播放器）。
    _pictureSlot = AylaPictureSlot.none;
    _history?.removeListener(_onHistoryChanged);
    _historyRelayed = false;
    _history?.dispose();
    _history = null;
    _renderedFrameIds.clear();
    // 小窗宿主释放（**唯一 owner**）：本会话是小窗时先摘牌，清 UI 投影放在下面的
    // 「页面卸载完成后」同步段里（web `leave` 末尾的 `setMiniPlayer(null)`）。
    final bool ownsMiniPlayer = _ownsMiniPlayer;
    if (ownsMiniPlayer) _miniPlayerOwner = null;
    _miniPlayerFromBackground = false;
    _miniWindowDismissedByUser = false;
    _unbindMiniWindowLifecycle();
    // 会话结束了就不该再被「回前台恢复观看登记」碰到（那个集合是全局的）。
    _backgroundPausedSessions.remove(this);
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
    _backgroundPausedSessions.remove(this);
    // 原生事件订阅随会话终结（它引用 this，漏摘会让已 dispose 的会话继续收事件）。
    unawaited(_detachedEventsSub?.cancel() ?? Future<void>.value());
    _detachedEventsSub = null;
    _miniWindowLifecycleBound = false;
    unawaited(_miniWindowEventsSub?.cancel() ?? Future<void>.value());
    _miniWindowEventsSub = null;
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

  /// 历史窗口尚未就绪时的弹幕来源 —— **只认本会话频道的那份实时队列**。
  ///
  /// ## 为什么不能直接 `?? _live.danmaku`（2026-11-02 侧栏切台修复，探针实证）
  /// 切台那一刻，新会话刚 `start()`，而它创建 `_history` 是在
  /// `await Future<void>.delayed(Duration.zero)` **之后**（`start()` 头部：必须先让位，
  /// Riverpod 禁止在 build/initState 期间改 provider）。旧会话的 `stop()` 同样排在
  /// microtask（见 `live_room_page.dart` 的 `_switchChannel`）。
  /// ⇒ **切台首帧**里 `_history` 还是 null、`_live.danmaku` 还是**上一个频道**的队列，
  /// 直接回落就会把旧频道的弹幕挂到新频道的列表与飘弹幕层上。
  ///
  /// 探针实测（切台首帧）：`overlay=1 channelKey=2 items=3 bodyLoading=false`
  /// —— 正是旧频道的 3 条弹幕。web 侧不存在该窗口：`liveSessionRuntime.enter()`
  /// 在切频道分支**同步**先 `this.leave()`（`clearCurrent()` 清空 danmaku）再建新会话。
  ///
  /// 判据用 store 的 `currentChannel.id`：实时队列在 store 里**总是**属于当前频道
  /// （`AylaLiveState.setViewers` / `appendDanmaku` 都是这个口径），所以「current 是
  /// 本会话频道」⇔「这份队列属于我」。不成立就返回空 —— 宁可首帧空列表，
  /// 也不能显示别的直播间的弹幕。
  List<AylaLiveDanmaku> _fallbackDanmaku() {
    if (_live.isDisposed) return const <AylaLiveDanmaku>[];
    final String? owner = _live.currentChannel?.id;
    if (owner == channelId) return _live.danmaku;
    return const <AylaLiveDanmaku>[];
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
    final List<AylaLiveDanmaku> source = _history?.items ?? _fallbackDanmaku();
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


/// App 生命周期 → 直播小窗 + 观看登记的收口（`main.dart` 的 `didChangeAppLifecycleState` 只转发到这里）。
///
/// ## 语义（逐条，勿凭印象改）
/// | 生命周期档 | 行为 |
/// |---|---|
/// | `resumed` | **先撤掉「切后台自动弹出」的小窗**（用户规格：回到直播间小窗必须消失）⇒ 再续上观看登记 |
/// | `paused` / `hidden` / `detached` | **若正在看直播 ⇒ 弹出窗口外小窗**（用户实报「放后台没有出现小窗」）；再问原生是否在画中画：在 PiP 里 ⇒ 不暂停观看登记；否则暂停 |
/// | `inactive` | 不动（来电/通知横幅/切控制中心都只是短暂失焦）—— 小窗也不能在这一档弹：Android 从 `inactive` 就开始画转场，太早弹会闪 |

/// ⚠️ **小窗时序**：`paused` 是引擎「帧已停」的那一档（见 `scheduler/binding.dart`
/// 的 `handleAppLifecycleStateChanged`：hidden/paused/detached 会 `_setFramesEnabledState(false)`）。
/// 小窗在 `paused` 之前（`hidden`）被请求，原生侧就能在引擎停下之前把第二引擎拉起来；
/// 若只认 `paused`，用户把 App 切后台时小窗会晚一拍才出现。三档都调、靠会话内部幂等去重。
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
      // 回到前台 ⇒ 撤掉「切后台自动弹出」的那个小窗（用户规格：「回到直播间时
      // 小窗应该消失」）。只撤这一档：用户在**离开直播间之后**主动得到的小窗
      // （`detachView` 那条路径）必须一直留着，用户可能正在别的 App 里看它。
      await _dismissBackgroundAutoMiniWindow();
      await aylaResumeLiveViewingFromBackground();
    case AppLifecycleState.hidden:
    case AppLifecycleState.paused:
    case AppLifecycleState.detached:
      // 进后台 ⇒ 若正看着直播，弹出窗口外小窗（用户实报「从直播间离开 app，
      // 把 Ayla 放后台没有出现小窗」）。必须在「暂停观看登记」**之前**做：
      // 小窗要接管画面，先断观看登记会让它在一次网络往返里处于「不在播」的判定下。
      await _activeViewSession?.enterMiniPlayerOnBackground();
      if (await _livePipGuardSaysStillWatching(detached)) return;
      await aylaPauseLiveViewingForBackground();
    case AppLifecycleState.inactive:
      // 短暂失焦不算离开，**不动**。
      break;
  }
}

/// 撤掉「App 切后台时自动弹出」的小窗（回到前台时调用）。
///
/// 只处理**自动弹出**那一档（[AylaLiveRoomSession.miniWindowIsBackgroundAuto]）：
/// 「离开直播间」得到的小窗是用户主动保留的观看面，回前台不该被抢走。
///
/// 让位语义与「进直播间」一致：小窗是第二个引擎 + 第二个 HLS 播放器，页面要重新
/// 挂画面就必须先把它关掉（两路同播会抢流 / 双声道），然后由会话把页面播放器重新
/// 挂上（进后台时被 `_suspendMainPlayerForDetached` 挂起过）。
Future<void> _dismissBackgroundAutoMiniWindow() async {
  final AylaLiveRoomSession? owner = _miniPlayerOwner;
  if (owner == null) return;
  if (!owner.miniWindowIsBackgroundAuto) return;
  // ⚠️ **先摘牌、再关窗**：关窗会让原生回 `onLiveWindowClosed`，会话的监听逻辑
  // 是「我还是小窗 owner ⇒ 完整销毁会话」。此刻会话正是页面在用的那一个，
  // 被销毁就等于回到前台后直播间整个黑掉。摘牌之后那条事件自然被忽略。
  owner.releaseMiniPlayerForForeground();
  await owner.closeDetachedWindow();
  if (!owner.alive) return;
  await owner.resumePagePlayerAfterMini();
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
    if (s == null) continue;
    s.pauseViewerPresence();
    _backgroundPausedSessions.add(s);
  }
}

/// 因「App 进后台」被暂停观看登记的会话（回前台要原样续上）。
///
/// ⚠️ 为什么要单独记：进后台时会话可能**刚被移交成小窗**（`_enterMiniPlayer` 会把
/// `_activeViewSession` 置空 —— 那是页面代际防御），而回前台撤小窗时又会摘掉
/// 小窗牌子 ⇒ 那一刻 [aylaResumeLiveViewingFromBackground] 在两个全局槽里都找不到它，
/// 结果「回到前台还挂在离开观看的状态」（别人看你不在看了，心跳也不恢复）。
final Set<AylaLiveRoomSession> _backgroundPausedSessions =
    <AylaLiveRoomSession>{};

/// App 回到前台时的恢复（与 [aylaPauseLiveViewingForBackground] 配对）。
Future<void> aylaResumeLiveViewingFromBackground() async {
  final AylaLiveRoomSession? active = _activeViewSession;
  final AylaLiveRoomSession? mini = _miniPlayerOwner;
  final List<AylaLiveRoomSession> targets = <AylaLiveRoomSession>[
    ..._backgroundPausedSessions,
    if (active != null) active,
    if (mini != null) mini,
  ];
  _backgroundPausedSessions.clear();
  for (final AylaLiveRoomSession s in targets) {
    s.resumeViewerPresence();
  }
}

/// 关闭小窗并**完整销毁**会话（web `LiveMiniPlayer.tsx:93–96` →
/// `liveSessionRuntime.leave()`：hls → WS → 清 store → 活动态；含 `setMiniPlayer(null)`）。
///
/// 幂等：无小窗（或已被关闭）时静默返回，重入不产生任何副作用。
Future<void> aylaCloseLiveMiniPlayer() async {
  final AylaLiveRoomSession? owner = _miniPlayerOwner;
  if (owner == null) return;
  // ⚠️ 用户就站在直播间页里时，这个会话是**页面的**会话，不能连同 dispose ——
  // 那会让页面拿到已销毁的播放器与 store 状态，画面永远停在加载态、退不出去
  // （2026-11-01 实报「退不出直播间」）。只摘牌 + 交还画面。
  if (owner.isPageAlive) {
    owner.releaseMiniPlayerForForeground();
    await owner.closeDetachedWindow();
    await owner.resumePagePlayerAfterMini();
    return;
  }
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
