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
/// - **仍域外 7 条**：见 [kAylaChatWsOutOfBatchFrames] 的显式登记（不静默吞掉）。
///
/// ## 平台差异（登记）
/// - `isSubgroupMessageConfirmedRead`（子群已读确认）随子群域批次；本批私聊无子群概念 ⇒
///   `readByMe` 只由「自己在底部看到」与「服务端已读回执」两处驱动；
/// - `subscriptionHeads`（不依赖页面是否加载过历史的补发基线）**已按 web 实现**（`chat.ts:133–134`）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../state/badges_state.dart';
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
///   投影到 `state/subgroup_state.dart`），故此处只剩 **7 条**：
///   `post.*`(4) + `comment.*`(2) 属帖子域 ·
///   `favorite.changed`(1) 需一个**跨页共享**的收藏状态缓存（库内 `AylaFavoriteStatusController`
///   目前是每页实例 ⇒ 单点广播接不进去，属「收藏状态收敛轮」）。
const List<String> kAylaChatWsOutOfBatchFrames = <String>[
  'post.created',
  'post.deleted',
  'post.updated',
  'post.viewed',
  'comment.created',
  'comment.deleted',
  'favorite.changed',
];

/// `subscribe` 帧单批上限（web `chat.ts:193/256` 的 100 一组）。
const int kAylaChatSubscribeBatch = 100;

/// 群订阅登记失败的重试退避（web `chat.ts:316`：`5000 * 2^n`，上限 60s）。
const int kAylaChatRegistrationBaseMs = 5000;
const int kAylaChatRegistrationMaxMs = 60000;

/// 接收帧处理器（供页面监听 typing / 认证消息刷新等）。
typedef AylaChatFrameHandler = void Function(Map<String, dynamic> frame);

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
    final Map<String, dynamic> data = frame['data'] is Map
        ? Map<String, dynamic>.from(frame['data'] as Map)
        : const <String, dynamic>{};
    switch (rawType) {
      case 'message.new':
        _onMessageNew(data);
      case 'message.recall':
        _message.setRecalled(_str(data['conversation_id']), _str(data['message_id']));
      case 'message.poke':
        _onMessagePoke(data);
      case 'message.read':
        _message.markReadByMessage(
          _str(data['conversation_id']),
          _str(data['message_id']),
          _str(data['user_id']),
        );
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
      case 'pong':
      case 'error':
        break; // 连接层回执 / 服务端错误：web 同为 no-op
      default:
        // 仍域外的帧（见 kAylaChatWsOutOfBatchFrames）：显式忽略，不猜测语义。
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
