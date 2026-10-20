/// chat 通道客户端 —— web `ws/chat.ts`（1000 行）的 Flutter 等价物。
///
/// ## 职责（与 web 逐条对应）
/// | 本类 | web |
/// |---|---|
/// | [connect] / [disconnect] | `chat.ts:148–158 / 958–982`（新连接会话重置首连标记） |
/// | [subscribe] / [resume] / [unsubscribe] | `chat.ts:254–280`（批量 `subscribe` 每 100 个一组） |
/// | `onOpen` 的首连/重连分档 | `chat.ts:171–196`（首连补发 `subscribe`、重连按 `last_message_seq` 逐条 `resume`） |
/// | [registerAuthorizedGroups] | `chat.ts:283–320`（分页订阅 + 失败 5s×2^n 退避、上限 60s） |
/// | [reconcileConversation] | `chat.ts:322–333`（帧只是失效信号，REST 摘要才是权威） |
/// | [onFrame] | `chat.ts:952–955`（页面级监听：typing / 认证消息刷新 / 评论帧） |
///
/// ## 41 个接收 case 的对账（**缺席即缺席**）
/// - **消息域批次实装 18 条**：`message.new` · `message.recall` · `message.poke` · `message.read` ·
///   `typing` · `history.sync` · `chat.subscribed` · `pong` · `error` · `elysia.reply` ·
///   `group.request.new` · `group.request.resolved` · `group.invite.new` · `friend.request.new` ·
///   `friend.request.resolved` · `group.member.left` · `group.created` · `group.joined`；
/// - **房内页批次转正 12 条**（2026-09-28）：`voice.channel.*`(4) · `live.channel.*`(4) ·
///   `live.viewers.changed`(1) · `boardgame.room.*`(3) —— 由 `core/ws/room_frames.dart` 的
///   [AylaRoomDirectoryBridge] 承接（挂在本类的 `onFrame` 上；**帧仍然流经 [onFrame] 的监听者**，
///   页面可另按需订阅）。
/// - **群聊批次再转正 4 条**（2026-09-29）：`subgroup.created` · `subgroup.updated` ·
///   `subgroup.deleted` · `subgroup.read` —— 直接投影到 `state/subgroup_state.dart`，
///   同时 `message.new` 补上子群归属（默认组兜底 / 子群未读 / 精确已读确认）。
/// - **排序实时源批次再转正 4 条**（2026-10-01）：`post.created` · `post.updated` ·
///   `post.deleted` · `post.viewed` —— 由 `core/ws/posts_frames.dart` 的
///   [AylaPostsFramesBridge] 承接（同 [AylaRoomDirectoryBridge] 的形制），
///   效应落在帖子 store + 群「新内容」排序。
/// - **仍域外 3 条**：见 [kAylaChatWsOutOfBatchFrames] 的显式登记（不静默吞掉）。
///
/// ## 平台差异（登记）
/// - `isSubgroupMessageConfirmedRead`（子群已读确认）已随子群域批次落地，且**不只在**
///   本条 `message.new` 路径：web 的 `withConfirmedRead`（`stores/message.ts:85–88`）
///   作用在**每一条入库路径**上（96 / 135 / 176 / 324），Flutter 侧同口径 ——
///   `state/message_state.dart` 的 `upsertMessage` / `resolvePendingMessage` /
///   `resolvePendingByKey` / `prependHistory` 都在入库前调用
///   `_withConfirmedRead`。本处的显式计算仍是必要的：下面的未读分派分支
///   （`else if (isFromOther && !confirmedRead)`）要读它。
/// - `subscriptionHeads`（不依赖页面是否加载过历史的补发基线）**已按 web 实现**（`chat.ts:133–134`）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../state/badges_state.dart';
import '../../state/favorite_status.dart' show aylaFavoriteApplyChanged;
import '../../state/chat_state.dart';
import '../../state/message_state.dart';
import '../../state/notices_state.dart';
import '../../state/realtime_state.dart';
import '../../state/group_providers.dart' show aylaApplySubgroupReadReceipt;
import '../../state/subgroup_state.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/share_payload.dart';
import '../models/subgroup.dart' show AylaSubGroup;
import '../models/post.dart' show AylaMediaDescriptor;
import '../api/chat_api.dart';
import '../net/dio_client.dart' show ApiException;
import 'ws_manager.dart';

/// **仍不属本批**的接收帧（见文件头对账；显式登记，避免「静默吞掉」被读成已实现）。
///
/// - 2026-09-28（房内页批次）从原 23 条中**转正 12 条**，由
///   `core/ws/room_frames.dart` 的 [AylaRoomDirectoryBridge] 承接（语音 4 + 直播 5 + 桌游 3）；
/// - 2026-09-29（群聊批次）再**转正 `subgroup.*` 4 条**（[AylaChatWsClient] 直接消费，
///   投影到 `state/subgroup_state.dart`）；
/// - 2026-10-01（排序实时源批次）再**转正 `post.*` 4 条**，由
///   `core/ws/posts_frames.dart` 的 [AylaPostsFramesBridge] 承接
///   （与 [AylaRoomDirectoryBridge] 同形制：挂在 [onFrame] 上，帧**照样流经本类**），
///   故此处只剩 **2 条**：
///   `comment.*`(2) 属帖子详情域（web 里该分支本身是 no-op，评论乐观插入由详情页的
///   `onFrame` 订阅消费）。
///
/// ⚠️ **`favorite.changed` 已于 2026-10-16 转正**（原登记「需跨页共享缓存，属收藏状态收敛轮」）：
/// `state/favorite_status.dart` 的 [aylaFavoriteApplyChanged] 会把增量广播给**全部**
/// 已注册的控制器实例（等价 web 模块级 store 的一次写入），本类直接消费（见 [_onFavoriteChanged]）。
const List<String> kAylaChatWsOutOfBatchFrames = <String>[
  'comment.created',
  'comment.deleted',
];

/// `subscribe` 帧单批上限（web `chat.ts:193/256` 的 100 一组）。
const int kAylaChatSubscribeBatch = 100;

/// 群订阅登记失败的重试退避（web `chat.ts:316`：`5000 * 2^n`，上限 60s）。
const int kAylaChatRegistrationBaseMs = 5000;
const int kAylaChatRegistrationMaxMs = 60000;

/// 接收帧处理器（供页面监听 typing / 认证消息刷新等）。
typedef AylaChatFrameHandler = void Function(Map<String, dynamic> frame);

/// 从「归属群 + 白名单群」提取该内容可见的群 id 集合（bump 排序用；去重、过滤空值）
/// —— web `ws/chat.ts:102–112` 的 `visibleGroupIds`。
///
/// web 的入参是 `{ group?: string | null; allowed_group_ids?: string[] | null }`
/// （voice/live 描述符的公共形状）；Dart 侧用命名参数逐字段对应，
/// 空串与 null 一律不算（web 的 `if (id != null)` + `if (descriptor.group)`）。
List<String> aylaVisibleGroupIds({
  String? group,
  Iterable<String> allowedGroupIds = const <String>[],
}) {
  final Set<String> ids = <String>{};
  if (group != null && group.isNotEmpty) ids.add(group);
  for (final String id in allowedGroupIds) {
    if (id.isNotEmpty) ids.add(id);
  }
  return ids.toList(growable: false);
}

/// bump 一段可见群 id 的「最近收到新内容」时间戳（单调，往前排）
/// —— web `ws/chat.ts:114–118` 的 `bumpGroups`。
void aylaBumpGroups(AylaChatState chat, Iterable<String> ids) {
  for (final String id in ids) {
    chat.bumpGroupActivity(id);
  }
}

/// chat 通道客户端（单例语义由 [aylaChatWs] 承担；测试可直接 new）。
class AylaChatWsClient {
  AylaChatWsClient({
    required AylaChatState chatState,
    required AylaMessageState messageState,
    required AylaNoticesController notices,
    required AylaBadgesController badges,
    required AylaRealtimeState realtime,
    required AylaSubGroupState subgroupState,
    required String? Function() currentUserId,
    this.autoReconcile = true,
  })  : _chat = chatState,
        _message = messageState,
        _notices = notices,
        _badges = badges,
        _realtime = realtime,
        _subgroups = subgroupState,
        _currentUserId = currentUserId;

  final AylaChatState _chat;
  final AylaMessageState _message;

  /// 子群未读/活跃度投影（`subgroup.*` 四条帧 + `message.new` 的子群归属）。
  final AylaSubGroupState _subgroups;
  final AylaNoticesController _notices;
  final AylaBadgesController _badges;
  final AylaRealtimeState _realtime;
  final String? Function() _currentUserId;

  /// 是否对未知会话自动拉摘要对账（web `chat.ts:452` 的 `reconcileConversation`）。
  final bool autoReconcile;

  WsChannel? _channel;
  bool _hasConnectedOnce = false;
  bool _manualClosed = false;

  /// 已订阅会话（重连后据此 resume）。
  final Set<String> _subscribed = <String>{};

  /// 订阅补发基线：**与页面是否加载过历史无关**（web `chat.ts:133–134`）。
  final Map<String, int> _subscriptionHeads = <String, int>{};

  final Set<AylaChatFrameHandler> _handlers = <AylaChatFrameHandler>{};

  final Map<String, Future<void>> _summaryReconciliations =
      <String, Future<void>>{};

  Timer? _registrationRetry;
  int _registrationAttempt = 0;
  Future<void>? _registrationPending;

  /// 当前连接状态（供 UI 的「连接中」提示）。
  WsChannelStatus get connection =>
      _channel?.status ?? WsChannelStatus.idle;

  /// 已订阅会话（只读）。
  Set<String> get subscribed => Set<String>.unmodifiable(_subscribed);

  /// 订阅补发基线（只读；测试与对账用）。
  Map<String, int> get subscriptionHeads =>
      Map<String, int>.unmodifiable(_subscriptionHeads);

  /// 绑定通道（生产 = `wsManager.chat`；测试 = 注入替身）。
  void attach(WsChannel channel) {
    _channel = channel;
    channel.onEvent = _dispatch;
    channel.onOpen = _onOpen;
    channel.onStatus = _onStatus;
  }

  /// 登录后连接（web `chatWS.connect()`）。
  void connect() {
    final WsChannel? channel = _channel;
    if (channel == null) return;
    _manualClosed = false;
    // 新连接会话（登录/刷新）：重置首连标记 ⇒ onOpen 走「补发 subscribe」而非 resume。
    _hasConnectedOnce = false;
    channel.connect();
    unawaited(registerAuthorizedGroups());
  }

  /// 显式断开（登出）：不自动重连，清订阅与基线。
  void disconnect() {
    _manualClosed = true;
    _subscribed.clear();
    _subscriptionHeads.clear();
    _registrationRetry?.cancel();
    _registrationRetry = null;
    _registrationAttempt = 0;
    _registrationPending = null;
    _summaryReconciliations.clear();
    _channel?.disconnect();
    _realtime.setStatus(
      AylaRealtimeChannel.chat,
      AylaRealtimeConnection.offline,
    );
  }

  /// 订阅一批会话（幂等；每 100 个一组发 `subscribe`）。
  void subscribe(List<String> convIds) {
    if (convIds.isEmpty) return;
    _subscribed.addAll(convIds);
    for (int i = 0; i < convIds.length; i += kAylaChatSubscribeBatch) {
      final List<String> batch = convIds.sublist(
        i,
        (i + kAylaChatSubscribeBatch) > convIds.length
            ? convIds.length
            : i + kAylaChatSubscribeBatch,
      );
      _send(<String, dynamic>{
        'type': 'subscribe',
        'conversation_ids': batch,
      });
    }
  }

  /// 订一条并**补发**（web `resume(convId)`）。
  ///
  /// ⚠️ 无基线（`lastSeq == 0` 且从未登记 head）时**只发 subscribe**：
  /// 未加载过历史的会话若发 `resume {last_message_seq: 0}`，后端会补发 seq>0 的**全部**消息（web 原话）。
  void resume(String convId, {int? lastMessageSeq}) {
    _subscribed.add(convId);
    final int head = _subscriptionHeads[convId] ?? 0;
    final int bucketSeq = _message.buckets[convId]?.lastSeq ?? 0;
    final int fromArg = lastMessageSeq ?? 0;
    int lastSeq = head > bucketSeq ? head : bucketSeq;
    if (fromArg > lastSeq) lastSeq = fromArg;
    if (lastSeq == 0 && !_subscriptionHeads.containsKey(convId)) {
      _send(<String, dynamic>{
        'type': 'subscribe',
        'conversation_ids': <String>[convId],
      });
      return;
    }
    _send(<String, dynamic>{
      'type': 'resume',
      'conversation_id': convId,
      'last_message_seq': lastSeq,
    });
  }

  /// 退订单个会话（服务端无独立退订帧；重连时不再 resume 即可，web 同）。
  void unsubscribe(String convId) {
    _subscribed.remove(convId);
  }

  /// 监听接收帧（返回值 = 取消函数）。
  void Function() onFrame(AylaChatFrameHandler handler) {
    _handlers.add(handler);
    return () => _handlers.remove(handler);
  }

  /// 登记有权订阅的会话（分页；失败退避重试）。
  Future<void> registerAuthorizedGroups() {
    final Future<void>? pending = _registrationPending;
    if (pending != null) return pending;
    final String? actor = _currentUserId();
    if (actor == null || _manualClosed) return Future<void>.value();
    late Future<void> task;
    task = () async {
      String? cursor;
      final Set<String> cursors = <String>{};
      while (true) {
        final page = await AylaChatApi.listConversationSubscriptionsPage(
          limit: 100,
          cursor: cursor,
        );
        if (_manualClosed || _currentUserId() != actor) return;
        for (final AylaConversationSubscription item in page.results) {
          _subscriptionHeads.putIfAbsent(item.id, () => item.lastMessageSeq);
        }
        subscribe(
          <String>[
            for (final AylaConversationSubscription item in page.results) item.id,
          ],
        );
        if (!page.hasMore) break;
        final String? next = page.nextCursor;
        if (next == null || cursors.contains(next)) {
          throw const ApiException(0, '群消息订阅分页无效');
        }
        cursors.add(next);
        cursor = next;
      }
      _registrationAttempt = 0;
      _registrationRetry?.cancel();
      _registrationRetry = null;
      if (_channel?.status == WsChannelStatus.online) {
        _realtime.setStatus(
          AylaRealtimeChannel.chat,
          AylaRealtimeConnection.online,
        );
      }
    }()
        .catchError((Object _) {
          if (_manualClosed) return;
          _realtime.setStatus(
            AylaRealtimeChannel.chat,
            AylaRealtimeConnection.failed,
            error: '群消息订阅未完成，正在重试',
          );
          _registrationRetry ??= Timer(
            Duration(
              milliseconds: _registrationBackoffMs(_registrationAttempt++),
            ),
            () {
              _registrationRetry = null;
              unawaited(registerAuthorizedGroups());
            },
          );
        })
        .whenComplete(() {
          if (_registrationPending == task) _registrationPending = null;
        });
    _registrationPending = task;
    return task;
  }

  static int _registrationBackoffMs(int attempt) {
    final int n = attempt > 4 ? 4 : attempt;
    final int delay = kAylaChatRegistrationBaseMs * (1 << n);
    return delay > kAylaChatRegistrationMaxMs
        ? kAylaChatRegistrationMaxMs
        : delay;
  }

  /// 拉一次会话摘要并 upsert（**帧只是失效信号，REST 才是权威**）。
  Future<void> reconcileConversation(String convId) {
    if (!autoReconcile) return Future<void>.value();
    final Future<void>? inFlight = _summaryReconciliations[convId];
    if (inFlight != null) return inFlight;
    final String? actor = _currentUserId();
    late Future<void> task;
    task = AylaChatApi.getConversationSummary(convId)
        .then((AylaConversationSummary conv) {
          if (actor != _currentUserId()) return;
          _chat.upsertConversation(conv);
        })
        .catchError((Object _) {
          // 403/404：当前用户不可见或已删除 —— 静默（页面下次显式刷新会报真实错误）
        })
        .whenComplete(() {
          if (_summaryReconciliations[convId] == task) {
            _summaryReconciliations.remove(convId);
          }
        });
    _summaryReconciliations[convId] = task;
    return task;
  }

  // ---------------- 连接生命周期 ----------------

  void _onStatus(WsChannelStatus status) {
    switch (status) {
      case WsChannelStatus.connecting:
        _realtime.setStatus(
          AylaRealtimeChannel.chat,
          _manualClosed
              ? AylaRealtimeConnection.offline
              : AylaRealtimeConnection.connecting,
        );
      case WsChannelStatus.online:
        _realtime.setStatus(
          AylaRealtimeChannel.chat,
          _registrationRetry != null
              ? AylaRealtimeConnection.failed
              : AylaRealtimeConnection.online,
          error: _registrationRetry != null ? '群消息订阅未完成，正在重试' : null,
        );
      case WsChannelStatus.offline:
        _realtime.setStatus(
          AylaRealtimeChannel.chat,
          AylaRealtimeConnection.offline,
        );
      case WsChannelStatus.idle:
        break;
    }
  }

  /// 连接建立：首连补发 `subscribe`，重连逐条 `resume`（web `chat.ts:171–196`）。
  void _onOpen() {
    if (_hasConnectedOnce) {
      for (final String convId in _subscribed) {
        resume(convId);
      }
      // 断线期间的私信/申请/邀请事件可能丢失 ⇒ 重连补拉一次（事件驱动主路径的兜底，
      // 全站轮询已删除，web `chat.ts:182–184`）。
      unawaited(_badges.fetch());
      return;
    }
    _hasConnectedOnce = true;
    if (_subscribed.isNotEmpty) {
      _send(<String, dynamic>{
        'type': 'subscribe',
        'conversation_ids': _subscribed.toList(growable: false),
      });
    }
  }

  void _send(Map<String, dynamic> json) {
    final void Function(Map<String, dynamic> frame)? override = debugSend;
    if (override != null) {
      override(json);
      return;
    }
    _channel?.send(json);
  }

  /// 测试专用：直接投喂一帧（生产路径是 [attach] 挂上的 `onEvent`）。
  @visibleForTesting
  void debugHandleFrame(Map<String, dynamic> frame) => _dispatch(frame);

  /// 测试专用：覆盖发送出口（默认走通道的 `send`）——用于断言 `subscribe` / `resume` 帧形状。
  @visibleForTesting
  void Function(Map<String, dynamic> frame)? debugSend;

  // ---------------- 事件分发 ----------------

  void _dispatch(Map<String, dynamic> frame) {
    final Object? rawType = frame['type'];
    if (rawType is! String) return;

    // 帧体分两种形状（后端如此，历史原因，不是缺陷）：
    // ① **会话级帧**（message.new / voice.channel.* / post.* …）：
    //    `{type, data:{...}}` ⇒ 取 data 子对象；
    // ② **用户级通知帧**（group.request.new / group.invite.new /
    //    friend.request.new / group.member.left / join_request.resolved …）：
    //    **扁平** `{type, request_id, conversation_title, ...}`（见
    //    `services._user_group_send_sync` 的载荷）⇒ 字段直接在顶层。
    //
    // ⚠️ 2026-10-20 修复：此前**只**取 `frame['data']`，扁平帧会拿到空 Map
    // ⇒ 所有通知类 case（:522 起的六条）读到的字段恒为 null，只能靠兜底文案
    // 「有人/群聊」显示 —— 用户永远看不到真实申请人/群名。
    final Map<String, dynamic> data = frame['data'] is Map
        ? Map<String, dynamic>.from(frame['data'] as Map)
        : frame;
    switch (rawType) {
      case 'message.new':
        _onMessageNew(data);
      case 'message.recall':
        _message.setRecalled(_str(data['conversation_id']), _str(data['message_id']));
      case 'message.poke':
        _onMessagePoke(data);
      case 'message.read':
        _onMessageRead(data);
      case 'subgroup.created':
      case 'subgroup.updated': {
        // web `chat.ts:514–530`：帧只带 id/name/is_default，**不带未读**
        // ⇒ upsert 时保留本地未读投影（[AylaSubGroupState.upsertSubgroup] 内部保证）。
        final String convId = _str(data['conversation_id']);
        final String sgId = _str(data['subgroup_id']);
        if (convId.isEmpty || sgId.isEmpty) break;
        _subgroups.upsertSubgroup(
          convId,
          AylaSubGroup(
            id: sgId,
            conversationId: convId,
            name: _str(data['name']),
            isDefault: data['is_default'] == true,
            unreadCount: _subgroups.unreadOf(convId, sgId),
            unreadSeqs: _subgroups.unreadSeqsOf(convId, sgId),
            hasUnreadSeqs: true,
            createdAt: data['created_at']?.toString(),
          ),
        );
      }
      case 'subgroup.deleted': {
        // web `chat.ts:531–545`：删掉后若它正是当前选中子群 → 切回默认组。
        final String convId = _str(data['conversation_id']);
        final String sgId = _str(data['subgroup_id']);
        if (convId.isEmpty || sgId.isEmpty) break;
        _subgroups.removeSubgroup(convId, sgId);
        if (_subgroups.activeSubgroupOf(convId) == sgId) {
          _subgroups.setActiveSubgroup(convId, _defaultSubgroupId(convId));
        }
      }
      case 'subgroup.read': {
        // 旧帧只有 `marked`、没有 `marked_seqs` ⇒ **无法证明哪些消息已读**，
        // 绝不据此清空新到的未读（web `chat.ts:543–547` 原话）。
        final String convId = _str(data['conversation_id']);
        final String sgId = _str(data['subgroup_id']);
        final String me = _currentUserId() ?? '';
        if (me.isNotEmpty && _str(data['user_id']) == me) {
          final Object? seqs = data['marked_seqs'];
          if (seqs is List) {
            aylaApplySubgroupReadReceipt(
              subgroupState: _subgroups,
              chatState: _chat,
              messageState: _message,
              convId: convId,
              subgroupId: sgId,
              markedSeqs: <int>[
                for (final Object? item in seqs)
                  if (item is num) item.toInt(),
              ],
            );
          }
          final AylaConversationSummary? conv = _chat.byId(convId);
          if (conv != null && conv.unreadSeqsComplete == false) {
            unawaited(reconcileConversation(convId));
          }
        }
      }
      case 'typing':
        break; // 由页面 onFrame 消费（私聊顶栏「对方正在输入…」）
      case 'history.sync':
        _message.setLastSeq(_str(data['conversation_id']), _int(data['last_seq']));
      case 'chat.subscribed':
        final String convId = _str(data['conversation_id']);
        _subscriptionHeads[convId] = _maxOf(
          _subscriptionHeads[convId] ?? 0,
          _int(data['last_seq']),
        );
      case 'group.request.new':
        _notices.push(
          kind: AylaRealtimeNoticeKind.groupRequestNew,
          title: '收到新的入群申请',
          detail:
              '${_strOr(data['applicant_name'], '有人')} 申请加入 ${_strOr(data['conversation_title'], '群聊')}',
        );
        unawaited(_badges.fetch());
      case 'group.request.resolved':
        _notices.push(
          kind: AylaRealtimeNoticeKind.groupRequestResolved,
          title: '入群申请有结果',
          detail:
              '${_strOr(data['conversation_title'], '群聊')}：你的申请${data['status'] == 'accepted' ? '已通过' : '已拒绝'}',
        );
        unawaited(_badges.fetch());
      case 'group.invite.new':
        _notices.push(
          kind: AylaRealtimeNoticeKind.groupInviteNew,
          title: '收到新的群邀请',
          detail:
              '${_strOr(data['inviter_name'], '有人')} 邀请你加入 ${_strOr(data['conversation_title'], '群聊')}',
        );
        unawaited(_badges.fetch());
      case 'friend.request.new':
        _notices.push(
          kind: AylaRealtimeNoticeKind.friendRequestNew,
          title: '收到新的好友申请',
          detail: '${_strOr(data['from_user_name'], '有人')} 想加你为好友',
        );
        unawaited(_badges.fetch());
      case 'friend.request.resolved':
        _notices.push(
          kind: AylaRealtimeNoticeKind.friendRequestResolved,
          title: '好友申请有结果',
          detail:
              '你的好友申请${data['status'] == 'accepted' ? '已通过' : '已拒绝'}',
        );
        unawaited(_badges.fetch());
      case 'group.member.left':
        _notices.push(
          kind: AylaRealtimeNoticeKind.groupMemberLeft,
          title: '群成员已离开',
          detail:
              '${_strOr(data['conversation_title'], '群聊')}：${_strOr(data['member_name'], '一位成员')} 已离开',
        );
      case 'group.created':
      case 'group.joined':
        final Object? conv = frame['conversation'];
        if (conv is Map) {
          final String id = _str(conv['id']);
          if (id.isNotEmpty) {
            subscribe(<String>[id]);
            unawaited(reconcileConversation(id));
          }
        }
      case 'elysia.reply':
        _onElysiaReply(data);
      case 'conversation.updated':
        _onConversationUpdated(data);
      case 'conversation.members.changed':
        _onConversationMembersChanged(data);
      case 'conversation.dissolved':
        _onConversationDissolved(data);
      case 'join_request.resolved':
        _onJoinRequestResolved(data);
      case 'favorite.changed':
        _onFavoriteChanged(data);
      case 'pong':
      case 'error':
        break; // 连接层回执 / 服务端错误：web 同为 no-op
      default:
        // 仍域外的帧（见 kAylaChatWsOutOfBatchFrames）：显式忽略，不猜测语义。
        // ⚠️ 已转正的帧（`voice/live/boardgame/post.*`）**同样落到这里** —— 本类对它们
        // 也是 no-op，真正的消费方是挂在 onFrame 上的两条帧桥（`room_frames.dart` /
        // `posts_frames.dart`）。不要因为「现在转正了」就在这里加分支。
        break;
    }
    for (final AylaChatFrameHandler handler in _handlers.toList(growable: false)) {
      handler(frame);
    }
  }

  /// `message.new`（web `chat.ts:409–509`）。
  void _onMessageNew(Map<String, dynamic> data) {
    final String convId = _str(data['conversation_id']);
    final int seq = _int(data['seq']);
    _subscriptionHeads[convId] = _maxOf(
      _subscriptionHeads[convId] ?? 0,
      seq,
    );
    // 子群归属投影（web `chat.ts:416–423`）：消息没带 `subgroup_id` 时归到**默认组**；
    // 已读确认按**会话级序号**判断（默认组描述尚未加载时的 legacy null 消息也能识别）。
    final String? subgroupId = data['subgroup_id']?.toString();
    final String? projectionId = subgroupId ?? _defaultSubgroupId(convId);
    final bool confirmedRead =
        _subgroups.isSubgroupMessageConfirmedRead(convId, seq);
    // 后端 WS 帧的 media 字段是 descriptor 对象（或 null）；兼容历史的裸 media_id 字符串。
    final Object? wsMedia = data['media'];
    final String? wsMediaId = wsMedia is String
        ? wsMedia
        : (wsMedia is Map ? wsMedia['media_id']?.toString() : null);
    final AylaChatMessage msg = AylaChatMessage(
      id: _str(data['message_id']),
      conversationId: convId,
      senderId: _str(data['sender_id']),
      type: AylaMessageType.parse(data['type'] as String?),
      content: _str(data['content']),
      mediaId: wsMediaId,
      media: wsMedia is Map
          ? AylaMediaDescriptor.fromJson(Map<String, dynamic>.from(wsMedia))
          : null,
      segments: _segmentsOf(data['segments']),
      sharePayload: data['share_payload'] is Map
          ? AylaSharePayload.fromJson(
              Map<String, dynamic>.from(data['share_payload'] as Map))
          : null,
      replyTo: data['reply_to']?.toString(),
      replyToSeq: _intOrNull(data['reply_to_seq']),
      readByMe: confirmedRead, // 服务端确认过的序号才是权威（web 同）
      status: AylaMessageStatus.sent,
      seq: seq,
      createdAt: _str(data['ts']),
      idempotencyKey: data['idempotency_key']?.toString(),
      subgroupId: subgroupId,
    );
    final String? me = _currentUserId();
    final bool isSelf = me != null && _str(data['sender_id']) == me;
    if (isSelf && msg.idempotencyKey != null) {
      // 自己发送的消息：用幂等键收敛本地 pending，避免双气泡。
      _message.resolvePendingByKey(convId, msg.idempotencyKey!, msg);
    } else {
      _message.upsertMessage(convId, msg);
    }
    final bool isFromOther = !isSelf;
    final bool isMention = isFromOther &&
        msg.segments.any((AylaMediaSegment seg) =>
            seg.type == AylaSegmentType.mention && seg.userId == me);
    final bool isReply = isFromOther && msg.replyTo != null;
    AylaConversationSummary? conv = _chat.byId(convId);
    if (conv == null) {
      unawaited(reconcileConversation(convId));
    }
    final bool isActive = _chat.activeConversationId == convId;
    // 活跃会话还需「滚在底部」才算正在看；翻记录时新消息计入未读（web `chat.ts:453–455`）。
    final bool atBottom = isActive && _message.viewerAtBottom(convId);
    // 子群视图：只有消息属于**当前选中子群**才视为「正在看」；否则计入该子群未读
    // （web `chat.ts:457–463`）。
    final String? activeSubgroupId = _subgroups.activeSubgroupOf(convId);
    final bool isActiveSubgroup = subgroupId == null ||
        activeSubgroupId == null ||
        activeSubgroupId == subgroupId;
    if (isFromOther &&
        conv != null &&
        conv.isPrivate &&
        atBottom &&
        isActiveSubgroup) {
      _message.markReadByMe(convId, msg.id);
      unawaited(
        AylaChatApi.markMessageRead(convId, msg.id, exact: true)
            .then((_) => _badges.fetch())
            .catchError((Object _) {}),
      );
    } else if (isFromOther && !confirmedRead) {
      // 群聊必须由 MessageList 实际可见的消息**精确确认**；底部状态不等于已看到。
      if (projectionId != null) {
        _subgroups.bumpSubgroupUnread(convId, projectionId, seq);
      }
      _chat.bumpUnread(convId,
          seq: seq, mention: isMention, reply: isReply);
      if (conv == null || conv.isPrivate || isMention) {
        unawaited(_badges.fetch());
      }
    }
    if (conv != null) {
      _chat.setLastMessage(
        convId,
        AylaLastMessagePreview(
          seq: seq,
          type: msg.type,
          content: msg.content,
          senderId: msg.senderId,
          senderName: _previewSenderName(conv, msg.senderId),
          status: 'sent',
          createdAt: msg.createdAt,
          preview: aylaSegmentPreviewOf(msg.segments) ??
              (msg.content.isNotEmpty ? msg.content : _typePreview(msg.type)),
        ),
      );
      if (conv.isGroup) _chat.bumpGroupActivity(convId);
    }
  }

  /// `message.read`（web `chat.ts:599–607`）。
  ///
  /// 两件事（web 逐条）：
  /// ① `message.markReadByMessage(conv_id, message_id, user_id)` —— 对端已读回执投影；
  /// ② **本人读**且该会话摘要的未读序号投影不完整（`unread_seqs_complete === false`）时
  ///    `reconcileConversation(conv_id)` —— 旧后端只给计数不给序号数组时，本地没法按
  ///    序号精确移除已读，只能拉一次权威摘要把计数收敛（web 原话）。
  ///
  /// ⚠️ ① 对**任何** user_id 都执行（含本人：其他端已读后本端也要同步）；② 只在「本人 +
  /// 序号不全」时执行 —— 序号完整的摘要本地已能精确推算，不必多打一次 REST。
  void _onMessageRead(Map<String, dynamic> data) {
    final String convId = _str(data['conversation_id']);
    final String userId = _str(data['user_id']);
    _message.markReadByMessage(
      convId,
      _str(data['message_id']),
      userId,
    );
    final String? me = _currentUserId();
    if (me == null || userId != me) return;
    final AylaConversationSummary? conv = _chat.byId(convId);
    if (conv != null && conv.unreadSeqsComplete == false) {
      unawaited(reconcileConversation(convId));
    }
  }

  /// 该会话的默认组 id（本地列表未加载 ⇒ null，**不猜**）。
  String? _defaultSubgroupId(String convId) {
    for (final AylaSubGroup sg in _subgroups.subgroupsOf(convId)) {
      if (sg.isDefault) return sg.id;
    }
    return null;
  }

  /// `message.poke`（web `chat.ts:558–598`）：独立事件，**不碰未读/红点/已读**。
  void _onMessagePoke(Map<String, dynamic> data) {
    final String convId = _str(data['conversation_id']);
    final int seq = _int(data['seq']);
    _message.upsertMessage(
      convId,
      AylaChatMessage(
        id: _str(data['message_id']),
        conversationId: convId,
        senderId: _str(data['sender_id']),
        type: AylaMessageType.poke,
        content: _str(data['target_user_id']),
        status: AylaMessageStatus.sent,
        seq: seq,
        createdAt: _str(data['ts']),
        subgroupId: data['subgroup_id']?.toString(),
      ),
    );
    final AylaConversationSummary? conv = _chat.byId(convId);
    if (conv == null) return;
    final String sender = _strOr(data['sender_name'], '有人');
    final String target = _strOr(data['target_name'], '对方');
    _chat.setLastMessage(
      convId,
      AylaLastMessagePreview(
        seq: seq,
        type: AylaMessageType.poke,
        content: _str(data['target_user_id']),
        senderId: _str(data['sender_id']),
        senderName: sender,
        status: 'sent',
        createdAt: _str(data['ts']),
        preview: '$sender戳了戳$target',
      ),
    );
    if (conv.isGroup) {
      _chat.bumpGroupActivity(convId);
    } else {
      _chat.bumpConversationActivity(convId);
    }
  }

  /// `elysia.reply`（web `chat.ts:885–936`）。
  void _onElysiaReply(Map<String, dynamic> data) {
    final String convId = _str(data['conversation_id']);
    final int seq = _int(data['seq']);
    final AylaChatMessage msg = AylaChatMessage(
      id: _str(data['message_id']),
      conversationId: convId,
      senderId: _str(data['sender_id']),
      type: AylaMessageType.parse(data['type'] as String?),
      content: _str(data['content']),
      status: AylaMessageStatus.sent,
      seq: seq,
      createdAt: _str(data['ts']),
    );
    _message.upsertMessage(convId, msg);
    final AylaConversationSummary? conv = _chat.byId(convId);
    if (conv != null) {
      _chat.setLastMessage(
        convId,
        AylaLastMessagePreview(
          seq: seq,
          type: msg.type,
          content: msg.content,
          senderId: msg.senderId,
          senderName: _previewSenderName(conv, msg.senderId),
          status: 'sent',
          createdAt: msg.createdAt,
          preview: msg.content.isNotEmpty ? msg.content : _typePreview(msg.type),
        ),
      );
      if (conv.isGroup) _chat.bumpGroupActivity(convId);
    }
    final bool atBottom = _chat.activeConversationId == convId &&
        _message.viewerAtBottom(convId);
    if (atBottom) {
      _message.markReadByMe(convId, msg.id);
      unawaited(
        AylaChatApi.markMessageRead(convId, msg.id, exact: true)
            .then((_) => _badges.fetch())
            .catchError((Object _) {}),
      );
    } else {
      _chat.bumpUnread(convId, seq: seq);
      if (conv == null || conv.isPrivate) {
        unawaited(_badges.fetch());
      }
    }
  }

  /// `favorite.changed`（web `ws/chat.ts:866–884`）。
  ///
  /// web 两档：
  /// - `target_type === "post"` ⇒ `usePostsStore.setFavorite(target_id, action==="added" ? favorite_id : null)`
  ///   （`stores/posts.ts:73–81`：写 `favoriteByPostId` + **同时** `applyFavoriteStatus`）；
  /// - 其余类型（live / voice / game / message）⇒ `applyFavoriteChanged(...)`
  ///   （`components/FavoriteButton.tsx:10–12` → 模块级收藏状态缓存）。
  ///
  /// Flutter 侧**只走一条**：两种目标类型最终都归到收藏状态机
  /// （`state/favorite_status.dart`）—— `posts_store.dart:33–35` 已登记
  /// 「不做 `favoriteByPostId`，收藏态由 `AylaFavoriteStatusController` 承担」，
  /// 因此 post 也走 [aylaFavoriteApplyChanged]。**与 web 的差异**仅在内部缓存载体
  /// （web 的 posts store 有第二份 `favoriteByPostId`，Flutter 没有），对外可观测行为一致：
  /// 同一目标的收藏键在两端都会被广播到。
  ///
  /// 帧结构（`api/types.ts`）：`data = { target_type, target_id, action, favorite_id }`。
  /// 取消收藏时后端不带 `favorite_id`（或带 null）⇒ 写 null。
  // ---------- 2026-10-20 补齐：群资料 / 成员 / 解散 / 审批（普查 W2/W4/W5/W6）----------

  /// `conversation.updated`（群资料变更：标题/公告/头像/入群策略/转让）。
  ///
  /// 后端此前**只 save 不广播** ⇒ 群壳标题、侧栏群名、会话列表、搜索结果全部停留旧值。
  /// 现在服务端会在 PATCH 后广播，客户端按 id 就地 patch 已加载的会话摘要。
  void _onConversationUpdated(Map<String, dynamic> data) {
    final Object? raw = data['conversation'];
    if (raw is! Map) return;
    final Map<String, dynamic> conv = Map<String, dynamic>.from(raw);
    final String id = _str(conv['id']);
    if (id.isEmpty) return;
    final AylaConversationSummary? existing = _chat.byId(id);
    // 未加载过这个会话 ⇒ 不凭空造（列表会在下次取页时拿到完整摘要）。
    if (existing == null) return;
    _chat.upsertConversation(_conversationWithMetadata(existing, conv));
  }

  /// `conversation.members.changed`（加入/踢出/退出/角色变更/转让）。
  ///
  /// 后端此前踢人、改角色**零广播**，`leave_group` 也只发给 owner/admin 且不更新人数
  /// ⇒ 群信息页成员列表、群名片人数、角色标签全部不实时；被踢者不知道自己被踢。
  void _onConversationMembersChanged(Map<String, dynamic> data) {
    final String convId = _str(data['conversation_id']);
    if (convId.isEmpty) return;
    final AylaConversationSummary? existing = _chat.byId(convId);
    if (existing != null) {
      final Object? count = data['member_count'];
      if (count is num) {
        _chat.upsertConversation(existing.copyWith(memberCount: count.toInt()));
      }
    }
    // 被踢/退出的是**本人** ⇒ 该会话要从列表移除，并退订。
    final String? me = _currentUserId();
    final String memberId = _str(data['member_id']);
    final String action = _str(data['action']);
    if (me != null &&
        memberId == me &&
        (action == 'left' || action == 'removed')) {
      _chat.removeConversation(convId);
      unsubscribe(convId);
    }
    // 群信息页/成员列表的权威数据由页面自行 REST 对账（这里只做摘要层投影）。
  }

  /// `conversation.dissolved`（群解散）。
  ///
  /// 后端此前直接 `conversation.delete()`、零广播 ⇒ 其他成员的会话列表、搜索结果、
  /// 正在看的群页全部残留，点开 404。
  void _onConversationDissolved(Map<String, dynamic> data) {
    final String convId = _str(data['conversation_id']);
    if (convId.isEmpty) return;
    _chat.removeConversation(convId);
    unsubscribe(convId);
  }

  /// `join_request.resolved`（入群申请已被**其他管理员**处理）。
  ///
  /// 后端此前只通知申请人 ⇒ 多管理员场景下 A 处理完的申请仍留在 B 的列表里。
  void _onJoinRequestResolved(Map<String, dynamic> data) {
    // 本类的职责边界：只把「有一条申请被处理了」作为失效信号广播给页面级监听
    //（与 web `noticeStore` 同口径）；具体列表刷新由消息中心的 onFrame 承担。
    _notices.push(
      kind: AylaRealtimeNoticeKind.groupRequestResolved,
      title: '入群申请已处理',
      detail:
          '${_strOr(data['conversation_title'], '群聊')}：${_strOr(data['applicant_name'], '有人')} 的申请已${data['status'] == 'accepted' ? '通过' : '拒绝'}',
    );
    unawaited(_badges.fetch());
  }

  /// 把 `conversation.updated` 帧里的元数据合进已有摘要（只覆盖帧里给出的字段）。
  static AylaConversationSummary _conversationWithMetadata(
    AylaConversationSummary existing,
    Map<String, dynamic> conv,
  ) {
    // 注：`ownerId` 不在 `copyWith` 的可变字段里（转让群主后由 REST 对账纠正，
    // 不在此处就地改写 —— 转让同时会触发 `conversation.members.changed`）。
    return existing.copyWith(
      title: conv['title']?.toString(),
      announcement: conv['announcement']?.toString(),
      avatar: conv['avatar']?.toString(),
      memberCount:
          conv['member_count'] is num ? (conv['member_count'] as num).toInt() : null,
    );
  }

  void _onFavoriteChanged(Map<String, dynamic> data) {
    final String targetType = _str(data['target_type']);
    final String targetId = _str(data['target_id']);
    // 缺 type/id ⇒ 直接忽略（不猜语义；web 对 undefined 也是空写）。
    if (targetType.isEmpty || targetId.isEmpty) return;
    final int? favoriteId = data['action'] == 'added'
        ? _intOrNull(data['favorite_id'])
        : null;
    aylaFavoriteApplyChanged(targetType, targetId, favoriteId);
  }

  /// 会话列表预览的发送者显示名（web `chat.ts:86–99`）。
  String _previewSenderName(AylaConversationSummary conv, String senderId) {
    final String? me = _currentUserId();
    if (me != null && senderId == me) return '我';
    if (conv.isPrivate && conv.peer != null) {
      return conv.peer!.displayName ?? '';
    }
    for (final AylaConversationMember m in conv.members) {
      if (m.user.id == senderId) return m.user.displayName ?? '';
    }
    return '';
  }
}

/// 类型兜底预览（web `chat.ts:501`：`[图片]` / `[视频]` / `[语音]`）。
String? _typePreview(AylaMessageType? type) => switch (type) {
      AylaMessageType.image => '[图片]',
      AylaMessageType.video => '[视频]',
      AylaMessageType.voice => '[语音]',
      _ => null,
    };

/// 混排摘要（web `utils/segment.ts` 的 `segmentPreview`）。
String? aylaSegmentPreviewOf(List<AylaMediaSegment> segments) {
  if (segments.isEmpty) return null;
  final StringBuffer out = StringBuffer();
  for (final AylaMediaSegment seg in segments) {
    switch (seg.type) {
      case AylaSegmentType.text:
        out.write(seg.text);
      case AylaSegmentType.image:
        out.write('[图片]');
      case AylaSegmentType.video:
        out.write('[视频]');
      case AylaSegmentType.mention:
        out.write('@${seg.mentionLabel}');
    }
  }
  final String text = out.toString().trim();
  return text.isEmpty ? null : text;
}

List<AylaMediaSegment> _segmentsOf(Object? raw) {
  if (raw is! List) return const <AylaMediaSegment>[];
  final List<AylaMediaSegment> out = <AylaMediaSegment>[];
  for (final Object? item in raw) {
    if (item is! Map) continue;
    final AylaMediaSegment? seg =
        AylaMediaSegment.fromJson(Map<String, dynamic>.from(item));
    if (seg != null) out.add(seg);
  }
  return List<AylaMediaSegment>.unmodifiable(out);
}

String _str(Object? raw) => raw?.toString() ?? '';

String _strOr(Object? raw, String fallback) {
  final String text = raw?.toString() ?? '';
  return text.isEmpty ? fallback : text;
}

int _int(Object? raw) => raw is num ? raw.toInt() : 0;

int? _intOrNull(Object? raw) => raw is num ? raw.toInt() : null;

int _maxOf(int a, int b) => a > b ? a : b;
