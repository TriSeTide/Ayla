/// 语音房会话层 —— web `runtime/voiceSessionRuntime.ts`（100 行）+
/// `hooks/useVoiceChannel.ts`（422 行）的 Flutter 等价物。
///
/// ## 两层分工（同 web）
/// - [AylaVoiceSessionRuntime]：**跨页面共享的会话 owner** —— 心跳、房间选择代际
///   （`selectionRevision`）、媒体归属（`mediaChannelId`）与「同一时刻只有一个
///   join/leave 在跑」（`runExclusive` / `runJoin` 合并）。全局单例。
/// - [AylaVoiceSession]：**页面级粘合**（web 的 `useVoiceChannel`）—— join/leave/
///   toggleMic/成员音量/错误文案。每个房内视图一份。
///
/// ## 关键不变量（web 注释里的血泪，逐条保留）
/// 1. `selectChannel` 前移 `selectionRevision`：被取代的未完成 join 不得再写状态；
/// 2. `runJoin` **合并同一 revision 的重复请求**（超车的排队房间永不发 join 请求）；
/// 3. `resetLocal` 幂等：被踢（`voice.state left` 帧）/心跳超时（403）/
///    房间删除（`voice.channel.deleted` 帧）三条路径都汇到它；
/// 4. **心跳归 runtime owner，页面卸载不停**（web 原话：`heartbeat 归 runtime owner；
///    页面卸载不停止，明确 leave 才释放`）；
/// 5. account 守卫：REST 往返期间账号变了 ⇒ 丢弃结果（`sameAccount()`）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../audio/voice_media.dart';
import '../core/api/users_api.dart' show AylaUserDetail, AylaUsersApi;
import '../core/api/voice_api.dart' hide AylaVoiceChatMessage;
import '../core/api/voice_api.dart' as api show AylaVoiceChatMessage;
import '../core/media/media_actions.dart' show AylaMediaActions;
import '../core/media/media_picker.dart' show AylaPickedFile;
import '../core/models/share_payload.dart' show AylaSharePayload;
import '../core/models/user_public.dart' show AylaUserPublic;
import '../core/net/dio_client.dart' show ApiException;
import '../core/ws/chat_ws.dart';
import '../core/ws/voice_ws.dart';
import '../state/auth_state.dart';
import '../state/chat_providers.dart' show chatWsProvider, elysiaProfileProvider;
import '../state/cursor_history.dart';
import '../state/favorite_status.dart';
import '../state/media_paged_list.dart';
import '../state/room_providers.dart';
import '../state/session_activity_state.dart';
import '../state/shell_state.dart';
import '../state/voice_state.dart';
import '../theme/app_theme.dart' show AylaTextStyles;
import '../theme/tokens.dart' show AylaSpacing;
import '../widgets/base/dialogs.dart' show AylaConfirmDialog;
import '../widgets/shell/create_sheet.dart' show AylaRootOverlay;
import '../widgets/base/directory_controls.dart' show AylaFavoriteButton;
import '../widgets/base/directory_page.dart' show aylaDirectoryIsNarrow;
// 历史窗口 ↔ 滚动控制器的绑定（web `hooks/useCursorHistory.ts` 自带的
// `listRef` + `useLayoutEffect` 贴底的 Flutter 等价物；见该文件头）。
import '../widgets/base/history_scroll_binding.dart';
import '../widgets/base/share.dart' show AylaShareButton;
import '../widgets/motion/gestures.dart' show AylaFullScreenSwipeBack;
import '../widgets/voice/voice_channel_panel.dart';
import '../widgets/voice/voice_member_row.dart' show AylaVoiceMember;
import '../widgets/voice/voice_room_body.dart';
import 'share_support.dart';

/// 语音 presence 心跳间隔（web `runtime/voiceSessionRuntime.ts:8`
/// `VOICE_HEARTBEAT_INTERVAL_MS = 40_000`；后端成员超时 120s，取其 1/3 量级）。
const Duration kVoiceHeartbeatInterval = Duration(seconds: 40);

/// 心跳失效原因（web `ExpiredReason`）。
enum AylaVoiceExpiredReason { removed, deleted }

/// 会话运行时（全局单例；web `voiceSessionRuntime`）。
class AylaVoiceSessionRuntime {
  Timer? _heartbeat;
  String? _channelId;
  void Function(AylaVoiceExpiredReason reason)? _expiredHandler;
  int _heartbeatRevision = 0;
  int _selectionRevision = 0;
  ({Object owner, String? channelId})? _selection;
  Future<void> _transitionTail = Future<void>.value();
  ({int revision, Future<void> promise})? _pendingJoin;
  String? _mediaChannelId;

  /// 路由选择（owner 变化或频道变化才前移 revision）。
  void selectChannel(Object owner, String? channelId) {
    final ({Object owner, String? channelId})? current = _selection;
    if (current != null &&
        identical(current.owner, owner) &&
        current.channelId == channelId) {
      return;
    }
    _selection = (owner: owner, channelId: channelId);
    _selectionRevision += 1;
  }

  /// 取消选择（离开房间时调用）。
  void cancelSelection() {
    _selection = null;
    _selectionRevision += 1;
  }

  /// 当前选中的频道 id。
  String? selectedChannelId() => _selection?.channelId;

  /// 当前选择代际。
  int currentRevision() => _selectionRevision;

  /// 该代际是否仍是最新。
  bool isRevisionCurrent(int revision) => _selectionRevision == revision;

  /// 记录媒体归属频道（null = 无媒体会话）。
  void setMediaChannel(String? channelId) => _mediaChannelId = channelId;

  /// 媒体归属频道。
  String? mediaChannel() => _mediaChannelId;

  /// 该频道是否持有媒体会话。
  bool ownsMedia(String channelId) => _mediaChannelId == channelId;

  /// 串行执行（**同一时刻只有一个 transition 能占有共享的 REST/媒体/WS 会话**）。
  Future<T> runExclusive<T>(Future<T> Function() operation) {
    final Future<T> task = _transitionTail.then(
      (_) => operation(),
      onError: (Object _) => operation(),
    );
    _transitionTail = task.then<void>((_) {}, onError: (Object _) {});
    return task;
  }

  /// 合并一次"选中的房间"进房请求（被取代的排队请求**永不发 join**）。
  Future<void> runJoin(
    Object owner,
    String channelId,
    Future<void> Function(bool Function() isCurrent) operation,
  ) {
    selectChannel(owner, channelId);
    final int revision = _selectionRevision;
    final ({int revision, Future<void> promise})? pending = _pendingJoin;
    if (pending != null && pending.revision == revision) return pending.promise;
    bool isCurrent() => _selectionRevision == revision;
    final Future<void> promise = runExclusive(() async {
      if (isCurrent()) await operation(isCurrent);
    }).whenComplete(() {
      if (_pendingJoin?.revision == revision) _pendingJoin = null;
    });
    _pendingJoin = (revision: revision, promise: promise);
    return promise;
  }

  /// 启动心跳（替换旧心跳；403/404 判定为"已被移出/房间已删除"并回调）。
  void startHeartbeat(
    String channelId,
    void Function(AylaVoiceExpiredReason reason) onExpired,
  ) {
    stopHeartbeat();
    final int revision = _heartbeatRevision;
    _channelId = channelId;
    _expiredHandler = onExpired;
    _heartbeat = Timer.periodic(kVoiceHeartbeatInterval, (Timer _) {
      if (_channelId != channelId || _heartbeatRevision != revision) return;
      unawaited(
        AylaVoiceApi.heartbeatVoiceChannel(channelId).catchError((Object error) {
          final int? status = error is ApiException ? error.status : null;
          if ((status == 403 || status == 404) &&
              _channelId == channelId &&
              _heartbeatRevision == revision) {
            final void Function(AylaVoiceExpiredReason)? handler = _expiredHandler;
            stopHeartbeat();
            handler?.call(
              status == 404
                  ? AylaVoiceExpiredReason.deleted
                  : AylaVoiceExpiredReason.removed,
            );
          }
        }),
      );
    });
  }

  /// 停止心跳（幂等；前移 revision 使在途回调失效）。
  void stopHeartbeat() {
    _heartbeatRevision += 1;
    _heartbeat?.cancel();
    _heartbeat = null;
    _channelId = null;
    _expiredHandler = null;
  }

  /// 是否正在为某频道心跳。
  bool isHeartbeating(String channelId) =>
      _channelId == channelId && _heartbeat != null;

  /// 测试/登出：复位全部（含在途 Future 链）。
  @visibleForTesting
  void debugReset() {
    stopHeartbeat();
    cancelSelection();
    _pendingJoin = null;
    _mediaChannelId = null;
    _transitionTail = Future<void>.value();
  }
}

/// 全局会话运行时（web `export const voiceSessionRuntime`）。
final AylaVoiceSessionRuntime voiceSessionRuntime = AylaVoiceSessionRuntime();

/// 进房选项（web `JoinOptions`）。
class AylaVoiceJoinOptions {
  const AylaVoiceJoinOptions({this.joinMuted = true, this.force = false});

  /// 加入时静音（默认 true：进频道默认关麦，避免误入即广播环境音）。
  final bool joinMuted;

  /// 显式媒体恢复（普通导航复用既有会话）。
  final bool force;
}

/// 页面级语音会话胶水（web `useVoiceChannel`）。
class AylaVoiceSession extends ChangeNotifier {
  AylaVoiceSession({
    required AylaVoiceState voiceState,
    required AylaVoiceWsClient voiceWs,
    required AylaVoiceMedia media,
    required String? Function() currentUserId,
    required String? Function() accessToken,
    AylaVoiceSessionRuntime? runtime,
    AylaChatWsClient? chat,
    AylaVoiceMediaEvents? mediaEvents,
    /// 媒体活动位写入（web `useAuthStore.getState().setMediaActivity(...)`，三处调用）。
    ///
    /// **默认 null = 不写**：本类还被画布样张与既有测试直接构造（断言媒体状态机），
    /// 默认动作必须是"不产生副作用"——那些调用方没有 auth 容器，也没有资格改全局登录态。
    /// 生产路径由 `_AylaVoiceRoomHostState.initState` 注入 `ref.read(...)` 的闭包。
    void Function(AylaMediaActivityKind kind, bool active, String? roomId)?
        onMediaActivity,

    /// 本房间自身的路由 —— 活动态索引的 `sourceRoute`（悬浮球点击的回房目标）。
    ///
    /// web 在 upsert 处现读 `window.location.pathname`（`useVoiceChannel.ts:258–259`）：
    /// 群内语音取 **群场景路由**（`/group/:id/voice`），一级语音取 `/voice/:id`。
    /// Flutter 的会话层没有 context ⇒ 由页面注入（两个挂载点已各自把
    /// `backPath` 传进来了 —— 它正是同一份事实）。
    ///
    /// **null = 本实例不写活动态索引**（与 [onMediaActivity] 同一纪律：画布样张与既有
    /// 测试直接构造本类断言媒体状态机，不得污染全局悬浮球）。生产两个挂载点恒传值。
    String? roomRoute,
  })  : _voice = voiceState,
        _ws = voiceWs,
        _media = media,
        _currentUserId = currentUserId,
        _accessToken = accessToken,
        _runtime = runtime ?? voiceSessionRuntime,
        _chat = chat,
        _onMediaActivity = onMediaActivity,
        _roomRoute = roomRoute {
    // ⚠️ 必须绑**媒体实例自己的**事件容器（默认分支）。
    //
    // 2026-10-26 用户实报「听得见声音但音量条完全不跳」的**真正根因**（上一轮
    // 只补了 `ref.watch` 订阅，不充分）：这里此前是 `mediaEvents ?? AylaVoiceMediaEvents()`
    // —— 新建的孤儿对象。而 [AylaVoiceMedia] 的回调转发在**构造体里**就绑定到
    // 它自己的那份 `_events` 上（`voice_media.dart` 的 `engineCallbacks.onRemoteAudioLevels`
    // → `_events.onRemoteAudioLevels?.call(...)`），引擎每 100ms 打的是**那一份**。
    // ⇒ 本会话把回调挂到没人调用的对象上：`setRemoteAudioLevels` / `setLocalAudioLevel` /
    // `setMedia` 全部永不触发，媒体链路本身正常（所以照样能听见声音）。
    // 测试守卫见 `test/voice_audio_level_wiring_test.dart`。
    bindMediaEvents(mediaEvents ?? _media.events);
    _chatOff = _chat?.onFrame(_onChatFrame);
    _wsOff = _ws.onFrame(_onVoiceFrame);
  }

  final AylaVoiceState _voice;
  final AylaVoiceWsClient _ws;
  final AylaVoiceMedia _media;
  final String? Function() _currentUserId;
  final String? Function() _accessToken;
  final AylaVoiceSessionRuntime _runtime;
  final AylaChatWsClient? _chat;

  /// 媒体活动位写入（见构造参数）；null = 本实例不改全局登录态。
  final void Function(AylaMediaActivityKind kind, bool active, String? roomId)?
      _onMediaActivity;

  /// 本房间自身路由（见构造参数）；null = 本实例不写活动态索引。
  final String? _roomRoute;

  void Function()? _chatOff;
  void Function()? _wsOff;

  /// 本视图的选择 owner（web `selectionOwnerRef`）。
  final Object _selectionOwner = Object();

  int _joinGeneration = 0;
  bool _joining = false;
  String? _error;
  bool _disposed = false;

  /// 进房进行中。
  bool get joining => _joining;

  /// 最近一次错误文案（页面展示；[clearError] 清除）。
  String? get error => _error;

  /// 媒体会话运行时（页面需要 ownsMedia 判定时用）。
  AylaVoiceSessionRuntime get runtime => _runtime;

  /// 绑定媒体层事件 → 状态（web `useVoiceChannel` 的 setEvents 块逐条）。
  void bindMediaEvents(AylaVoiceMediaEvents events) {
    events
      ..onStateChange = (RelayState state) {
        _voice.setMedia(_mediaConnectionOf(state));
        if (state == RelayState.connected) {
          _voice.setMicEnabled(_media.microphoneEnabled);
        }
      }
      ..onTrackMuted = (int slot, bool muted) {
        // 远端轨道静音事实 → **应用层成员事实**（web `onTrackMuted` 原话：
        // 成员表以 voice.state 为准，媒体事件只做提示；这里仅对**已在成员表里**的
        // identity 落一条 muted/unmuted）。
        final String? identity = _media.identityOfSlot(slot);
        if (identity == null) return;
        final AylaVoiceMemberState? existing = _voice.memberOf(identity);
        if (existing == null) return;
        _voice.applyVoiceState(
          _voice.currentChannelId ?? '',
          identity,
          muted
              ? AylaVoiceMemberEventState.muted
              : AylaVoiceMemberEventState.unmuted,
          DateTime.now().toIso8601String(),
        );
      }
      ..onLocalAudioLevel = _voice.setLocalAudioLevel
      ..onRemoteAudioLevels = _voice.setRemoteAudioLevels;
  }

  static AylaVoiceMediaConnection _mediaConnectionOf(RelayState state) =>
      switch (state) {
        RelayState.idle => AylaVoiceMediaConnection.idle,
        RelayState.connecting => AylaVoiceMediaConnection.connecting,
        RelayState.connected => AylaVoiceMediaConnection.connected,
        RelayState.reconnecting => AylaVoiceMediaConnection.reconnecting,
        RelayState.failed => AylaVoiceMediaConnection.failed,
        RelayState.closed => AylaVoiceMediaConnection.idle,
      };

  @override
  void dispose() {
    _disposed = true;
    _chatOff?.call();
    _chatOff = null;
    _wsOff?.call();
    _wsOff = null;
    super.dispose();
  }

  void _setError(String? message) {
    _error = message;
    if (!_disposed) notifyListeners();
  }

  /// 清错误文案（页面消费后调用）。
  void clearError() => _setError(null);

  void _setJoining(bool value) {
    _joining = value;
    if (!_disposed) notifyListeners();
  }

  /// 选择/取消选择当前房间（页面 `didChangeDependencies` 与路由变化时调用）。
  void select(String? channelId) {
    _runtime.selectChannel(_selectionOwner, channelId);
    final String? mediaChannel = _runtime.mediaChannel();
    if (mediaChannel != null &&
        mediaChannel != channelId &&
        _voice.currentChannelId != mediaChannel) {
      _runtime.setMediaChannel(null);
      unawaited(_media.disconnect());
    }
    if (!_disposed) notifyListeners();
  }

  bool _sameAccount(String? actor) => _currentUserId() == actor && !_disposed;

  /// 本地重置到未加入态（被踢/心跳超时/房间删除后的统一收尾；**幂等**）。
  Future<void> resetLocal({
    String? expectedChannelId,
    bool preserveSelection = false,
  }) async {
    final String? channelId = expectedChannelId ??
        _voice.currentChannelId ??
        _runtime.mediaChannel();
    if (!preserveSelection) {
      _runtime.cancelSelection();
      _joinGeneration += 1;
      _setJoining(false);
    }
    if (channelId != null && _runtime.isHeartbeating(channelId)) {
      _runtime.stopHeartbeat();
    }
    if (channelId != null) _ws.unsubscribe(channelId);
    if (channelId != null && _runtime.ownsMedia(channelId)) {
      _runtime.setMediaChannel(null);
      await _media.disconnect();
    }
    if (channelId == _voice.currentChannelId) _voice.leaveChannelLocal();
    // 媒体活动位 + 活动态索引收尾（web useVoiceChannel.ts:96–99）：
    // `if (channelId === useSessionActivityStore.getState().voiceSession?.sessionId)`
    // —— **按 id 校验**，别人的/上一次的房间不得被本次收尾误清。
    _clearVoiceActivity(channelId);
    // 注：web 的 `resetLocal` **不**改 `mine`（只有显式 leave 与 join 的补偿路径改），
    // 这里照 web 保持同口径（列表项的"我在其中"标记由下一次目录刷新收敛）。
  }

  /// 成员对账（join 后铺底 / WS 重连后补偿；web `reconcile`）。
  Future<void> reconcile(String channelId) async {
    final int revision = _runtime.currentRevision();
    final String? actor = _currentUserId();
    final List<AylaVoiceMemberDescriptor> list =
        await AylaVoiceApi.listVoiceChannelMembers(
      channelId,
      isCurrent: () => _sameAccount(actor),
    );
    if (_disposed ||
        _voice.currentChannelId != channelId ||
        !_runtime.isRevisionCurrent(revision)) {
      return;
    }
    _voice.reconcileMembers(list);
  }

  /// 加入频道（重复 join 同频道幂等安全；web `join`）。
  Future<void> join(
    String channelId, {
    AylaVoiceJoinOptions options = const AylaVoiceJoinOptions(),
  }) async {
    select(channelId);
    final int generation = ++_joinGeneration;
    _setJoining(true);
    _setError(null);
    try {
      await _runtime.runJoin(_selectionOwner, channelId,
          (bool Function() ownsSelection) async {
        final String? actor = _currentUserId();
        bool isCurrent() =>
            !_disposed && ownsSelection() && _currentUserId() == actor && _accessToken() != null;
        if (!isCurrent()) return;
        final String? initialChannel = _voice.currentChannelId;
        if (!options.force &&
            initialChannel == channelId &&
            _voice.media != AylaVoiceMediaConnection.failed) {
          return;
        }
        final String? previousChannelId = initialChannel;
        bool joined = false;
        bool committed = false;
        Object? failure;
        Future<void> clearProjection(String id) async {
          if (_currentUserId() != actor) return;
          if (_voice.currentChannelId == id) _voice.leaveChannelLocal();
          _voice.patchChannel(id, mine: false);
          // 媒体活动位 + 活动态索引：**按 id 校验**后收尾（web :229–234 ——
          // 这条是"join 补偿路径"的收尾，与 `resetLocal` 同款但独立一份）。
          _clearVoiceActivity(id, status: AylaActivityStatus.idle);
        }

        Future<void> releaseMedia(String id) async {
          if (!_runtime.ownsMedia(id)) return;
          _runtime.setMediaChannel(null);
          await _media.disconnect();
        }

        try {
          // REST 先改成员事实；即使随后被取代，也必须补偿**那一个**频道。
          // 回执里带 `media` 旁路字段（服务端裁决 transport + 双下发两种配置）：
          // 连接时按它选后端，LiveKit 失败可在**原地**降级到中继。
          final AylaVoiceJoinResult joinResult =
              await AylaVoiceApi.joinVoiceChannel(channelId);
          joined = true;
          if (!isCurrent()) return;
          if (previousChannelId != null && previousChannelId != channelId) {
            if (_runtime.isHeartbeating(previousChannelId)) {
              _runtime.stopHeartbeat();
            }
            _ws.unsubscribe(previousChannelId);
            await AylaVoiceApi.leaveVoiceChannel(previousChannelId);
            await releaseMedia(previousChannelId);
            await clearProjection(previousChannelId);
            if (!isCurrent()) return;
          }
          // 媒体活动位：**进房成功（REST 已改成员事实）后**才置真（web useVoiceChannel.ts:255–257）。
          _onMediaActivity?.call(
            AylaMediaActivityKind.voice,
            true,
            int.tryParse(channelId)?.toString(),
          );
          // 活动态索引 upsert（web useVoiceChannel.ts:256–262）。
          // ⚠️ `sourceRoute` 的群内分支：web 原话 `window.location.pathname.startsWith("/group/")`
          //    ? pathname : \`/voice/:id\` —— Flutter 侧不能在会话层读路由（无 context），
          //    由页面在构造时注入房间自身的路由（`AylaVoiceRoomHost` 的 `backPath` 就是它）。
          final String? roomRoute = _roomRoute;
          if (roomRoute != null) {
            aylaSessionActivity.upsert(
              AylaActivityRecord(
                kind: AylaActivityKind.voice,
                sessionId: channelId,
                sourceRoute: roomRoute,
                owner: _voice.channels[channelId]?.ownerId,
                title: _voiceChannelTitle(channelId),
                status: AylaActivityStatus.connecting, // web: status: "connecting"
              ),
            );
          }
          _voice.setMedia(AylaVoiceMediaConnection.connecting);
          _runtime.setMediaChannel(channelId);
          final String? mediaToken = _accessToken();
          if (mediaToken == null) {
            throw StateError('登录状态失效，请重新登录');
          }
          // 媒体通道：按服务端下发的 media 配置选传输（livekit | ws_relay），
          // LiveKit 连接失败**原地降级**到 ws_relay（web `useVoiceChannel.ts:266–275`）。
          // `selfUserId` 只用于 identity 纪律诊断（后端 identity 必须是裸 user.pk）。
          await _media.connectWithMedia(
            channelId,
            mediaToken,
            joinResult.media,
            selfUserId: _currentUserId(),
          );
          if (!isCurrent()) return;
          await _media.startAudio();
          if (!isCurrent()) return;
          final bool wantMic = !options.joinMuted;
          try {
            await _media.setMicrophoneEnabled(wantMic);
            if (!isCurrent()) return;
            _voice.setMicEnabled(wantMic);
          } on AylaVoiceMediaCancelled {
            rethrow;
          } catch (_) {
            if (!isCurrent()) return;
            _voice.setMicEnabled(false);
            if (wantMic) _setError('需要麦克风权限，已在静音状态加入');
          }
          final List<AylaVoiceMemberDescriptor> members =
              await AylaVoiceApi.listVoiceChannelMembers(
            channelId,
            isCurrent: () => isCurrent() && _currentUserId() == actor,
          );
          if (!isCurrent()) return;
          final Map<String, AylaVoiceMemberState> retained =
              _voice.currentChannelId == channelId
                  ? _voice.members
                  : const <String, AylaVoiceMemberState>{};
          _voice.enterChannel(channelId, <AylaVoiceMemberState>[
            for (final AylaVoiceMemberDescriptor m in members)
              AylaVoiceMemberState(
                userId: m.userId,
                joinedAt: m.joinedAt,
                lastSeenAt: m.lastSeenAt,
                muted: retained[m.userId]?.muted ?? false,
                volume: retained[m.userId]?.volume ?? 100,
                locallyMuted: retained[m.userId]?.locallyMuted ?? false,
                audioLevel: retained[m.userId]?.audioLevel ?? 0,
              ),
          ]);
          _voice.patchChannel(channelId, mine: true);
          // 活动态索引：媒体通道接通后转 connected（web useVoiceChannel.ts:294）。
          aylaSessionActivity.setStatus(
            AylaActivityKind.voice,
            AylaActivityStatus.connected,
          );
          _startHeartbeat(channelId);
          _ws.subscribe(<String>[channelId]);
          committed = true;
        } catch (error) {
          failure = error;
        } finally {
          if (joined && !committed) {
            try {
              await AylaVoiceApi.leaveVoiceChannel(channelId);
            } catch (error) {
              failure ??= error;
            }
            try {
              await releaseMedia(channelId);
            } catch (error) {
              failure ??= error;
            }
            await clearProjection(channelId);
          }
          if (failure != null && isCurrent()) {
            _voice.setMedia(
              joined
                  ? AylaVoiceMediaConnection.failed
                  : AylaVoiceMediaConnection.idle,
            );
            _setError(_joinErrorMessage(failure));
          }
        }
      });
    } finally {
        if (!_disposed && generation == _joinGeneration) _setJoining(false);
      }
  }

  /// 进房失败文案（web `useVoiceChannel.ts:311–314` 的三元链逐条）。
  String _joinErrorMessage(Object failure) {
    if (failure is AylaVoiceMediaCancelled) return '语音连接已被取代，请重试';
    if (failure is ApiException) {
      if (failure.status == 503) return '语音服务未配置，暂不可用';
      if (failure.status == 404) return '频道不存在';
      return failure.message;
    }
    if (failure is StateError) return failure.message;
    if (failure is Exception) {
      final String text = '$failure';
      return text.isEmpty ? '加入频道失败' : text;
    }
    return '加入频道失败';
  }

  void _startHeartbeat(String channelId) {
    _runtime.startHeartbeat(channelId, (AylaVoiceExpiredReason reason) {
      final String? next = _runtime.selectedChannelId();
      final bool switchingAway = next != null && next != channelId;
      unawaited(resetLocal(
        expectedChannelId: channelId,
        preserveSelection: switchingAway,
      ));
      if (!switchingAway) {
        _setError(
          reason == AylaVoiceExpiredReason.deleted
              ? '语音房已被删除'
              : '你已被移出语音频道（心跳超时）',
        );
      }
    });
  }

  /// 离开频道（幂等）。
  ///
  /// **服务端先裁决**：房主必须先转让（403）等拒绝在此抛出，本地状态
  /// （心跳/媒体/成员）保持原样，由调用方展示错误并留在房间；只有服务端确认离开后
  /// 才断开媒体并清理本地状态（web `leave` 原话）。
  Future<void> leave() async {
    final String? channelId = _voice.currentChannelId;
    final String? actor = _currentUserId();
    _runtime.cancelSelection();
    _joinGeneration += 1;
    _setJoining(false);
    await _runtime.runExclusive(() async {
      if (channelId == null) return;
      await AylaVoiceApi.leaveVoiceChannel(channelId);
      if (_runtime.isHeartbeating(channelId)) _runtime.stopHeartbeat();
      _ws.unsubscribe(channelId);
      if (_runtime.ownsMedia(channelId)) {
        _runtime.setMediaChannel(null);
        await _media.disconnect();
      }
      if (_voice.currentChannelId == channelId) _voice.leaveChannelLocal();
      if (_currentUserId() != actor) return;
      // 媒体活动位 + 活动态索引收尾（web :347–352；此路径的 status 是默认的 "ended"）。
      _clearVoiceActivity(channelId, status: AylaActivityStatus.ended);
      _voice.patchChannel(channelId, mine: false);
    });
  }

  /// 语音侧的媒体活动收尾（web `useVoiceChannel` 三处同款判定的唯一实现）。
  ///
  /// 判定顺序逐条对齐 web：**先按 id 校验**活动态索引里的会话是不是这一个，
  /// 是才清媒体位与索引（web 三处都是
  /// `if (useSessionActivityStore.getState().voiceSession?.sessionId === id)`）。
  /// 清媒体位放在索引清空**之前**（web 同序：`setMediaActivity(...)` → `clear("voice", ...)`）。
  ///
  /// [channelId] 可空：web 的 id 来自
  /// `expectedChannelId ?? currentChannelId ?? mediaChannel()`，三者都可能为 null；
  /// JS 的 `null === sessionId` 恒假 ⇒ 这里用 `!=` 比较同一个语义（Dart 的 `String?`
  /// 相等判定与 JS 的 `===` 对 null 的行为一致）。
  void _clearVoiceActivity(
    String? channelId, {
    AylaActivityStatus status = AylaActivityStatus.ended,
  }) {
    if (aylaSessionActivity.voiceSession?.sessionId != channelId) return;
    _onMediaActivity?.call(AylaMediaActivityKind.voice, false, null);
    aylaSessionActivity.clear(AylaActivityKind.voice, status);
  }

  /// 活动态索引的标题（web `useVoiceChannel.ts:260`）：
  /// `channels.find((channel) => channel.id === channelId)?.name ?? "语音房"`。
  ///
  /// 兜底是**字面量「语音房」**（不是频道 id、不是空串）—— web 用它表达"名字还没读到"。
  String _voiceChannelTitle(String channelId) {
    final String? name = _voice.channels[channelId]?.name;
    return (name == null || name.isEmpty) ? '语音房' : name;
  }

  /// 静音切换：乐观 UI + 媒体失败回滚（web `toggleMic`）。
  Future<void> toggleMic() async {
    final String? channelId = _voice.currentChannelId;
    final int revision = _runtime.currentRevision();
    final String? selected = _runtime.selectedChannelId();
    if (channelId == null || (selected != null && selected != channelId)) return;
    final bool next = !_voice.micEnabled;
    _voice.setMicEnabled(next);
    try {
      await _media.setMicrophoneEnabled(next);
      // 静音态上报（2026-10-29）：媒体开关**成功之后**，把"自己的"静音事实广播给
      // 同频道其他人。此前 muted/unmuted 只由各端从 LiveKit 的 TrackMuted/
      // TrackUnmuted 本地合成、服务端从不广播 ⇒ 换端登录 / 重进房间的人永远
      // 看不到别人当前是否静音（跨端静音态不同步，用户实报项之一）。
      //
      // 位置很关键：必须在媒体操作成功之后发，否则媒体失败回滚时会把错的
      // 状态广播出去（catch 分支不补发，天然避免）。
      _broadcastMicState(channelId, next);
    } catch (error) {
      if (_voice.currentChannelId != channelId ||
          !_runtime.isRevisionCurrent(revision)) {
        return;
      }
      _voice.setMicEnabled(!next);
      _setError(
        error is Exception ? '切换麦克风失败：$error' : '切换麦克风失败',
      );
    }
  }

  /// 把**自己的**静音态上报给服务端（由服务端广播成 `voice.state muted/unmuted`）。
  ///
  /// 只发帧、不改本地状态：本地成员表已由乐观更新写好；服务端回来的
  /// `voice.state` 会走 [_onVoiceFrame] 既有路径（幂等覆盖）。
  ///
  /// **不同步等待、失败不抛**：静音上报是辅助事实，不能因为它失败就回滚已经成功
  /// 的媒体操作（否则用户会看到"麦开了又关"）。
  void _broadcastMicState(String channelId, bool muted) {
    try {
      _ws.send(<String, dynamic>{
        'type': 'voice.mute',
        'channel_id': channelId,
        'muted': muted,
      });
    } catch (error) {
      debugPrint('[voice] 静音态上报失败（不影响媒体）: $error');
    }
  }

  /// 远端成员音量（本地播放偏好，不落库）。
  void setMemberVolume(String userId, double volume) {
    _voice.setMemberVolume(userId, volume);
    _media.setRemoteVolume(userId, volume / 100);
  }

  /// 远端成员本地播放静音（喇叭按钮；不改变 volume 设定值）。
  void setMemberLocallyMuted(String userId, bool muted) {
    _voice.setMemberLocallyMuted(userId, muted);
    final AylaVoiceMemberState? m = _voice.memberOf(userId);
    if (m != null) {
      _media.setRemoteVolume(userId, muted ? 0 : m.volume / 100);
    }
  }

  /// 本地麦克风音量 0~100（100 = 原始；web 映射 = `volume / 50` → 增益 0~2）。
  void setLocalVolume(double volume) {
    _voice.setLocalVolume(volume);
    _media.setLocalVolume(volume / 50);
  }

  /// 媒体最终断线后的"重新加入"（走 join 幂等路径）。
  Future<void> rejoin() async {
    final String? channelId = _voice.currentChannelId;
    if (channelId == null) return;
    await join(
      channelId,
      options: AylaVoiceJoinOptions(
        joinMuted: !_voice.micEnabled,
        force: true,
      ),
    );
  }

  // ---------------- 帧监听 ----------------

  /// 房主成员操作（页面传参用；[action] = `kick` / `transfer` 字面量）。
  Future<void> memberAction(
    String channelId,
    String userId,
    String action,
  ) =>
      AylaVoiceApi.actionVoiceMember(channelId, userId, action);

  void _onVoiceFrame(Map<String, dynamic> frame) {
    if (frame['type'] != 'voice.state') return;
    // 被踢（后端广播 left）→ 强制本地退出（web `useVoiceChannel.ts:172–184`）。
    final Object? raw = frame['data'];
    if (raw is! Map) return;
    final Map<String, dynamic> data = Map<String, dynamic>.from(raw);
    final AylaVoiceMemberEventState? state =
        AylaVoiceMemberEventState.parse(data['state']);
    if (state != AylaVoiceMemberEventState.left) return;
    final String? me = _currentUserId();
    final String channelId = _voice.currentChannelId ?? '';
    if (me == null ||
        channelId.isEmpty ||
        channelId != data['channel_id']?.toString() ||
        data['user_id']?.toString() != me) {
      return;
    }
    final String? next = _runtime.selectedChannelId();
    final bool switchingAway = next != null && next != channelId;
    unawaited(resetLocal(
      expectedChannelId: channelId,
      preserveSelection: switchingAway,
    ));
    if (!switchingAway) _setError('你已被移出语音频道');
  }

  void _onChatFrame(Map<String, dynamic> frame) {
    if (frame['type'] != 'voice.channel.deleted') return;
    final Object? raw = frame['data'];
    if (raw is! Map) return;
    final String deletedId =
        Map<String, dynamic>.from(raw)['channel_id']?.toString() ?? '';
    if (deletedId.isEmpty) return;
    final String? selected = _runtime.selectedChannelId();
    if (selected == deletedId) _runtime.cancelSelection();
    final String? channelId = _voice.currentChannelId;
    if (channelId != deletedId) return;
    unawaited(resetLocal(
      expectedChannelId: channelId,
      preserveSelection: selected != null && selected != channelId,
    ));
    _setError('语音房已被删除');
  }
}


// ======================= 页面级宿主 =======================

/// 语音房内页宿主 —— web `pages/VoiceHubPage.tsx:212–260` 的房内分支。
///
/// ## 职责（逐条对应 tsx）
/// | 本宿主 | web |
/// |---|---|
/// | 拉频道详情铺底（大厅列表还没返回也能渲染） | tsx 168–179 |
/// | 建 [AylaVoiceSession] 并在挂载时 `join(channelId, {joinMuted: true})` | tsx 184–192（`lastJoinRouteRef` 的"仅路由变化才 join"由 `ValueKey(channelId)` 重建表达） |
/// | 底栏下滑走 + 返回 | tsx 135–141（`setBottomTabsLeaving`）+ tsx 197–200 |
/// | 成员分页（limit 20）+ 帧失效 + `left` 剔除 + 自己出现后刷新一次 | `VoiceChannelPanel.tsx:53–100` |
/// | 房内聊天历史 + `voice.chat.message` 幂等 append | `VoiceRoomBody.tsx:82–135` |
/// | 删除房间确认弹窗 → DELETE → 本地收尾 | tsx 238–257 |
///
/// ## 机制差异（登记）
/// - 成员昵称/头像：web `VoiceMemberRow` 自带 `ensureUser` 懒拉（批量缓存）；Flutter 侧
///   无批量接口，由**本宿主**按"当前页成员 + 自己"逐个拉 `GET /users/{id}/` 并缓存
///   （与已交付 `live_hub_page.dart` 的主播名懒拉同手法）；
/// - 删除确认弹窗：web 走 `createPortal(document.body)`，Flutter 侧按库内惯例由宿主
///   `Stack` 顶层承载（`AylaConfirmDialog` 自带遮罩层；同 `game_room_placeholder.dart`）。
class AylaVoiceRoomHost extends ConsumerStatefulWidget {
  const AylaVoiceRoomHost({
    super.key,
    required this.channelId,
    this.backPath = '/voice',
    this.roomRoute,
    this.inGroup = false,
  });

  /// 是否**群内**语音（`/group/:id/voice/:cid`，2026-10-19 新增）。
  ///
  /// 群页已渲染 `AylaGroupTopTabs`，**状态栏由群顶栏覆盖着色** ⇒ 房内头部不应再让位，
  /// 否则群顶栏与房内头部之间会多出一条空白色带。
  /// 一级语音 tab（`/voice/:id`）没有群顶栏，必须自己让 ⇒ 默认 false。
  final bool inGroup;

  /// 频道 id（路由 `/voice/:channelId`）。
  final String channelId;

  /// 房内三条退出路径（返回 / 离开频道 / 删除房间后）的落点。
  ///
  /// 一级语音 tab = `/voice`（tsx 197–200 / 205–208 / 238–257）；群内语音
  /// （`GroupVoice.tsx:139–151`）传 `/group/:id/voice`——同一宿主两处复用，
  /// 避免群内复制一份房内编排。
  final String backPath;

  /// 悬浮球点击后的**回房路由**（活动态索引的 `sourceRoute`）。
  ///
  /// ⚠️ 与 [backPath] **不是同一个值**（2026-10-17 用户实报「列表页看不到语音悬浮球」轮区分）：
  /// - `backPath` = 房内「返回 / 离开 / 删除」的**退出落点** —— 一级语音是列表页 `/voice`；
  /// - `roomRoute` = 悬浮球点回来时要**回到的那个房间** —— 一级语音是 `/voice/:id`。
  ///
  /// web 的 `sourceRoute` 取的是后者（`useVoiceChannel.ts:258–259`：
  /// `pathname.startsWith("/group/") ? pathname : `/voice/${channelId}``），
  /// 此前 Flutter 侧把两者混用同一个 `backPath` ⇒ 一级语音的回房路由成了 `/voice`
  /// （列表页），点球**回不到房间**。
  ///
  /// null = 由 [backPath] 兜底（群内语音两者本来就相同：`/group/:id/voice`）。
  final String? roomRoute;

  @override
  ConsumerState<AylaVoiceRoomHost> createState() => _AylaVoiceRoomHostState();
}

class _AylaVoiceRoomHostState extends ConsumerState<AylaVoiceRoomHost> {
  late final AylaVoiceSession _session;
  late final AylaMediaPagedList<AylaVoiceMemberDescriptor> _members;
  late final AylaCursorHistory<api.AylaVoiceChatMessage> _chat;

  /// 房内聊天列表的滚动控制器 —— **归页面所有**（web `history.listRef` 同构）。
  ///
  /// 组件自己 new 出来的控制器页面拿不到，`pendingScrollToBottom` 就没有消费方
  /// （用户实报「语音房聊天老是新消息不自动滚底」的直接根因）；控制器上移后由
  /// [_chatScroll] 绑定消费。
  final ScrollController _chatScroll = ScrollController();

  /// 历史窗口 ↔ 滚动控制器绑定（贴底跟随 + 「距底 < 40 继续跟随」）。
  late final AylaHistoryScrollBinding<api.AylaVoiceChatMessage> _chatScrollBinding;
  late final AylaShareController _share;
  final AylaFavoriteStatusController _favorites = AylaFavoriteStatusController();

  /// 成员列表在加载期间被帧更新（web `invalidated`）。
  bool _membersInvalidated = false;

  /// 是否已为「自己出现在对账里」刷新过一次（web `refreshedChannelRef`）。
  bool _refreshedForSelf = false;

  /// 成员资料缓存（web `ensureUser` 的等价物；见类头「机制差异」）。
  final Map<String, AylaUserPublic> _profiles = <String, AylaUserPublic>{};
  final Set<String> _profileFetched = <String>{};

  bool _deleteConfirmOpen = false;
  bool _busyDeleting = false;
  String? _deleteError;

  /// shell UI notifier（initState 取出；**dispose 里 `ref` 不可用** —— Riverpod 会抛
  /// “Cannot use ref after the widget was disposed”）。
  ShellUiNotifier? _shell;

  void Function()? _voiceFrameOff;

  @override
  void initState() {
    super.initState();
    final String? selfId = ref.read(authNotifierProvider).user?.id;
    _session = AylaVoiceSession(
      voiceState: ref.read(voiceStateProvider),
      voiceWs: ref.read(voiceWsProvider),
      media: aylaVoiceMedia(),
      chat: ref.read(chatWsProvider),
      currentUserId: () => ref.read(authNotifierProvider).user?.id,
      accessToken: () => ref.read(authNotifierProvider).accessToken,
      // 媒体活动位（web `useAuthStore.getState().setMediaActivity` 的三处调用）
      // 与活动态索引的回房路由 —— 两条都只在生产装配里注入（会话类默认不写）。
      //
      // ⚠️ 闭包里用 `ref.read` 而不是缓存 notifier 字段：本回调只在**会话生命周期
      // 事件**（join 提交 / 心跳失效 / leave）里被同步调用，那时宿主必定仍挂着
      // （语音房是整页路由，卸载即会话结束）；且 `ref.read` 每次都是常数时间查表。
      // 若将来出现"会话活得比宿主久"的场景，这里要改成和 `LiveStudioPage` 一样
      // 在 initState 缓存 notifier 引用（那里有覆盖层遮蔽后 ref 失效的真实风险）。
      onMediaActivity: (AylaMediaActivityKind kind, bool active, String? roomId) =>
          ref.read(authNotifierProvider.notifier).setMediaActivity(
        kind: kind,
        active: active,
        roomId: roomId,
      ),
      // web `useVoiceChannel.ts:258–259`：群内语音的 `sourceRoute` 取**群场景路由**，
      // 一级语音取 `/voice/:id`。
      // ⚠️ 不能直接用 `backPath`：一级语音的 backPath 是**列表页** `/voice`（退出落点），
      // 而回房路由必须带频道 id（2026-10-17 修正 —— 混用会让点球回不到房间）。
      roomRoute: widget.roomRoute ?? widget.backPath,
    )..addListener(_onSessionChanged);
    _share = AylaShareController();
    _chat = AylaCursorHistory<api.AylaVoiceChatMessage>(
      owner: 'voice-chat:${selfId ?? ''}:${widget.channelId}',
      fetchPage: (String? cursor, String? beforeId) =>
          AylaVoiceApi.listVoiceChatMessagesPage(
        widget.channelId,
        cursor: cursor,
        beforeId: beforeId,
      ),
      idOf: (api.AylaVoiceChatMessage m) => m.id,
      createdAtOf: (api.AylaVoiceChatMessage m) => m.createdAt,
    )..addListener(_onChanged);
    // 贴底跟随的唯一 owner（web `useCursorHistory` 的 `listRef` + `pendingScroll`）：
    // 历史窗口一 notify 就排帧消费 `pendingScrollToBottom`，并在列表尚未挂载时
    // **保留**请求（不吞）—— `_bootstrap()` 的 `reset()` 早于首帧也不丢。
    _chatScrollBinding = AylaHistoryScrollBinding<api.AylaVoiceChatMessage>(
      history: _chat,
      controller: _chatScroll,
    )..bind();
    _members = AylaMediaPagedList<AylaVoiceMemberDescriptor>(
      scope: 'voice-members:${selfId ?? ''}:${widget.channelId}',
      request: (String? cursor) => AylaVoiceApi.listVoiceChannelMembersPage(
        widget.channelId,
        cursor: cursor,
        limit: 20,
      ),
      idOf: (AylaVoiceMemberDescriptor m) => m.userId,
    )..addListener(_onChanged);
    _voiceFrameOff = ref.read(voiceWsProvider).onFrame(_onVoiceFrame);
    _session.select(widget.channelId);
    unawaited(_bootstrap());
    // 底栏下滑走（web tsx 135–141）：首帧后注册；销毁时复位。
    _shell = ref.read(shellUiProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _shell?.setBottomTabsLeaving(true);
      // 登录后启动应用层语音通道（web `VoiceHubPage.tsx:144–146`）。
      // ⚠️ **放在首帧之后**：`connect()` 会同步写 `realtimeProvider`，而 initState
      // 期间改 provider 会被 Riverpod 拒绝（实测与 build 期同一条断言）。
      aylaStartVoiceWs(ref);
    });
  }

  @override
  void dispose() {
    _voiceFrameOff?.call();
    _voiceFrameOff = null;
    _session.removeListener(_onSessionChanged);
    _session.dispose();
    _chat.removeListener(_onChanged);
    // ⚠️ 先解绑（它会从 _chat / _chatScroll 上摘监听），再释放两者；
    // 顺序反了会在已 dispose 的 ChangeNotifier 上 removeListener。
    _chatScrollBinding.dispose();
    _chatScroll.dispose();
    _chat.dispose();
    _members.removeListener(_onChanged);
    _members.dispose();
    _favorites.dispose();
    _share.dispose();
    // ⚠️ Riverpod 禁止在 dispose 内改 provider ⇒ 延迟到生命周期之外
    // （与 `voice_hub_page.dart` 的 unregisterRefresh 同法）。
    scheduleMicrotask(() => _shell?.setBottomTabsLeaving(false));
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _bootstrap() async {
    final AylaVoiceState voice = ref.read(voiceStateProvider);
    if (voice.channelOf(widget.channelId) == null) {
      try {
        final AylaVoiceChannelSnapshot channel =
            await AylaVoiceApi.getVoiceChannel(widget.channelId);
        if (!mounted) return;
        voice.upsertChannel(channel);
      } catch (_) {
        // 404/403：房内没有描述 —— 头部退化为「语音房」（**不伪造名字**）
      }
    }
    if (!mounted) return;
    await _chat.reset();
    if (!mounted) return;
    await _members.reset();
    if (!mounted) return;
    await _session.join(widget.channelId);
  }

  void _onVoiceFrame(Map<String, dynamic> frame) {
    final Object? rawType = frame['type'];
    final Object? raw = frame['data'];
    if (raw is! Map) return;
    final Map<String, dynamic> data = Map<String, dynamic>.from(raw);
    if (data['channel_id']?.toString() != widget.channelId) return;
    if (rawType == 'voice.chat.message') {
      final api.AylaVoiceChatMessage? message =
          api.AylaVoiceChatMessage.fromJson(data);
      if (message == null) return;
      // 幂等（web：显示去重双向 —— 乐观 append 与 WS 回播谁先到都只渲染一条）。
      if (_chat.append(message)) setState(() {});
      return;
    }
    if (rawType != 'voice.state') return;
    final AylaVoiceMemberEventState? state =
        AylaVoiceMemberEventState.parse(data['state']);
    if (state != AylaVoiceMemberEventState.joined &&
        state != AylaVoiceMemberEventState.left) {
      return;
    }
    _membersInvalidated = true;
    if (state == AylaVoiceMemberEventState.left) {
      final String userId = data['user_id']?.toString() ?? '';
      if (userId.isNotEmpty) {
        _members.updateItems((List<AylaVoiceMemberDescriptor> items) =>
            <AylaVoiceMemberDescriptor>[
          for (final AylaVoiceMemberDescriptor m in items)
            if (m.userId != userId) m,
        ]);
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _refreshMembers() async {
    await _members.refresh();
    if (!mounted) return;
    setState(() => _membersInvalidated = false);
  }

  Future<void> _sendChat(String content) async {
    final api.AylaVoiceChatMessage message =
        await AylaVoiceApi.sendVoiceChatMessage(
      widget.channelId,
      content: content,
    );
    if (!mounted) return;
    // 乐观 append 同样按 id 去重（web `VoiceRoomBody.tsx:160–162`）。
    if (_chat.append(message)) setState(() {});
  }

  Future<void> _sendChatImage() async {
    final AylaPickedFile? file = await AylaMediaActions.pickImage();
    if (file == null || !mounted) return;
    final String mediaId = await AylaMediaActions.uploadImage(file);
    if (!mounted) return;
    final api.AylaVoiceChatMessage message =
        await AylaVoiceApi.sendVoiceChatMessage(
      widget.channelId,
      content: '图片',
      mediaId: mediaId,
    );
    if (!mounted) return;
    if (_chat.append(message)) setState(() {});
  }

  /// 头像点击目标 —— web `utils/navigation.ts:24–35` 的 `goUserProfile`
  /// （`VoiceMemberRow.tsx:143–149` 的调用方）：自己 → `/profile`，
  /// 他人 → `/user/:id`（encode），空 id 不跳。
  void _openUserProfile(String userId, String? currentUserId) {
    if (userId.isEmpty) return;
    if (currentUserId != null && currentUserId == userId) {
      // web goUserProfile 的 navigateTo('/profile') = **push** ⇒ 返回回原页面
      //（2026-10-23 返回键修复：go 会替换掉语音房 ⇒ 返回直接回主页）。
      context.push('/profile');
    } else {
      context.push('/user/${Uri.encodeComponent(userId)}');
    }
  }

  /// 成员行投影：分页描述符 + 当前状态表的媒体/音量事实（web `VoiceChannelPanel.tsx:61–64`）。
  /// 构造面板成员行。
  ///
  /// ⚠️ **2026-10-26 修复（用户实报「语音还是不跳动」）**：`voice` 由**调用方**
  /// 以 `ref.watch` 取得后传入 —— 本方法此前内部用 `ref.read(voiceStateProvider)`，
  /// 而它处在 **build 调用链**上：`ref.read` 不建立订阅 ⇒ 音频电平
  /// （`setRemoteAudioLevels` 每 100ms notify）到达后**页面根本不重建** ⇒
  /// 成员行的 `audioLevel` 永远停在初始 0 ⇒ 音量条**完全不跳**。
  ///
  /// 这是「听得见声音但条子不动」的直接原因：音频链路正常，只是 UI 没订阅。
  AylaVoicePanelMember _rowOf(AylaVoiceState voice, String userId) {
    final AylaVoiceMemberState? state = voice.memberOf(userId);
    final AylaUserPublic? profile = _profiles[userId];
    return AylaVoicePanelMember(
      member: state?.toMember() ?? AylaVoiceMember(userId: userId),
      displayName: profile?.displayName,
      avatarUrl: profile?.avatar,
      online: profile?.online ?? false,
    );
  }

  /// 为可见成员懒拉资料（web `ensureUser`；见类头「机制差异」）。
  void _ensureProfiles(List<String> userIds) {
    final List<String> missing = <String>[
      for (final String id in userIds)
        if (id.isNotEmpty && !_profileFetched.contains(id)) id,
    ];
    if (missing.isEmpty) return;
    _profileFetched.addAll(missing);
    unawaited(() async {
      for (final String id in missing) {
        try {
          final AylaUserDetail detail = await AylaUsersApi.getUserDetail(id);
          if (!mounted) return;
          setState(() => _profiles[id] = detail.user);
        } catch (_) {
          // 拉不到就回落 `user_id` 前 6 位（**不伪造昵称**）
        }
      }
    }());
  }

  Future<void> _runDelete() async {
    setState(() {
      _deleteConfirmOpen = false;
      _busyDeleting = true;
      _deleteError = null;
    });
    try {
      await AylaVoiceApi.deleteVoiceChannel(widget.channelId);
      if (!mounted) return;
      // 删除成功后本地即时收尾（不依赖 WS 广播时序；广播到达时同样幂等）。
      await _session.resetLocal(expectedChannelId: widget.channelId);
      if (!mounted) return;
      ref.read(voiceStateProvider).removeChannel(widget.channelId);
      if (!mounted) return;
      // 返回：能回退就 pop（进房是 push），栈底回 backPath。
      //
      // ⚠️ 此前这里是**三层嵌套的同一个 if**（2026-10-23 清理）：三个分支的条件与
      // 动作完全相同，纯属复制粘贴产物 —— 行为虽对，但读起来像有三级兜底，
      // 会误导后续改动。收敛成与 [_onBack] / [_onLeave] 完全一致的单一形态。
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(widget.backPath);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busyDeleting = false;
        _deleteError = error is Exception ? '$error' : '删除失败';
      });
    }
  }

  void _onBack() {
    // 顶部返回只离开房间界面，**保留语音连接与全局浮层**（web tsx 197–200）。
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(widget.backPath);
    }
  }

  Future<void> _onLeave() async {
    try {
      await _session.leave();
    } catch (_) {
      // 离开失败静默（web tsx 205–208）
    }
    if (!mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(widget.backPath);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool narrow = aylaDirectoryIsNarrow(context);
    final AylaTextStyles t = AylaTextStyles.of(context);
    // ---- 窄订阅（2026-10-26）----
    // 不再 `ref.watch(voiceStateProvider)` 整个 store（10Hz 电平 notify 会把整页 +
    // `AylaVoiceRoomBody`（1419 行）+ 整棵成员面板一起重建，与音频采集/解码挤在
    // 同一个 isolate 上）：改为按**本页渲染真正依赖的字段**逐个 `select` 订阅，
    // 电平字段交给面板内的 [ListenableBuilder]（见 `buildPanel`）。
    // **语义与视觉不变** —— 列在下面的就是本页全部依赖；新增读字段时必须同时加订阅。
    final AylaVoiceState voice = ref.read(voiceStateProvider);

    /// 一个字段 → 订阅表达式。
    ///
    /// `AylaVoiceChannelSnapshot` **没有** `==`/`hashCode`，`select` 拿它做相等
    /// 判断会恒不相等（等于没订阅、每帧都重建）⇒ 只在 `channels[本房]` 的**身份**
    /// 变化（upsert/patch/remove 都会换新实例）时重建；字段值取的是最新的那个实例。
    final AylaVoiceChannelSnapshot? channel = ref.watch(
      voiceStateProvider.select(
        (AylaVoiceState s) => s.channelOf(widget.channelId),
      ),
    );
    final String? selfId = ref.watch(
      authNotifierProvider.select((AuthState s) => s.user?.id),
    );
    // 自己是否已在存成员表里（web `VoiceChannelPanel.tsx:96–100` 的 `selfInStore`）
    // —— 依赖成员表的**身份集合**（joined/left），不依赖电平。
    final bool selfInStore = selfId != null &&
        ref.watch(
          voiceStateProvider.select(
            (AylaVoiceState s) => s.memberOf(selfId) != null,
          ),
        );
    // 媒体断线（`voice.media === failed`）：参与「重新加入」按钮，必须在订阅里。
    final bool rejoin = ref.watch(
      voiceStateProvider.select(
        (AylaVoiceState s) => s.media == AylaVoiceMediaConnection.failed,
      ),
    );
    // ★ 电平**不**在本页订阅（2026-10-26 收敛轮）：`audioLevel` / `localAudioLevel`
    // 每 100ms 就可能变一次，它们只被成员面板消费 ⇒ 由 `buildPanel` 的
    // [ListenableBuilder] 单独重绘那一棵子树（web 侧 zustand 的 selector 也是
    // 只重渲染成员行）。本页（页头 / 房间体 / 聊天列表）完全不参与 10Hz 重绘。
    // 本 build 里**没有任何**地方读电平字段 —— 若将来要读，必须走同样的窄订阅，
    // 否则电平变化不会再唤醒本页。
    final bool isOwner = channel != null && channel.ownerId == selfId;
    final String? sessionError = _session.error;
    // 爱莉的 user id（成员行头像光环判定；web `VoiceChannelPanel.tsx` 从 presence store 读）。
    // ⚠️ 必须**在这里**（build 期）watch：本值随后被 [ListenableBuilder] 的 builder 捕获使用，
    // 而那条路径由 10Hz notify 在 build 之外触发 —— 在回调里 `ref.watch` 会晚注册依赖。
    final String? elysiaUserId =
        ref.watch(elysiaProfileProvider).valueOrNull?.userId;
    // 自己出现在对账里而分页第一页还没有 ⇒ 刷新一次（web `VoiceChannelPanel.tsx:96–100`）。
    if (selfInStore && _members.loaded && !_refreshedForSelf) {
      _refreshedForSelf = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_refreshMembers());
      });
    }
    final List<String> visibleIds = <String>[
      for (final AylaVoiceMemberDescriptor m in _members.items) m.userId,
      if (selfId != null) selfId,
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureProfiles(visibleIds);
    });

    // 人数：只订阅**个数**（int，天然去抖）—— 电平变化不会改成员数，不会触发这里。
    final int? memberCount = ref.watch(
      voiceStateProvider.select(
        (AylaVoiceState s) => s.currentChannelId == widget.channelId
            ? s.members.length
            : null,
      ),
    );
    final int? displayCount = memberCount ?? (_members.loaded ? _members.total : null);

    // 面板构造 = 局部函数：材质归属档由房间体传入（见下方 voicePanelBuilder 的注释）。
    //
    // ⚠️ **这里是电平唯一的重绘面**（2026-10-26 窄订阅轮）：[ListenableBuilder] 只包
    // 成员面板这一棵子树（与 web 的 zustand selector 只重渲染成员行同粒度）——
    // 页头 / 房间体 / 聊天列表都不再跟 10Hz 电平抖动。
    Widget buildPanelContent(bool ownMaterial) => AylaVoiceChannelPanel(
      channelName: channel?.displayName ?? '语音房',
      members: <AylaVoicePanelMember>[
        for (final AylaVoiceMemberDescriptor m in _members.items)
          _rowOf(voice, m.userId),
      ],
      selfUserId: selfId,
      selfMember: selfId == null ? null : _rowOf(voice, selfId),
      // 值在 build 期取好（`valueOrNull`：无网络时该 FutureProvider 处于 AsyncError，
      // `.value` 会**抛出** —— 实测 LateInitializationError 冒到 build）。
      elysiaUserId: elysiaUserId,
      count: displayCount,
      isOwner: isOwner,
      self: voice.selfState(),
      page: AylaVoiceMembersPage(
        loading: _members.loading,
        error: _members.error,
        hasMore: _members.hasMore,
        invalidated: _membersInvalidated,
        loadMore: _members.loadMore,
        refresh: _refreshMembers,
      ),
      ownMaterial: ownMaterial,
      roomContext: true,
      showRejoin: rejoin,
      onToggleMic: () => unawaited(_session.toggleMic()),
      onLocalVolumeChange: _session.setLocalVolume,
      onVolumeChange: _session.setMemberVolume,
      onToggleMemberMuted: (String userId) {
        final AylaVoiceMemberState? m = voice.memberOf(userId);
        if (m != null) _session.setMemberLocallyMuted(userId, !m.locallyMuted);
      },
      // 成员头像 → 个人主页（web `VoiceMemberRow.tsx:143–149`：
      // `onClick={() => goUserProfile(currentUserId, member.user_id)}`）。
      // 语义 = `utils/navigation.ts:24–35`：自己 → /profile，他人 → /user/:id，空 id 不跳。
      onOpenProfile: (String userId) => _openUserProfile(userId, selfId),
      onLeave: () => unawaited(_onLeave()),
      onRejoin: () => unawaited(_session.rejoin()),
      onMemberAction: isOwner
          ? (String userId, AylaVoiceMemberAction action) async {
              // UI 枚举（voice_channel_panel.dart）→ API 字面量
              await _session.memberAction(widget.channelId, userId, action.name);
              await _refreshMembers();
            }
          : null,
    );

    /// 面板 = [ListenableBuilder] 订阅 `voiceState`（**只有成员面板重建**）。
    ///
    /// 订阅的是整个 `AylaVoiceState` 的 notify —— 与 web 面板内部
    /// `useVoiceStore(...)` 的粒度一致：成员表（含每一行的 `audioLevel`）任一变化
    /// 都重画面板；但**页头 / 房间体 / 聊天列表不参与**，10Hz 电平不会带着
    /// `AylaVoiceRoomBody`（1419 行）一起重建。
    Widget buildPanel(bool ownMaterial) => ListenableBuilder(
          listenable: voice,
          builder: (BuildContext _, Widget? __) => buildPanelContent(ownMaterial),
        );

    final AylaSharePayload sharePayload = AylaSharePayload.voice(
      id: widget.channelId,
      name: channel?.displayName ?? '语音房',
      memberCount: channel?.memberCount,
      groupId: channel?.group,
    );

    final Widget body = AylaVoiceRoomBody(
      channelName: channel?.displayName ?? '语音房',
      channelId: widget.channelId,
      selfUserId: selfId,
      isOwner: isOwner,
      visibilityLabels: channel?.visibilityLabels ?? const <String>[],
      // 展示投影：api 模型 → `voice_room_body.dart` 的 `AylaVoiceChatMessage`
      // （组件自带的消息投影，字段面更窄；两类的同名是历史命名，见该文件公开面）。
      messages: <AylaVoiceChatMessage>[
        for (final api.AylaVoiceChatMessage m in _chat.items)
          AylaVoiceChatMessage(
            id: m.id,
            senderNickname: m.senderNickname,
            senderUserId: m.senderUserId,
            content: m.content,
            mediaId: m.mediaId,
            thumbnailUrl: m.thumbnailUrl,
            media: m.media,
          ),
      ],
      history: AylaVoiceChatHistory(
        loading: _chat.loading,
        error: _chat.error,
        hasMore: _chat.hasMore,
        hasNewer: _chat.hasNewer,
        loadOlder: _chat.loadOlder,
        // web `returnLatest`：成功读回最新页才算数（失败保留原页，
        // `useCursorHistory.ts:112–117`）。Flutter `_load(older:false)` 成功后
        // 已同时做三件：`hasNewer` 归零（`cursor_history.dart:248` 的
        // `_invalidationRevision != revision`）、`following = true`（241 行）、
        // `pendingScrollToBottom = true`（242 行）⇒ 绑定会自动贴底，无需页面补收尾。
        returnLatest: _chat.returnLatest,
        retry: _chat.retry,
        // web `onScroll={history.handleScroll}`（tsx 187）→ `setFollowing`：
        // 距底 < 40 继续跟随，上翻即停（useCursorHistory.ts:160–164）。
        setFollowing: _chat.setFollowing,
      ),
      // web `VoiceRoomBody.tsx:97` `const chatListRef = history.listRef`：
      // 滚动容器与历史窗口同属一处 ⇒ 控制器由页面注入。
      chatListScroll: _chatScroll,
      // ⚠️ 根因 A（2026-10-08 修）：本页此前**只在「重试」分支里调 `_favorites.load`**
      // ⇒ 语音房头部收藏键在正常路径下永远 unknown（禁用 +「加载中…」）。
      // web `VoiceRoomBody.tsx:278` 只写
      // `<FavoriteButton targetType="voice" targetId={channelId} compact/>` ⇒
      // 加载由收藏键自己承担；Flutter 侧同样改为自给自足档。
      favorite: AylaFavoriteButton(
        compact: true,
        targetType: 'voice',
        targetId: widget.channelId,
        controller: _favorites,
      ),
      share: AylaShareButton(
        label: '分享语音房',
        onPressed: () => unawaited(aylaOpenShareSheet(
          context,
          payload: sharePayload,
          controller: _share,
          currentUserId: selfId,
        )),
      ),
      onBack: _onBack,
      onDeleteChannel: isOwner ? () => setState(() => _deleteConfirmOpen = true) : null,
      onSendText: _sendChat,
      onSendImage: _sendChatImage,
      // 群内：不让状态栏（群顶栏已覆盖着色，再让会多出一条空白色带）。
      topInset: !widget.inGroup,
      // 面板材质归属档由**房间体**按断点算好（宽屏材质在 `.voice-room-voice-card`、
      // 窄屏归 `.voice-panel`）⇒ 直接用它的入参，不再自行判定一遍。
      voicePanelBuilder: buildPanel,
    );

    final Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (sessionError != null)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AylaSpacing.sp4,
              vertical: AylaSpacing.sp2,
            ),
            child: Text(sessionError, style: t.body),
          ),
        if (_deleteError != null)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AylaSpacing.sp4,
              vertical: AylaSpacing.sp2,
            ),
            child: Text(_deleteError!, style: t.body),
          ),
        Expanded(child: body),
      ],
    );

    // ⚠️ 确认框**不放在本页 Stack 里**（2026-10-09 修）：web 的 `ConfirmDialog` 自身
    // `createPortal(…, document.body)`（`components/ConfirmDialog.tsx:10 / 52 / 118`），
    // ⇒ 遮罩是 `position: fixed; inset: 0`（`styles/private.css:185` 的
    // `.create-sheet-overlay`）铺满**整视口**。挂在本页 Stack 里则落在
    // **shell navigator 的那层 Overlay**（其上边界在顶栏之下，见 `layout/app_shell.dart`
    // 的 `Column[TopNav, Expanded(内容)]`）⇒ 实测遮罩只有 `(0,76)–(1526,900)`，
    // 顶栏那一整条不被压暗。改用 [AylaRootOverlay] 挂到根 Overlay。
    final Widget laid = Stack(
      children: <Widget>[
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: narrow
                  ? AylaFullScreenSwipeBack(onBack: _onBack, child: content)
                  : content,
            ),
          ],
        ),
        if (_deleteConfirmOpen)
          AylaRootOverlay(
            builder: (BuildContext _) => AylaConfirmDialog(
              title: '删除语音房',
              message: '确定删除语音房「${channel?.displayName ?? ''}」？此操作不可撤销，房间内所有人都会被移出。',
              busy: _busyDeleting,
              onConfirm: () => unawaited(_runDelete()),
              onClose: () => setState(() => _deleteConfirmOpen = false),
            ),
          ),
      ],
    );
    return laid;
  }
}
