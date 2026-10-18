/// P0-4「申请入群」两条入口的定向测试 —— 对照 web：
/// - `pages/SearchPage.tsx:480–489`（搜索页弹窗）+ `components/group/GroupApplyDialog.tsx:39–55`（提交两态）；
/// - `components/chat/ShareBubble.tsx:75–136`（分享卡守卫 + 弹窗）。
///
/// 断言的是**链路**（不是纯组件）：
/// 1. 搜索页提交 ⇒ 真的打了 `POST /chat/conversations/<id>/join-requests/`；
/// 2. `accepted` 分支 ⇒ 跳群（路由变 `/group/<conversation_id>`）；
/// 3. 申请制分支 ⇒ **不跳转**，弹窗转「申请已发送」成功态；
/// 4. 分享卡：未加入的群 ⇒ 弹 GROUP REQUEST；已加入 ⇒ 直接跳转；
/// 5. 未注入/无 ProviderScope ⇒ 不守卫（不凭空弹窗）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/models/chat_message.dart';
import '../lib/core/models/conversation.dart';
import '../lib/core/models/share_payload.dart';
import '../lib/core/net/dio_client.dart';
import '../lib/pages/search_page.dart';
import '../lib/state/chat_providers.dart' show chatStateProvider;
import '../lib/theme/app_theme.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/chat/share_bubble.dart';
import '../lib/widgets/group/group_apply.dart';

// ===================== 假传输层 =====================

/// 搜索页要打到的端点 + 入群申请端点。
///
/// `applyStatus / applyBody` 决定 `join-requests/` 的响应（两态 + 失败）。
class _ApiAdapter implements HttpClientAdapter {
  /// `join-requests/` 的响应体（null ⇒ 走 `applyStatus` 的错误态）。
  Map<String, dynamic>? applyBody = <String, dynamic>{
    'status': 'accepted',
    'conversation_id': 'g1',
  };

  /// `join-requests/` 的状态码。
  int applyStatus = 200;

  /// 收到的 `join-requests/` 请求（path + body）。
  final List<({String path, Map<String, dynamic> body})> applyCalls =
      <({String path, Map<String, dynamic> body})>[];

  /// `public-summary/` 的响应（分享卡补 join_policy 用）。
  Map<String, dynamic>? publicSummary;

  /// `public-summary/` 被调用次数。
  int publicSummaryCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final String path = options.path;
    Object? body = <String, dynamic>{};

    if (path.endsWith('/join-requests/') && options.method == 'POST') {
      final Object? raw = options.data;
      applyCalls.add((
        path: path,
        body: raw is Map
            ? raw.map((Object? k, Object? v) => MapEntry<String, dynamic>('$k', v))
            : const <String, dynamic>{},
      ));
      if (applyStatus != 200) {
        body = <String, dynamic>{'detail': applyStatus == 400 ? '参数不合法' : '服务器开小差了'};
      } else {
        body = applyBody ?? <String, dynamic>{};
      }
      return _json(body, applyStatus);
    }
    if (path.endsWith('/public-summary/')) {
      publicSummaryCalls += 1;
      if (publicSummary == null) {
        return _json(<String, dynamic>{'detail': '会话不存在'}, 404);
      }
      return _json(publicSummary!, 200);
    }
    if (path.contains('/search/')) {
      body = <String, dynamic>{
        'groups': <String, dynamic>{
          'items': <Object?>[
            <String, dynamic>{
              'id': 'g1',
              'title': '冰樱研究社',
              'join_policy': 'public',
              'member_count': 7,
              'is_member': false,
            },
          ],
          'total': 1,
          'next_cursor': null,
          'has_more': false,
        },
      };
      return _json(body, 200);
    }
    if (path.endsWith('/me/badges/')) {
      return _json(<String, dynamic>{'request_badge': 0, 'message_badge': 0}, 200);
    }
    return _json(<String, dynamic>{}, 200);
  }

  ResponseBody _json(Object body, int status) => ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: <String, List<String>>{
          'content-type': <String>['application/json; charset=utf-8'],
        },
      );

  @override
  void close({bool force = false}) {}
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

// ===================== 宿主 =====================

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _ApiAdapter adapter;

  setUp(() {
    adapter = _ApiAdapter();
    DioClient.instance.init(tokenStore: _NoTokens(), onSessionExpired: () {});
    DioClient.instance.dio.httpClientAdapter = adapter;
  });

  /// 搜索页宿主：真实 `appRouterProvider` 太沉（会拉起整个 AppShell），
  /// 这里用**最小 GoRouter**（两条路由）+ 预览主题，保证 `context.go` 真的走路由。
  Future<GoRouter> pumpSearch(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    final GoRouter router = GoRouter(
      initialLocation: '/search?q=群',
      routes: <RouteBase>[
        GoRoute(
          path: '/search',
          builder: (BuildContext c, GoRouterState s) => SearchPage(
            initialQuery: s.uri.queryParameters['q'],
            initialType: s.uri.queryParameters['type'],
          ),
        ),
        GoRoute(
          path: '/group/:id',
          builder: (BuildContext c, GoRouterState s) =>
              Scaffold(body: Text('GROUP ${s.pathParameters['id']}')),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: buildAylaTheme(),
          // 弹窗里的 `AylaGlassInput` 是 TextField，需要 Material 祖先：
          // `MaterialApp` 的 Scaffold 只在页面里有，而**根 Overlay** 上的弹层不在
          // 那个 Scaffold 之下 ⇒ 在这里给整棵树兜一层透明 Material。
          builder: (BuildContext context, Widget? child) => Material(
            type: MaterialType.transparency,
            child: child!,
          ),
        ),
      ),
    );
    for (int i = 0; i < 8; i += 1) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    return router;
  }

  group('入口 A：搜索页入群弹窗提交（SearchPage.tsx:480–489）', () {
    testWidgets('公开群 accepted ⇒ 真的打 applyToGroup 并跳 /group/<conversation_id>',
        (WidgetTester tester) async {
      final GoRouter router = await pumpSearch(tester);

      await tester.tap(find.text('申请入群').first);
      for (int i = 0; i < 6; i += 1) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.byType(AylaGroupApplyDialog), findsOneWidget);

      await tester.tap(find.text('直接加入'));
      for (int i = 0; i < 10; i += 1) {
        await tester.pump(const Duration(milliseconds: 60));
      }

      expect(adapter.applyCalls.length, 1, reason: '提交必须真的发请求');
      expect(adapter.applyCalls.single.path, contains('/chat/conversations/g1/join-requests/'));
      expect(adapter.applyCalls.single.body['message'], '');
      expect(router.state.uri.path, '/group/g1', reason: 'accepted ⇒ onJoined 跳群');
      expect(tester.takeException(), isNull);
    });

    testWidgets('申请制（返回申请单）⇒ 不跳转、弹窗转「申请已发送」', (WidgetTester tester) async {
      // 后端 `GroupJoinRequestSerializer` 的真实形状（`serializers.py:818–842`）。
      adapter.applyBody = <String, dynamic>{
        'id': 1,
        'conversation_id': 'g1',
        'conversation_title': '冰樱研究社',
        'applicant': <String, dynamic>{'id': 'u9', 'nickname': '我'},
        'message': '',
        'status': 'pending',
        'handled_by_id': null,
        'handled_at': null,
        'created_at': '2026-10-16T00:00:00Z',
      };
      final GoRouter router = await pumpSearch(tester);

      await tester.tap(find.text('申请入群').first);
      for (int i = 0; i < 6; i += 1) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.tap(find.text('直接加入'));
      for (int i = 0; i < 10; i += 1) {
        await tester.pump(const Duration(milliseconds: 60));
      }

      expect(adapter.applyCalls.length, 1);
      expect(find.text('申请已发送'), findsOneWidget, reason: 'tsx 49：sent 成功态');
      expect(router.state.uri.path, '/search', reason: '申请制**不跳转**');
      expect(tester.takeException(), isNull);
    });

    testWidgets('后端 400 ⇒ 展示 detail 文案、留在弹窗（不伪造成功）',
        (WidgetTester tester) async {
      adapter.applyStatus = 400;
      final GoRouter router = await pumpSearch(tester);

      await tester.tap(find.text('申请入群').first);
      for (int i = 0; i < 6; i += 1) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.tap(find.text('直接加入'));
      for (int i = 0; i < 10; i += 1) {
        await tester.pump(const Duration(milliseconds: 60));
      }

      expect(find.text('参数不合法'), findsOneWidget);
      expect(find.text('申请已发送'), findsNothing);
      expect(router.state.uri.path, '/search');
    });

    testWidgets('响应两态都不成立 ⇒ 显式报错（不把非法响应当成功）',
        (WidgetTester tester) async {
      adapter.applyBody = <String, dynamic>{'detail': '奇怪的响应'};
      await pumpSearch(tester);

      await tester.tap(find.text('申请入群').first);
      for (int i = 0; i < 6; i += 1) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.tap(find.text('直接加入'));
      for (int i = 0; i < 10; i += 1) {
        await tester.pump(const Duration(milliseconds: 60));
      }

      expect(find.text('入群申请响应格式不合法'), findsOneWidget);
      expect(find.text('申请已发送'), findsNothing);
    });
  });

  group('入口 B：分享卡群申请守卫（ShareBubble.tsx:75–136）', () {
    /// 分享卡宿主：**必须**用 [previewTheme] 而非裸 MaterialApp ——
    /// 弹窗里的 `AylaGlassInput` 是 TextField，要求 Material + Overlay +
    /// MaterialLocalizations 祖先（见 `theme/preview_theme.dart` 文件头的三条实测约束）。
    /// 该宿主**不带 ProviderScope** ⇒ 「未注入成员关系」那档正好落在这里。
    AylaChatMessage shareMsg(String targetId) => AylaChatMessage(
          id: 's1',
          conversationId: 'c1',
          senderId: 'u1',
          type: AylaMessageType.share,
          content: '',
          sharePayload: AylaSharePayload.group(
            id: targetId,
            title: '爱莉的粉丝群',
          ),
          status: AylaMessageStatus.sent,
          seq: 1,
          createdAt: '2026-09-24T10:00:00Z',
        );

    /// 分享卡宿主（**不带 ProviderScope** —— 见「不做守卫」那档）。
    Widget host(Widget child) => previewTheme(
          Builder(
            builder: (BuildContext context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(size: const Size(560, 400)),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: 560, height: 400, child: child),
              ),
            ),
          ),
        );

    testWidgets('未加入（isGroupJoined=false）⇒ 点卡不跳转、弹 GROUP REQUEST',
        (WidgetTester tester) async {
      String? route;
      await tester.pumpWidget(host(AylaShareBubble(
        msg: shareMsg('g1'),
        isGroupJoined: (String _) => false,
        onNavigate: (String r) => route = r,
      )));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('爱莉的粉丝群'));
      for (int i = 0; i < 6; i += 1) {
        await tester.pump(const Duration(milliseconds: 60));
      }

      expect(find.byType(AylaGroupApplyDialog), findsOneWidget,
          reason: '未加入 ⇒ 弹 GROUP REQUEST（tsx 82–85 + 124–136）');
      // payload 没有 join_policy，public-summary 在本宿主里会 404（假后端默认 null）
      // ⇒ 回退到已知字段 + 未知策略按申请制（tsx 15）⇒ 提交键文案是「发送入群申请」。
      expect(find.text('发送入群申请'), findsOneWidget,
          reason: '未知 join_policy ⇒ 按申请制文案与流程（GroupApplyDialog.tsx:15）');
      expect(route, isNull, reason: '守卫拦截：不跳转');
    });

    testWidgets('已加入（isGroupJoined=true）⇒ 直接走分流跳转、不弹窗',
        (WidgetTester tester) async {
      String? route;
      await tester.pumpWidget(host(AylaShareBubble(
        msg: shareMsg('g1'),
        isGroupJoined: (String _) => true,
        onNavigate: (String r) => route = r,
      )));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('爱莉的粉丝群'));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(AylaGroupApplyDialog), findsNothing);
      expect(route, isNotNull, reason: '已加入 ⇒ web 走 resolveShareTarget 正常跳转');
    });

    testWidgets('注入 onRequestJoin ⇒ 用注入的回调（不自作主张开弹窗）',
        (WidgetTester tester) async {
      String? requested;
      await tester.pumpWidget(host(AylaShareBubble(
        msg: shareMsg('g1'),
        isGroupJoined: (String _) => false,
        onRequestJoin: (AylaSharePayload p) => requested = p.targetId,
      )));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('爱莉的粉丝群'));
      await tester.pump(const Duration(milliseconds: 60));

      expect(requested, 'g1');
      expect(find.byType(AylaGroupApplyDialog), findsNothing,
          reason: '注入优先 ⇒ 弹窗宿主归调用方');
    });

    testWidgets('既未注入 isGroupJoined、也没有 ProviderScope ⇒ 不做守卫（不凭空弹窗）',
        (WidgetTester tester) async {
      String? route;
      await tester.pumpWidget(host(AylaShareBubble(
        msg: shareMsg('g1'),
        onNavigate: (String r) => route = r,
      )));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('爱莉的粉丝群'));
      await tester.pump(const Duration(milliseconds: 60));

      expect(find.byType(AylaGroupApplyDialog), findsNothing);
      expect(route, isNotNull, reason: '无成员关系来源 ⇒ 与修前一致：正常跳转');
    });

    testWidgets('有 ProviderScope 且会话列表里没有该群 ⇒ 自查出「未加入」并弹窗',
        (WidgetTester tester) async {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      // 会话列表里只有别的群 ⇒ g1 未加入。
      container.read(chatStateProvider).setConversations(<AylaConversationSummary>[
        const AylaConversationSummary(
          id: 'g-other',
          type: AylaConversationType.group,
          title: '别的群',
        ),
      ]);
      String? route;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: host(AylaShareBubble(
            msg: shareMsg('g1'),
            onNavigate: (String r) => route = r,
          )),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('爱莉的粉丝群'));
      for (int i = 0; i < 6; i += 1) {
        await tester.pump(const Duration(milliseconds: 60));
      }

      expect(find.byType(AylaGroupApplyDialog), findsOneWidget,
          reason: 'web 的判据就是 conversations.some(...)，缺省（未注入）也必须生效');
      expect(route, isNull);
    });
  });
}
