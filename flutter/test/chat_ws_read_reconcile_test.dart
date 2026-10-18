/// P1-3 定向测试：`message.read` 的**会话摘要对账**分支
/// —— web `ws/chat.ts:599–607`。
///
/// web 原文：
/// ```ts
/// case "message.read":
///   const d = frame.data;
///   message.markReadByMessage(d.conversation_id, d.message_id, d.user_id);
///   if (String(d.user_id) === String(useAuthStore.getState().currentUser?.id)
///     && chat.conversations.find((item) => item.id === d.conversation_id)?.unread_seqs_complete === false) {
///     this.reconcileConversation(d.conversation_id);
///   }
/// ```
///
/// 两条判据缺一不可：**本人**（`user_id === me`）且**摘要未读序号不全**
/// （`unread_seqs_complete === false`）。其余组合一律不触发 REST。
///
/// `reconcileConversation` 的真实实现是拉 `GET /chat/conversations/<id>/?metadata=directory`
/// 并 `upsertConversation` ⇒ 本组用**真实回环 HTTP** 断言「发了/没发」。
/// ⚠️ 不要初始化 `TestWidgetsFlutterBinding`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/conversation.dart';
import '../lib/core/net/dio_client.dart';
import '../lib/core/ws/chat_ws.dart';
import '../lib/state/badges_state.dart';
import '../lib/state/chat_state.dart';
import '../lib/state/message_state.dart';
import '../lib/state/notices_state.dart';
import '../lib/state/realtime_state.dart';
import '../lib/state/subgroup_state.dart';

/// 最小会话后端：`GET /api/v1/chat/conversations/<id>/`（`?metadata=directory`）。
class _ChatBackend {
  /// convId → 响应体；缺失即 404。
  final Map<String, Map<String, dynamic>> conversations =
      <String, Map<String, dynamic>>{};

  /// 实际收到的请求路径（断言「有没有发 REST」用）。
  final List<String> requests = <String>[];

  Future<void> handle(HttpRequest request) async {
    requests.add(request.uri.toString());
    final RegExpMatch? m =
        RegExp('^/api/v1/chat/conversations/([^/]+)/\$').firstMatch(request.uri.path);
    if (request.method != 'GET' || m == null) {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    final String id = m.group(1)!;
    final Map<String, dynamic>? body = conversations[id];
    request.response.statusCode = body == null ? 404 : 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(
      body ?? <String, dynamic>{'detail': 'not found'},
    ));
    await request.response.close();
  }
}

class _NoTokens implements AuthTokenStore {
  @override
  String? get accessToken => null;

  @override
  String? get refreshToken => null;

  @override
  void setTokens(String access, String? refresh) {}

  @override
  void clear() {}
}

/// 会话摘要响应体（只带本组关心的字段）。
Map<String, dynamic> _summaryBody({
  required String id,
  bool? unreadSeqsComplete,
  int unreadCount = 0,
}) =>
    <String, dynamic>{
      'id': id,
      'type': 'group',
      'title': '群$id',
      'announcement': '',
      'avatar': '',
      'owner_id': 'u-me',
      'members': <Map<String, dynamic>>[],
      'members_complete': false,
      'member_count': 3,
      'unread_count': unreadCount,
      'my_role': 'owner',
      'created_at': '2026-10-01T00:00:00Z',
      if (unreadSeqsComplete != null) 'unread_seqs_complete': unreadSeqsComplete,
    };

void main() {
  HttpOverrides.global = null;
  late _ChatBackend backend;
  late HttpServer server;

  setUpAll(() async {
    backend = _ChatBackend();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // ignore: unawaited_futures
    server.listen(backend.handle);
    DioClient.instance.debugBaseUrlOverride = 'http://127.0.0.1:${server.port}';
    DioClient.instance.init(tokenStore: _NoTokens(), onSessionExpired: () {});
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  setUp(() {
    backend.conversations.clear();
    backend.requests.clear();
  });

  /// 脚手架：真实 client（**开** autoReconcile —— 本组测的就是这个分支）。
  ({AylaChatWsClient client, AylaChatState chat, AylaMessageState message})
      harness({String? me = 'u-me'}) {
    final AylaChatState chat = AylaChatState();
    final AylaMessageState message = AylaMessageState();
    final AylaChatWsClient client = AylaChatWsClient(
      chatState: chat,
      messageState: message,
      notices: AylaNoticesController(),
      badges: AylaBadgesController(),
      realtime: AylaRealtimeState(),
      subgroupState: AylaSubGroupState(),
      currentUserId: () => me,
      autoReconcile: true,
    );
    client.debugSend = (Map<String, dynamic> _) {};
    return (client: client, chat: chat, message: message);
  }

  /// 预置一个会话摘要（`unread_seqs_complete` 由调用方决定）。
  void seedConversation(
    AylaChatState chat, {
    required String id,
    bool? unreadSeqsComplete,
    int unreadCount = 5,
  }) =>
      chat.setConversations(<AylaConversationSummary>[
        AylaConversationSummary(
          id: id,
          type: AylaConversationType.group,
          title: '群',
          unreadCount: unreadCount,
          unreadSeqsComplete: unreadSeqsComplete,
        ),
      ]);

  Map<String, dynamic> readFrame({
    String convId = 'c1',
    String messageId = 'm1',
    String userId = 'u-me',
  }) =>
      <String, dynamic>{
        'type': 'message.read',
        'data': <String, dynamic>{
          'conversation_id': convId,
          'message_id': messageId,
          'user_id': userId,
          'seq': 1,
        },
      };

  group('message.read 摘要对账（web ws/chat.ts:599–607）', () {
    test('本人 + unread_seqs_complete == false ⇒ 触发一次摘要对账并 upsert',
        () async {
      backend.conversations['c1'] = _summaryBody(
        id: 'c1',
        unreadSeqsComplete: false,
        unreadCount: 0,
      );
      final h = harness();
      seedConversation(h.chat,
          id: 'c1', unreadSeqsComplete: false, unreadCount: 5);
      h.message.openBucket('c1');

      h.client.debugHandleFrame(readFrame());
      await pumpEventQueue();

      expect(backend.requests.length, 1,
          reason: 'web :604 reconcileConversation 会拉一次摘要');
      expect(backend.requests.single, contains('/chat/conversations/c1/'));
      // 对账结果落地：未读数被服务端权威值覆盖（5 → 0）。
      expect(h.chat.byId('c1')!.unreadCount, 0);
    });

    test('本人 + unread_seqs_complete == true ⇒ **不发** REST（本地已能精确推算）',
        () async {
      final h = harness();
      seedConversation(h.chat,
          id: 'c1', unreadSeqsComplete: true, unreadCount: 5);
      h.message.openBucket('c1');

      h.client.debugHandleFrame(readFrame());
      await pumpEventQueue();

      expect(backend.requests, isEmpty, reason: 'web 判据要求 === false');
    });

    test('本人 + unread_seqs_complete 为 null（旧后端不返回）⇒ 不发 REST',
        () async {
      // web：`undefined === false` 为假 ⇒ 不触发。**不能**把 null 当 false 处理。
      final h = harness();
      seedConversation(h.chat, id: 'c1', unreadSeqsComplete: null);
      h.message.openBucket('c1');

      h.client.debugHandleFrame(readFrame());
      await pumpEventQueue();

      expect(backend.requests, isEmpty);
    });

    test('**他人**已读 + 序号不全 ⇒ 不发 REST（web 要求 user_id === me）', () async {
      final h = harness();
      seedConversation(h.chat,
          id: 'c1', unreadSeqsComplete: false, unreadCount: 5);
      h.message.openBucket('c1');

      h.client.debugHandleFrame(readFrame(userId: 'u-peer'));
      await pumpEventQueue();

      expect(backend.requests, isEmpty);
      // 但「对端已读回执」这一半照常生效（① 无条件执行）。
      expect(h.message.readBy('c1', 'm1'), <String>['u-peer']);
    });

    test('会话不在本地缓存（byId == null）+ 序号不全 ⇒ 不发 REST（web find() 为 undefined）',
        () async {
      final h = harness();
      // 不 seed：本地表里没有 c1。
      h.message.openBucket('c1');

      h.client.debugHandleFrame(readFrame());
      await pumpEventQueue();

      expect(backend.requests, isEmpty);
    });

    test('未登录（me == null）⇒ 不发 REST、不崩', () async {
      final h = harness(me: null);
      seedConversation(h.chat,
          id: 'c1', unreadSeqsComplete: false, unreadCount: 5);
      h.message.openBucket('c1');

      h.client.debugHandleFrame(readFrame(userId: 'u-other'));
      await pumpEventQueue();

      expect(backend.requests, isEmpty);
      expect(h.message.readBy('c1', 'm1'), <String>['u-other'],
          reason: '① 回执投影不依赖登录态');
    });

    test('REST 404 ⇒ 静默（不抛、不改本地未读）', () async {
      // 后端没有 c1 ⇒ 404；reconcileConversation 的 catchError 必须吃掉。
      final h = harness();
      seedConversation(h.chat,
          id: 'c1', unreadSeqsComplete: false, unreadCount: 5);
      h.message.openBucket('c1');

      h.client.debugHandleFrame(readFrame());
      await pumpEventQueue();

      expect(backend.requests.length, 1);
      expect(h.chat.byId('c1')!.unreadCount, 5, reason: '失败不改本地（不伪造）');
    });

    test('缺 conversation_id ⇒ 不崩、不发 REST', () async {
      final h = harness();
      h.client.debugHandleFrame(<String, dynamic>{
        'type': 'message.read',
        'data': <String, dynamic>{'message_id': 'm1', 'user_id': 'u-me'},
      });
      await pumpEventQueue();
      expect(backend.requests, isEmpty);
    });
  });
}
