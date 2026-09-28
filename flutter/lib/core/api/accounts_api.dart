/// 账号聚合 API —— web `api/accounts.ts`（14 行）的 Dart 等价物。
///
/// - `GET /me/badges/` —— 全站未读与待处理聚合（web `api/accounts.ts:10–12`）。
///
/// ## 消费点（本批带出的原因）
/// 消息中心的「认证消息」红点（`MessagesPage.tsx:93–94` 的 `requestBadge()`）与
/// AppShell 的消息入口红点（`AppShell.tsx:93–95`）。两者口径**不同**（见 [AylaAccountBadges]）。
library;

import '../net/dio_client.dart';

/// `GET /me/badges/` 的五维计数（web `api/types.ts:1357–1366` `Badges`）。
///
/// ⚠️ 两个消费口径（web 侧就是两套，**不统一**）：
/// - 认证消息红点 = `friend_requests + group_invites + join_requests_pending`
///   （`stores/badges.ts:62–65` 的 `requestBadge()`）；
/// - AppShell 消息入口红点 = `private_unread + friend_requests + group_invites +
///   join_requests_pending`（`AppShell.tsx:93–95` 的**内联公式**，**不含** `mention_unread`）。
///
/// `mention_unread` 只在 `stores/badges.ts:50–60` 的 `messageBadge()` 里参与聚合，
/// 而 AppShell 没有用那个方法 ⇒ 本类两个 getter 逐条对齐各自的真实来源。
class AylaAccountBadges {
  const AylaAccountBadges({
    this.privateUnread = 0,
    this.groupUnread = 0,
    this.mentionUnread = 0,
    this.friendRequests = 0,
    this.groupInvites = 0,
    this.joinRequestsPending = 0,
  });

  final int privateUnread;
  final int groupUnread;
  final int mentionUnread;
  final int friendRequests;
  final int groupInvites;
  final int joinRequestsPending;

  /// 认证消息红点（`stores/badges.ts:62–65`）。
  int get requestBadge =>
      friendRequests + groupInvites + joinRequestsPending;

  /// AppShell 消息入口红点（`AppShell.tsx:93–95`，**不含** mention_unread）。
  int get messageBadge =>
      privateUnread + friendRequests + groupInvites + joinRequestsPending;

  static AylaAccountBadges fromJson(Map<String, dynamic> json) =>
      AylaAccountBadges(
        privateUnread: (json['private_unread'] as num?)?.toInt() ?? 0,
        groupUnread: (json['group_unread'] as num?)?.toInt() ?? 0,
        mentionUnread: (json['mention_unread'] as num?)?.toInt() ?? 0,
        friendRequests: (json['friend_requests'] as num?)?.toInt() ?? 0,
        groupInvites: (json['group_invites'] as num?)?.toInt() ?? 0,
        joinRequestsPending:
            (json['join_requests_pending'] as num?)?.toInt() ?? 0,
      );
}

class AylaAccountsApi {
  const AylaAccountsApi._();

  /// `GET /me/badges/` —— 五维聚合计数。失败向上抛（调用方保持上一版计数，**不伪造清零**）。
  static Future<AylaAccountBadges> getBadges() async {
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>('/me/badges/');
    return AylaAccountBadges.fromJson(resp);
  }
}
