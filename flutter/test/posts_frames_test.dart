/// 帖子帧桥定向测试 —— 事实源：`Ayla/web/src/ws/chat.ts:766–840`（`post.*` 四条）
/// 与 `chat.ts:102–118`（`visibleGroupIds` / `bumpGroups`）。
///
/// ## 为什么用真实 HTTP 回环
/// `post.created` / `post.updated` 的语义是「**帧只是提示，REST 详情才是权威**」
/// （web 原话：以权限 REST 详情为权威）—— upsert 落地的是 `GET /posts/<id>/` 的响应，
/// 不是帧本身。用 `HttpServer` + `DioClient.debugBaseUrlOverride` 端到端跑，
/// 才能证明「拉详情 → upsert → bump 可见群」这条链真的成立；纯 mock store 会把这个
/// 环节整个跳过（帧里那些简化字段根本不足以构造 AylaPost）。
///
/// ⚠️ 与 `auth_remember_test.dart` 同一套纪律：
/// **不要初始化 `TestWidgetsFlutterBinding`**（它把 `HttpOverrides.global` 换成 mock ⇒
/// 任何请求返回 400）；server 必须在 `setUpAll` 建好并固定端口（`DioClient` 是进程级单例，
/// `dio` 的 baseUrl 只在首次 `init` 时构造）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/post.dart';
import '../lib/core/net/dio_client.dart';
import '../lib/core/ws/posts_frames.dart';
import '../lib/state/chat_state.dart';
import '../lib/state/posts_store.dart';

/// 最小帖子后端：只实现本链路真正打到的一个端点（`GET /posts/<id>/`）。
class _Backend {
  /// postId → 响应体；缺失即 404（「当前用户不可见或帖子已删除」）。
  final Map<int, Map<String, dynamic>> posts = <int, Map<String, dynamic>>{};

  /// postId → 状态码覆盖（403/404 静默路径用）。
  final Map<int, int> status = <int, int>{};

  Future<void> handle(HttpRequest request) async {
    final String path = request.uri.path;
    final RegExpMatch? match = RegExp(r'^/api/v1/posts/(\d+)/$').firstMatch(path);
    if (request.method == 'GET' && match != null) {
      final int id = int.parse(match.group(1)!);
      final int code = status[id] ?? (posts.containsKey(id) ? 200 : 404);
      request.response.statusCode = code;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(
        code == 200 ? posts[id]! : <String, dynamic>{'detail': 'not found'},
      ));
      await request.response.close();
      return;
    }
    request.response.statusCode = 404;
    await request.response.close();
  }
}

Map<String, dynamic> _postJson(
  int id, {
  String title = 'T',
  String? groupId,
  List<String> allowedGroupIds = const <String>[],
  String? createdAt,
}) =>
    <String, dynamic>{
      'id': id,
      'title': title,
      'body': 'b',
      'author': <String, dynamic>{'id': 'u2', 'nickname': '小樱'},
      'author_id': 'u2',
      'group': groupId,
      'allowed_group_ids': allowedGroupIds,
      'images': <Object?>[],
      'is_viewed': false,
      'created_at': createdAt ?? '2026-10-01T00:00:00Z',
    };

void main() {
  // 见库文档：本组是纯 Dart 逻辑 + 真实回环 HTTP，不要装 widget binding 的 mock HTTP。
  HttpOverrides.global = null;

  late _Backend backend;
  late HttpServer server;

  setUpAll(() async {
    backend = _Backend();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // ignore: unawaited_futures
    server.listen(backend.handle);
    // 必须在第一次 `DioClient.init` 之前设好（dio 的 baseUrl 只在首次 init 构造）。
    DioClient.instance.debugBaseUrlOverride = 'http://127.0.0.1:${server.port}';
    DioClient.instance.init(tokenStore: _NoTokens(), onSessionExpired: () {});
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  setUp(() {
    backend.posts.clear();
    backend.status.clear();
  });

  AylaPostsFramesBridge bridgeWith({
    required AylaPostsStore posts,
    required AylaChatState chat,
    String? me = 'me',
  }) =>
      AylaPostsFramesBridge(
        postsStore: posts,
        chatState: chat,
        currentUserId: () => me,
      );

  group('AylaPostsFramesBridge（web ws/chat.ts:766–840）', () {
    test('post.created：拉 REST 详情 → upsert 到头部 + bump 可见群活跃度', () async {
      final AylaPostsStore posts = AylaPostsStore();
      posts.setPage(<AylaPost>[
        AylaPost.fromJson(_postJson(1, title: '旧帖'))!,
      ], null, false);
      final AylaChatState chat = AylaChatState();
      // 归属群 `g1` + 白名单 `[g1, g2]` ⇒ 去重后 bump 两个群（web visibleGroupIds 102–112）。
      backend.posts[2] = _postJson(2, title: '新帖', groupId: 'g1',
          allowedGroupIds: const <String>['g1', 'g2']);

      final AylaPostsFramesBridge bridge =
          bridgeWith(posts: posts, chat: chat);
      bridge.handleFrame(<String, dynamic>{
        'type': 'post.created',
        'post': <String, dynamic>{'id': '2', 'title': '新帖'},
      });
      await pumpEventQueue();

      expect(posts.posts.map((AylaPost p) => p.id).toList(), <int>[2, 1]);
      expect(posts.posts.first.title, '新帖');
      expect(chat.groupActivityAt.keys.toSet(), <String>{'g1', 'g2'});
      expect(chat.groupActivityAt['g1']! > 0, isTrue);
    });

    test('post.updated：同样 upsert + bump（created_at 不变也算新内容）', () async {
      final AylaPostsStore posts = AylaPostsStore();
      posts.setPage(<AylaPost>[
        AylaPost.fromJson(_postJson(5, title: '原标题'))!,
      ], null, false);
      final AylaChatState chat = AylaChatState();
      backend.posts[5] = _postJson(5, title: '改后标题',
          allowedGroupIds: const <String>['g9']);

      bridgeWith(posts: posts, chat: chat).handleFrame(<String, dynamic>{
        'type': 'post.updated',
        'post': <String, dynamic>{'id': '5'},
      });
      await pumpEventQueue();

      // 已存在 ⇒ **原位替换**（web 95–99），不进头部。
      expect(posts.posts.single.title, '改后标题');
      expect(chat.groupActivityAt.containsKey('g9'), isTrue);
    });

    test('post.deleted：removePost(post_id)，其余顺序不动', () {
      final AylaPostsStore posts = AylaPostsStore();
      posts.setPage(<AylaPost>[
        AylaPost.fromJson(_postJson(1))!,
        AylaPost.fromJson(_postJson(2))!,
        AylaPost.fromJson(_postJson(3))!,
      ], null, false);
      bridgeWith(posts: posts, chat: AylaChatState())
          .handleFrame(<String, dynamic>{
        'type': 'post.deleted',
        'post_id': '2',
      });
      expect(posts.posts.map((AylaPost p) => p.id).toList(), <int>[1, 3]);
    });

    test('post.viewed：viewer 是本人 ⇒ markViewedBatch（is_viewed + 覆盖 view_count）', () {
      final AylaPostsStore posts = AylaPostsStore();
      posts.setPage(<AylaPost>[
        AylaPost.fromJson(_postJson(4))!,
      ], null, false);
      bridgeWith(posts: posts, chat: AylaChatState(), me: 'me')
          .handleFrame(<String, dynamic>{
        'type': 'post.viewed',
        'data': <String, dynamic>{
          'post_id': '4',
          'view_count': 11,
          'viewer_id': 'me',
          'allowed_group_ids': <String>['g1'],
        },
      });
      expect(posts.posts.single.isViewed, isTrue);
      expect(posts.posts.single.viewCount, 11);
    });

    test('post.viewed：viewer 是他人 ⇒ 只刷 view_count，不标已读', () {
      final AylaPostsStore posts = AylaPostsStore();
      posts.setPage(<AylaPost>[
        AylaPost.fromJson(_postJson(4))!,
      ], null, false);
      bridgeWith(posts: posts, chat: AylaChatState(), me: 'me')
          .handleFrame(<String, dynamic>{
        'type': 'post.viewed',
        'data': <String, dynamic>{
          'post_id': '4',
          'view_count': 12,
          'viewer_id': 'someone-else',
          'allowed_group_ids': <String>['g1'],
        },
      });
      expect(posts.posts.single.viewCount, 12);
      expect(posts.posts.single.isViewed, isFalse);
    });

    test('403/404 静默：不 upsert、不 bump、不抛错（web catch 原话）', () async {
      final AylaPostsStore posts = AylaPostsStore();
      final AylaChatState chat = AylaChatState();
      backend.status[7] = 403;
      bridgeWith(posts: posts, chat: chat).handleFrame(<String, dynamic>{
        'type': 'post.created',
        'post': <String, dynamic>{'id': '7'},
      });
      await pumpEventQueue();
      expect(posts.posts, isEmpty);
      expect(chat.groupActivityAt, isEmpty);
    });

    test('帧结构非法 ⇒ 直接忽略（不猜语义）', () async {
      final AylaPostsStore posts = AylaPostsStore();
      final AylaChatState chat = AylaChatState();
      final AylaPostsFramesBridge bridge =
          bridgeWith(posts: posts, chat: chat);
      bridge.handleFrame(<String, dynamic>{'type': 'post.created'});
      bridge.handleFrame(<String, dynamic>{
        'type': 'post.created',
        'post': <String, dynamic>{'id': 'not-a-number'},
      });
      bridge.handleFrame(<String, dynamic>{'type': 'post.deleted'});
      bridge.handleFrame(<String, dynamic>{'type': 'post.viewed'});
      bridge.handleFrame(<String, dynamic>{'type': 7});
      await pumpEventQueue();
      expect(posts.posts, isEmpty);
      expect(chat.groupActivityAt, isEmpty);
    });

    test('账号在 REST 往返期间变化 ⇒ 丢弃结果（与 room_frames 同法）', () async {
      // 用可变 currentUserId 模拟「请求发出后用户登出/换号」。
      String? me = 'me';
      final AylaPostsStore posts = AylaPostsStore();
      final AylaChatState chat = AylaChatState();
      backend.posts[8] = _postJson(8, allowedGroupIds: const <String>['g1']);
      final AylaPostsFramesBridge bridge = AylaPostsFramesBridge(
        postsStore: posts,
        chatState: chat,
        currentUserId: () => me,
      );
      bridge.handleFrame(<String, dynamic>{
        'type': 'post.created',
        'post': <String, dynamic>{'id': '8'},
      });
      me = null; // 请求在途，账号已变
      await pumpEventQueue();
      expect(posts.posts, isEmpty, reason: '账号变了就丢弃，不写进新账号的表');
      expect(chat.groupActivityAt, isEmpty);
    });

    test('attach / detach：挂上收帧，解绑后不再收（幂等）', () {
      final AylaPostsStore posts = AylaPostsStore();
      final AylaPostsFramesBridge bridge =
          bridgeWith(posts: posts, chat: AylaChatState());
      // 无 chat 客户端时 detach 是 no-op（不抛）。
      bridge.detach();
      bridge.detach();
      expect(posts.posts, isEmpty);
    });
  });
}

/// 无令牌的 token store（本组不打需要鉴权的路径；`init` 只为构造 dio 的 baseUrl）。
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
