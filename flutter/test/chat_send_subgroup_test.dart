/// 群聊发送的 **子群归属** 端到端回归锁 —— web @useChat.ts:427/448/477/381@ +
/// @MessageInput.tsx:249-253@ + @GroupChat.tsx:317/416@。
///
/// ## 为什么必须有这条（用户实报「群子群也是接线错误，接到主群去了」）
/// 真根因在**发送链**：@AylaMessageInputSubmission@ 此前没有 subgroupId、
/// @AylaConversationRuntime.send@ 也不传 ⇒ 群聊所有 POST 都不带 @subgroup_id@
/// ⇒ 后端落 NULL、消息归默认组/主群，子群活跃度永不推进。
///
/// ## 口径（硬要求）
/// **断言真实 POST body 里的 @subgroup_id@** —— 不是函数返回值、不是纯函数。
/// 用真实回环 HTTP server 收请求（与 @auth_remember_test.dart@ 同款范式）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/chat_api.dart';
import '../lib/core/models/chat_message.dart';
import '../lib/core/net/dio_client.dart';
import '../lib/pages/chat_support.dart' show aylaSubgroupIdParam;

/// 无令牌占位（本文件只验 body，不关心鉴权头）。
class _NoToken implements AuthTokenStore {
  @override
  String? get accessToken => null;
  @override
  String? get refreshToken => null;
  @override
  void setTokens(String access, String? refresh) {}
  @override
  void clear() {}
}

/// 记录到达的 POST body（只关心 messages 端点）。
class _Recorder {
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];

  Future<void> handle(HttpRequest request) async {
    final String raw = await utf8.decoder.bind(request).join();
    if (request.uri.path.contains('/messages/') &&
        request.method == 'POST') {
      bodies.add(jsonDecode(raw) as Map<String, dynamic>);
      request.response
        ..statusCode = 201
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(<String, dynamic>{
          'id': 'm1',
          'conversation_id': 'g1',
          'sender_id': 'u1',
          'type': 'text',
          'content': 'x',
          'seq': 1,
          'created_at': '2026-10-01T00:00:00Z',
        }));
    } else {
      request.response.statusCode = 200;
      request.response.write('{}');
    }
    await request.response.close();
  }
}

void main() {
  // 真实回环 HTTP：不要初始化 widget binding（它会把进程内 HTTP 全换成 400 mock）。
  HttpOverrides.global = null;

  late _Recorder recorder;
  late HttpServer server;

  setUpAll(() async {
    recorder = _Recorder();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // ignore: unawaited_futures
    server.listen(recorder.handle);
    // ⚠️ 顺序固定：先设 override（dio 的 baseUrl 只在首次 init 时构造），
    // 再 init（构造出 dio 实例），否则 DioClient.dio 是 late 未初始化的。
    DioClient.instance.debugBaseUrlOverride = 'http://127.0.0.1:${server.port}';
    DioClient.instance.init(
      tokenStore: _NoToken(),
      onSessionExpired: () {},
    );
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  setUp(() {
    recorder.bodies.clear();
  });

  group('POST body 的 subgroup_id（web useChat.ts:381/448/477）', () {
    test('纯文本消息：subgroupId 为 null ⇒ **不进 body**（web undefined 同义）', () {
      final AylaCreateMessagePayload p = AylaCreateMessagePayload(
        type: AylaMessageType.text,
        content: '你好',
        idempotencyKey: 'k1',
        subgroupId: aylaSubgroupIdParam(null),
      );
      expect(p.toJson().containsKey('subgroup_id'), isFalse,
          reason: 'core/models/chat_message.dart:478「缺席即缺席」');
    });

    test('纯文本消息：subgroupId "7" ⇒ body 里 subgroup_id == 7（int）', () {
      final AylaCreateMessagePayload p = AylaCreateMessagePayload(
        type: AylaMessageType.text,
        content: '你好',
        idempotencyKey: 'k1',
        subgroupId: aylaSubgroupIdParam('7'),
      );
      expect(p.toJson()['subgroup_id'], 7,
          reason: 'web useChat.ts:448 的 Number(subgroupId)');
    });

    test('真实 POST：带 subgroupId 发送 ⇒ 服务端收到 subgroup_id', () async {
      await AylaChatApi.sendMessage(
        'g1',
        AylaCreateMessagePayload(
          type: AylaMessageType.text,
          content: '发到子群',
          idempotencyKey: 'k-live',
          subgroupId: aylaSubgroupIdParam('42'),
        ),
      );

      expect(recorder.bodies, hasLength(1));
      expect(recorder.bodies.single['subgroup_id'], 42,
          reason: '★ 真实链路：这是「子群接到主群」的直接判据');
      expect(recorder.bodies.single['content'], '发到子群');
    });

    test('真实 POST：不带 subgroupId ⇒ body 里没有 subgroup_id 键', () async {
      await AylaChatApi.sendMessage(
        'g1',
        AylaCreateMessagePayload(
          type: AylaMessageType.text,
          content: '主群消息',
          idempotencyKey: 'k-main',
        ),
      );
      expect(recorder.bodies.single.containsKey('subgroup_id'), isFalse);
    });

    test('非法子群 id（非数字）⇒ 不发该字段（对齐 Number() 得 NaN 的 undefined）', () {
      expect(aylaSubgroupIdParam('abc'), isNull,
          reason: 'web Number("abc") = NaN ⇒ JSON 序列化成 null ⇒ 等价于不发');
    });
  });
}
