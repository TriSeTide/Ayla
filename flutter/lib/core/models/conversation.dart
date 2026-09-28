/// 会话模型（`Ayla/web/src/api/types.ts` 的 chat 域投影）。
///
/// ## 事实源
///
/// | 本文件 | web |
/// |---|---|
/// | [AylaConversationType] | `types.ts:297` ConversationType |
/// | [AylaConversationMemberRole] | `types.ts:292` ConversationMember.role |
/// | [AylaConversationMember] | `types.ts:289–295` ConversationMember |
/// | [AylaLastMessagePreview] | `types.ts:300–311` LastMessagePreview |
/// | [AylaConversationSummary] | `types.ts:314–353` ConversationSummary |
///
/// 纪律：snake_case 契约；未知枚举返回 null（**不 fallback**）；字段缺失就是缺失。
library;

import 'chat_message.dart' show AylaMessageType;
import 'user_public.dart';

/// 会话类型（`types.ts:297`）。
enum AylaConversationType {
  private,
  group;

  String get wire => name;

  /// 未知取值返回 null（不 fallback 成 private）。
  static AylaConversationType? parse(String? raw) => switch (raw) {
        'private' => AylaConversationType.private,
        'group' => AylaConversationType.group,
        _ => null,
      };
}

/// 群成员角色（`types.ts:292`）。
enum AylaConversationMemberRole {
  member,
  admin,
  owner;

  String get wire => name;

  static AylaConversationMemberRole? parse(String? raw) => switch (raw) {
        'member' => AylaConversationMemberRole.member,
        'admin' => AylaConversationMemberRole.admin,
        'owner' => AylaConversationMemberRole.owner,
        _ => null,
      };
}

/// 会话成员（`types.ts:289–295` ConversationMemberSerializer 字段）。
class AylaConversationMember {
  const AylaConversationMember({
    required this.id,
    required this.user,
    this.role,
    this.muted = false,
    this.joinedAt,
  });

  final String id;
  final AylaUserPublic user;
  final AylaConversationMemberRole? role;
  final bool muted;
  final String? joinedAt;

  static AylaConversationMember? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final AylaUserPublic? user = AylaUserPublic.fromJson(raw['user']);
    final Object? id = raw['id'];
    if (user == null || id == null) return null;
    return AylaConversationMember(
      id: id.toString(),
      user: user,
      role: AylaConversationMemberRole.parse(raw['role'] as String?),
      muted: raw['muted'] as bool? ?? false,
      joinedAt: raw['joined_at'] as String?,
    );
  }

  static List<AylaConversationMember> listFromJson(Object? raw) {
    if (raw is! List) return const <AylaConversationMember>[];
    return raw
        .map(AylaConversationMember.fromJson)
        .whereType<AylaConversationMember>()
        .toList(growable: false);
  }
}

/// 最新一条消息预览（`types.ts:300–311`）。
class AylaLastMessagePreview {
  const AylaLastMessagePreview({
    this.seq = 0,
    this.type,
    this.content = '',
    this.senderId,
    this.senderName = '',
    this.status,
    this.createdAt,
    this.preview,
  });

  final int seq;

  /// 未知类型为 null。
  final AylaMessageType? type;

  final String content;
  final String? senderId;

  /// 群聊预览前缀用的发送者名（空串 = 无）。
  final String senderName;

  /// 消息状态（`recalled` 时列表显示 `[已撤回]`）。
  final String? status;

  final String? createdAt;

  /// 混排摘要文案（后端生成；缺失时前端按类型兜底）。
  final String? preview;

  static AylaLastMessagePreview? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return AylaLastMessagePreview(
      seq: (raw['seq'] as num?)?.toInt() ?? 0,
      type: AylaMessageType.parse(raw['type'] as String?),
      content: (raw['content'] as String?) ?? '',
      senderId: raw['sender_id']?.toString(),
      senderName: (raw['sender_name'] as String?) ?? '',
      status: raw['status'] as String?,
      createdAt: raw['created_at'] as String?,
      preview: raw['preview'] as String?,
    );
  }
}

/// 群状态角标（`types.ts:330` 的 `group_presence`；后端
/// `apps/chat/serializers.py:567` 的 `ConversationDirectorySerializer.get_group_presence`）。
///
/// 语义：**存在性**，与"最近有新内容"（排序）是两套逻辑（`groupActivity.ts:69–72`）：
/// `live` = 群内有直播**在播**；`voice` = 群内有语音房**有人**；`game` = 群内有桌游房。
class AylaGroupPresence {
  const AylaGroupPresence({
    this.live = false,
    this.voice = false,
    this.game = false,
  });

  final bool live;
  final bool voice;
  final bool game;

  /// 解析；非 Map ⇒ null（**缺席就是缺席** —— 调用方据此走"扫描目录"兜底，
  /// 而不是把它当成"三个都没有"）。
  static AylaGroupPresence? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return AylaGroupPresence(
      live: raw['live'] == true,
      voice: raw['voice'] == true,
      game: raw['game'] == true,
    );
  }
}

/// 会话摘要（`types.ts:314–353` ConversationListSerializer 字段）。
///
/// 未列出的后端字段按需再加，避免无消费者的字段膨胀。
///
/// ## 2026-09-28（消息域批次）新增 4 个未读游标字段
/// `unread_seqs` / `mention_unread_seqs` / `reply_unread_seqs` / `unread_seqs_complete`
/// （`types.ts:327–347`）—— 它们是 `stores/chat.ts` 的 `bumpUnread` / `markReadSeqs`
/// 唯一依赖的投影；WS `message.new` 实时未读增量必须有它们才能与 web 同语义
/// （只加 `unread_count` 数字会与「可追踪未读序号」两套口径打架）。
class AylaConversationSummary {
  const AylaConversationSummary({
    required this.id,
    required this.type,
    required this.title,
    this.announcement = '',
    this.avatar = '',
    this.joinPolicy,
    this.ownerId = '',
    this.members = const <AylaConversationMember>[],
    this.membersComplete,
    this.myMuted,
    this.myRole,
    this.memberCount = 0,
    this.unreadCount = 0,
    this.lastReadSeq,
    this.isPinned,
    this.lastMessage,
    this.mentionUnreadCount,
    this.postUnreadCount,
    this.directoryActivityAt,
    this.groupPresence,
    this.createdAt,
    this.peer,
    this.unreadSeqs = const <int>[],
    this.mentionUnreadSeqs = const <int>[],
    this.replyUnreadSeqs = const <int>[],
    this.unreadSeqsComplete,
  });

  final String id;

  /// 未知类型为 null → 调用方按非私聊处理（不伪造类型）。
  final AylaConversationType? type;

  final String title;
  final String announcement;

  /// 群头像（媒体 content URL，仅群聊；私聊为空串）。
  final String avatar;

  /// `public` / `application`（旧后端可缺省）。
  final String? joinPolicy;

  final String ownerId;
  final List<AylaConversationMember> members;

  /// False = 分页目录元数据（不可当完整群成员用）。
  final bool? membersComplete;

  final bool? myMuted;

  /// `member` / `admin` / `owner`；null = 未知。
  final AylaConversationMemberRole? myRole;

  final int memberCount;
  final int unreadCount;
  final int? lastReadSeq;

  /// 本人视图是否置顶（旧后端可缺省）。
  final bool? isPinned;

  final AylaLastMessagePreview? lastMessage;

  /// 本会话 @ 我且未读的消息数（旧后端可缺省）。
  final int? mentionUnreadCount;

  /// 群内未读帖子数（仅群聊非 0）。
  final int? postUnreadCount;

  /// 群最近收到新内容的时间（ISO；目录行的 `directory_activity_at`，
  /// `types.ts:329` + `stores/chat.ts:145–148` 的 `groupActivityAt` 取值来源）。
  final String? directoryActivityAt;

  /// 群状态角标（目录行才有；null = 后端未给 ⇒ 调用方扫描目录兜底）。
  final AylaGroupPresence? groupPresence;

  final String? createdAt;

  /// 私聊对端用户（ConversationListSerializer 补充）。
  final AylaUserPublic? peer;

  /// 未读消息的会话序号集合（`types.ts:342–343`；旧后端缺失 ⇒ 空数组）。
  final List<int> unreadSeqs;

  /// @ 我未读的消息序号集合（`types.ts:344–345`）。
  final List<int> mentionUnreadSeqs;

  /// 回复未读的消息序号集合（`types.ts:346–347`）。
  final List<int> replyUnreadSeqs;

  /// False = 摘要只含计数、省略了递增的未读序号数组（`types.ts:327–328`）；
  /// null = 后端未给（按 web `toSummary` 的 `?? true` 语义**视为完整**）。
  final bool? unreadSeqsComplete;

  bool get isGroup => type == AylaConversationType.group;

  bool get isPrivate => type == AylaConversationType.private;

  /// 合并式拷贝：**null 一律表示「保留旧值」**（与 web `upsertConversation`
  /// 的「详情接口无 peer ⇒ 不得用 null 覆盖已有对端」同语义）。
  AylaConversationSummary copyWith({
    String? title,
    String? announcement,
    String? avatar,
    String? joinPolicy,
    List<AylaConversationMember>? members,
    bool? membersComplete,
    bool? myMuted,
    AylaConversationMemberRole? myRole,
    int? memberCount,
    int? unreadCount,
    int? lastReadSeq,
    bool? isPinned,
    AylaLastMessagePreview? lastMessage,
    int? mentionUnreadCount,
    int? postUnreadCount,
    String? directoryActivityAt,
    AylaGroupPresence? groupPresence,
    AylaUserPublic? peer,
    List<int>? unreadSeqs,
    List<int>? mentionUnreadSeqs,
    List<int>? replyUnreadSeqs,
    bool? unreadSeqsComplete,
  }) =>
      AylaConversationSummary(
        id: id,
        type: type,
        title: title ?? this.title,
        announcement: announcement ?? this.announcement,
        avatar: avatar ?? this.avatar,
        joinPolicy: joinPolicy ?? this.joinPolicy,
        ownerId: ownerId,
        members: members ?? this.members,
        membersComplete: membersComplete ?? this.membersComplete,
        myMuted: myMuted ?? this.myMuted,
        myRole: myRole ?? this.myRole,
        memberCount: memberCount ?? this.memberCount,
        unreadCount: unreadCount ?? this.unreadCount,
        lastReadSeq: lastReadSeq ?? this.lastReadSeq,
        isPinned: isPinned ?? this.isPinned,
        lastMessage: lastMessage ?? this.lastMessage,
        mentionUnreadCount: mentionUnreadCount ?? this.mentionUnreadCount,
        postUnreadCount: postUnreadCount ?? this.postUnreadCount,
        directoryActivityAt: directoryActivityAt ?? this.directoryActivityAt,
        groupPresence: groupPresence ?? this.groupPresence,
        createdAt: createdAt,
        peer: peer ?? this.peer,
        unreadSeqs: unreadSeqs ?? this.unreadSeqs,
        mentionUnreadSeqs: mentionUnreadSeqs ?? this.mentionUnreadSeqs,
        replyUnreadSeqs: replyUnreadSeqs ?? this.replyUnreadSeqs,
        unreadSeqsComplete: unreadSeqsComplete ?? this.unreadSeqsComplete,
      );

  static AylaConversationSummary? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id == null) return null;
    return AylaConversationSummary(
      id: id.toString(),
      type: AylaConversationType.parse(raw['type'] as String?),
      title: (raw['title'] as String?) ?? '',
      announcement: (raw['announcement'] as String?) ?? '',
      avatar: (raw['avatar'] as String?) ?? '',
      joinPolicy: raw['join_policy'] as String?,
      ownerId: raw['owner_id']?.toString() ?? '',
      members: AylaConversationMember.listFromJson(raw['members']),
      membersComplete: raw['members_complete'] as bool?,
      myMuted: raw['my_muted'] as bool?,
      myRole: AylaConversationMemberRole.parse(raw['my_role'] as String?),
      memberCount: (raw['member_count'] as num?)?.toInt() ?? 0,
      unreadCount: (raw['unread_count'] as num?)?.toInt() ?? 0,
      lastReadSeq: (raw['last_read_seq'] as num?)?.toInt(),
      isPinned: raw['is_pinned'] as bool?,
      lastMessage: AylaLastMessagePreview.fromJson(raw['last_message']),
      mentionUnreadCount: (raw['mention_unread_count'] as num?)?.toInt(),
      postUnreadCount: (raw['post_unread_count'] as num?)?.toInt(),
      directoryActivityAt: raw['directory_activity_at'] as String?,
      groupPresence: AylaGroupPresence.fromJson(raw['group_presence']),
      createdAt: raw['created_at'] as String?,
      peer: AylaUserPublic.fromJson(raw['peer']),
      unreadSeqs: _intList(raw['unread_seqs']),
      mentionUnreadSeqs: _intList(raw['mention_unread_seqs']),
      replyUnreadSeqs: _intList(raw['reply_unread_seqs']),
      unreadSeqsComplete: raw['unread_seqs_complete'] as bool?,
    );
  }

  static List<AylaConversationSummary> listFromJson(Object? raw) {
    if (raw is! List) return const <AylaConversationSummary>[];
    return raw
        .map(AylaConversationSummary.fromJson)
        .whereType<AylaConversationSummary>()
        .toList(growable: false);
  }
}

/// 未读序号数组解析（非 List ⇒ 空数组；非数字项**丢弃**，不猜值）。
List<int> _intList(Object? raw) {
  if (raw is! List) return const <int>[];
  return List<int>.unmodifiable(<int>[
    for (final Object? item in raw)
      if (item is num) item.toInt(),
  ]);
}
