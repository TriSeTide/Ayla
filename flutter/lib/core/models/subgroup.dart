/// 子群 / 入群申请域模型 —— 与 web `api/types.ts` 的 `SubGroup`（416–428）以及
/// `components/group/GroupApplyDialog.tsx` 的 `GroupApplyData`（16–22）逐条同源。
///
/// 纪律（沿用 chat / social / boardgame 域口径）：JSON 键名与后端一致（snake_case）；
/// 缺失就是缺失（null，与 false 不同义）；未知枚举返回 null（不 fallback）。
library;

/// 群聊子群（`SubGroupSerializer`）。
class AylaSubGroup {
  const AylaSubGroup({
    required this.id,
    required this.conversationId,
    required this.name,
    required this.isDefault,
    required this.unreadCount,
    this.muted,
    this.unreadSeqs = const <int>[],
    this.lastMessageSeq,
    this.createdAt,
  });

  final String id;

  /// 归属会话（群）id。
  final String conversationId;

  final String name;

  /// 默认组（`is_default`）——**默认组不可删除**（`SubGroupDialog.tsx:37` 的 `canDelete`）。
  final bool isDefault;

  /// 禁言开关（旧后端可缺省）：null = 后端没给该字段，与 false 不同义。
  final bool? muted;

  /// 本人视角未读数。
  final int unreadCount;

  /// 本人视角未读序号（旧后端可缺省）。
  final List<int> unreadSeqs;

  /// 子群最近消息的会话内序号；空子群为 0，旧后端可缺省。
  final int? lastMessageSeq;

  final String? createdAt;

  /// 解析；缺 `id` 视为非法 → null。
  static AylaSubGroup? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id == null || id.toString().isEmpty) return null;
    final Object? muted = raw['muted'];
    final Object? lastSeq = raw['last_message_seq'];
    return AylaSubGroup(
      id: id.toString(),
      conversationId: raw['conversation_id']?.toString() ?? '',
      name: raw['name']?.toString() ?? '',
      isDefault: raw['is_default'] == true,
      muted: muted is bool ? muted : null,
      unreadCount: int.tryParse(raw['unread_count']?.toString() ?? '') ?? 0,
      unreadSeqs: _intList(raw['unread_seqs']),
      lastMessageSeq: lastSeq is int ? lastSeq : int.tryParse(lastSeq?.toString() ?? ''),
      createdAt: raw['created_at']?.toString(),
    );
  }
}

/// 入群策略（`join_policy`；未知 → null，按**申请制**文案与流程处理，见 tsx:15 注释）。
enum AylaGroupJoinPolicy {
  /// 公开群：点击即可直接加入。
  public,

  /// 申请制：群主或管理员同意后才能入群。
  application;

  /// 后端字段值。
  String get wire => name;

  static AylaGroupJoinPolicy? parse(Object? raw) => switch (raw) {
        'public' => AylaGroupJoinPolicy.public,
        'application' => AylaGroupJoinPolicy.application,
        _ => null,
      };
}

/// 申请入群所需的最小群信息（`GroupApplyDialog.tsx:16–22` `GroupApplyData`）。
class AylaGroupApplyData {
  const AylaGroupApplyData({
    required this.id,
    this.title,
    this.joinPolicy,
    this.avatar,
  });

  final String id;

  /// 群名（弹窗标题里为空时回退「该群聊」，tsx:121/157）。
  final String? title;

  /// 入群策略；**null（未知）按申请制文案与流程**。
  final AylaGroupJoinPolicy? joinPolicy;

  /// 群头像（守卫卡片形态可展示；可选）。
  final String? avatar;

  /// 是否公开群（tsx:33：`join_policy === "public"`）。
  bool get isPublic => joinPolicy == AylaGroupJoinPolicy.public;

  /// 标题用群名：`title?.trim() || "该群聊"`（tsx:121/157）。
  String get displayTitle {
    final String trimmed = (title ?? '').trim();
    return trimmed.isEmpty ? '该群聊' : trimmed;
  }

  /// 解析；缺 `id` 视为非法 → null。
  static AylaGroupApplyData? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id == null || id.toString().isEmpty) return null;
    return AylaGroupApplyData(
      id: id.toString(),
      title: raw['title']?.toString(),
      joinPolicy: AylaGroupJoinPolicy.parse(raw['join_policy']),
      avatar: raw['avatar']?.toString(),
    );
  }
}

/// 入群申请结果（web `applyToGroup` 的两种结局，tsx:45–49）：
/// 公开群直接加入 → [isAccepted] + [conversationId]；申请制 → 待审核（表单转成功态）。
class AylaGroupApplyResult {
  /// 直接加入成功（`{"status":"accepted","conversation_id":…}`）。
  const AylaGroupApplyResult.accepted(this.conversationId) : isAccepted = true;

  /// 申请已发送、等待审核。
  const AylaGroupApplyResult.pending()
      : conversationId = null,
        isAccepted = false;

  final bool isAccepted;
  final String? conversationId;
}

List<int> _intList(Object? raw) {
  if (raw is! List) return const <int>[];
  return <int>[
    for (final Object? item in raw)
      if (int.tryParse(item?.toString() ?? '') case final int v) v,
  ];
}
