/// 页面 WS / 滚动恢复 / 分享接线专项回归锁（2026-10-02，A/B/C/D/E）。
///
/// | 本组 | web 事实源 |
/// |---|---|
/// | 【B】帖子详情「分享」真的打开分享弹窗 | `pages/PostDetailPage.tsx:460–466` + `utils/sharePayload.ts:79–93` |
/// | 【C】帖子详情消费 `comment.created` / `comment.deleted` / `post.viewed` | `pages/PostDetailPage.tsx:219–245` + `hooks/usePostComments.ts:129–134` |
/// | 【D】搜索页消费 `group.request.resolved` / `group.joined` / `group.member.left` | `pages/SearchPage.tsx:242–287` + 四级 `groupIsJoined`（144–148） |
/// | 【E】滚动恢复两门（active / ready）与 `saveScrollPosition` | `hooks/useScrollRestore.ts:48–105` |
/// | 【A】群内桌游 / 语音卡片左右留白 = 16（外层单一来源） | `boardgame.css:254–259` / `voice.css:690–695` / `group.css:411–417` |
///
/// ⚠️ 纪律：几何断言先钉表面尺寸（flutter_test 默认 800×600 是窄屏档）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/conversation.dart'
    show AylaConversationSummary, AylaConversationType;
import '../lib/core/models/post.dart';
import '../lib/core/models/share_payload.dart' show AylaSharePayload, AylaShareType;
import '../lib/core/net/dio_client.dart';
import '../lib/pages/group_games_page.dart';
import '../lib/pages/group_voice_page.dart';
import '../lib/core/api/directory_page.dart' show AylaDirectoryPage;
import '../lib/pages/post_detail_page.dart';
import '../lib/pages/posts_hub_page.dart' show PostsHubPage;
import '../lib/state/posts_store.dart' show aylaPostTabCache;
import '../lib/pages/search_page.dart';
import '../lib/state/auth_state.dart';
import '../lib/state/chat_providers.dart'
    show chatStateProvider, chatWsProvider;
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart' show AylaSpacing;
import '../lib/widgets/base/scroll_restore.dart';
import '../lib/widgets/game/game_room_card.dart' show AylaGameRoomCard;
import '../lib/widgets/game/games_grid.dart' show AylaGamesGrid;
import '../lib/widgets/group/group_scene.dart' show AylaGroupSceneStickyHead;
import '../lib/widgets/voice/voice_channels.dart' show AylaVoiceChannelCard;
import '../lib/widgets/base/directory_page.dart' show AylaDirectoryContent;
import '../lib/widgets/base/share.dart'
    show AylaShareButton, AylaShareSheet;
import '../lib/widgets/posts/comments.dart' show AylaCommentList;
import '../lib/widgets/posts/post_card.dart' show AylaPostCard;
import '../lib/widgets/posts/post_detail_chrome.dart'
    show AylaPostDetailChrome;

// ===================== HTTP 替身 =====================

/// 记录请求并按路径回预设响应的传输层（`media_actions_test` 同款）。
///
/// ⚠️ **不要**用 `HttpServer`：`TestWidgetsFlutterBinding` 会把 `HttpOverrides.global`
/// 换成 mock（`flutter_test/_binding_io.dart:26–28`）⇒ 真实回环请求一律返回 400。
/// ⚠️ `options.path` 是**相对 baseUrl 的路径**（baseUrl 已含 /api/v1）⇒ 键里不带前缀。
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

Map<String, dynamic> _emptyPage() => <String, dynamic>{
      'results': <Object?>[],
      'next_cursor': null,
      'has_more': false,
    };

Map<String, dynamic> _postJson(int id, {String title = '帖子', String body = '正文'}) =>
    <String, dynamic>{
      'id': id,
      'title': title,
      'body': body,
      'author': <String, dynamic>{'id': 'u2', 'nickname': '小樱'},
      'author_id': 'u2',
      'group': null,
      'allowed_group_ids': <String>[],
      'images': <Object?>[
        <String, dynamic>{
          'id': 9,
          'media': <String, dynamic>{
            'media_id': 'm-cover',
            'kind': 'image',
            'thumbnail': '/api/v1/media/thumb/cover.jpg',
          },
        },
      ],
      'comment_count': 1,
      'view_count': 3,
      'is_viewed': false,
      'created_at': '2026-10-01T00:00:00Z',
    };

Map<String, dynamic> _roomJson(String id, String name) => <String, dynamic>{
      'id': id,
      'name': name,
      'owner': <String, dynamic>{'id': 'u1', 'nickname': '房主'},
      'owner_id': 'u1',
      'status': 'waiting',
      'created_at': '2026-10-01T00:00:00Z',
    };

Map<String, dynamic> _voiceJson(String id, String name) => <String, dynamic>{
      'id': id,
      'name': name,
      'member_count': 1,
      'created_at': '2026-10-01T00:00:00Z',
    };

Map<String, dynamic> _commentJson(int id, {String body = '评论'}) =>
    <String, dynamic>{
      'id': id,
      'post_id': '5',
      'body': body,
      'author': <String, dynamic>{'id': 'u3', 'nickname': '路人'},
      'author_id': 'u3',
      'images': <Object?>[],
      'is_author': false,
      'created_at': '2026-10-02T00:00:00Z',
    };

// ===================== 宿主 =====================

/// 测试宿主：显式 [ProviderContainer]（可在断言里读 provider）+ 真实主题 + 预览兜底。
class _Harness {
  _Harness(this.tester) {
    container = ProviderContainer();
    addTearDown(container.dispose);
  }

  final WidgetTester tester;
  late final ProviderContainer container;

  Future<void> pump(Widget page, {Size viewport = const Size(1440, 900)}) async {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(size: viewport),
              child: previewScope(
                Align(alignment: Alignment.topLeft, child: page),
              ),
            ),
          ),
        ),
      ),
    );
    await settle();
  }

  /// 走完「首帧 → 详情 → 评论」这条异步链（不 pumpAndSettle：极光是无限动画）。
  Future<void> settle() async {
    for (int i = 0; i < 6; i += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  void frame(Map<String, dynamic> frame) {
    container.read(chatWsProvider).debugHandleFrame(frame);
  }

  /// 当前渲染的详情卡（`AylaPostCard.post` 是公开字段 ⇒ 不用碰私有 State）。
  AylaPost get card {
    final Iterable<AylaPostCard> cards =
        tester.widgetList<AylaPostCard>(find.byType(AylaPostCard));
    for (final AylaPostCard c in cards) {
      if (c.detail) return c.post;
    }
    return cards.first.post;
  }

  /// 当前渲染的评论列表（`AylaCommentList.comments` 是公开字段）。
  List<AylaPostComment> get comments {
    final Finder f = find.byType(AylaCommentList);
    if (f.evaluate().isEmpty) return const <AylaPostComment>[];
    return tester.widget<AylaCommentList>(f).comments;
  }

  List<String> get commentBodies =>
      <String>[for (final AylaPostComment c in comments) c.body];
}

/// 详情页要打到的端点（路径取自 `core/api/posts_api.dart`）。
void _routePostDetail(_ApiAdapter adapter,
    {int id = 5, List<Map<String, dynamic>> comments = const <Map<String, dynamic>>[]}) {
  adapter.routes['GET /posts/$id/'] = (200, jsonEncode(_postJson(id)));
  adapter.routes['POST /posts/views/'] =
      (200, jsonEncode(<String, dynamic>{'updated': <String, dynamic>{}}));
  adapter.routes['GET /posts/$id/comments/'] = (200,
      jsonEncode(<String, dynamic>{
        'results': comments.cast<Object?>(),
        'next_cursor': null,
        'has_more': false,
      }));
  adapter.routes['GET /chat/conversations/'] = (200, jsonEncode(_emptyPage()));
}

/// chat WS 自身的副作用端点（§group.joined§ 会触发会话摘要对账；通知帧会拉 badges）。
void _routeChatSideEffects(_ApiAdapter adapter) {
  adapter.routes['GET /me/badges/'] = (200,
      jsonEncode(<String, dynamic>{
        'request_badge': 0,
        'message_badge': 0,
      }));
  adapter.routes['GET /chat/conversations/g1/'] = (200,
      jsonEncode(<String, dynamic>{
        'id': 'g1',
        'type': 'group',
        'title': '爱莉的粉丝群',
      }));
}

void main() {
  late _ApiAdapter adapter;

  setUp(() {
    adapter = _ApiAdapter();
    DioClient.instance.debugBaseUrlOverride = 'http://test.local';
    DioClient.instance.init(tokenStore: _NoTokens(), onSessionExpired: () {});
    DioClient.instance.dio.httpClientAdapter = adapter;
    AylaScrollMemory.clear();
  });

  tearDown(AylaScrollMemory.clear);

  // ==================================================================
  // 【B】分享按钮接线（PostDetailPage.tsx:460–466）
  // ==================================================================
  group('【B】帖子详情分享（PostDetailPage.tsx:460–466 / sharePayload.ts:79–93）', () {
    test('payload 逐字段：标题 / 正文归一截断 / 群归属 / 首图 thumbnail 封面', () {
      final AylaPost post = AylaPost.fromJson(
        _postJson(12, title: '关于 Y2K', body: '  一   二 '),
      )!;
      final AylaSharePayload payload = aylaPostSharePayloadFor(post);
      expect(payload.shareType, AylaShareType.post);
      expect(payload.targetId, '12');
      expect(payload.title, '关于 Y2K');
      expect(payload.subtitle, '一 二'); // \s+ → 单空格（sharePayload.ts:83）
      expect(payload.cover, '/api/v1/media/thumb/cover.jpg');
      expect(payload.extra, isNull); // post.group == null
    });

    test('摘要超过 24 个码元 ⇒ 截断 + 省略号（sharePayload.ts:84）', () {
      final AylaPost post = AylaPost.fromJson(_postJson(1, body: 'a' * 30))!;
      expect(aylaPostSharePayloadFor(post).subtitle, '${'a' * 24}\u2026');
    });

    testWidgets('点「分享帖子」⇒ 分享弹层出现（不是空回调）', (WidgetTester tester) async {
      _routePostDetail(adapter);
      final _Harness h = _Harness(tester);
      await h.pump(const PostDetailPage(postId: '5'));

      expect(adapter.requests, contains('GET /posts/5/'));
      final Finder shareBtn = find.byType(AylaShareButton);
      expect(shareBtn, findsOneWidget, reason: 'tsx 449–455：头部有分享入口');
      expect(find.byType(AylaShareSheet), findsNothing,
          reason: '打开前不应存在弹层');

      await tester.tap(shareBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(AylaShareSheet), findsOneWidget);
    });
  });

  // ==================================================================
  // 【C】帖子详情实时帧（PostDetailPage.tsx:219–245 / usePostComments.ts:129–134）
  // ==================================================================
  group('【C】帖子详情 WS 帧（PostDetailPage.tsx:219–245）', () {
    testWidgets('comment.created ⇒ 评论数 +1 且列表出现该评论', (WidgetTester tester) async {
      _routePostDetail(adapter,
          comments: <Map<String, dynamic>>[_commentJson(1, body: '已有评论')]);
      final _Harness h = _Harness(tester);
      await h.pump(const PostDetailPage(postId: '5'));

      expect(h.commentBodies, <String>['已有评论']);
      final int before = h.card.commentCount!;

      h.frame(<String, dynamic>{
        'type': 'comment.created',
        'data': <String, dynamic>{
          'post_id': '5',
          'comment': _commentJson(2, body: '来自他人的新评论'),
          'comment_count': before + 1,
        },
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(h.commentBodies, contains('来自他人的新评论'),
          reason: 'hook:131 upsert 把新评论插进列表');
      expect(h.card.commentCount, before + 1);
    });

    testWidgets('comment.deleted ⇒ 列表移除该评论且计数下降', (WidgetTester tester) async {
      _routePostDetail(adapter, comments: <Map<String, dynamic>>[
        _commentJson(1, body: '留下的评论'),
        _commentJson(2, body: '将被删除'),
      ]);
      final _Harness h = _Harness(tester);
      await h.pump(const PostDetailPage(postId: '5'));
      expect(h.commentBodies, <String>['留下的评论', '将被删除']);

      h.frame(<String, dynamic>{
        'type': 'comment.deleted',
        'data': <String, dynamic>{
          'post_id': '5',
          'comment_id': 2,
          'comment_count': 1,
        },
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(h.commentBodies, <String>['留下的评论'],
          reason: 'hook:132 remove 从列表移除');
      expect(h.card.commentCount, 1);
    });

    testWidgets('post.viewed（他人）⇒ 浏览量覆盖；本人 ⇒ 同步 is_viewed',
        (WidgetTester tester) async {
      _routePostDetail(adapter);
      final _Harness h = _Harness(tester);
      await h.pump(const PostDetailPage(postId: '5'));
      expect(h.card.viewCount, 3);

      // 他人浏览（tsx 227–242 的 else 分支）：只刷 view_count。
      h.frame(<String, dynamic>{
        'type': 'post.viewed',
        'data': <String, dynamic>{
          'post_id': '5',
          'view_count': 99,
          'viewer_id': 'u-other',
          'allowed_group_ids': <String>[],
        },
      });
      await tester.pump();
      expect(h.card.viewCount, 99);
      expect(h.card.isViewed, isFalse);

      // 本人多端浏览：同步 is_viewed（tsx 231–237 的 isMe 分支）。
      h.container.read(authNotifierProvider.notifier).setUser(
            const AuthUser(
              id: 'me',
              username: 'me',
              nickname: '我',
              avatar: '',
              signature: '',
              status: '',
              online: true,
              displayStatus: '',
              dateJoined: '',
              isInVoice: false,
              voiceRoomId: null,
              isLive: false,
              liveRoomId: null,
              showContent: true,
              email: '',
            ),
          );
      await tester.pump();
      h.frame(<String, dynamic>{
        'type': 'post.viewed',
        'data': <String, dynamic>{
          'post_id': '5',
          'view_count': 100,
          'viewer_id': 'me',
          'allowed_group_ids': <String>[],
        },
      });
      await tester.pump();
      expect(h.card.viewCount, 100);
      expect(h.card.isViewed, isTrue);
    });

    testWidgets('post_id 不符的帧被丢弃（tsx 222/227 的守卫）', (WidgetTester tester) async {
      _routePostDetail(adapter);
      final _Harness h = _Harness(tester);
      await h.pump(const PostDetailPage(postId: '5'));

      h.frame(<String, dynamic>{
        'type': 'comment.created',
        'data': <String, dynamic>{
          'post_id': '6',
          'comment': _commentJson(9, body: '别的帖子的评论'),
          'comment_count': 42,
        },
      });
      await tester.pump();
      expect(h.commentBodies, isEmpty);
      expect(h.card.commentCount, 1);
    });
  });

  // ==================================================================
  // 【D】搜索页成员事件（SearchPage.tsx:242–287 / 144–148）
  // ==================================================================
  group('【D】搜索页成员事件（SearchPage.tsx:242–287）', () {
    testWidgets('三帧依次到达 ⇒ 群结果入口文案随之变化', (WidgetTester tester) async {
      adapter.routes['GET /search/'] = (200,
          jsonEncode(<String, dynamic>{
            'groups': <String, dynamic>{
              'items': <Object?>[
                <String, dynamic>{
                  'id': 'g1',
                  'title': '爱莉的粉丝群',
                  'is_member': false,
                  'member_count': 3,
                },
              ],
              'total': 1,
              'next_cursor': null,
              'has_more': false,
            },
          }));
      _routeChatSideEffects(adapter);
      final _Harness h = _Harness(tester);
      await h.pump(const SearchPage(initialQuery: '爱'));

      // tsx 418：未加入 ⇒ 申请入群
      expect(find.text('申请入群'), findsOneWidget);

      // ① group.request.resolved(accepted) ⇒ 已通过（tsx 254–263）
      h.frame(<String, dynamic>{
        'type': 'group.request.resolved',
        'data': <String, dynamic>{
          'status': 'accepted',
          'conversation_id': 'g1',
        },
      });
      await tester.pump();
      expect(find.text('已通过'), findsOneWidget);

      // ② group.joined ⇒ 已加入 + 从「已通过」移除（tsx 270–276）。
      //    ⚠️ 该帧同时会被 chat WS 自身消费（§reconcileConversation§ ⇒ 拉会话摘要），
      //    端点已在 _routeSearchStale 里给全，避免留下 pending 请求。
      h.frame(<String, dynamic>{
        'type': 'group.joined',
        'conversation': <String, dynamic>{'id': 'g1'},
      });
      await tester.pump();
      // stale 会自动重搜一轮（tsx 336–339）⇒ 让它跑完，别留 pending 请求
      await h.settle();
      expect(find.text('已加入'), findsOneWidget);
    });

    testWidgets('group.member.left 仅本人 ⇒ 成员关系置假；他人离开不处理',
        (WidgetTester tester) async {
      adapter.routes['GET /search/'] = (200,
          jsonEncode(<String, dynamic>{
            'groups': <String, dynamic>{
              'items': <Object?>[
                <String, dynamic>{
                  'id': 'g1',
                  'title': '爱莉的粉丝群',
                  'is_member': true,
                },
              ],
              'total': 1,
              'next_cursor': null,
              'has_more': false,
            },
          }));
      final _Harness h = _Harness(tester);
      await h.pump(const SearchPage(initialQuery: '爱'));
      expect(find.text('已加入'), findsOneWidget);

      // 他人离开（member_id ≠ 本人）⇒ tsx 282 的守卫使其不生效。
      h.frame(<String, dynamic>{
        'type': 'group.member.left',
        'data': <String, dynamic>{
          'conversation_id': 'g1',
          'member_id': 'someone-else',
        },
      });
      await tester.pump();
      expect(find.text('已加入'), findsOneWidget,
          reason: 'tsx 282：只有本人离开才改成员关系');

      // 本人离开 ⇒ 回落到「申请入群」。
      h.container.read(authNotifierProvider.notifier).setUser(_me('me'));
      await tester.pump();
      h.frame(<String, dynamic>{
        'type': 'group.member.left',
        'data': <String, dynamic>{
          'conversation_id': 'g1',
          'member_id': 'me',
        },
      });
      await tester.pump();
      expect(find.text('申请入群'), findsOneWidget);
    });

    testWidgets('响应 is_member=null 时回落已加入会话集合（tsx 148 第四级）',
        (WidgetTester tester) async {
      adapter.routes['GET /search/'] = (200,
          jsonEncode(<String, dynamic>{
            'groups': <String, dynamic>{
              'items': <Object?>[
                <String, dynamic>{'id': 'g1', 'title': '爱莉的粉丝群'},
              ],
              'total': 1,
              'next_cursor': null,
              'has_more': false,
            },
          }));
      final _Harness h = _Harness(tester);
      // tsx 82–85：joinedConversationIds 来自 chat store 的群会话列表。
      h.container.read(chatStateProvider).setConversations(
            <AylaConversationSummary>[
              AylaConversationSummary(
                id: 'g1',
                type: AylaConversationType.group,
                title: '爱莉的粉丝群',
              ),
            ],
          );
      await h.pump(const SearchPage(initialQuery: '爱'));
      expect(find.text('已加入'), findsOneWidget);
    });
  });

  // ==================================================================
  // 【A】群内桌游 / 语音卡片左右留白（group.css:411–417 是唯一来源）
  // ==================================================================
  group('【A】群内卡片左右留白 = 16（boardgame.css:254–259 / voice.css:690–695）', () {
    const double kSp4 = 16;

    testWidgets('群内桌游：左 16 / 右 16（外层 sp4，网格自身归零）', (WidgetTester tester) async {
      adapter.routes['GET /boardgame/rooms/'] = (200,
          jsonEncode(<String, dynamic>{
            'results': <Object?>[
              _roomJson('r1', '你画我猜'),
              _roomJson('r2', '狼人杀'),
            ],
            'next_cursor': null,
            'has_more': false,
          }));
      final _Harness h = _Harness(tester);
      await h.pump(const GroupGamesPage(groupId: 'g1'));

      // 以外层场景滚动容器为参照（页面宽度由壳层决定，不能写死视口值）
      final Rect outer =
          tester.getRect(find.byType(AylaGroupSceneStickyHead).first);
      final Rect grid = tester.getRect(find.byType(AylaGamesGrid));
      final Rect first = tester.getRect(find.byType(AylaGameRoomCard).first);
      // 2 列：右边缘看**最后一张卡**的右边缘（第一张的右侧是列间距，不是页面留白）
      final Rect last = tester.getRect(find.byType(AylaGameRoomCard).at(1));
      expect(first.left - outer.left, kSp4,
          reason: '左留白 = .group-page .group-games 的 sp4（外层唯一来源）');
      expect(outer.right - last.right, kSp4,
          reason: '右留白同值（网格自身 padding 已归零）');
      // 网格盒 = 外层 padding 内缘（证明没有第二层内距）
      expect(grid.left - outer.left, kSp4);
      expect(outer.right - grid.right, kSp4);
      expect(last.left - first.right, AylaSpacing.sp3,
          reason: 'boardgame.css:256 的 gap: var(--sp-3)');
    });

    testWidgets('群内语音：左 16 / 右 16（外层 sp4，列表自身归零）', (WidgetTester tester) async {
      adapter.routes['GET /voice/channels/'] = (200,
          jsonEncode(<String, dynamic>{
            'results': <Object?>[
              _voiceJson('v1', '深夜电台'),
              _voiceJson('v2', '自习室'),
            ],
            'next_cursor': null,
            'has_more': false,
          }));
      final _Harness h = _Harness(tester);
      await h.pump(const GroupVoicePage(groupId: 'g1'));

      final Rect outer =
          tester.getRect(find.byType(AylaGroupSceneStickyHead).first);
      final Rect first = tester.getRect(find.byType(AylaVoiceChannelCard).first);
      final Rect last = tester.getRect(find.byType(AylaVoiceChannelCard).at(1));
      expect(first.left - outer.left, kSp4,
          reason: '左留白 = .group-page .group-voice 的 sp4（外层唯一来源）');
      expect(outer.right - last.right, kSp4,
          reason: '右留白同值（列表 padding:0 已显式归零）');
      expect(last.left - first.right, AylaSpacing.sp3,
          reason: 'voice.css:693 的 gap: var(--sp-3)');
    });
  });

  // ==================================================================
  // 【E】滚动位置恢复（useScrollRestore.ts:48–105）
  // ==================================================================
  group('【E】滚动位置恢复（useScrollRestore.ts:48–105）', () {
    test('记忆按 key 隔离；save 对未挂载的 controller 不写（:31–34）', () {
      expect(AylaScrollMemory.has('a'), isFalse);
      AylaScrollMemory.put('a', 10);
      AylaScrollMemory.put('b', 20);
      expect(AylaScrollMemory.get('a'), 10);
      expect(AylaScrollMemory.get('b'), 20);
      AylaScrollMemory.remove('a');
      expect(AylaScrollMemory.has('a'), isFalse);
      expect(AylaScrollMemory.get('b'), 20);
      // controller 未挂载 ⇒ 不写（web `if (!el) return`）
      AylaScrollMemory.save('c', ScrollController());
      expect(AylaScrollMemory.has('c'), isFalse);
      AylaScrollMemory.clear();
      expect(AylaScrollMemory.has('b'), isFalse);
    });

    testWidgets('ready=false ⇒ restoring 命中但不落位；ready=true ⇒ 落位',
        (WidgetTester tester) async {
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      AylaScrollMemory.put('k', 100);

      final AylaScrollRestore restore = AylaScrollRestore(
        key: 'k',
        controller: controller,
        ready: false,
      )..attach();
      addTearDown(restore.dispose);

      await tester.pumpWidget(_tallList(controller));
      await tester.pump();
      // :65–69：hasSavedPosition 已在 ready 之前置位 ⇒ restoring=true
      expect(restore.restoring, isTrue);
      expect(restore.hasSavedPosition, isTrue);
      expect(controller.offset, 0, reason: 'ready=false 时 :69 直接 return');

      restore.update(ready: true);
      await tester.pump();
      expect(controller.offset, 100);

      // :75–79 下一帧再补一次（幂等）
      await tester.pump();
      expect(controller.offset, 100);
    });

    testWidgets('active=false ⇒ restoring 置 false（:60–64）且不写记忆（:88）',
        (WidgetTester tester) async {
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      AylaScrollMemory.put('k', 50);
      final AylaScrollRestore restore = AylaScrollRestore(
        key: 'k',
        controller: controller,
      )..attach();
      addTearDown(restore.dispose);
      restore.update(active: true, ready: true);
      await tester.pumpWidget(_tallList(controller));
      await tester.pump();
      await tester.pump();
      expect(controller.offset, 50);

      restore.update(active: false, ready: false);
      expect(restore.restoring, isFalse, reason: ':61–64');
      // 失活期间的位移不得回写（web 卸载 scroll 监听，:88–102）
      controller.jumpTo(120);
      await tester.pump();
      expect(AylaScrollMemory.get('k'), 50);
    });

    testWidgets('滚动写入记忆；detach 不回写（:97–101）', (WidgetTester tester) async {
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      final AylaScrollRestore restore = AylaScrollRestore(
        key: 'k',
        controller: controller,
      )..attach();
      await tester.pumpWidget(_tallList(controller));
      await tester.pump();
      controller.jumpTo(120);
      await tester.pump();
      expect(AylaScrollMemory.get('k'), 120);

      // 卸载前显式保存（web saveScrollPosition）
      AylaScrollMemory.save('k', controller);
      expect(AylaScrollMemory.get('k'), 120);
      restore.detach();
      controller.jumpTo(0);
      await tester.pump();
      expect(AylaScrollMemory.get('k'), 120,
          reason: 'detach 后不再有监听 ⇒ 退出阶段的 0 不覆盖记录');
    });

    testWidgets('帖子 hub 往返：滚到中部 → 卸载 → 重挂载 ⇒ 位置被恢复（PostsHubPage.tsx:119）',
        (WidgetTester tester) async {
      aylaPostTabCache.requestOverride = (String? cursor) async =>
          AylaDirectoryPage<AylaPost>(
            results: <AylaPost>[
              for (int i = 1; i <= 30; i += 1)
                AylaPost.fromJson(_postJson(i, title: '帖子 @D@i'))!,
            ],
            nextCursor: null,
            hasMore: false,
          );
      addTearDown(() => aylaPostTabCache.clear());
      aylaPostTabCache.clear();
      final _Harness h = _Harness(tester);
      await h.pump(const PostsHubPage());
      await h.settle();

      expect(find.byType(AylaPostCard), findsWidgets,
          reason: '列表要真的渲染出来（否则没有可滚高度）');
      final ScrollController first = _contentScrollController(tester);
      expect(first.position.maxScrollExtent, greaterThan(200));
      first.jumpTo(180);
      await tester.pump();
      expect(AylaScrollMemory.get('posts-feed:all'), 180);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(AylaScrollMemory.get('posts-feed:all'), 180,
          reason: '卸载不得把位置覆盖成 0（:97–101）');

      await h.pump(const PostsHubPage());
      await h.settle();
      expect(_contentScrollController(tester).offset, closeTo(180, 0.5));
    });

    testWidgets('详情页往返：滚到中部 → 卸载 → 重挂载 ⇒ 位置被恢复（PostDetailPage.tsx:135）',
        (WidgetTester tester) async {
      _routePostDetail(adapter, comments: <Map<String, dynamic>>[
        for (int i = 1; i <= 30; i += 1) _commentJson(i, body: '评论 $i'),
      ]);
      final _Harness h = _Harness(tester);
      await h.pump(const PostDetailPage(postId: '5'));

      final ScrollController first = _detailScrollController(tester);
      expect(first.hasClients, isTrue);
      expect(first.position.maxScrollExtent, greaterThan(200),
          reason: '内容要足够长，恢复才有意义');
      first.jumpTo(200);
      await tester.pump();
      expect(AylaScrollMemory.get('post-comments:5'), 200);

      // 离开详情（State dispose ⇒ AylaScrollRestore.dispose）
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(AylaScrollMemory.get('post-comments:5'), 200,
          reason: '卸载不得把位置覆盖成 0');

      // 回到同一帖子 ⇒ 恢复
      await h.pump(const PostDetailPage(postId: '5'));
      final ScrollController second = _detailScrollController(tester);
      expect(second.offset, closeTo(200, 0.5), reason: 'tsx 135 的恢复');
    });
  });
}

AuthUser _me(String id) => AuthUser(
      id: id,
      username: id,
      nickname: '我',
      avatar: '',
      signature: '',
      status: '',
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

/// 够高的可滚列表（滚动恢复用例的宿主）。
Widget _tallList(ScrollController controller) => MaterialApp(
      home: SizedBox(
        width: 400,
        height: 400,
        child: ListView.builder(
          controller: controller,
          itemCount: 100,
          itemBuilder: (BuildContext context, int i) =>
              SizedBox(height: 40, child: Text('row $i')),
        ),
      ),
    );

ScrollController _detailScrollController(WidgetTester tester) =>
    tester
        .widget<AylaPostDetailChrome>(find.byType(AylaPostDetailChrome))
        .scrollController!;

/// 取目录页**内容区**的滚动控制器（侧栏另有自己的滚动区，不能取第一个）。
ScrollController _contentScrollController(WidgetTester tester) {
  final ScrollController? c =
      tester.widget<AylaDirectoryContent>(find.byType(AylaDirectoryContent))
          .controller;
  if (c == null) throw StateError('内容区没有控制器');
  return c;
}
