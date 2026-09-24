/// 社交认证消息模型（`Ayla/web/src/api/types.ts` 的 Dart 等价）。
///
/// ## 事实源
///
/// | 本文件 | web |
/// |---|---|
/// | [AylaFriendRequest] | `types.ts:117–125` `FriendRequest`（`chat` 域好友申请） |
/// | [AylaGroupInvite] | `types.ts:1380–1390` `GroupInvite`（`chat.GroupInviteSerializer`） |
/// | [AylaGroupJoinRequest] | `types.ts:1368–1378` `GroupJoinRequest` |
/// | [AylaGroupMemberLeaveNotice] | `types.ts:1392–1400` `GroupMemberLeaveNotice` |
/// | [AylaSocialPage] | web `useSocialPage` 的分页投影（items / loading / error / hasMore / loadMore / refresh），
/// 与 `AylaDirectoryLoadMore` 的契约对齐 |
///
/// 未知枚举值保持 `null`（不猜、不造默认值，与库内其他模型同口径）。
library;

import 'user_public.dart';

/// 好友申请（`FriendRequest`）。
class AylaFriendRequest {
  const AylaFriendRequest({
    required this.id,
    required this.fromUser,
    this.toUser,
    this.message = '',
    this.status,
    this.createdAt,
    this.handledAt,
  });

  final String id;
  final AylaUserPublic fromUser;
  final AylaUserPublic? toUser;
  final String message;

  /// `pending` / `accepted` / `rejected`；未知为 null。
  final String? status;

  final String? createdAt;
  final String? handledAt;

  factory AylaFriendRequest.fromJson(Map<String, dynamic> json) =>
      AylaFriendRequest(
        id: '${json['id']}',
        // 契约（`types.ts:117–125`）保证 `from_user` 有 id；缺失即数据异常 ⇒ 用 `!`
        // **显式失败**，不构造占位用户（不伪造）。
        fromUser: AylaUserPublic.fromJson(
          (json['from_user'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
        )!,
        toUser: json['to_user'] == null
            ? null
            : AylaUserPublic.fromJson(json['to_user'] as Map<String, dynamic>),
        message: (json['message'] as String?) ?? '',
        status: json['status'] as String?,
        createdAt: json['created_at'] as String?,
        handledAt: json['handled_at'] as String?,
      );
}

/// 入群邀请（`GroupInvite`）。
class AylaGroupInvite {
  const AylaGroupInvite({
    required this.id,
    required this.conversationTitle,
    required this.inviter,
    this.conversationId,
    this.status,
    this.createdAt,
  });

  final String id;
  final String conversationTitle;
  final AylaUserPublic inviter;
  final String? conversationId;
  final String? status;
  final String? createdAt;

  factory AylaGroupInvite.fromJson(Map<String, dynamic> json) => AylaGroupInvite(
        id: '${json['id']}',
        conversationTitle: (json['conversation_title'] as String?) ?? '',
        inviter: AylaUserPublic.fromJson(
          (json['inviter'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
        )!,
        conversationId: json['conversation_id'] as String?,
        status: json['status'] as String?,
        createdAt: json['created_at'] as String?,
      );
}

/// 入群申请（`GroupJoinRequest`）。
class AylaGroupJoinRequest {
  const AylaGroupJoinRequest({
    required this.id,
    required this.conversationTitle,
    required this.applicant,
    this.conversationId,
    this.message = '',
    this.status,
    this.createdAt,
  });

  final String id;
  final String conversationTitle;
  final AylaUserPublic applicant;
  final String? conversationId;
  final String message;
  final String? status;
  final String? createdAt;

  factory AylaGroupJoinRequest.fromJson(Map<String, dynamic> json) =>
      AylaGroupJoinRequest(
        id: '${json['id']}',
        conversationTitle: (json['conversation_title'] as String?) ?? '',
        applicant: AylaUserPublic.fromJson(
          (json['applicant'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
        )!,
        conversationId: json['conversation_id'] as String?,
        message: (json['message'] as String?) ?? '',
        status: json['status'] as String?,
        createdAt: json['created_at'] as String?,
      );
}

/// 持久化退群通知（`GroupMemberLeaveNotice`）。
class AylaGroupMemberLeaveNotice {
  const AylaGroupMemberLeaveNotice({
    required this.id,
    required this.conversationTitle,
    required this.memberName,
    this.conversationId,
    this.readAt,
    this.createdAt,
  });

  final String id;
  final String conversationTitle;
  final String memberName;
  final String? conversationId;
  final String? readAt;
  final String? createdAt;

  factory AylaGroupMemberLeaveNotice.fromJson(Map<String, dynamic> json) =>
      AylaGroupMemberLeaveNotice(
        id: '${json['id']}',
        conversationTitle: (json['conversation_title'] as String?) ?? '',
        memberName: (json['member_name'] as String?) ?? '',
        conversationId: json['conversation_id'] as String?,
        readAt: json['read_at'] as String?,
        createdAt: json['created_at'] as String?,
      );
}

/// 一页社交数据（web `useSocialPage` 投影；与 `AylaDirectoryLoadMore` 契约一致）。
class AylaSocialPage<T> {
  const AylaSocialPage({
    this.items = const <Never>[],
    this.loading = false,
    this.error,
    this.hasMore = false,
    this.loadMore,
    this.refresh,
  });

  final List<T> items;
  final bool loading;
  final String? error;
  final bool hasMore;
  final Future<void> Function()? loadMore;
  final Future<void> Function()? refresh;

  /// 「空态」判定（web：`items.length === 0 && !loading && !error`）。
  bool get isEmptyState => items.isEmpty && !loading && error == null;

  /// 是否应渲染该分组（web：有数据 或 loading 或 error 或 hasMore）。
  bool get shouldRender =>
      items.isNotEmpty || loading || error != null || hasMore;
}
