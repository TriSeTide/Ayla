/// 会话域 API —— web `api/chat.ts` 的会话列表子集 + `api/social.ts` 的查询串口径。
///
/// ## 逐条对应
/// | 本方法 | web |
/// |---|---|
/// | [listConversationsPage] | `api/chat.ts:30–32` + `api/social.ts:15–21` |
/// | [getGroupPresence] | `api/chat.ts:48–52`（后端 `apps/chat/views.py` 的 `GroupPresenceBatchView`） |
///
/// ## 为什么现在才带出
/// 第 2 批的三个 hub 页只消费目录接口；主页（`HomePage.tsx:53` 的
/// `useSocialPage("conversations", { type: "group" })`）是**第一个**消费会话列表的页面
/// ⇒ 按「不为没有消费者的能力提前开口子」（AGENTS.md §9）到本批才建。
library;

import '../models/conversation.dart';
import '../net/dio_client.dart';
import 'directory_page.dart';

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
}
