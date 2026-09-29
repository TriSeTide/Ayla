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

import 'package:flutter/widgets.dart';

import '../core/api/live_api.dart';
import '../core/ws/chat_ws.dart';
import '../core/ws/live_ws.dart';
import '../player/hls_player.dart';
import '../player/platforms/hls_platform.dart';
import '../state/cursor_history.dart';
import '../state/live_state.dart';
import '../widgets/live/danmaku.dart' show AylaDanmakuEntry;
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
  })  : _live = liveState,
        _ws = liveWs,
        _chat = chat,
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
      final AylaLiveStatusResult status = await _fetchStatus(channelId);
      if (!_alive) return;
      store.setSrsStatus(status.status);
      _ws.connect(channelId);
      // 在看人数权威快照（必须晚于 setCurrentChannel —— setViewers 只认当前直播间）。
      unawaited(refreshViewers());
      if (status.status == AylaLiveSrsStatus.live) {
        await _attachPlayer();
      }
      store.setCurrentLoading(false);
    } catch (error) {
      if (!_alive) return;
      store.setCurrentError(error is Exception ? '$error' : '加载直播间失败');
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
    final String? url = channel?.hlsUrl;
    if (url == null || url.isEmpty) return;
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
    final String? url = _live.currentChannel?.hlsUrl;
    if (url == null || url.isEmpty) return;
    _playerAttached = true;
    await _player.destroy();
    await _player.attach(url);
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
  Future<void> stop() async {
    _alive = false;
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
    await _player.destroy();
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// 弹幕展示投影（页面装配 [AylaLiveRoomData.danmaku] 用）。
  ///
  /// 映射写在页面层（不在 `AylaLiveDanmaku` 上开 `toEntry`）：数据投影在 `core/api`、
  /// 展示投影 `AylaDanmakuEntry` 在 `widgets/live` ⇒ 由页面做跨层映射，
  /// 避免 `core/api` 反向依赖渲染类型。
  List<AylaDanmakuEntry> danmakuEntries({bool senderOnline = false}) {
    final List<AylaLiveDanmaku> source = _history?.items ?? _live.danmaku;
    return <AylaDanmakuEntry>[
      for (final AylaLiveDanmaku item in source)
        AylaDanmakuEntry(
          id: item.id,
          senderNickname: item.senderNickname,
          senderUserId: item.senderUserId,
          senderAvatarUrl: item.senderAvatar,
          senderOnline: senderOnline,
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
