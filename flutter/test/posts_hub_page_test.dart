/// 帖子流页面定向测试（假 adapter 驱动 REST；不连真实后端）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/net/dio_client.dart';
import '../lib/pages/posts/posts_hub_page.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/masonry_columns.dart';
import '../lib/widgets/post_card.dart';

class _Store implements AuthTokenStore {
  @override
  String? get accessToken => 't';
  @override
  String? get refreshToken => null;
  @override
  void setTokens(String access, String? refresh) {}
  @override
  void clear() {}
}

class _PostsAdapter implements HttpClientAdapter {
  _PostsAdapter(this.responder);

  final Map<String, dynamic> Function(RequestOptions options) responder;
  final List<String> requests = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // 记录完整 URI（含 query），断言用 `limit=20` / `cursor=c2` 这类稳定片段
    requests.add('${options.method} ${options.uri}');
    return ResponseBody.fromString(
      jsonEncode(responder(options)),
      200,
      headers: const <String, List<String>>{
        'content-type': <String>['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> post(int id, {String body = '正文', int views = 3}) => <String, dynamic>{
      'id': id,
      'title': '标题 $id',
      'body': body,
      'author': <String, dynamic>{'id': 'u1', 'nickname': '星野遥'},
      'author_id': 'u1',
      'visibility': 'public',
      'images': const <Object?>[],
      'comment_count': 0,
      'view_count': views,
      'is_viewed': false,
      'created_at': '2026-09-20T12:00:00Z',
    };

void main() {
  late _PostsAdapter adapter;

  setUpAll(() {
    DioClient.instance.init(tokenStore: _Store(), onSessionExpired: () {});
  });

  setUp(() {
    aylaClearPostTabMemory();
    aylaClearMasonryMemory();
  });

  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(const AylaPostsHubPage(accountKey: 'test')));
    await tester.pumpAndSettle();
  }

  testWidgets('首屏成功：渲染卡片 + 统计 + 加载更多', (WidgetTester tester) async {
    adapter = _PostsAdapter((RequestOptions options) => <String, dynamic>{
          'results': <Object?>[post(1), post(2)],
          'next_cursor': 'c2',
          'has_more': true,
          'total': 5,
        });
    DioClient.instance.dio.httpClientAdapter = adapter;
    await pumpPage(tester);
    expect(find.byType(AylaPostCard), findsNWidgets(2));
    expect(find.text('5 条帖子'), findsOneWidget);
    expect(find.text('加载更多'), findsOneWidget);
    expect(
      adapter.requests.single.contains('limit=20'),
      isTrue,
      reason: '默认每页 20 条（web limit: 20）',
    );
  });

  testWidgets('空流：还没有帖子', (WidgetTester tester) async {
    adapter = _PostsAdapter((RequestOptions options) => <String, dynamic>{
          'results': const <Object?>[],
          'next_cursor': null,
          'has_more': false,
          'total': 0,
        });
    DioClient.instance.dio.httpClientAdapter = adapter;
    await pumpPage(tester);
    expect(find.text('还没有帖子'), findsOneWidget);
    expect(find.text('点右下角 + 发布第一条帖子'), findsOneWidget);
  });

  testWidgets('加载更多：第二次请求带 cursor，卡片累加', (WidgetTester tester) async {
    adapter = _PostsAdapter((RequestOptions options) {
      final bool second = options.queryParameters['cursor'] == 'c2';
      return <String, dynamic>{
        'results': <Object?>[second ? post(3) : post(1)],
        'next_cursor': second ? null : 'c2',
        'has_more': !second,
        'total': 2,
      };
    });
    DioClient.instance.dio.httpClientAdapter = adapter;
    await pumpPage(tester);
    expect(find.byType(AylaPostCard), findsOneWidget);
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(find.byType(AylaPostCard), findsNWidgets(2));
    expect(adapter.requests.length, 2);
    expect(adapter.requests[1].contains('cursor=c2'), isTrue);
  });
}
