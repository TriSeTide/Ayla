/// 群聊子群状态 —— web `stores/subgroup.ts`（220 行）+ `stores/subgroupRead.ts`（21 行）
/// 的 Dart 等价物。
///
/// ## 四张投影（逐条对应 web 注释）
/// - [byGroup]：conversation_id → 子群列表（后端顺序，默认组在前）；
/// - [activeByGroup]：conversation_id → 当前选中子群 id（未设置 = 未加载，默认组兜底）；
/// - [lastMessageSeqByKey]：消息最大序号 —— **保留列表加载前收到的消息**，避免迟到
///   REST 响应把活跃度回退；
/// - [unreadByKey] / [unreadSeqsByKey]：`${convId}:${subgroupId}` → 本人未读投影。
///   列表加载时以服务端 `unread_count` / `unread_seqs` 为准；WS `message.new` 实时增量；
///   实际看到消息后**按服务端确认序号**移除（`subgroup.read` 同步其他端）。
///
/// ## 纪律（认知零规则同源）
/// 旧帧只有 `marked`（没有 `marked_seqs`）时**无法证明哪些消息已读** ⇒ 绝不清空整组
/// 未读（web `chat.ts:543–547` 原话：「绝不能据此清空新到的未读」）。
library;

import 'package:flutter/foundation.dart';

import '../core/models/subgroup.dart' show AylaSubGroup;

/// `subgroupKey(convId, subgroupId)` —— web `stores/subgroup.ts:14–16`。
String aylaSubgroupKey(String convId, String? subgroupId) =>
    '$convId:${subgroupId ?? ''}';

/// 宽屏侧栏投影：默认组固定第一，其余按最近消息降序，并列保持列表原序
/// —— web `stores/subgroup.ts:19–23` 的 `sortSubgroupsByActivity`。
List<AylaSubGroup> aylaSortSubgroupsByActivity(List<AylaSubGroup> list) {
  final List<AylaSubGroup> copy = List<AylaSubGroup>.of(list);
  copy.sort((AylaSubGroup a, AylaSubGroup b) {
    final int byDefault =
        (b.isDefault ? 1 : 0) - (a.isDefault ? 1 : 0);
    if (byDefault != 0) return byDefault;
    return (b.lastMessageSeq ?? 0) - (a.lastMessageSeq ?? 0);
  });
  return copy;
}

/// 子群未读/活跃度状态机。
class AylaSubGroupState extends ChangeNotifier {
  final Map<String, List<AylaSubGroup>> _byGroup =
      <String, List<AylaSubGroup>>{};
  final Map<String, String?> _activeByGroup = <String, String?>{};
  final Map<String, int> _unreadByKey = <String, int>{};
  final Map<String, List<int>> _unreadSeqsByKey = <String, List<int>>{};
  final Map<String, int> _lastMessageSeqByKey = <String, int>{};
  final Map<String, List<int>> _confirmedReadSeqsByKey =
      <String, List<int>>{};

  /// 会话 → 子群列表（不可变视图）。
  Map<String, List<AylaSubGroup>> get byGroup =>
      Map<String, List<AylaSubGroup>>.unmodifiable(<String, List<AylaSubGroup>>{
        for (final MapEntry<String, List<AylaSubGroup>> e in _byGroup.entries)
          e.key: List<AylaSubGroup>.unmodifiable(e.value),
      });

  /// 某会话的子群列表（无 → 空列表；web 的 `?? []`）。
  List<AylaSubGroup> subgroupsOf(String convId) =>
      List<AylaSubGroup>.unmodifiable(_byGroup[convId] ?? const <AylaSubGroup>[]);

  /// 当前选中子群 id（null = 未设置 / 显式清空）。
  String? activeSubgroupOf(String convId) => _activeByGroup[convId];

  /// 某子群未读数（无记录 → 0）。
  int unreadOf(String convId, String? subgroupId) =>
      _unreadByKey[aylaSubgroupKey(convId, subgroupId)] ?? 0;

  /// 某子群未读序号（无记录 → 空列表）。
  List<int> unreadSeqsOf(String convId, String? subgroupId) =>
      List<int>.unmodifiable(
          _unreadSeqsByKey[aylaSubgroupKey(convId, subgroupId)] ?? const <int>[]);

  /// 某消息序号是否已被本人确认已读（web `subgroup.ts:217–220`）——
  /// **跨子群**扫描：默认组描述未加载时仍能识别已确认的 legacy null 消息。
  bool isSubgroupMessageConfirmedRead(String convId, int seq) {
    for (final MapEntry<String, List<int>> e
        in _confirmedReadSeqsByKey.entries) {
      if (e.key.startsWith('$convId:') && e.value.contains(seq)) return true;
    }
    return false;
  }

  /// REST 列表与单组编辑响应共用快照边界：保留之后的新消息，排除已确认序号
  /// —— web `mergeUnreadSnapshot`。
  ({List<int> seqs, int count}) _mergeUnreadSnapshot(
    String convId,
    AylaSubGroup sg,
  ) {
    final String key = aylaSubgroupKey(convId, sg.id);
    final Set<int> confirmed =
        (_confirmedReadSeqsByKey[key] ?? const <int>[]).toSet();
    final List<int> incoming = sg.hasUnreadSeqs
        ? sg.unreadSeqs
        : (_unreadSeqsByKey[key] ?? const <int>[]);
    final List<int> later = (_unreadSeqsByKey[key] ?? const <int>[])
        .where((int seq) =>
            sg.lastMessageSeq == null || seq > sg.lastMessageSeq!)
        .toList(growable: false);
    final List<int> merged = <int>{...incoming, ...later}
        .where((int seq) => !confirmed.contains(seq))
        .toList()
      ..sort();
    // `unread_seqs` 存在时以序号数组为准；缺席时取「服务端计数」与「序号数组长度」的较大者
    //（**不把未知剩余量归零**）。
    final int count = sg.hasUnreadSeqs
        ? merged.length
        : _maxInt(_unreadByKey[key] ?? 0, merged.length);
    return (seqs: merged, count: count);
  }

  /// REST 列表落库（web `setSubgroups`）—— 服务端顺序、默认组在前。
  void setSubgroups(String convId, List<AylaSubGroup> list) {
    final List<AylaSubGroup> next = <AylaSubGroup>[];
    for (final AylaSubGroup sg in list) {
      final String key = aylaSubgroupKey(convId, sg.id);
      final ({List<int> seqs, int count}) unread =
          _mergeUnreadSnapshot(convId, sg);
      _unreadByKey[key] = unread.count;
      _unreadSeqsByKey[key] = unread.seqs;
      final int seq = _maxInt(sg.lastMessageSeq ?? 0, _lastMessageSeqByKey[key] ?? 0);
      _lastMessageSeqByKey[key] = seq;
      next.add(sg.copyWith(
        lastMessageSeq: seq,
        unreadCount: unread.count,
        unreadSeqs: unread.seqs,
        hasUnreadSeqs: true,
      ));
    }
    _byGroup[convId] = next;
    notifyListeners();
  }

  /// 单组插入/更新（REST 单条响应 + WS `subgroup.created` / `subgroup.updated`）。
  void upsertSubgroup(String convId, AylaSubGroup sg) {
    final List<AylaSubGroup> list = _byGroup[convId] ?? <AylaSubGroup>[];
    final String key = aylaSubgroupKey(convId, sg.id);
    final int seq = _maxInt(sg.lastMessageSeq ?? 0, _lastMessageSeqByKey[key] ?? 0);
    final ({List<int> seqs, int count}) unread = _mergeUnreadSnapshot(convId, sg);
    final AylaSubGroup updated = sg.copyWith(
      lastMessageSeq: seq,
      unreadCount: unread.count,
      unreadSeqs: unread.seqs,
      hasUnreadSeqs: true,
    );
    final bool exists = list.any((AylaSubGroup item) => item.id == sg.id);
    _byGroup[convId] = exists
        ? <AylaSubGroup>[
            for (final AylaSubGroup item in list)
              if (item.id == sg.id)
                // WS 帧（created/updated）不带未读：保留本地已有未读投影，
                // 避免被 undefined 覆盖（web 注释）；`created_at` 也保留本地值。
                updated.copyWith(createdAt: item.createdAt ?? updated.createdAt)
              else
                item,
          ]
        : <AylaSubGroup>[...list, updated];
    _lastMessageSeqByKey[key] = seq;
    _unreadByKey[key] = unread.count;
    _unreadSeqsByKey[key] = unread.seqs;
    notifyListeners();
  }

  /// 删除子群（WS `subgroup.deleted` / REST 删除成功）—— 四张投影一起清键。
  void removeSubgroup(String convId, String subgroupId) {
    final List<AylaSubGroup> list = _byGroup[convId] ?? <AylaSubGroup>[];
    _byGroup[convId] =
        list.where((AylaSubGroup item) => item.id != subgroupId).toList();
    final String key = aylaSubgroupKey(convId, subgroupId);
    _unreadByKey.remove(key);
    _unreadSeqsByKey.remove(key);
    _lastMessageSeqByKey.remove(key);
    _confirmedReadSeqsByKey.remove(key);
    notifyListeners();
  }

  /// 选中子群（null = 显式清空 —— 删除当前子群后切回默认组的路径会用到）。
  void setActiveSubgroup(String convId, String? subgroupId) {
    if (_activeByGroup.containsKey(convId) &&
        _activeByGroup[convId] == subgroupId) {
      return;
    }
    _activeByGroup[convId] = subgroupId;
    notifyListeners();
  }

  /// 已落库消息推进活跃度；与未读、发送者、当前查看位置**无关**
  /// （本地 pending 不参与排序：seq 必须为正整数）。
  void recordMessageActivity(String convId, String? subgroupId, int seq) {
    if (subgroupId == null || seq <= 0) return;
    final String key = aylaSubgroupKey(convId, subgroupId);
    if (seq <= (_lastMessageSeqByKey[key] ?? 0)) return;
    _lastMessageSeqByKey[key] = seq;
    final List<AylaSubGroup>? list = _byGroup[convId];
    if (list != null) {
      _byGroup[convId] = <AylaSubGroup>[
        for (final AylaSubGroup sg in list)
          if (sg.id == subgroupId) sg.copyWith(lastMessageSeq: seq) else sg,
      ];
    }
    notifyListeners();
  }

  /// WS `message.new`：消息先进入未读，待可视区**精确确认**（带 seq 去重）。
  void bumpSubgroupUnread(String convId, String subgroupId, [int? seq]) {
    final String key = aylaSubgroupKey(convId, subgroupId);
    final List<int> seqs = _unreadSeqsByKey[key] ?? <int>[];
    if (seq != null &&
        (seqs.contains(seq) ||
            (_confirmedReadSeqsByKey[key] ?? const <int>[]).contains(seq))) {
      return;
    }
    _unreadByKey[key] = (_unreadByKey[key] ?? 0) + 1;
    if (seq != null) {
      _unreadSeqsByKey[key] = <int>[...seqs, seq]..sort();
    }
    notifyListeners();
  }

  /// 仅移除本次确认序号，返回**实际移除的本地未读数**；重复确认幂等
  /// （web `markSubgroupReadSeqs` 的返回值语义 —— 旧会话响应缺序号时
  /// `decrementUnread` 只能减这个数，**禁止把未知剩余量归零**）。
  int markSubgroupReadSeqs(
    String convId,
    String subgroupId,
    List<int> seqs,
  ) {
    final List<int> read = seqs.where((int seq) => seq > 0).toList();
    if (read.isEmpty) return 0;
    final String key = aylaSubgroupKey(convId, subgroupId);
    final List<int> confirmed = <int>{
      ...(_confirmedReadSeqsByKey[key] ?? const <int>[]),
      ...read,
    }.toList();
    final Set<int> incoming = read.toSet();
    final List<int> previous = _unreadSeqsByKey[key] ?? <int>[];
    final List<int> unread =
        previous.where((int seq) => !incoming.contains(seq)).toList();
    final int removed = previous.length - unread.length;
    final int count = _maxInt(0, (_unreadByKey[key] ?? previous.length) - removed);
    _confirmedReadSeqsByKey[key] = confirmed;
    _unreadByKey[key] = count;
    _unreadSeqsByKey[key] = unread;
    final List<AylaSubGroup>? list = _byGroup[convId];
    if (list != null) {
      _byGroup[convId] = <AylaSubGroup>[
        for (final AylaSubGroup sg in list)
          if (sg.id == subgroupId)
            sg.copyWith(unreadCount: count, unreadSeqs: unread)
          else
            sg,
      ];
    }
    notifyListeners();
    return removed;
  }

  /// 显式清理投影；**查看/切换子群与已读回执不得调用**
  /// （web 注释：日常路径只应用服务端确认的序号，不整组清零）。
  void clearSubgroupUnread(String convId, String subgroupId) {
    final String key = aylaSubgroupKey(convId, subgroupId);
    _unreadByKey[key] = 0;
    _unreadSeqsByKey[key] = const <int>[];
    notifyListeners();
  }

  void reset() {
    _byGroup.clear();
    _activeByGroup.clear();
    _unreadByKey.clear();
    _unreadSeqsByKey.clear();
    _lastMessageSeqByKey.clear();
    _confirmedReadSeqsByKey.clear();
    notifyListeners();
  }

  static int _maxInt(int a, int b) => a > b ? a : b;
}
