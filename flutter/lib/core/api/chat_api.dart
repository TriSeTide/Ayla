/// 会话 / 消息域 API —— web `api/chat.ts`（356 行）的 Dart 等价物。
///
/// ## 逐条对应
/// | 本方法 | web |
/// |---|---|
/// | [listConversationsPage] | `api/chat.ts:30–32` + `api/social.ts:15–21`（`pagination=cursor`） |
/// | [listConversationSubscriptionsPage] | `api/chat.ts:34–37`（WS `registerAuthorizedGroups` 的取数口） |
/// | [getConversationMetadata] | `api/chat.ts:39–42`（`?metadata=1`，成员完整） |
/// | [getConversationSummary] | `api/chat.ts:44–46`（`?metadata=directory`，无成员） |
/// | [getGroupPresence] | `api/chat.ts:48–52`（`GroupPresenceBatchView`） |
/// | [createGroupConversation] | `api/chat.ts:66–75` |
/// | [listMessages] | `api/chat.ts:94–102`（`before_seq` / `limit` / `subgroup_id`） |
/// | [sendMessage] | `api/chat.ts:160–166`（幂等 POST） |
/// | [sendPoke] | `api/chat.ts:168–179`（`type=poke`，content=目标 user id） |
/// | [markConversationRead] | `api/chat.ts:181–190` |
/// | [markMessageRead] | `api/chat.ts:211–217`（`exact` 精确已读） |
/// | [recallMessage] | `api/chat.ts:219–225`（限时 120s、仅发送者） |
/// | [declareTyping] | `api/chat.ts:227–233` |
/// | [listMyInvitesPage] | `api/chat.ts:332–334`、[listManagedJoinRequestsPage] | `api/chat.ts:315–317` |
/// | [listLeaveNoticesPage] / [readLeaveNotice] | `api/chat.ts:341–348` |
/// | [actionGroupInvite] / [actionJoinRequest] | `api/chat.ts:319–325 / 350–356` |
///
/// ## 纪律
/// - 路径与查询串与 web **逐字**一致（`pagination=cursor` 是后端硬要求，`views.py:145`）；
/// - **缺席即缺席**：响应里没有的字段不进模型（不造 0 / 不造空串）；
/// - 幂等键由调用方生成并复用（重试同键），本层不偷偷换键。
library;

import 'dart:math';

import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/social_requests.dart';
import '../net/dio_client.dart';
import 'directory_page.dart';

/// 会话订阅项（`api/chat.ts:34` `ConversationSubscription`）。
class AylaConversationSubscription {
  const AylaConversationSubscription({
    required this.id,
    required this.lastMessageSeq,
  });

  final String id;

  /// 该会话的最后一条消息序号（WS `resume` 的补发基线）。
  final int lastMessageSeq;

  static AylaConversationSubscription? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id == null) return null;
    return AylaConversationSubscription(
      id: id.toString(),
      lastMessageSeq: (raw['last_message_seq'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 标已读的响应载荷（`api/chat.ts:212–216`）。
class AylaMessageReadReceipt {
  const AylaMessageReadReceipt({this.markedSeqs, this.subgroupId});

  /// 服务端确认已读的 seq 列表（旧后端缺省 ⇒ null，**不得**据此清零未读）。
  final List<int>? markedSeqs;

  /// 命中的子群（群聊才有；私聊为 null）。
  final String? subgroupId;

  static AylaMessageReadReceipt fromJson(Map<String, dynamic> raw) {
    final Object? seqs = raw['marked_seqs'];
    return AylaMessageReadReceipt(
      markedSeqs: seqs is List
          ? <int>[
              for (final Object? item in seqs)
                if (item is num) item.toInt(),
            ]
          : null,
      subgroupId: raw['subgroup_id']?.toString(),
    );
  }
}

/// 幂等键（web `useChat.ts:38–44` 的 `crypto.randomUUID()` 等价物）。
///
/// Dart 侧无内建 UUID ⇒ 用 [Random.secure] 生成 v4 形态字符串（同一格式、同一去重语义）；
/// **重试必须复用同一个键**（服务端按 key 幂等，换键会造重复消息）。
String aylaNewIdempotencyKey() {
  final Random random = Random.secure();
  final List<int> bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10
  String hex(int start, int end) => <String>[
        for (int i = start; i < end; i++) bytes[i].toRadixString(16).padLeft(2, '0'),
      ].join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}

class AylaChatApi {
  const AylaChatApi._();

  /// `GET /chat/conversations/?pagination=cursor&limit=&cursor=&type=` —— 会话游标页。
  ///
  /// - `pagination=cursor` 是后端**硬要求**（`apps/chat/views.py:145` 的
  ///   `page_requested` 分支才返回 `{results,next_cursor,has_more,total}`）；
  /// - `type` 只在非 all 时带（web `stores/social.ts` 的 `socialQuery` 同：null/空串跳过）；
  /// - 返回行是 `ConversationDirectorySerializer`（`apps/chat/serializers.py:545`），
  ///   含 `group_presence` 与 `directory_activity_at`。
  static Future<AylaDirectoryPage<AylaConversationSummary>>
      listConversationsPage({
    int limit = 20,
    String? cursor,
    String? type,
  }) async {
    final Map<String, dynamic> query = <String, dynamic>{
      'pagination': 'cursor',
      'limit': '$limit',
    };
    if (cursor != null) query['cursor'] = cursor;
    if (type != null && type.isNotEmpty && type != 'all') query['type'] = type;
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>('/chat/conversations/', query: query);
    return AylaDirectoryPage.fromJson<AylaConversationSummary>(
      resp,
      AylaConversationSummary.fromJson,
    );
  }

  /// `GET /chat/subscriptions/?pagination=cursor&limit=&cursor=` —— 有权订阅的会话 id + 各自 last_seq。
  ///
  /// 消费点 = WS 客户端的 `registerAuthorizedGroups`（web `ws/chat.ts:283–320`）：
  /// 登录后批量 `subscribe`，断线重连时按 `last_message_seq` 逐条 `resume`。
  static Future<AylaDirectoryPage<AylaConversationSubscription>>
      listConversationSubscriptionsPage({
    int limit = 100,
    String? cursor,
  }) async {
    final Map<String, dynamic> query = <String, dynamic>{
      'pagination': 'cursor',
      'limit': '$limit',
    };
    if (cursor != null) query['cursor'] = cursor;
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>('/chat/subscriptions/', query: query);
    return AylaDirectoryPage.fromJson<AylaConversationSubscription>(
      resp,
      AylaConversationSubscription.fromJson,
    );
  }

  /// `GET /chat/conversations/<id>/?metadata=1` —— 会话详情（成员**完整**，供 @ 选择器）。
  static Future<AylaConversationSummary> getConversationMetadata(
    String convId,
  ) async {
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>(
      '/chat/conversations/${Uri.encodeComponent(convId)}/',
      query: <String, dynamic>{'metadata': '1'},
    );
    final AylaConversationSummary? conv =
        AylaConversationSummary.fromJson(resp);
    if (conv == null) throw const ApiException(0, '会话详情格式不合法');
    return conv;
  }

  /// `GET /chat/conversations/<id>/?metadata=directory` —— 会话摘要（无成员数组）。
  static Future<AylaConversationSummary> getConversationSummary(
    String convId,
  ) async {
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>(
      '/chat/conversations/${Uri.encodeComponent(convId)}/',
      query: <String, dynamic>{'metadata': 'directory'},
    );
    final AylaConversationSummary? conv =
        AylaConversationSummary.fromJson(resp);
    if (conv == null) throw const ApiException(0, '会话摘要格式不合法');
    return conv;
  }

  /// `POST /chat/conversations/group/` —— 建群（web `api/chat.ts:67–75`），
  /// 返回新会话 id（消费点 = 主页的建群弹窗提交，web `GroupCreateDialog.tsx:51–60`）。
  static Future<String> createGroupConversation({
    required String title,
    required List<String> memberIds,
  }) async {
    final Map<String, dynamic> resp =
        await DioClient.instance.post<Map<String, dynamic>>(
      '/chat/conversations/group/',
      body: <String, dynamic>{
        'title': title,
        'member_ids': memberIds,
      },
    );
    final Object? id = resp['id'];
    if (id == null) throw const ApiException(0, '建群响应缺少会话 id');
    return id.toString();
  }

  /// `POST /chat/group-presence/` —— 批量群状态角标（最多 100 个会话 id）。
  ///
  /// web `api/chat.ts:48–52`：`{presences: {<id>: {live,voice,game} | null}}`。
  /// **缺席即缺席**：响应里没有的 id 不进 map（调用方保持「未知」而不是造 `false`）。
  static Future<Map<String, AylaGroupPresence>> getGroupPresence(
    List<String> conversationIds,
  ) async {
    if (conversationIds.isEmpty) return const <String, AylaGroupPresence>{};
    final Map<String, dynamic> resp =
        await DioClient.instance.post<Map<String, dynamic>>(
      '/chat/group-presence/',
      body: <String, dynamic>{
        'conversation_ids': conversationIds.take(100).toList(growable: false),
      },
    );
    final Object? presences = resp['presences'];
    if (presences is! Map) return const <String, AylaGroupPresence>{};
    final Map<String, AylaGroupPresence> out = <String, AylaGroupPresence>{};
    for (final MapEntry<Object?, Object?> entry in presences.entries) {
      final AylaGroupPresence? value =
          AylaGroupPresence.fromJson(entry.value);
      if (value != null) out[entry.key.toString()] = value;
    }
    return out;
  }

  /// `GET /chat/conversations/<id>/messages/?before_seq=&limit=&subgroup_id=` —— 历史分页。
  ///
  /// web `api/chat.ts:94–102` 返回 `ChatMessage[]`（**裸数组**，不是游标页）。
  /// 首屏 `limit` 20 / 上拉翻页 50（`useChat.ts:34–35` 的两档常量由调用方给）。
  static Future<List<AylaChatMessage>> listMessages(
    String convId, {
    int? beforeSeq,
    int? limit,
    String? subgroupId,
  }) async {
    final Map<String, dynamic> query = <String, dynamic>{};
    if (beforeSeq != null) query['before_seq'] = '$beforeSeq';
    if (limit != null) query['limit'] = '$limit';
    if (subgroupId != null) query['subgroup_id'] = subgroupId;
    final Object? resp = await DioClient.instance.get<Object?>(
      '/chat/conversations/${Uri.encodeComponent(convId)}/messages/',
      query: query.isEmpty ? null : query,
    );
    if (resp is! List) return const <AylaChatMessage>[];
    return <AylaChatMessage>[
      for (final Object? item in resp)
        if (AylaChatMessage.fromJson(item) case final AylaChatMessage msg) msg,
    ];
  }

  /// `POST /chat/conversations/<id>/messages/` —— 发消息（幂等）。
  static Future<AylaChatMessage> sendMessage(
    String convId,
    AylaCreateMessagePayload payload,
  ) async {
    final Map<String, dynamic> resp =
        await DioClient.instance.post<Map<String, dynamic>>(
      '/chat/conversations/${Uri.encodeComponent(convId)}/messages/',
      body: payload.toJson(),
    );
    final AylaChatMessage? msg = AylaChatMessage.fromJson(resp);
    if (msg == null) throw const ApiException(0, '发送响应格式不合法');
    return msg;
  }

  /// `POST /chat/conversations/<id>/messages/` —— 戳一戳（`type=poke`，content=目标 user id）。
  ///
  /// 免打扰轻互动（web `api/chat.ts:168–179`）：落库进历史，但不产生未读/红点/已读回执。
  static Future<AylaChatMessage> sendPoke(
    String convId,
    String targetUserId,
  ) =>
      sendMessage(
        convId,
        AylaCreateMessagePayload(
          type: AylaMessageType.poke,
          content: targetUserId,
          idempotencyKey: aylaNewIdempotencyKey(),
        ),
      );

  /// `POST /chat/conversations/<id>/read/` —— 会话批量已读。
  ///
  /// `preserve_special` = 保留 @我 / 回复类未读（web `markConversationReadThrough`）。
  static Future<void> markConversationRead(
    String convId, {
    int? throughSeq,
    List<String>? excludeMessageIds,
    bool preserveSpecial = false,
  }) async {
    await DioClient.instance.post<Map<String, dynamic>>(
      '/chat/conversations/${Uri.encodeComponent(convId)}/read/',
      body: <String, dynamic>{
        if (throughSeq != null) 'through_seq': throughSeq,
        if (excludeMessageIds != null && excludeMessageIds.isNotEmpty)
          'exclude_message_ids': excludeMessageIds,
        if (preserveSpecial) 'preserve_special': true,
      },
    );
  }

  /// `POST /chat/conversations/<id>/messages/<mid>/read/` —— 标已读（`exact` = 精确一条）。
  static Future<AylaMessageReadReceipt> markMessageRead(
    String convId,
    String messageId, {
    bool exact = false,
  }) async {
    final Map<String, dynamic> resp =
        await DioClient.instance.post<Map<String, dynamic>>(
      '/chat/conversations/${Uri.encodeComponent(convId)}/messages/${Uri.encodeComponent(messageId)}/read/',
      body: exact ? <String, dynamic>{'exact': true} : null,
    );
    return AylaMessageReadReceipt.fromJson(resp);
  }

  /// `POST /chat/conversations/<id>/messages/<mid>/recall/` —— 撤回（限时 120s、仅发送者）。
  static Future<AylaChatMessage> recallMessage(
    String convId,
    String messageId,
  ) async {
    final Map<String, dynamic> resp =
        await DioClient.instance.post<Map<String, dynamic>>(
      '/chat/conversations/${Uri.encodeComponent(convId)}/messages/${Uri.encodeComponent(messageId)}/recall/',
    );
    final AylaChatMessage? msg = AylaChatMessage.fromJson(resp);
    if (msg == null) throw const ApiException(0, '撤回响应格式不合法');
    return msg;
  }

  /// `POST /chat/conversations/<id>/typing/` —— 声明输入中（触发 typing 广播）。
  static Future<void> declareTyping(String convId, bool isTyping) async {
    await DioClient.instance.post<Map<String, dynamic>>(
      '/chat/conversations/${Uri.encodeComponent(convId)}/typing/',
      body: <String, dynamic>{'is_typing': isTyping},
    );
  }

  /// `GET /chat/me/invites/?pagination=cursor&limit=&cursor=` —— 我收到的入群邀请。
  static Future<AylaDirectoryPage<AylaGroupInvite>> listMyInvitesPage({
    int limit = 30,
    String? cursor,
  }) async {
    final Map<String, dynamic> query = <String, dynamic>{
      'pagination': 'cursor',
      'limit': '$limit',
    };
    if (cursor != null) query['cursor'] = cursor;
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>('/chat/me/invites/', query: query);
    return AylaDirectoryPage.fromJson<AylaGroupInvite>(
      resp,
      (Object? raw) => raw is Map<String, dynamic>
          ? AylaGroupInvite.fromJson(raw)
          : null,
    );
  }

  /// `GET /chat/me/join-requests/?pagination=cursor&limit=&cursor=` —— 待我审批的入群申请（群主/管理员）。
  static Future<AylaDirectoryPage<AylaGroupJoinRequest>>
      listManagedJoinRequestsPage({
    int limit = 30,
    String? cursor,
  }) async {
    final Map<String, dynamic> query = <String, dynamic>{
      'pagination': 'cursor',
      'limit': '$limit',
    };
    if (cursor != null) query['cursor'] = cursor;
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>('/chat/me/join-requests/', query: query);
    return AylaDirectoryPage.fromJson<AylaGroupJoinRequest>(
      resp,
      (Object? raw) => raw is Map<String, dynamic>
          ? AylaGroupJoinRequest.fromJson(raw)
          : null,
    );
  }

  /// `GET /chat/leave-notices/?pagination=cursor&limit=&cursor=` —— 未读退群通知。
  static Future<AylaDirectoryPage<AylaGroupMemberLeaveNotice>>
      listLeaveNoticesPage({
    int limit = 30,
    String? cursor,
  }) async {
    final Map<String, dynamic> query = <String, dynamic>{
      'pagination': 'cursor',
      'limit': '$limit',
    };
    if (cursor != null) query['cursor'] = cursor;
    final Map<String, dynamic> resp = await DioClient.instance
        .get<Map<String, dynamic>>('/chat/leave-notices/', query: query);
    return AylaDirectoryPage.fromJson<AylaGroupMemberLeaveNotice>(
      resp,
      (Object? raw) => raw is Map<String, dynamic>
          ? AylaGroupMemberLeaveNotice.fromJson(raw)
          : null,
    );
  }

  /// `POST /chat/leave-notices/<id>/read/` —— 标记退群通知已读。
  static Future<void> readLeaveNotice(String noticeId) async {
    await DioClient.instance.post<Map<String, dynamic>>(
      '/chat/leave-notices/${Uri.encodeComponent(noticeId)}/read/',
    );
  }

  /// `POST /chat/invites/<id>/action/` —— 接受/拒绝入群邀请。
  static Future<void> actionGroupInvite(
    String inviteId,
    bool accept,
  ) async {
    await DioClient.instance.post<Map<String, dynamic>>(
      '/chat/invites/${Uri.encodeComponent(inviteId)}/action/',
      body: <String, dynamic>{'action': accept ? 'accept' : 'reject'},
    );
  }

  /// `POST /chat/join-requests/<id>/action/` —— 同意/拒绝入群申请。
  static Future<void> actionJoinRequest(
    String requestId,
    bool accept,
  ) async {
    await DioClient.instance.post<Map<String, dynamic>>(
      '/chat/join-requests/${Uri.encodeComponent(requestId)}/action/',
      body: <String, dynamic>{'action': accept ? 'accept' : 'reject'},
    );
  }
}
