/// message 全局状态 —— web `stores/message.ts`（400 行）的 Flutter 等价物。
///
/// ## 逐条对应
/// | 本类 | web |
/// |---|---|
/// | [upsertMessage] | `message.ts:95–111`（按 seq 去重；重复投递忽略） |
/// | [addPendingMessage] | `message.ts:113–132`（幂等：同 id / 同幂等键的 pending 只留一条） |
/// | [resolvePendingMessage] / [resolvePendingByKey] | `message.ts:134–211`（本地 pending 与服务端消息**只留一条**） |
/// | [markMessageFailed] / [setMessageUploadProgress] / [removeMessage] | `message.ts:213–257` |
/// | [setRecalled] / [markReadByMe] / [markReadByMessage] | `message.ts:276–321` |
/// | [prependHistory] / [openBucket] / [setLastSeq] | `message.ts:323–389` |
/// | [viewerAtBottom] / [setViewerAtBottom] | `message.ts:391–397`（WS 判断「新消息是否即时已读」） |
///
/// ## 未实现（登记）
/// - `mergeMedia` 的异步补拉调用点（web `M5-2.1` 的 `media_id → descriptor`）：本库
///   `AylaMediaContent` 自带「descriptor 缺失时按 media_id 拉取」的路径 ⇒ store 侧不重复实现，
///   仅保留 [mergeMedia] 供调用方回填；
/// - 子群活动登记（`useSubGroupStore.recordMessageActivity`）属群聊子群域批次。
library;

import 'package:flutter/foundation.dart';

import '../core/models/chat_message.dart';
import '../core/models/post.dart' show AylaMediaDescriptor;

/// 一个会话的消息桶（`message.ts:17–25`）。
class AylaMessageBucket {
  const AylaMessageBucket({
    this.messages = const <AylaChatMessage>[],
    this.lastSeq = 0,
    this.hasMore = false,
    this.loading = false,
  });

  /// 按 seq 升序（pending 乐观消息恒置底）。
  final List<AylaChatMessage> messages;

  /// 已收到的最新 seq。
  final int lastSeq;

  /// 还有更早历史（返回条数 < limit 置 false）。
  final bool hasMore;

  final bool loading;

  AylaMessageBucket copyWith({
    List<AylaChatMessage>? messages,
    int? lastSeq,
    bool? hasMore,
    bool? loading,
  }) =>
      AylaMessageBucket(
        messages: messages ?? this.messages,
        lastSeq: lastSeq ?? this.lastSeq,
        hasMore: hasMore ?? this.hasMore,
        loading: loading ?? this.loading,
      );
}

/// 会话消息状态（按 conversation_id 分桶）。
class AylaMessageState extends ChangeNotifier {
  final Map<String, AylaMessageBucket> _buckets = <String, AylaMessageBucket>{};
  final Map<String, Map<String, List<String>>> _readMarks =
      <String, Map<String, List<String>>>{};
  final Map<String, bool> _viewerAtBottom = <String, bool>{};

  Map<String, AylaMessageBucket> get buckets =>
      Map<String, AylaMessageBucket>.unmodifiable(_buckets);

  /// 某会话的桶（null = 未打开过）。
  AylaMessageBucket? bucketOf(String convId) => _buckets[convId];

  /// 某会话的消息（未打开 ⇒ 空列表；**不代表服务端没有消息**）。
  List<AylaChatMessage> messagesOf(String convId) =>
      _buckets[convId]?.messages ?? const <AylaChatMessage>[];

  /// 是否滚动在底部（web `?? true`：未登记过视为在底部）。
  bool viewerAtBottom(String convId) => _viewerAtBottom[convId] ?? true;

  /// 某条消息的对端已读用户 id（群聊已读回执投影）。
  List<String> readBy(String convId, String messageId) =>
      _readMarks[convId]?[messageId] ?? const <String>[];

  /// 子群活跃度投影钩子 —— web `stores/message.ts:97/136/177/326` 的
  /// `useSubGroupStore.getState().recordMessageActivity(convId, msg.subgroup_id, msg.seq)`。
  ///
  /// 由装配层（`state/chat_providers.dart`）接到 [AylaSubGroupState]；
  /// **未接时是空操作** ⇒ 纯 state 单测与不关心子群的调用方行为不变。
  void Function(String convId, String? subgroupId, int seq)? onSubgroupActivity;

  /// 「已落库消息推进活跃度」：只有**带子群归属且 seq 为正**的消息参与
  /// （本地 pending seq=0 不参与排序 —— 与 web 同）。
  void _recordActivity(String convId, String? subgroupId, int seq) {
    if (subgroupId == null || seq <= 0) return;
    onSubgroupActivity?.call(convId, subgroupId, seq);
  }

  /// 插入（同 seq 的非 pending 消息**忽略**）。
  void upsertMessage(String convId, AylaChatMessage msg) {
    final AylaMessageBucket bucket =
        _buckets[convId] ?? const AylaMessageBucket();
    _buckets[convId] = bucket.copyWith(
      messages: aylaInsertBySeq(bucket.messages, msg),
      lastSeq: bucket.lastSeq > msg.seq ? bucket.lastSeq : msg.seq,
    );
    _recordActivity(convId, msg.subgroupId, msg.seq);
    notifyListeners();
  }

  /// 乐观发送：插入本地 pending 消息（seq=0 恒置底；按 id / 幂等键去重）。
  void addPendingMessage(String convId, AylaChatMessage msg) {
    final AylaMessageBucket bucket =
        _buckets[convId] ?? const AylaMessageBucket();
    final bool exists = bucket.messages.any((AylaChatMessage m) =>
        m.pending &&
            (m.id == msg.id ||
                (msg.idempotencyKey != null &&
                    m.idempotencyKey == msg.idempotencyKey)));
    if (exists) return;
    _buckets[convId] = bucket.copyWith(
      messages: aylaSortMessages(<AylaChatMessage>[...bucket.messages, msg]),
    );
    notifyListeners();
  }

  /// 乐观发送成功：localId 存在则原地替换；否则按 seq 幂等补入。
  void resolvePendingMessage(
    String convId,
    String localId,
    String idempotencyKey,
    AylaChatMessage serverMsg,
  ) {
    _recordActivity(convId, serverMsg.subgroupId, serverMsg.seq);
    final AylaMessageBucket? bucket = _buckets[convId];
    if (bucket == null) return;
    final bool localExists = bucket.messages
        .any((AylaChatMessage m) => m.pending && m.id == localId);
    if (!localExists) {
      if (bucket.messages
          .any((AylaChatMessage m) => !m.pending && m.seq == serverMsg.seq)) {
        return;
      }
      _buckets[convId] = bucket.copyWith(
        messages: aylaSortMessages(<AylaChatMessage>[...bucket.messages, serverMsg]),
        lastSeq: bucket.lastSeq > serverMsg.seq ? bucket.lastSeq : serverMsg.seq,
      );
      notifyListeners();
      return;
    }
    // pending 还在：删本地 pending + 删同 seq 的 WS 版，补服务端回包。
    final List<AylaChatMessage> filtered = <AylaChatMessage>[
      for (final AylaChatMessage m in bucket.messages)
        if (!(m.pending && m.idempotencyKey == idempotencyKey) &&
            !(!m.pending && m.seq == serverMsg.seq))
          m,
    ];
    _buckets[convId] = bucket.copyWith(
      messages: aylaSortMessages(<AylaChatMessage>[...filtered, serverMsg]),
      lastSeq: bucket.lastSeq > serverMsg.seq ? bucket.lastSeq : serverMsg.seq,
    );
    notifyListeners();
  }

  /// WS 广播带幂等键到达自己发送的消息：用服务端消息替换匹配的本地 pending。
  void resolvePendingByKey(
    String convId,
    String idempotencyKey,
    AylaChatMessage serverMsg,
  ) {
    _recordActivity(convId, serverMsg.subgroupId, serverMsg.seq);
    final AylaMessageBucket? bucket = _buckets[convId];
    if (bucket == null) return;
    AylaChatMessage? pending;
    for (final AylaChatMessage m in bucket.messages) {
      if (m.pending && m.idempotencyKey == idempotencyKey) {
        pending = m;
        break;
      }
    }
    if (pending == null) {
      _buckets[convId] = bucket.copyWith(
        messages: aylaInsertBySeq(bucket.messages, serverMsg),
        lastSeq: bucket.lastSeq > serverMsg.seq ? bucket.lastSeq : serverMsg.seq,
      );
      notifyListeners();
      return;
    }
    final String pendingId = pending.id;
    _buckets[convId] = bucket.copyWith(
      messages: aylaSortMessages(<AylaChatMessage>[
        for (final AylaChatMessage m in bucket.messages)
          if (m.id == pendingId) serverMsg else m,
      ]),
      lastSeq: bucket.lastSeq > serverMsg.seq ? bucket.lastSeq : serverMsg.seq,
    );
    notifyListeners();
  }

  /// 乐观发送失败：消息保留、标记失败态（气泡左侧可重试/删除）。
  void markMessageFailed(String convId, String messageId) {
    _patch(convId, messageId, (AylaChatMessage m) {
      return m.copyWith(pending: false, sendFailed: true);
    });
  }

  /// 上传进度（0–100；null = 上传完成/无媒体）。
  void setMessageUploadProgress(
    String convId,
    String messageId,
    double? pct,
  ) {
    _patch(convId, messageId, (AylaChatMessage m) {
      if (!m.pending) return m;
      return m.copyWith(uploadProgress: pct, resetUploadProgress: pct == null);
    });
  }

  /// 删除消息（乐观失败丢弃 / 本地清理）。
  void removeMessage(String convId, String messageId) {
    final AylaMessageBucket? bucket = _buckets[convId];
    if (bucket == null) return;
    final List<AylaChatMessage> next = <AylaChatMessage>[
      for (final AylaChatMessage m in bucket.messages)
        if (m.id != messageId) m,
    ];
    if (next.length == bucket.messages.length) return;
    _buckets[convId] = bucket.copyWith(messages: next);
    notifyListeners();
  }

  /// 撤回是「元事件」：只改状态，不新增消息。
  void setRecalled(String convId, String messageId) {
    _patch(convId, messageId, (AylaChatMessage m) {
      return m.copyWith(status: AylaMessageStatus.recalled);
    });
  }

  /// 服务端确认后：本地已读投影（自己）。
  void markReadByMe(String convId, String messageId) {
    _patch(convId, messageId, (AylaChatMessage m) {
      return m.copyWith(readByMe: true);
    });
  }

  /// 对端已读回执（`message.read` 帧）。
  void markReadByMessage(String convId, String messageId, String userId) {
    final Map<String, List<String>> convMarks =
        _readMarks[convId] ?? <String, List<String>>{};
    final List<String> users = convMarks[messageId] ?? const <String>[];
    if (users.contains(userId)) return;
    _readMarks[convId] = <String, List<String>>{
      ...convMarks,
      messageId: <String>[...users, userId],
    };
    notifyListeners();
  }

  /// 回填媒体 descriptor（WS 帧只带 media_id 时的异步补拉）。
  void mergeMedia(String convId, String messageId, AylaMediaDescriptor media) {
    _patch(convId, messageId, (AylaChatMessage m) {
      return m.copyWith(media: media);
    });
  }

  /// 历史前插（`before_seq` 分页；[hasMore] = 本页是否还可能继续往前）。
  void prependHistory(
    String convId,
    List<AylaChatMessage> msgs, {
    required bool hasMore,
  }) {
    final AylaMessageBucket bucket = _buckets[convId] ??
        const AylaMessageBucket();
    List<AylaChatMessage> merged = bucket.messages;
    for (final AylaChatMessage m in msgs) {
      merged = aylaInsertBySeq(merged, m);
    }
    int lastSeq = bucket.lastSeq;
    for (final AylaChatMessage m in msgs) {
      if (m.seq > lastSeq) lastSeq = m.seq;
    }
    _buckets[convId] = bucket.copyWith(
      messages: merged,
      hasMore: hasMore,
      lastSeq: lastSeq,
    );
    for (final AylaChatMessage m in msgs) {
      _recordActivity(convId, m.subgroupId, m.seq);
    }
    notifyListeners();
  }

  /// 打开桶（未存在时建空桶；`hasMore: true` 与 web 同 —— 首屏尚未取过历史）。
  void openBucket(String convId) {
    if (_buckets.containsKey(convId)) return;
    _buckets[convId] = const AylaMessageBucket(hasMore: true);
    notifyListeners();
  }

  void setLoading(String convId, bool loading) {
    final AylaMessageBucket? bucket = _buckets[convId];
    if (bucket == null) return;
    _buckets[convId] = bucket.copyWith(loading: loading);
    notifyListeners();
  }

  /// `history.sync` / `chat.subscribed`：只推进基线，不改消息集合。
  void setLastSeq(String convId, int lastSeq) {
    final AylaMessageBucket? bucket = _buckets[convId];
    if (bucket == null) return;
    if (bucket.lastSeq >= lastSeq) return;
    _buckets[convId] = bucket.copyWith(lastSeq: lastSeq);
    notifyListeners();
  }

  void setViewerAtBottom(String convId, bool atBottom) {
    if (_viewerAtBottom[convId] == atBottom) return;
    _viewerAtBottom[convId] = atBottom;
    notifyListeners();
  }

  /// 登出 / 切用户。
  void reset() {
    _buckets.clear();
    _readMarks.clear();
    _viewerAtBottom.clear();
    notifyListeners();
  }

  void _patch(
    String convId,
    String messageId,
    AylaChatMessage Function(AylaChatMessage msg) update,
  ) {
    final AylaMessageBucket? bucket = _buckets[convId];
    if (bucket == null) return;
    bool changed = false;
    final List<AylaChatMessage> next = <AylaChatMessage>[];
    for (final AylaChatMessage m in bucket.messages) {
      if (m.id == messageId) {
        final AylaChatMessage updated = update(m);
        changed = changed || !identical(updated, m);
        next.add(updated);
      } else {
        next.add(m);
      }
    }
    if (!changed) return;
    _buckets[convId] = bucket.copyWith(messages: next);
    notifyListeners();
  }
}

/// 排序：非 pending 按 seq 升序；pending 恒置底（彼此保持插入序）。
///
/// ⚠️ Dart 的 `List.sort` **不保证稳定** ⇒ 用原始下标做末位比较键。
List<AylaChatMessage> aylaSortMessages(List<AylaChatMessage> list) {
  final List<AylaChatMessage> copy = List<AylaChatMessage>.of(list);
  final Map<AylaChatMessage, int> order = <AylaChatMessage, int>{
    for (int i = 0; i < copy.length; i++) copy[i]: i,
  };
  copy.sort((AylaChatMessage a, AylaChatMessage b) {
    if (a.pending != b.pending) return a.pending ? 1 : -1;
    if (a.seq != b.seq) return a.seq - b.seq;
    return (order[a] ?? 0) - (order[b] ?? 0);
  });
  return List<AylaChatMessage>.unmodifiable(copy);
}

/// 按 seq 升序插入（同 seq 的非 pending 消息**忽略**；pending 不参与去重）。
List<AylaChatMessage> aylaInsertBySeq(
  List<AylaChatMessage> list,
  AylaChatMessage msg,
) {
  if (!msg.pending &&
      list.any((AylaChatMessage m) => m.seq == msg.seq)) {
    return list;
  }
  return aylaSortMessages(<AylaChatMessage>[...list, msg]);
}
