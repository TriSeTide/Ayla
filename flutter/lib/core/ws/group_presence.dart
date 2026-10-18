/// 群 presence 对账 —— web `ws/chat.ts:335–378` 的 `queueGroupPresence` /
/// `refreshGroupPresence` 的 Flutter 等价物。
///
/// ## 它解决的问题（用户可感知）
/// 被踢出 / 主动退出的群，以及「群内已经没有任何语音房 / 直播 / 桌游房」的群，
/// presence 角标与会话列表都必须跟着变 —— 否则退出的群**永久滞留**在会话列表里。
/// web 侧的做法：三条房间帧族（`voice.channel.*` / `live.channel.*` /
/// `boardgame.room.*`）到达后只当作**失效信号**，用 250ms 窗口合并成一次
/// `POST /chat/group-presence/`（每批 ≤100 个会话 id），响应逐条落地：
/// - `presence === null`（当前用户已不是该群成员）⇒ `removeConversation` + `unsubscribe`；
/// - 否则 `upsertConversation({...conversation, group_presence: presence})`。
///
/// ## 逐条对应（web 事实源）
/// | 本件 | web |
/// |---|---|
/// | [queueGroupPresence] | `chat.ts:336–343`（`presenceDirty` + `presenceTimer` 250ms 合并） |
/// | [refreshGroupPresence] | `chat.ts:345–378`（只对**已加载的群**对账、分批 100） |
/// | [dispose] | `chat.ts:968–976`（`disconnect()` 清 timer / pending / dirty） |
///
/// ## 与 web 的一处**登记差异**（`getGroupPresence` 的 null 表达）
/// web 直接遍历响应 `presences` 的条目、判 `presence === null`；
/// Flutter 侧沿用的 [AylaChatApi.getGroupPresence] 返回
/// `Map<String, AylaGroupPresence>`（**已把 null 值过滤掉**）⇒ 无法直接表达「该群已不在」。
///
/// 因此本件按**后端契约**做保守推断：`GroupPresenceBatchView`（`apps/chat/views.py:80–98`）
/// 是 `result = dict.fromkeys(ids)` —— **每个请求到的 id 必然出现在响应里**（值为 null 表示
/// 非成员）。于是「**本批请求过、但响应里没有**」⇔ web 的 `presence === null`。
/// 这里只对**本批实际请求到**的 id 做删除判断（响应里多出来的键一概不管），
/// 且网络/协议失败一律保留原状（不误删，见 [refreshGroupPresence] 的 catch 分支）。
///
/// ## 纪律
/// - **账号守卫**：REST 往返期间账号变了 / 已 dispose ⇒ 丢弃整批结果（web 用
///   `actor` + `registrationRevision` 同法）；
/// - **失败保留原状**：网络错误只写 realtime 失败档（web 文案逐字），会话列表不动；
/// - 只对 `type === "group"` 的会话对账（私聊没有 presence 概念）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../state/chat_state.dart';
import '../../state/realtime_state.dart';
import '../api/chat_api.dart';
import '../models/conversation.dart'
    show AylaConversationSummary, AylaGroupPresence;

/// 帧合并窗口（web `chat.ts:341` 的 `setTimeout(…, 250)`）。
const Duration kAylaGroupPresenceWindow = Duration(milliseconds: 250);

/// 单批会话 id 上限（web `chat.ts:354` 的 `offset += 100`；
/// 后端 `GroupPresenceBatchView` 同样只接受 1..100 个）。
const int kAylaGroupPresenceBatch = 100;

/// 对账失败时写给 realtime 的文案（web `chat.ts:373` 逐字）。
const String kAylaGroupPresenceFailedText = '群状态更新失败，刷新页面可重试';

/// 群 presence 对账器（单例由 chat WS 帧桥持有）。
///
/// 生命周期 = 登录周期：帧桥构造时创建，登出（`disconnect`）后
/// [dispose] 由持有方在销毁路径调用（幂等）。
class AylaGroupPresenceReconciler {
  AylaGroupPresenceReconciler({
    required AylaChatState chatState,
    required String? Function() currentUserId,
    required void Function(String convId) unsubscribe,
    AylaRealtimeState? realtime,
    Future<Map<String, AylaGroupPresence>> Function(List<String> ids) fetch =
        AylaChatApi.getGroupPresence,
    this.coalesceWindow = kAylaGroupPresenceWindow,
    this.batchSize = kAylaGroupPresenceBatch,
  })  : _chat = chatState,
        _currentUserId = currentUserId,
        _unsubscribe = unsubscribe,
        _realtime = realtime,
        _fetch = fetch;

  final AylaChatState _chat;
  final String? Function() _currentUserId;

  /// 退订会话（web `this.unsubscribe(id)`）—— 被移出群后不再订阅它的消息。
  final void Function(String convId) _unsubscribe;

  /// 连接状态表（web `useRealtimeStore`）；**可空** = 不报连接状态
  /// （旧调用点 / 纯 store 测试；生产由帧桥注入）。
  final AylaRealtimeState? _realtime;

  /// 取一批 presence（默认 = [AylaChatApi.getGroupPresence]；测试注入假后端）。
  final Future<Map<String, AylaGroupPresence>> Function(List<String> ids) _fetch;

  /// 250ms 合并窗口（web `chat.ts:341`）。
  final Duration coalesceWindow;

  /// 单批 id 上限。
  final int batchSize;

  bool _closed = false;
  bool _pending = false;
  bool _dirty = false;
  Timer? _timer;

  /// 是否已销毁（登出后台不再接受新帧）。
  bool get isClosed => _closed;

  /// 是否有一轮对账在飞（web `presencePending`）。
  bool get isPending => _pending;

  /// 是否有未处理的失效信号（web `presenceDirty`）。
  bool get isDirty => _dirty;

  /// 已发起的对账轮数（测试观测用；生产不消费）。
  @visibleForTesting
  int debugRefreshCount = 0;

  /// 帧到达 ⇒ 登记失效信号，并在窗口后跑一轮对账（web `queueGroupPresence`）。
  ///
  /// 合并语义三条（逐条照 web `chat.ts:336–343`）：
  /// 1. 已经有 timer 在等 ⇒ **不重复起**（250ms 内所有帧共用一个窗口）；
  /// 2. 已经有一轮在飞 ⇒ 只置 dirty，由那一轮的 `finally` 再起一轮；
  /// 3. 已销毁 ⇒ 完全 no-op（web 的 `manualClosed`）。
  void queueGroupPresence() {
    if (_closed) return;
    _dirty = true;
    if (_timer != null || _pending) return;
    _timer = Timer(coalesceWindow, () {
      _timer = null;
      unawaited(refreshGroupPresence());
    });
  }

  /// 立即跑一轮对账（web `refreshGroupPresence`；[queueGroupPresence] 的窗口到点调它）。
  Future<void> refreshGroupPresence() async {
    if (_closed) return;
    final String? actor = _currentUserId();
    // web `chat.ts:347–348`：未登录 / 已断开 ⇒ 什么都不做（不伪造空结果）。
    if (actor == null) return;

    bool current() => !_closed && _currentUserId() == actor;

    debugRefreshCount += 1;
    _pending = true;
    _dirty = false;

    // web `chat.ts:352–353`：**只对已加载的群**对账（私聊不参与）。
    final List<String> ids = <String>[
      for (final AylaConversationSummary c in _chat.conversations)
        if (c.isGroup) c.id,
    ];

    try {
      for (int offset = 0; offset < ids.length; offset += batchSize) {
        final List<String> chunk = ids.sublist(
          offset,
          math.min(offset + batchSize, ids.length),
        );
        final Map<String, AylaGroupPresence> presences = await _fetch(chunk);
        if (!current()) return;
        for (final String id in chunk) {
          // web `chat.ts:357–358`：会话必须**仍在**列表里才处理（中途被别的路径删掉就跳过）。
          final AylaConversationSummary? conv = _chat.byId(id);
          if (conv == null) continue;
          final AylaGroupPresence? presence = presences[id];
          if (presence == null) {
            // web `chat.ts:362–364`：`presence === null` ⇒ 已不在群里 ⇒ 移除会话 + 退订。
            _chat.removeConversation(id);
            _unsubscribe(id);
          } else {
            // web `chat.ts:365–366`：`upsertConversation({ ...conversation, group_presence })`。
            _chat.upsertConversation(conv.copyWith(groupPresence: presence));
          }
        }
      }
    } catch (_) {
      // web `chat.ts:371–373`：失败**保留原状**，只把 chat 通道标成 failed + 可操作文案。
      if (current()) {
        _realtime?.setStatus(
          AylaRealtimeChannel.chat,
          AylaRealtimeConnection.failed,
          error: kAylaGroupPresenceFailedText,
        );
      }
    } finally {
      // web `chat.ts:374–377`：收起 pending；若期间又有帧进来（dirty）⇒ 立刻再排一轮。
      if (current()) {
        _pending = false;
        if (_dirty) queueGroupPresence();
      }
    }
  }

  /// 登出 / 断开：清 timer / pending / dirty（web `chat.ts:968–976` 的 `disconnect()` 收尾）。
  ///
  /// ⚠️ **不是** [dispose]：Flutter 的 `AylaChatWsClient` 是**跨登录周期**的单例
  /// （登出 `disconnect()` 后再次登录会 `connect()` 同一个实例），因此这里只清
  /// 传输期状态、对象仍可复用；真正销毁由持有方调 [dispose]。
  void reset() {
    _timer?.cancel();
    _timer = null;
    _pending = false;
    _dirty = false;
  }

  /// 销毁（终态）：[reset] + 之后到达的帧一律 no-op（不再对账）。
  ///
  /// 幂等。
  void dispose() {
    _closed = true;
    reset();
  }
}