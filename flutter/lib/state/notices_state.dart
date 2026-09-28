/// 实时通知状态 —— web `stores/notices.ts`（29 行）的 Flutter 等价物。
///
/// 消费点：消息中心「认证消息」tab 的**实时退群通知**分组
/// （`MessagesPage.tsx:48` / `WideMessagesSidebar.tsx:83` 的 `realtimeLeaveNotices`）。
///
/// 纪律：这些条目是**瞬态提示**（会话内有效），不是权威历史 —— 权威退群通知走
/// `GET /chat/leave-notices/`（[AylaChatApi.listLeaveNoticesPage]）。
library;

import 'package:flutter/foundation.dart';

/// 实时通知类别（web `notices.ts:3` 的六档）。
enum AylaRealtimeNoticeKind {
  groupRequestNew,
  groupRequestResolved,
  groupInviteNew,
  groupMemberLeft,
  friendRequestNew,
  friendRequestResolved;

  /// 与 web 的 `kind` 字符串逐字一致（WS 帧按它过滤）。
  String get wire => switch (this) {
        AylaRealtimeNoticeKind.groupRequestNew => 'group.request.new',
        AylaRealtimeNoticeKind.groupRequestResolved => 'group.request.resolved',
        AylaRealtimeNoticeKind.groupInviteNew => 'group.invite.new',
        AylaRealtimeNoticeKind.groupMemberLeft => 'group.member.left',
        AylaRealtimeNoticeKind.friendRequestNew => 'friend.request.new',
        AylaRealtimeNoticeKind.friendRequestResolved => 'friend.request.resolved',
      };
}

/// 一条实时通知（web `notices.ts:5–11`）。
class AylaRealtimeNotice {
  const AylaRealtimeNotice({
    required this.id,
    required this.kind,
    required this.title,
    required this.detail,
    required this.createdAtMs,
  });

  final String id;
  final AylaRealtimeNoticeKind kind;
  final String title;
  final String detail;
  final int createdAtMs;
}

/// 实时通知列表（**最多保留 4 条**，web `notices.ts:25` 的 `.slice(-4)`）。
class AylaNoticesController extends ChangeNotifier {
  final List<AylaRealtimeNotice> _notices = <AylaRealtimeNotice>[];
  int _sequence = 0;

  List<AylaRealtimeNotice> get notices =>
      List<AylaRealtimeNotice>.unmodifiable(_notices);

  /// 按类别过滤（消息中心用 `group.member.left`）。
  List<AylaRealtimeNotice> ofKind(AylaRealtimeNoticeKind kind) =>
      <AylaRealtimeNotice>[
        for (final AylaRealtimeNotice n in _notices)
          if (n.kind == kind) n,
      ];

  /// 追加一条（id 由本控制器生成，与 web 的 `notice-<ts>-<seq>` 同形）。
  void push({
    required AylaRealtimeNoticeKind kind,
    required String title,
    required String detail,
  }) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    _notices.add(AylaRealtimeNotice(
      id: 'notice-$now-${_sequence++}',
      kind: kind,
      title: title,
      detail: detail,
      createdAtMs: now,
    ));
    while (_notices.length > 4) {
      _notices.removeAt(0);
    }
    notifyListeners();
  }

  void dismiss(String id) {
    final int before = _notices.length;
    _notices.removeWhere((AylaRealtimeNotice n) => n.id == id);
    if (_notices.length != before) notifyListeners();
  }

  void clear() {
    if (_notices.isEmpty) return;
    _notices.clear();
    notifyListeners();
  }
}
