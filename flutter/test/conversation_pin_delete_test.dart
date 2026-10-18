/// 会话「置顶 / 删除」的两步式动作 + 改密改邮箱 API 的**契约测试**（P0-1 / P0-2 / P1-9）。
///
/// ## 为什么必须锁这几条（2026-10-15 用户实报）
/// - 置顶：四个挂载点**全部没传** `onTogglePin` ⇒ 菜单项点了没反应；
/// - 删除：`hideConversation` 没有接线，且菜单项**没有二次确认**
///   （web 是 ConfirmDialog 先行，确认后才发请求）；
/// - 改密/改邮箱：`AylaPrivacySheet` 的三个注入位在 `profile_page` 全为 null ⇒
///   点「发送验证码 / 确认修改」什么都不发生。
///
/// ## 口径（硬要求，全部指回 web）
/// 1. 置顶/删除是**两步式**：**先请求、成功后**才动本地状态，失败静默
///    （`ConversationMoreMenu.tsx:91–120` / `ServerRail.tsx:75–85`）；
/// 2. 改密/改邮箱的 **POST 路径与 body 键名逐字一致**
///    （`api/auth.ts:28–41` + `types.ts:57–67`）—— 用真实回环 HTTP 断言，
///    不是断言函数返回值（与 `chat_send_subgroup_test.dart` 同款范式）。
///
/// ⚠️ 本文件**只放 `test()`**：`testWidgets` 会让 `TestWidgetsFlutterBinding`
/// 把进程内 HTTP 全换成 400 mock，真实回环链路会整片失败（实测）。
/// 菜单弹层的 widget 断言见 `conversation_more_menu_confirm_test.dart`。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/auth_api.dart';
import '../lib/core/models/conversation.dart';
import '../lib/core/net/dio_client.dart';
import '../lib/state/chat_state.dart';

/// 无令牌占位（本文件只验路径/body，不关心鉴权头）。
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

/// 一条到达的请求（method + path + body）。
class _Hit {
  _Hit(this.method, this.path, this.body);
  final String method;
  final String path;
  final Map<String, dynamic> body;
}

/// 极简回环服务：按路径返回预设 JSON，并记录全部请求。
class _Server {
  final List<_Hit> hits = <_Hit>[];
  final Map<String, Map<String, dynamic>> responses =
      <String, Map<String, dynamic>>{};
  final Set<String> failPaths = <String>{};

  Future<void> handle(HttpRequest request) async {
    final String raw = await utf8.decoder.bind(request).join();
    final Map<String, dynamic> body = raw.isEmpty
        ? const <String, dynamic>{}
        : (jsonDecode(raw) as Map<String, dynamic>);
    final String path = request.uri.path;
    hits.add(_Hit(request.method, path, body));
    if (failPaths.contains(path)) {
      request.response
        ..statusCode = 500
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(<String, dynamic>{'detail': '服务异常'}));
    } else {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(responses[path] ?? <String, dynamic>{}));
    }
    await request.response.close();
  }
}

AylaConversationSummary _conv({
  required String id,
  String title = '会话',
  bool group = false,
  bool pinned = false,
}) =>
    AylaConversationSummary(
      id: id,
      type: group ? AylaConversationType.group : AylaConversationType.private,
      title: title,
      isPinned: pinned,
    );

void main() {
  // 真实回环 HTTP：不要初始化 widget binding（它会把进程内 HTTP 全换成 400 mock）。
  HttpOverrides.global = null;

  late _Server server;
  late HttpServer http;

  setUpAll(() async {
    server = _Server();
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // ignore: unawaited_futures
    http.listen(server.handle);
    // ⚠️ 顺序固定：先设 override（dio 的 baseUrl 只在首次 init 时构造），再 init。
    DioClient.instance.debugBaseUrlOverride = 'http://127.0.0.1:${http.port}';
    DioClient.instance.init(tokenStore: _NoToken(), onSessionExpired: () {});
  });

  tearDownAll(() async {
    await http.close(force: true);
  });

  setUp(() {
    server.hits.clear();
    server.responses.clear();
    server.failPaths.clear();
  });

  // ======================= P0-1 置顶 =======================

  group('P0-1 置顶（web ConversationMoreMenu.tsx:91–103 / ServerRail.tsx:75–85）', () {
    test('成功路径：POST pin 的路径与 body 逐字一致，成功后本地才翻转', () async {
      final AylaChatState chat = AylaChatState()
        ..setConversations(<AylaConversationSummary>[
          _conv(id: 'c1'),
          _conv(id: 'c2'),
        ]);
      server.responses['/api/v1/chat/conversations/c1/pin/'] =
          <String, dynamic>{'pinned': true, 'detail': 'ok'};

      final bool ok = await aylaToggleConversationPin(chat, 'c1', true);

      expect(ok, isTrue);
      expect(server.hits, hasLength(1));
      expect(server.hits.single.method, 'POST');
      expect(server.hits.single.path, '/api/v1/chat/conversations/c1/pin/',
          reason: 'api/chat.ts:193 `POST /chat/conversations/<id>/pin/`');
      expect(server.hits.single.body, <String, dynamic>{'pinned': true},
          reason: 'api/chat.ts:196 body = { pinned }');
      expect(chat.byId('c1')!.isPinned, isTrue,
          reason: 'web .then 里才 setPin ⇒ 成功后才翻转');
      expect(chat.byId('c2')!.isPinned, isFalse, reason: '只动目标会话');
    });

    test('失败路径：请求失败 ⇒ 本地状态**不动**（静默，不上抛）', () async {
      final AylaChatState chat = AylaChatState()
        ..setConversations(<AylaConversationSummary>[_conv(id: 'c1')]);
      server.failPaths.add('/api/v1/chat/conversations/c1/pin/');

      // 不抛异常就是「静默」的直接判据（web .catch(() => {})）。
      final bool ok = await aylaToggleConversationPin(chat, 'c1', true);

      expect(ok, isFalse);
      expect(chat.byId('c1')!.isPinned, isFalse,
          reason: 'ConversationMoreMenu.tsx:99–101 置顶失败静默：不更新、不回滚');
    });

    test('取消置顶：pinned=false 原样进 body', () async {
      final AylaChatState chat = AylaChatState()
        ..setConversations(<AylaConversationSummary>[
          _conv(id: 'c1', pinned: true),
        ]);
      await aylaToggleConversationPin(chat, 'c1', false);
      expect(server.hits.single.body['pinned'], isFalse);
      expect(chat.byId('c1')!.isPinned, isFalse);
    });

    test('未注入 chatState（null）⇒ 仍发请求、不崩（纯函数可用性）', () async {
      final bool ok = await aylaToggleConversationPin(null, 'c1', true);
      expect(ok, isTrue);
      expect(server.hits, hasLength(1));
    });
  });

  // ======================= P0-2 删除 =======================

  group('P0-2 删除（web ConversationMoreMenu.tsx:110–120）', () {
    test('成功路径：POST hide 路径逐字一致，成功后从列表移除', () async {
      final AylaChatState chat = AylaChatState()
        ..setConversations(<AylaConversationSummary>[
          _conv(id: 'c1'),
          _conv(id: 'c2'),
        ]);

      final bool ok = await aylaHideConversation(chat, 'c1');

      expect(ok, isTrue);
      expect(server.hits.single.method, 'POST');
      expect(server.hits.single.path, '/api/v1/chat/conversations/c1/hide/',
          reason: 'api/chat.ts:204 `POST /chat/conversations/<id>/hide/`');
      expect(chat.byId('c1'), isNull);
      expect(chat.byId('c2'), isNotNull, reason: '只移除目标会话');
    });

    test('失败路径：请求失败 ⇒ 会话仍在列表里（静默）', () async {
      final AylaChatState chat = AylaChatState()
        ..setConversations(<AylaConversationSummary>[_conv(id: 'c1')]);
      server.failPaths.add('/api/v1/chat/conversations/c1/hide/');

      final bool ok = await aylaHideConversation(chat, 'c1');

      expect(ok, isFalse);
      expect(chat.byId('c1'), isNotNull,
          reason: 'ConversationMoreMenu.tsx:117–119 删除失败静默：条目保留以便重试');
    });

    test('删除当前选中会话 ⇒ activeConversationId 一并清空（chat.ts:168–172）',
        () async {
      final AylaChatState chat = AylaChatState()
        ..setConversations(<AylaConversationSummary>[_conv(id: 'c1')]);
      chat.openConversation('c1');
      await aylaHideConversation(chat, 'c1');
      expect(chat.activeConversationId, isNull);
    });
  });

  // ======================= 页面投影辅助 =======================

  group('页面私有分页投影的辅助函数（Flutter 侧特有的一步）', () {
    test('aylaApplyPinToProjection：就地替换同 id 的置顶态，纯函数不改入参', () {
      final List<AylaConversationSummary> items = <AylaConversationSummary>[
        _conv(id: 'c1'),
        _conv(id: 'c2'),
      ];
      final List<AylaConversationSummary> pinned =
          aylaApplyPinToProjection(items, 'c1', true);
      expect(pinned.first.isPinned, isTrue);
      expect(pinned[1].isPinned, isFalse);
      expect(items.first.isPinned, isFalse, reason: '不得原地改入参');
    });

    test('aylaRemoveFromProjection：移除一条、保留其余', () {
      final List<AylaConversationSummary> items = <AylaConversationSummary>[
        _conv(id: 'c1'),
        _conv(id: 'c2'),
      ];
      final List<AylaConversationSummary> removed =
          aylaRemoveFromProjection(items, 'c1');
      expect(removed.map((AylaConversationSummary c) => c.id), <String>['c2']);
      expect(items, hasLength(2), reason: '不得原地改入参');
    });
  });

  // ======================= P1-9 改密 / 改邮箱 =======================

  group('P1-9 改密 / 改邮箱（web api/auth.ts:28–41）', () {
    test('changePassword：POST /auth/change-password/，body = {code, new_password}',
        () async {
      server.responses['/api/v1/auth/change-password/'] =
          <String, dynamic>{'detail': '密码已更新'};
      final String detail = await AuthApi.changePassword(
        code: '123456',
        newPassword: 'newpass1234',
      );

      expect(server.hits.single.method, 'POST');
      expect(server.hits.single.path, '/api/v1/auth/change-password/',
          reason: 'api/auth.ts:30');
      expect(server.hits.single.body, <String, dynamic>{
        'code': '123456',
        'new_password': 'newpass1234',
      }, reason: 'types.ts:57–60 ChangePasswordPayload 逐字一致');
      expect(detail, '密码已更新');
    });

    test('changeEmail：POST /auth/change-email/，body 三键逐字一致', () async {
      server.responses['/api/v1/auth/change-email/'] =
          <String, dynamic>{'detail': '邮箱已更新', 'email': 'new@example.com'};
      final String email = await AuthApi.changeEmail(
        currentCode: '111111',
        newEmail: 'new@example.com',
        newCode: '222222',
      );

      expect(server.hits.single.path, '/api/v1/auth/change-email/',
          reason: 'api/auth.ts:38');
      expect(server.hits.single.body, <String, dynamic>{
        'current_code': '111111',
        'new_email': 'new@example.com',
        'new_code': '222222',
      }, reason: 'types.ts:63–67 ChangeEmailPayload 逐字一致');
      expect(email, 'new@example.com', reason: '响应 email 回传给调用方');
    });

    test('未绑定邮箱：current_code 照传空串（web PrivacySheet.tsx:137）', () async {
      await AuthApi.changeEmail(
        currentCode: '',
        newEmail: 'a@b.co',
        newCode: '333333',
      );
      expect(server.hits.single.body['current_code'], '',
          reason: 'boundEmail ? curCode.trim() : ""');
    });

    test('失败路径：后端 500 ⇒ 抛 ApiException，文案取后端 detail', () async {
      server.failPaths.add('/api/v1/auth/change-password/');
      await expectLater(
        AuthApi.changePassword(code: '000000', newPassword: 'aaaaaaaaa'),
        throwsA(isA<ApiException>()
            .having((ApiException e) => e.message, 'message', '服务异常')),
      );
    });
  });
}
