/// 群内帖子**未读红点热更新 + 页面级 WS 热更新**的回归锁 ——
/// 事实源：web `ws/chat.ts:766–840`（帧桥未读增减）、`stores/chat.ts:260–267`
/// （`adjustPostUnread`）、`pages/group/GroupPosts.tsx:188–231`（页面级 `onFrame`）
/// 与 `:251–265`（`displayPosts` 投影）。
///
/// ## 本轮修的四条缺口（2026-10-11）
/// 1. `adjustPostUnread` 不存在 ⇒ 群未读帖子数**只有 REST 首屏一次**，WS 期间完全不动
///    （新帖不 +1、浏览后不 −1）⇒ 红点不热更新；
/// 2. `post.created` / `post.viewed` 两个 30s 去重窗口缺失 ⇒ 后端重复广播会重复计数；
/// 3. 页面**没有**自己订阅 `chatWS.onFrame` ⇒ 新帖/删帖/跨端已读不进本页列表，
///    必须手动下拉刷新（web 是单条 REST 对账、零刷新）；
/// 4. 缺 `displayPosts` 投影 ⇒ 共享 store 里的已读态不会回灌本页未读标签。
///
/// ## 为什么用 dio 的 `httpClientAdapter`
/// 页面档需要推进 microtask 上的请求（同 `group_posts_report_fixes_test.dart` 的文件头）。
/// 帧桥档是纯逻辑（只有 `getPost` 一个 REST 往返），也可用同一 adapter。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/models/conversation.dart'
    show AylaConversationSummary, AylaConversationType;
import '../lib/core/models/post.dart' show AylaPost;
import '../lib/core/net/dio_client.dart';
import '../lib/core/ws/posts_frames.dart';
import '../lib/pages/group_posts_page.dart';
import '../lib/state/auth_state.dart' show AuthUser, authNotifierProvider;
import '../lib/state/chat_providers.dart' show chatWsProvider;
import '../lib/state/chat_state.dart';
import '../lib/state/posts_store.dart';
import '../lib/theme/app_theme.dart';
import '../lib/theme/glass.dart' show AylaGlassSurface;
import '../lib/theme/tokens.dart' show AylaSpacing;
import '../lib/widgets/group/group_posts_composer.dart'
    show AylaGroupPostsComposer;
import '../lib/widgets/base/reveal.dart' show AylaRevealScope;
import '../lib/widgets/posts/masonry_grid.dart'
    show AylaMasonryGrid, aylaClearMasonryMemory;
import '../lib/widgets/posts/post_card.dart' show AylaPostCard;

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

Map<String, dynamic> _postJson(
  int id, {
  String groupId = 'g1',
  List<String> allowedGroupIds = const <String>['g1'],
  String authorId = 'u1',
  bool isViewed = false,
  int viewCount = 3,
  String title = '帖子',
}) =>
    <String, dynamic>{
      'id': id,
      'title': title,
      'body': '正文 ' + id.toString(),
      'author': <String, dynamic>{'id': authorId, 'nickname': '小樱'},
      'author_id': authorId,
      'group': groupId,
      'allowed_group_ids': allowedGroupIds,
      'images': <Object?>[],
      'is_viewed': isViewed,
      'view_count': viewCount,
      'comment_count': 0,
      'is_author': false,
      'created_at': '2026-10-01T00:00:00Z',
    };

/// 登录用户（页面 post.viewed 分支的 `me` 判据；web tsx 221–223）。
AuthUser _me() => const AuthUser(
      id: 'u1',
      username: 'u1',
      nickname: 'u1',
      avatar: '',
      signature: '',
      status: 'online',
      online: true,
      displayStatus: '',
      dateJoined: '',
      isInVoice: false,
      voiceRoomId: null,
      isLive: false,
      liveRoomId: null,
      showContent: true,
      email: '',
    );

AylaConversationSummary _conv(
  String id,
  AylaConversationType type, {
  int? postUnread,
}) =>
    AylaConversationSummary(
      id: id,
      type: type,
      title: id,
      unreadCount: 0,
      postUnreadCount: postUnread,
    );

/// 最小帖子后端：`GET /posts/`（列表）、`GET /posts/<id>/`（单条对账）、
/// `POST /posts/views/`（浏览上报，幂等）。
class _PostsAdapter implements HttpClientAdapter {
  _PostsAdapter({this.listIds = const <int>[]});

  /// `GET /posts/` 返回的 id 序列。
  List<int> listIds;

  /// `GET /posts/<id>/` 的响应体；缺失 ⇒ 404（不可见/已删除，静默档）。
  Map<int, Map<String, dynamic>> posts = <int, Map<String, dynamic>>{};

  /// `GET /posts/<id>/` 命中次数（单条 REST 对账断言用）。
  int detailHits = 0;

  /// `GET /posts/` 命中次数（「不重拉首页」断言用）。
  int listHits = 0;

  static const Map<String, List<String>> _json = <String, List<String>>{
    Headers.contentTypeHeader: <String>[Headers.jsonContentType],
  };

  ResponseBody _ok(Object body) =>
      ResponseBody.fromString(jsonEncode(body), 200, headers: _json);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'POST' && options.path == '/posts/views/') {
      return _ok(<String, Object?>{'updated': <String, Object?>{}});
    }
    if (options.method == 'GET' && options.path == '/posts/') {
      listHits += 1;
      return _ok(<String, Object?>{
        'results': <Object?>[for (final int id in listIds) _postJson(id)],
        'next_cursor': null,
        'has_more': false,
        'total': listIds.length,
      });
    }
    final RegExpMatch? m =
        RegExp(r'^/posts/(\d+)/$').firstMatch(options.path);
    if (options.method == 'GET' && m != null) {
      detailHits += 1;
      final int id = int.parse(m.group(1)!);
      final Map<String, dynamic>? body = posts[id];
      if (body == null) {
        return ResponseBody.fromString(
          jsonEncode(<String, Object?>{'detail': 'not found'}),
          404,
          headers: _json,
        );
      }
      return _ok(body);
    }
    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{'detail': 'not found'}),
      404,
      headers: _json,
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _PostsAdapter adapter;

  setUpAll(() {
    DioClient.instance.init(tokenStore: _NoTokens(), onSessionExpired: () {});
  });

  setUp(() {
    aylaClearMasonryMemory();
    adapter = _PostsAdapter();
    DioClient.instance.dio.httpClientAdapter = adapter;
  });

  tearDown(() {
    aylaPostsStore.reset();
  });

  AylaPostsFramesBridge bridgeWith({
    required AylaPostsStore posts,
    required AylaChatState chat,
    String? me = 'me',
    int Function()? now,
  }) =>
      AylaPostsFramesBridge(
        postsStore: posts,
        chatState: chat,
        currentUserId: () => me,
        now: now,
      );

  // ============ ① 未读红点：增减两档（web chat.ts:779–788 / 826–835）============

  group('① 群未读帖子数（web stores/chat.ts:260–267 adjustPostUnread）', () {
    test('post.created 非作者 ⇒ 白名单每个群 +1', () async {
      final AylaChatState chat = AylaChatState();
      chat.setConversations(<AylaConversationSummary>[
        _conv('g1', AylaConversationType.group, postUnread: 2),
        _conv('g2', AylaConversationType.group, postUnread: 0),
      ]);
      adapter.posts[101] = _postJson(101,
          groupId: 'g1', allowedGroupIds: const <String>['g1', 'g2']);
      bridgeWith(posts: AylaPostsStore(), chat: chat)
          .handleFrame(<String, dynamic>{
        'type': 'post.created',
        'post': <String, dynamic>{'id': '101'},
      });
      await pumpEventQueue();
      expect(chat.byId('g1')!.postUnreadCount, 3);
      expect(chat.byId('g2')!.postUnreadCount, 1);
    });

    test('post.viewed 本人 ⇒ 已读 + 白名单每个群 −1', () {
      final AylaChatState chat = AylaChatState();
      chat.setConversations(<AylaConversationSummary>[
        _conv('g1', AylaConversationType.group, postUnread: 2),
        _conv('g2', AylaConversationType.group, postUnread: 5),
      ]);
      final AylaPostsStore posts = AylaPostsStore();
      posts.setPage(<AylaPost>[AylaPost.fromJson(_postJson(102))!], null, false);
      bridgeWith(posts: posts, chat: chat).handleFrame(<String, dynamic>{
        'type': 'post.viewed',
        'data': <String, dynamic>{
          'post_id': '102',
          'view_count': 8,
          'viewer_id': 'me',
          'allowed_group_ids': <String>['g1', 'g2'],
        },
      });
      expect(chat.byId('g1')!.postUnreadCount, 1);
      expect(chat.byId('g2')!.postUnreadCount, 4);
      expect(posts.posts.single.isViewed, isTrue);
    });

    test('作者本人发帖不计未读，但帖子照常 upsert', () async {
      final AylaChatState chat = AylaChatState();
      chat.setConversations(<AylaConversationSummary>[
        _conv('g1', AylaConversationType.group, postUnread: 0),
      ]);
      final AylaPostsStore posts = AylaPostsStore();
      adapter.posts[103] = _postJson(103, authorId: 'me');
      bridgeWith(posts: posts, chat: chat).handleFrame(<String, dynamic>{
        'type': 'post.created',
        'post': <String, dynamic>{'id': '103'},
      });
      await pumpEventQueue();
      expect(chat.byId('g1')!.postUnreadCount, 0,
          reason: '作者自己发的帖子天然已读');
      expect(posts.posts.single.id, 103);
    });

    test('post.updated 不动未读（编辑不算新帖）', () async {
      final AylaChatState chat = AylaChatState();
      chat.setConversations(<AylaConversationSummary>[
        _conv('g1', AylaConversationType.group, postUnread: 4),
      ]);
      adapter.posts[104] = _postJson(104);
      bridgeWith(posts: AylaPostsStore(), chat: chat)
          .handleFrame(<String, dynamic>{
        'type': 'post.updated',
        'post': <String, dynamic>{'id': '104'},
      });
      await pumpEventQueue();
      expect(chat.byId('g1')!.postUnreadCount, 4);
    });

    test('下限 0：无未读时收到已读事件不写成负数', () {
      final AylaChatState chat = AylaChatState();
      chat.setConversations(<AylaConversationSummary>[
        _conv('g1', AylaConversationType.group, postUnread: 0),
      ]);
      bridgeWith(posts: AylaPostsStore(), chat: chat)
          .handleFrame(<String, dynamic>{
        'type': 'post.viewed',
        'data': <String, dynamic>{
          'post_id': '105',
          'view_count': 1,
          'viewer_id': 'me',
          'allowed_group_ids': <String>['g1'],
        },
      });
      expect(chat.byId('g1')!.postUnreadCount, 0);
    });

    test('私聊会话不被 post.* 改写（type === group 守卫）', () async {
      final AylaChatState chat = AylaChatState();
      chat.setConversations(<AylaConversationSummary>[
        _conv('p1', AylaConversationType.private),
      ]);
      adapter.posts[106] = _postJson(106,
          groupId: 'p1', allowedGroupIds: const <String>['p1']);
      bridgeWith(posts: AylaPostsStore(), chat: chat)
          .handleFrame(<String, dynamic>{
        'type': 'post.created',
        'post': <String, dynamic>{'id': '106'},
      });
      await pumpEventQueue();
      expect(chat.byId('p1')!.postUnreadCount, isNull);
    });

    test('未加载的群不凭空造摘要（map 命中不到即 no-op）', () async {
      final AylaChatState chat = AylaChatState();
      chat.setConversations(<AylaConversationSummary>[
        _conv('g1', AylaConversationType.group, postUnread: 0),
      ]);
      adapter.posts[107] = _postJson(107,
          groupId: 'ghost', allowedGroupIds: const <String>['ghost']);
      bridgeWith(posts: AylaPostsStore(), chat: chat)
          .handleFrame(<String, dynamic>{
        'type': 'post.created',
        'post': <String, dynamic>{'id': '107'},
      });
      await pumpEventQueue();
      expect(chat.byId('ghost'), isNull, reason: '不伪造一条会话摘要');
      expect(chat.byId('g1')!.postUnreadCount, 0);
    });
  });

  // ============ ② 两个 30s 幂等窗口（web chat.ts:41–83）============

  group('② 幂等窗口（web markPostCreatedHandled / markPostViewedHandled）', () {
    test('同一 post.created 30s 内只计一次；窗口外重新计数', () async {
      int now = 1000;
      final AylaChatState chat = AylaChatState();
      chat.setConversations(<AylaConversationSummary>[
        _conv('g1', AylaConversationType.group, postUnread: 0),
      ]);
      adapter.posts[108] = _postJson(108);
      final AylaPostsFramesBridge bridge =
          bridgeWith(posts: AylaPostsStore(), chat: chat, now: () => now);
      Map<String, dynamic> frame() => <String, dynamic>{
            'type': 'post.created',
            'post': <String, dynamic>{'id': '108'},
          };
      bridge.handleFrame(frame());
      await pumpEventQueue();
      expect(chat.byId('g1')!.postUnreadCount, 1);

      now += 29900; // 窗口内
      bridge.handleFrame(frame());
      await pumpEventQueue();
      expect(chat.byId('g1')!.postUnreadCount, 1, reason: '30s 内只计一次');

      now += 30000; // 窗口外
      bridge.handleFrame(frame());
      await pumpEventQueue();
      expect(chat.byId('g1')!.postUnreadCount, 2);
    });

    test('同一 post.viewed 本人 30s 内红点只减一次（群组频道 + 本人频道各一次）', () {
      int now = 1000;
      final AylaChatState chat = AylaChatState();
      chat.setConversations(<AylaConversationSummary>[
        _conv('g1', AylaConversationType.group, postUnread: 5),
      ]);
      final AylaPostsStore posts = AylaPostsStore();
      posts.setPage(<AylaPost>[AylaPost.fromJson(_postJson(109))!], null, false);
      final AylaPostsFramesBridge bridge =
          bridgeWith(posts: posts, chat: chat, now: () => now);
      Map<String, dynamic> frame(int views) => <String, dynamic>{
            'type': 'post.viewed',
            'data': <String, dynamic>{
              'post_id': '109',
              'view_count': views,
              'viewer_id': 'me',
              'allowed_group_ids': <String>['g1'],
            },
          };
      bridge.handleFrame(frame(4));
      expect(chat.byId('g1')!.postUnreadCount, 4);

      now += 100; // 第二次广播（本人频道）
      bridge.handleFrame(frame(5));
      expect(chat.byId('g1')!.postUnreadCount, 4, reason: '红点递减按 postId 去重');
      expect(posts.posts.single.viewCount, 5,
          reason: 'view_count 不去重（幂等覆盖）');
    });

    test('同一帧里重复的群只减一次（web touched Set）', () {
      final AylaChatState chat = AylaChatState();
      chat.setConversations(<AylaConversationSummary>[
        _conv('g1', AylaConversationType.group, postUnread: 5),
      ]);
      bridgeWith(posts: AylaPostsStore(), chat: chat)
          .handleFrame(<String, dynamic>{
        'type': 'post.viewed',
        'data': <String, dynamic>{
          'post_id': '110',
          'view_count': 1,
          'viewer_id': 'me',
          'allowed_group_ids': <String>['g1', 'g1', '', 'g1'],
        },
      });
      expect(chat.byId('g1')!.postUnreadCount, 4);
    });

    test('去重表超 200 条时惰性清理旧条目（web chat.ts:54–59），后续事件仍正常计数',
        () async {
      int now = 1000000;
      final AylaChatState chat = AylaChatState();
      chat.setConversations(<AylaConversationSummary>[
        _conv('g1', AylaConversationType.group, postUnread: 0),
      ]);
      final AylaPostsStore posts = AylaPostsStore();
      final AylaPostsFramesBridge bridge =
          bridgeWith(posts: posts, chat: chat, now: () => now);
      for (int i = 0; i < 205; i += 1) {
        adapter.posts[2000 + i] = _postJson(2000 + i);
      }
      for (int i = 0; i < 205; i += 1) {
        now += 1000; // 每个间隔 1s；累计 205s > 2 × 30s 窗口
        bridge.handleFrame(<String, dynamic>{
          'type': 'post.created',
          'post': <String, dynamic>{'id': (2000 + i).toString()},
        });
      }
      await pumpEventQueue();
      expect(chat.byId('g1')!.postUnreadCount, 205,
          reason: '每个都是新帖，全部计数（清理不得影响去重正确性）');
      // 清理后再来一条新帖仍要计数
      now += 1000;
      adapter.posts[9999] = _postJson(9999);
      bridge.handleFrame(<String, dynamic>{
        'type': 'post.created',
        'post': <String, dynamic>{'id': '9999'},
      });
      await pumpEventQueue();
      expect(chat.byId('g1')!.postUnreadCount, 206);
    });
  });

  // ============ ③ 页面级 WS 热更新（web GroupPosts.tsx:188–231）============

  group('③ 页面级 WS 热更新（web GroupPosts.tsx:188–231）', () {
    Future<ProviderContainer> pump(
      WidgetTester tester, {
      required _PostsAdapter custom,
      Size size = const Size(560, 700),
    }) async {
      adapter = custom;
      DioClient.instance.dio.httpClientAdapter = custom;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      // 页面 post.viewed 分支读 authNotifierProvider（web tsx 221–222）⇒ 必须有登录用户。
      container.read(authNotifierProvider.notifier).setUser(_me());
      final GoRouter router = GoRouter(
        initialLocation: '/group/g1/posts',
        routes: <RouteBase>[
          GoRoute(
            path: '/group/:id/posts',
            pageBuilder: (BuildContext c, GoRouterState s) => NoTransitionPage<void>(
              child: GroupPostsPage(groupId: s.pathParameters['id'] ?? ''),
            ),
          ),
          GoRoute(
            path: '/group/:id/posts/:postId',
            pageBuilder: (BuildContext c, GoRouterState s) => NoTransitionPage<void>(
              child: GroupPostsPage(
                groupId: s.pathParameters['id'] ?? '',
                postId: s.pathParameters['postId'],
              ),
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            theme: buildAylaTheme(),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: Scaffold(backgroundColor: Colors.transparent, body: child),
            ),
          ),
        ),
      );
      for (int i = 0;
          i < 400 && find.byType(AylaPostCard).evaluate().isEmpty;
          i += 1) {
        await tester.pump(
          i % 5 == 0 ? const Duration(milliseconds: 1) : Duration.zero,
        );
      }
      await tester.pump();
      await tester.pump();
      return container;
    }

    Future<void> drain(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    }

    /// 页面自己挂在 chat WS 上的监听（= web tsx 188 的 `chatWS.onFrame`）。
    void feed(ProviderContainer container, Map<String, dynamic> frame) {
      container.read(chatWsProvider).debugHandleFrame(frame);
    }

    testWidgets('post.created ⇒ 单条 REST 对账后插到列表头，不重拉首页', (WidgetTester tester) async {
      final _PostsAdapter a = _PostsAdapter(listIds: <int>[1, 2, 3]);
      a.posts[99] = _postJson(99, title: '新帖99');
      final ProviderContainer container = await pump(tester, custom: a);
      expect(find.byType(AylaPostCard), findsNWidgets(3));
      final int listBefore = a.listHits;

      feed(container, <String, dynamic>{
        'type': 'post.created',
        'post': <String, dynamic>{'id': '99', 'title': '新帖99'},
      });
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(AylaPostCard), findsNWidgets(4));
      expect(find.text('新帖99'), findsOneWidget);
      expect(a.detailHits, 1,
          reason: '帧只带简化字段 ⇒ 必须走单条权限 REST 对账');
      expect(a.listHits, listBefore, reason: '不重拉首页（游标/滚动位置不丢）');
      await drain(tester);
    });

    testWidgets('post.deleted ⇒ 立即从列表移除（零手动刷新）', (WidgetTester tester) async {
      final _PostsAdapter a = _PostsAdapter(listIds: <int>[1, 2, 3]);
      final ProviderContainer container = await pump(tester, custom: a);
      expect(find.byType(AylaPostCard), findsNWidgets(3));
      feed(container, <String, dynamic>{'type': 'post.deleted', 'post_id': '2'});
      await tester.pump();
      expect(find.byType(AylaPostCard), findsNWidgets(2));
      expect(find.text('帖子 2'), findsNothing);
      await drain(tester);
    });

    testWidgets('post.viewed（本人）⇒ 本页列表就地标已读，标签计数实时减少', (WidgetTester tester) async {
      final _PostsAdapter a = _PostsAdapter(listIds: <int>[1, 2, 3]);
      final ProviderContainer container = await pump(tester, custom: a);
      final int before = _unreadTotal(tester);
      expect(before, greaterThan(0), reason: '前提：确有未读条目');

      feed(container, <String, dynamic>{
        'type': 'post.viewed',
        'data': <String, dynamic>{
          'post_id': '1',
          'view_count': 42,
          'viewer_id': 'u1',
          'allowed_group_ids': <String>['g1'],
        },
      });
      await tester.pump();
      await tester.pump();
      expect(
        _unreadTotal(tester),
        before - 1,
        reason: 'web tsx 218–230：本人已读帧 ⇒ 本页 groupPosts 就地标已读，标签减 1',
      );
      await drain(tester);
    });

    testWidgets('post.viewed（他人）⇒ 不动本页已读态', (WidgetTester tester) async {
      final _PostsAdapter a = _PostsAdapter(listIds: <int>[1, 2, 3]);
      final ProviderContainer container = await pump(tester, custom: a);
      final int before = _unreadTagCount(tester);
      feed(container, <String, dynamic>{
        'type': 'post.viewed',
        'data': <String, dynamic>{
          'post_id': '1',
          'view_count': 42,
          'viewer_id': 'someone-else',
          'allowed_group_ids': <String>['g1'],
        },
      });
      await tester.pump();
      expect(_unreadTagCount(tester), before);
      await drain(tester);
    });

    testWidgets('已删帖的迟到 created 响应不复活它（deletedIds 守卫，web tsx 204）',
        (WidgetTester tester) async {
      final _PostsAdapter a = _PostsAdapter(listIds: <int>[1, 2, 3]);
      a.posts[2] = _postJson(2, title: '复活测试');
      final ProviderContainer container = await pump(tester, custom: a);
      feed(container, <String, dynamic>{'type': 'post.deleted', 'post_id': '2'});
      await tester.pump();
      expect(find.text('复活测试'), findsNothing);

      feed(container, <String, dynamic>{
        'type': 'post.created',
        'post': <String, dynamic>{'id': '2'},
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('复活测试'), findsNothing,
          reason: '已删帖不得被迟到响应复活');
      await drain(tester);
    });

    testWidgets('白名单不含本群的帖子不进本页列表（web tsx 205–209）', (WidgetTester tester) async {
      final _PostsAdapter a = _PostsAdapter(listIds: <int>[1, 2, 3]);
      a.posts[98] = _postJson(98,
          groupId: 'other', allowedGroupIds: const <String>['other'], title: '别群帖子');
      final ProviderContainer container = await pump(tester, custom: a);
      feed(container, <String, dynamic>{
        'type': 'post.created',
        'post': <String, dynamic>{'id': '98'},
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('别群帖子'), findsNothing);
      expect(find.byType(AylaPostCard), findsNWidgets(3));
      await drain(tester);
    });

    testWidgets('页面 dispose 后帧不再落地、不抛错（owner.active 守卫，web tsx 189）',
        (WidgetTester tester) async {
      final _PostsAdapter a = _PostsAdapter(listIds: <int>[1, 2, 3]);
      final ProviderContainer container = await pump(tester, custom: a);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      feed(container, <String, dynamic>{'type': 'post.deleted', 'post_id': '1'});
      await tester.pump();
      expect(tester.takeException(), isNull);
      await drain(tester);
    });
  });

  // ============ ④ displayPosts 投影（web tsx 251–265）============

  group('④ displayPosts 投影（web GroupPosts.tsx:251–265）', () {
    Future<ProviderContainer> pump(
      WidgetTester tester, {
      required _PostsAdapter custom,
    }) async {
      adapter = custom;
      DioClient.instance.dio.httpClientAdapter = custom;
      const Size size = Size(560, 700);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(authNotifierProvider.notifier).setUser(_me());
      final GoRouter router = GoRouter(
        initialLocation: '/group/g1/posts',
        routes: <RouteBase>[
          GoRoute(
            path: '/group/:id/posts',
            pageBuilder: (BuildContext c, GoRouterState s) => NoTransitionPage<void>(
              child: GroupPostsPage(groupId: s.pathParameters['id'] ?? ''),
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            theme: buildAylaTheme(),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: Scaffold(backgroundColor: Colors.transparent, body: child),
            ),
          ),
        ),
      );
      for (int i = 0;
          i < 400 && find.byType(AylaPostCard).evaluate().isEmpty;
          i += 1) {
        await tester.pump(
          i % 5 == 0 ? const Duration(milliseconds: 1) : Duration.zero,
        );
      }
      await tester.pump();
      await tester.pump();
      return container;
    }

    Future<void> drain(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('共享 store 的已读态回灌本页未读标签', (WidgetTester tester) async {
      // 共享 store 的落地口径 = web `appInit.ts:38–42` 预取 `listPosts({scope:"feed"})`
      // ⇒ 先把同样三帖灌进去（`usePostsStore` 里就是这三条）。
      aylaPostsStore.setPage(<AylaPost>[
        AylaPost.fromJson(_postJson(1))!,
        AylaPost.fromJson(_postJson(2))!,
        AylaPost.fromJson(_postJson(3))!,
      ], null, false);

      await pump(tester, custom: _PostsAdapter(listIds: <int>[1, 2, 3]));
      final int before = _unreadTotal(tester);
      expect(before, 3, reason: '前提：三帖都未读');

      // 模拟「本账号在别的页面浏览过这三帖」（web：usePostsStore.markViewedBatch）
      aylaPostsStore.markViewedBatch(<String, int>{'1': 10, '2': 11, '3': 12});
      await tester.pump();
      await tester.pump();
      expect(
        _unreadTotal(tester),
        0,
        reason: 'displayPosts 必须取 store 的单调已读（web tsx 251–265）⇒ 标签消失',
      );
      expect(_unreadTagCount(tester), 0);
      await drain(tester);
    });

    testWidgets('store 里不在本页分页里的帖子不扩进列表', (WidgetTester tester) async {
      await pump(tester, custom: _PostsAdapter(listIds: <int>[1, 2, 3]));
      expect(find.byType(AylaPostCard), findsNWidgets(3));
      aylaPostsStore.upsertPost(
        AylaPost.fromJson(_postJson(777, title: '缓存外帖子'))!,
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('缓存外帖子'), findsNothing);
      expect(find.byType(AylaPostCard), findsNWidgets(3));
      await drain(tester);
    });
  });

  registerJumpTagGeometryTests();
  registerRevealAfterRefreshTests();
}

/// 页面上可见的未读标签条数（上 + 下）。
int _unreadTagCount(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .where((Text t) => (t.data ?? '').contains('未读帖子'))
    .length;

/// 两条标签里的未读**总数**（文案形如「↑ 2 条未读帖子」）。
///
/// ⚠️ 不能只数标签条数：两条标签是「上方 > 0」「下方 > 0」的独立开关，
/// 少一条未读时条数可以不变 —— 只有数字会变。
int _unreadTotal(WidgetTester tester) {
  int total = 0;
  for (final Text t in tester.widgetList<Text>(find.byType(Text))) {
    final String s = t.data ?? '';
    if (!s.contains('未读帖子')) continue;
    final RegExpMatch? m = RegExp(r'(\d+)').firstMatch(s);
    if (m != null) total += int.parse(m.group(1)!);
  }
  return total;
}

/// ⑤ 跳转标签定位组（2026-10-11 用户实报「上方位置有误」的回归锁）。
///
/// 由 `main()` 调用注册 —— 需要 `late _PostsAdapter adapter` 之外的独立装配。
void registerJumpTagGeometryTests() {
  group('⑤ 跳转标签定位（web posts.css:942–948 · 911–929 · 1084–1086）', () {
    Future<void> setUpPage(WidgetTester tester, Size size) async {
      DioClient.instance.dio.httpClientAdapter =
          _PostsAdapter(listIds: <int>[1, 2, 3]);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      final GoRouter router = GoRouter(
        initialLocation: '/group/g1/posts',
        routes: <RouteBase>[
          GoRoute(
            path: '/group/:id/posts',
            pageBuilder: (BuildContext c, GoRouterState s) => NoTransitionPage<void>(
              child: GroupPostsPage(groupId: s.pathParameters['id'] ?? ''),
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            theme: buildAylaTheme(),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: Scaffold(backgroundColor: Colors.transparent, body: child),
            ),
          ),
        ),
      );
      for (int i = 0;
          i < 400 && find.byType(AylaPostCard).evaluate().isEmpty;
          i += 1) {
        await tester.pump(
          i % 5 == 0 ? const Duration(milliseconds: 1) : Duration.zero,
        );
      }
      await tester.pump();
      await tester.pump();
    }

    Future<void> drain(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    }

    /// 某条标签胶囊（`.message-jump-mention`）的矩形。
    Rect pillRect(WidgetTester tester, String prefix) {
      final Finder text = find.byWidgetPredicate(
        (Widget w) => w is Text && (w.data ?? '').startsWith(prefix),
      );
      expect(text, findsOneWidget);
      final Element e = text.evaluate().first;
      final Finder surface = find.ancestor(
        of: find.byElementPredicate((Element x) => x == e),
        matching: find.byType(AylaGlassSurface),
      );
      expect(surface, findsOneWidget);
      return tester.getRect(surface.first);
    }

    for (final MapEntry<String, Size> c in <String, Size>{
      '窄屏 375': const Size(375, 700),
      '宽屏 820': const Size(820, 700),
    }.entries) {
      testWidgets('${c.key}：上标签顶 = 容器顶 + sp3(12)，下标签底 = 容器底 − (sp3 + 64)',
          (WidgetTester tester) async {
        await setUpPage(tester, c.value);
        // `.group-posts`（position: relative）是标签的包含块 —— Flutter 侧对应
        // `AylaGroupPostsComposer`（= 整个群内帖子容器）。
        final Rect container =
            tester.getRect(find.byType(AylaGroupPostsComposer));

        // 上标签：`.message-jump-tags-above { top: var(--sp-3) }`（app.css:923–925）
        expect(
          pillRect(tester, '↑ ').top - container.top,
          AylaSpacing.sp3,
          reason: 'web 实测（DPR 1.25 浏览器）：容器顶 + 12.0',
        );

        // 下标签：`.group-posts .message-jump-tags-below { bottom: calc(sp3 + 64px) }`
        // （posts.css:1084–1086；64 = compact 输入栏高度，抬到输入栏之上）
        expect(
          container.bottom - pillRect(tester, '↓ ').bottom,
          AylaSpacing.sp3 + 64,
          reason: 'web 实测（DPR 1.25 浏览器）：容器底 − 76.0（两档同值）',
        );
        await drain(tester);
      });
    }

    testWidgets('两条标签的包含块是**整个容器**（不是滚动口 / 输入栏槽）',
        (WidgetTester tester) async {
      // 回归锁（2026-10-11 用户实报「跳转键上方位置有误」的根因）：
      // 旧实现把标签放进 composer 的 child 槽（= 收起态的「列表」那一格），
      // 于是下方标签的容器底 = **列表口底** ⇒ 比 web 高出整个输入栏。
      await setUpPage(tester, const Size(820, 700));
      final Rect container =
          tester.getRect(find.byType(AylaGroupPostsComposer));
      final Rect down = pillRect(tester, '↓ ');
      // 列表口（滚动区）的底明显高于容器底 ⇒ 判据必须相对**容器底**成立。
      final Rect scroll = tester.getRect(find.byType(Scrollable).first);
      expect(scroll.bottom, lessThan(container.bottom - 10),
          reason: '前提：滚动口底与容器底之间确有输入栏高度（实测差 ≈ 60.8）');
      expect(down.bottom, greaterThan(scroll.bottom),
          reason: '下标签必须落在**输入栏之上、容器底 −76**，而不是贴列表口');
      await drain(tester);
    });
  });
}

/// ⑥ 组（入场抑制的 `revealAfterRefresh` 与项）—— 由 `main()` 调用注册。
///
/// 事实源：web `GroupPosts.tsx:379` 的
/// `suppressed = postId != null || ((restoring || skipRevealRestoreKey === scrollRestoreKey) && !revealAfterRefresh)`
/// 与三个写 `true`（tsx 148–153 取页成功 / tsx 212 帧插卡 / tsx 245 发帖）、
/// 两个写 `false`（tsx 363 进详情 / tsx 429 点卡进详情）。
void registerRevealAfterRefreshTests() {
  group('⑥ revealAfterRefresh 与项（web tsx 379）', () {
    Future<ProviderContainer> setUpPage(WidgetTester tester, _PostsAdapter a) async {
      DioClient.instance.dio.httpClientAdapter = a;
      const Size size = Size(560, 700);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(authNotifierProvider.notifier).setUser(_me());
      final GoRouter router = GoRouter(
        initialLocation: '/group/g1/posts',
        routes: <RouteBase>[
          GoRoute(
            path: '/group/:id/posts',
            pageBuilder: (BuildContext c, GoRouterState s) => NoTransitionPage<void>(
              child: GroupPostsPage(groupId: s.pathParameters['id'] ?? ''),
            ),
          ),
          GoRoute(
            path: '/group/:id/posts/:postId',
            pageBuilder: (BuildContext c, GoRouterState s) => NoTransitionPage<void>(
              child: GroupPostsPage(
                groupId: s.pathParameters['id'] ?? '',
                postId: s.pathParameters['postId'],
              ),
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            theme: buildAylaTheme(),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: Scaffold(backgroundColor: Colors.transparent, body: child),
            ),
          ),
        ),
      );
      for (int i = 0;
          i < 400 && find.byType(AylaPostCard).evaluate().isEmpty;
          i += 1) {
        await tester.pump(
          i % 5 == 0 ? const Duration(milliseconds: 1) : Duration.zero,
        );
      }
      await tester.pump();
      await tester.pump();
      return container;
    }

    Future<void> drain(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    }

    /// 列表态下 `AylaRevealScope.suppress` 的当前值。
    bool suppressOf(WidgetTester tester) {
      final Finder scope = find.byType(AylaRevealScope);
      expect(scope, findsOneWidget);
      return tester.widget<AylaRevealScope>(scope).suppress;
    }

    testWidgets('取页成功后 suppress = false（tsx 148–153 写 revealAfterRefresh）',
        (WidgetTester tester) async {
      await setUpPage(tester, _PostsAdapter(listIds: <int>[1, 2, 3]));
      expect(suppressOf(tester), isFalse,
          reason: '首屏取页成功即放开抑制，卡片正常播入场');
      await drain(tester);
    });

    testWidgets('进详情 ⇒ suppress = true；返回列表后取页完成 ⇒ 恢复 false',
        (WidgetTester tester) async {
      final _PostsAdapter a = _PostsAdapter(listIds: <int>[1, 2, 3]);
      await setUpPage(tester, a);
      expect(suppressOf(tester), isFalse);

      // 点卡进详情（web tsx 426–431：skipRevealRestoreKey + revealAfterRefresh(false)）
      await tester.tap(find.byType(AylaPostCard).first);
      await tester.pump();
      await tester.pump();
      // 详情态整页换 PostDetailPage ⇒ 列表与 RevealScope 均已卸载
      expect(find.byType(AylaMasonryGrid<AylaPost>), findsNothing);

      // 返回列表（web tsx 360–365 的 effect 已把 revealAfterRefresh 置 false ⇒ 抑制生效）
      final GoRouter router = tester
          .widget<MaterialApp>(find.byType(MaterialApp))
          .routerConfig! as GoRouter;
      router.go('/group/g1/posts');
      await tester.pump();
      await tester.pump();
      expect(find.byType(AylaPostCard), findsWidgets);
      // 首帧（未触发新取页）应为抑制态
      expect(suppressOf(tester), isTrue,
          reason: '从详情返回的首帧不播入场（tsx 379 的第二个析取项）');
      await drain(tester);
    });
  });
}