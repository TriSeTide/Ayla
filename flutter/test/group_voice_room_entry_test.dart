/// **群内直达语音房能真的进房**端到端回归锁（用户实报「无法进入语音房」）。
///
/// ## 事实源（web `pages/group/GroupVoice.tsx`，逐条）
/// | 环节 | web | 行 |
/// |---|---|---|
/// | 本地未命中 ⇒ 拉详情（**已有且本群可见才跳过**） | 88–100 |
/// | 房内命中 = 本地列表里 `allowed_group_ids` 含本群 | 121–129 |
/// | 路由给了频道但没就绪 ⇒ 骨架 +「正在加载语音房…」 | 201–203 |
///
/// ## 为什么走「真实页面 + 假传输层」而不是纯函数
/// 缺陷在 **接线**（目录取页 → 域 store 的字段搬运）而不在页面逻辑：
/// 页面判据本身没错，是它读到的 `allowedGroupIds` 恒为空 ⇒ `_roomChannel()` 恒 null
/// ⇒ 一路落到骨架。只有挂真实页面、喂真实后端形状的响应，才量得到「进得去」这件事。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/net/dio_client.dart';
import '../lib/pages/group_voice_page.dart';
import '../lib/state/auth_state.dart' show authNotifierProvider;
import '../lib/state/room_providers.dart'
    show aylaStartRoomFrames, aylaStopDirectoryTracking, voiceStateProvider;
import '../lib/state/directory_store.dart' show aylaDirectoryStore;
import '../lib/theme/app_theme.dart' show buildAylaTheme;
import '../lib/theme/preview_theme.dart' show previewScope;
import '../lib/widgets/voice/voice_room_body.dart' show AylaVoiceRoomBody;

/// 记录请求并按路径回预设响应的传输层（`media_actions_test` 同款）。
///
/// ⚠️ **不要**用 `HttpServer`：`TestWidgetsFlutterBinding` 会把 `HttpOverrides.global`
/// 换成 mock ⇒ 真实回环请求一律返回 400。
/// ⚠️ `options.path` 是**相对 baseUrl 的路径**（baseUrl 已含 `/api/v1`）。
class _ApiAdapter implements HttpClientAdapter {
  final List<String> requests = <String>[];

  /// 'METHOD /path' → (状态码, JSON 文本)。未命中 ⇒ 404。
  final Map<String, (int, String)> routes = <String, (int, String)>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final String key = '${options.method} ${options.path}';
    requests.add(key);
    if (requestStream != null) await requestStream.drain<void>();
    final (int, String)? hit = routes[key];
    if (hit == null) {
      return ResponseBody.fromString('{"detail":"not found"}', 404,
          headers: _jsonHeaders);
    }
    return ResponseBody.fromString(hit.$2, hit.$1, headers: _jsonHeaders);
  }

  @override
  void close({bool force = false}) {}
}

class _NoTokens implements AuthTokenStore {
  @override
  String? get accessToken => null;
  @override
  String? get refreshToken => null;
  @override
  void clear() {}
  @override
  void setTokens(String access, String? refresh) {}
}

const Map<String, List<String>> _jsonHeaders = <String, List<String>>{
  'content-type': <String>['application/json'],
};

/// 后端 `VoiceChannelSerializer` 的详情形状（`voice/views.py:191–200`）。
Map<String, dynamic> _channelJson(
  String id,
  String name,
  List<String> groups,
) =>
    <String, dynamic>{
      'id': id,
      'name': name,
      'room_name': 'room_$id',
      'owner_id': 'u1',
      'owner_nickname': '房主',
      'member_count': 2,
      'visibility': 'group',
      'group': 'g1',
      'group_name': '群一',
      'allowed_group_ids': groups,
      'allowed_group_names': <String>['群一'],
      'mine': false,
      'created_at': '2026-10-01T00:00:00Z',
      'last_occupied_at': '2026-10-02T00:00:00Z',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _ApiAdapter adapter;

  setUpAll(() {
    adapter = _ApiAdapter();
    DioClient.instance.init(tokenStore: _NoTokens(), onSessionExpired: () {});
    DioClient.instance.dio.httpClientAdapter = adapter;
  });

  setUp(() {
    adapter.routes.clear();
    adapter.requests.clear();
  });

  tearDown(() {
    aylaStopDirectoryTracking();
    aylaDirectoryStore.reset();
    aylaDirectoryStore.userId = null;
  });

  Future<void> pumpPage(
    WidgetTester tester,
    ProviderContainer container,
    Widget page,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAylaTheme(),
          home: Builder(
            builder: (BuildContext context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(size: const Size(1440, 900)),
              child: previewScope(
                Align(alignment: Alignment.topLeft, child: page),
              ),
            ),
          ),
        ),
      ),
    );
    for (int i = 0; i < 8; i += 1) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  group('群内直达语音房（GroupVoice.tsx:88–129）', () {
    testWidgets(
        '白名单含本群 ⇒ 渲染房内界面（**不是**「正在加载语音房…」骨架）',
        (WidgetTester tester) async {
      adapter.routes['GET /voice/channels/v1/'] =
          (200, jsonEncode(_channelJson('v1', '深夜电台', <String>['g1'])));

      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      aylaStartRoomFrames(container);
      aylaDirectoryStore.userId = 'u1';
      // 会话层 `isCurrent()` 要求有令牌（web 同判 auth store 的 accessToken）
      // ⇒ 无令牌时 join 会在第一道守卫静默返回，而本用例要测的是「真的进房」。
      container.read(authNotifierProvider.notifier).setTokens('access', 'r');

      await pumpPage(
        tester,
        container,
        const GroupVoicePage(groupId: 'g1', routeChannelId: 'v1'),
      );

      expect(
        find.text('正在加载语音房…'),
        findsNothing,
        reason: '★ 用户实报的「进不去」= 骨架常驻；白名单含本群时必须渲染房内界面',
      );
      expect(
        find.byType(AylaVoiceRoomBody),
        findsOneWidget,
        reason: '房内命中（tsx 121–129）⇒ 渲染 VoiceRoomBody',
      );
      expect(
        adapter.requests,
        contains('POST /voice/channels/v1/join/'),
        reason: 'tsx 130–138：路由命中即 join（joinMuted: true）',
      );
    });

    testWidgets('白名单**不含**本群 ⇒ 保持骨架（不伪造可见）',
        (WidgetTester tester) async {
      // 该房属于别的群：本群页面不得渲染房内界面（web tsx 94–96 的静默档）。
      adapter.routes['GET /voice/channels/v9/'] =
          (200, jsonEncode(_channelJson('v9', '别群房间', <String>['g2'])));

      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      aylaStartRoomFrames(container);
      aylaDirectoryStore.userId = 'u1';

      await pumpPage(
        tester,
        container,
        const GroupVoicePage(groupId: 'g1', routeChannelId: 'v9'),
      );

      expect(find.byType(AylaVoiceRoomBody), findsNothing);
      expect(find.text('正在加载语音房…'), findsOneWidget);
      // 关键：不得因为「拉到了」就把别群房间塞进域 store 当作本群可见。
      expect(
        container.read(voiceStateProvider).channelOf('v9'),
        isNull,
        reason: 'GroupVoice.tsx:94–96：不在本群可见范围不注入（界面保持加载态，静默）',
      );
    });
  });
}
