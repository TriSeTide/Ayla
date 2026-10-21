/// 收藏页「点收藏卡片跳转到原内容」的回归锁（一比一复刻 web FavoritesPage）。
///
/// ## 事实源
/// - `Ayla/web/src/pages/FavoritesPage.tsx:36–67`：`openTarget` 五类跳转 ——
///   post → `/posts/:id`、live → `/live/:id`、voice → `/voice/:id`、
///   game → `/games/:id`、message → `/chat/<conversation_id>?msg=&seq=&subgroup=`
///   （`seq > 0` 才带 seq、`subgroup` 非空才带 subgroup、`msg` 非空才带 msg）；
///   导航用 `navigate`（`tsx:285`）= **push**（React Router 默认，不替换当前页）。
/// - `Ayla/web/src/components/posts/PostCard.tsx:70–79`：帖卡作者头像
///   `onClick → goUserProfile(currentUserId, author.id)`；收藏页的帖卡就是同一个
///   `PostCard`（`DirectoryResultCards.tsx:53` 只多传 onOpen/action/previewOnly）
///   ⇒ 收藏页帖卡头像**必须可点**且跳个人主页。
/// - `Ayla/web/src/utils/navigation.ts:24–35`：`goUserProfile` = 自己 → `/profile`；
///   他人 → `/user/<encodeURIComponent(id)>`；目标 id 缺失 ⇒ 不做事。
/// - `Ayla/web/src/components/chat/MessageList.tsx:785–818`：外部跳转（收藏消息定位）
///   = 先 `find(id)` → 再 `findBySeq(seq)` → 都没有且 `seq > 0 && onLoadUntilSeq`
///   则先补页再找 → 命中才滚动 + 高亮（`handledJumpRef` 去重）。
///
/// ## 覆盖（五组）
/// ① 四类卡（post/live/voice/game）+ 消息卡：真实 [AylaFavoriteResultCard] 渲染 + tap ⇒ onOpen；
/// ② 页面级 push 语义：真实 [FavoritesPage] 挂真实 GoRouter，点卡片 ⇒ location 变化
///    且 `canPop()` 为真（历史栈留上一页）—— 旧实现用 `context.go` 时为假；
/// ③ 消息 query 拼装：msg / seq(>0) / subgroup(非空) 的三种组合（含全缺省）；
/// ④ 作者头像点击：组件层「头像可点且不冒泡到整卡」+ 页面层「自己 → /profile / 他人 → /user/:id」；
/// ⑤ 消息定位链路：目标不在首屏 + 带 seq ⇒ `onLoadUntilSeq` 被调用且最终命中
///    （`message_list.dart` 的 `_handleExternalJump` 按 `MessageList.tsx:797–817` 补齐）。
///
/// ⚠️ 全程**零网络**：页面取页走 `aylaFavoritesPageLoader` 注入点
/// （`favorites_page.dart` 文件级 `@visibleForTesting` 出口，生产恒 null），
/// 卡片点击 / 导航 / 拼参 / 渲染全部是真实实现。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:ayla_flutter/core/api/directory_page.dart' show AylaDirectoryPage;
import 'package:ayla_flutter/core/api/favorites_api.dart' show AylaFavoriteEntry;
import 'package:ayla_flutter/core/models/chat_message.dart';
import 'package:ayla_flutter/core/models/game_room.dart' show AylaGameCardData;
import 'package:ayla_flutter/core/models/post.dart' show AylaPost, AylaPostAuthor;
import 'package:ayla_flutter/pages/favorites_page.dart'
    show FavoritesPage, aylaFavoritesPageLoader;
import 'package:ayla_flutter/state/auth_state.dart'
    show AuthUser, authNotifierProvider;
import 'package:ayla_flutter/theme/app_theme.dart';
import 'package:ayla_flutter/widgets/base/avatar_halo.dart' show AylaAvatarHalo;
import 'package:ayla_flutter/widgets/base/directory_result_cards.dart';
import 'package:ayla_flutter/widgets/chat/message_list.dart' show AylaMessageList;
import 'package:ayla_flutter/widgets/game/game_room_card.dart'
    show AylaGameRoomCard;
import 'package:ayla_flutter/widgets/live/live_hall.dart'
    show AylaLiveCardData, AylaLiveChannelCard;
import 'package:ayla_flutter/widgets/voice/voice_channels.dart'
    show AylaVoiceCardData, AylaVoiceChannelCard;

// ============================================================================
// 测试替身
// ============================================================================

const AuthUser _me = AuthUser(
  id: 'me',
  username: 'me',
  nickname: '我',
  avatar: '',
  signature: '',
  status: 'auto',
  online: true,
  displayStatus: '在线',
  dateJoined: '',
  isInVoice: false,
  voiceRoomId: null,
  isLive: false,
  liveRoomId: null,
  showContent: true,
  email: '',
);

AylaChatMessage _msg({
  String id = 'm1',
  String conversationId = 'c1',
  int seq = 7,
  String? subgroupId,
  AylaMessageType type = AylaMessageType.text,
  String content = '被收藏的正文',
}) =>
    AylaChatMessage(
      id: id,
      conversationId: conversationId,
      senderId: 'u1',
      subgroupId: subgroupId,
      type: type,
      content: content,
      status: AylaMessageStatus.sent,
      seq: seq,
      createdAt: '2026-10-21T12:00:00Z',
    );

AylaPost _post({String authorId = 'u-2'}) => AylaPost(
      id: 106,
      author: AylaPostAuthor(id: authorId, nickname: '小樱'),
      authorId: authorId,
      title: '帖子标题',
      body: '帖子正文',
      createdAt: '2026-10-21T12:00:00Z',
    );

AylaFavoriteEntry _entry({
  required AylaFavoriteTargetType type,
  required String targetId,
  AylaPost? post,
  AylaChatMessage? message,
  int id = 1,
}) =>
    AylaFavoriteEntry(
      card: AylaFavoriteResultData(
        id: id,
        targetType: type,
        post: post,
        live: type == AylaFavoriteTargetType.live
            ? const AylaLiveCardData(id: 'live-1', title: '直播间')
            : null,
        voice: type == AylaFavoriteTargetType.voice
            ? const AylaVoiceCardData(id: 'v-1', name: '语音房')
            : null,
        game: type == AylaFavoriteTargetType.game
            ? const AylaGameCardData(id: 'g-1', name: '桌游房')
            : null,
        message: message,
      ),
      targetId: targetId,
      messageSenderNickname: message == null ? null : '爱莉',
    );

/// 最小卡片宿主（与 `directory_result_cards_test.dart` 同款）。
Widget _cardHost(Widget child, {Size viewport = const Size(460, 700)}) => MaterialApp(
      theme: buildAylaTheme(),
      home: Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: viewport),
          child: SizedBox.fromSize(
            size: viewport,
            child: SingleChildScrollView(child: child),
          ),
        ),
      ),
    );

/// 推进若干帧（注入 loader 的 Future 在 microtask 上完成，但页面还有入场动画）。
Future<void> _settle(WidgetTester tester, {int frames = 8}) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 目标页探针：把「被 push 到的路径 + query」变成可断言的文本。
class _TargetProbe extends StatelessWidget {
  const _TargetProbe({required this.name, required this.id, this.query = ''});

  final String name;
  final String id;
  final String query;

  @override
  Widget build(BuildContext context) {
    final String text = '$name:$id${query.isEmpty ? '' : '?$query'}';
    return Scaffold(body: Center(child: Text(text)));
  }
}

void main() {
  // ==========================================================================
  // ① 五类卡片：真实 AylaFavoriteResultCard 渲染 + tap ⇒ onOpen
  //    （web FavoritesPage.tsx:96 的 onOpen={() => onOpen(favorite)}）
  // ==========================================================================
  group('① 收藏卡点击触发 onOpen', () {
    testWidgets('post 卡：点卡片 ⇒ onOpen（tsx 39–41 / 53）', (WidgetTester tester) async {
      int opened = 0;
      await tester.pumpWidget(_cardHost(AylaFavoriteResultCard(
        favorite: AylaFavoriteResultData(
          id: 1,
          targetType: AylaFavoriteTargetType.post,
          post: _post(),
        ),
        onOpen: () => opened++,
      )));
      await tester.pump();
      await tester.tap(find.text('帖子标题'));
      await tester.pump();
      expect(opened, 1);
    });

    testWidgets('live 卡：点卡片 ⇒ onOpen（tsx 42–44 / 56）', (WidgetTester tester) async {
      int opened = 0;
      await tester.pumpWidget(_cardHost(AylaFavoriteResultCard(
        favorite: const AylaFavoriteResultData(
          id: 2,
          targetType: AylaFavoriteTargetType.live,
          live: AylaLiveCardData(id: 'live-1', title: '直播间'),
        ),
        onOpen: () => opened++,
      )));
      await tester.pump();
      await tester.tap(find.text('直播间').first);
      await tester.pump();
      expect(opened, 1);
    });

    testWidgets('voice 卡：点卡片 ⇒ onOpen（tsx 45–47 / 58）', (WidgetTester tester) async {
      int opened = 0;
      await tester.pumpWidget(_cardHost(AylaFavoriteResultCard(
        favorite: const AylaFavoriteResultData(
          id: 3,
          targetType: AylaFavoriteTargetType.voice,
          voice: AylaVoiceCardData(id: 'v-1', name: '语音房'),
        ),
        onOpen: () => opened++,
      )));
      await tester.pump();
      await tester.tap(find.text('语音房').first);
      await tester.pump();
      expect(opened, 1);
    });

    testWidgets('game 卡：点卡片 ⇒ onOpen（tsx 48–50 / 60）', (WidgetTester tester) async {
      int opened = 0;
      await tester.pumpWidget(_cardHost(AylaFavoriteResultCard(
        favorite: const AylaFavoriteResultData(
          id: 4,
          targetType: AylaFavoriteTargetType.game,
          game: AylaGameCardData(id: 'g-1', name: '桌游房'),
        ),
        onOpen: () => opened++,
      )));
      await tester.pump();
      await tester.tap(find.text('桌游房').first);
      await tester.pump();
      expect(opened, 1);
    });

    testWidgets('message 卡：点正文 ⇒ onOpen（tsx 61–117，canOpen = conversationId 非空）',
        (WidgetTester tester) async {
      int opened = 0;
      await tester.pumpWidget(_cardHost(AylaFavoriteResultCard(
        favorite: AylaFavoriteResultData(
          id: 5,
          targetType: AylaFavoriteTargetType.message,
          message: _msg(),
        ),
        senderLabel: '爱莉',
        onOpen: () => opened++,
      )));
      await tester.pump();
      await tester.tap(find.text('被收藏的正文'));
      await tester.pump();
      expect(opened, 1);
    });
  });

  // ==========================================================================
  // ② 页面级 push 语义：真实 FavoritesPage + 真实 GoRouter
  //    （web tsx:285 useNavigate ⇒ navigate(to) 默认 push；tsx:36–67 openTarget）
  // ==========================================================================
  group('② 页面级跳转：push（历史栈留上一页）', () {
    GoRouter makeRouter() => GoRouter(
          initialLocation: '/favorites',
          routes: <RouteBase>[
            GoRoute(
              path: '/favorites',
              builder: (BuildContext c, GoRouterState s) =>
                  FavoritesPage(initialType: s.uri.queryParameters['type']),
            ),
            // 四条目标路由（路径形态与 app_router.dart 一致；页面本体换成可判别探针）
            GoRoute(
              path: '/posts/:postId',
              builder: (BuildContext c, GoRouterState s) =>
                  _TargetProbe(name: 'POST', id: s.pathParameters['postId'] ?? ''),
            ),
            GoRoute(
              path: '/live/:channelId',
              builder: (BuildContext c, GoRouterState s) =>
                  _TargetProbe(name: 'LIVE', id: s.pathParameters['channelId'] ?? ''),
            ),
            GoRoute(
              path: '/voice/:channelId',
              builder: (BuildContext c, GoRouterState s) =>
                  _TargetProbe(name: 'VOICE', id: s.pathParameters['channelId'] ?? ''),
            ),
            GoRoute(
              path: '/games/:roomId',
              builder: (BuildContext c, GoRouterState s) =>
                  _TargetProbe(name: 'GAME', id: s.pathParameters['roomId'] ?? ''),
            ),
            GoRoute(
              path: '/chat/:conversationId',
              builder: (BuildContext c, GoRouterState s) => _TargetProbe(
                name: 'CHAT',
                id: s.pathParameters['conversationId'] ?? '',
                query: s.uri.query,
              ),
            ),
          ],
        );

    Future<GoRouter> mount(
      WidgetTester tester,
      ProviderContainer container,
      List<AylaFavoriteEntry> rows,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      container.read(authNotifierProvider.notifier).setUser(_me);
      aylaFavoritesPageLoader = (String? cursor) async =>
          AylaDirectoryPage<AylaFavoriteEntry>(results: rows, total: rows.length);
      final GoRouter router = makeRouter();
      addTearDown(router.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(theme: buildAylaTheme(), routerConfig: router),
      ));
      await _settle(tester);
      return router;
    }

    testWidgets('帖卡 ⇒ /posts/<id> 且 canPop（旧 context.go 会替换掉收藏页）',
        (WidgetTester tester) async {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      final GoRouter router = await mount(tester, container, <AylaFavoriteEntry>[
        _entry(type: AylaFavoriteTargetType.post, targetId: '106', post: _post()),
      ]);
      expect(router.state.uri.path, '/favorites');

      await tester.tap(find.text('帖子标题').first);
      await _settle(tester);

      expect(router.state.uri.path, '/posts/106',
          reason: 'tsx:39–41 openTarget：post → /posts/{target_id}');
      expect(router.canPop(), isTrue,
          reason: 'tsx:285 navigate = push（可返回上一页）；旧 context.go 替换路由后 canPop 为假');
      router.pop();
      await _settle(tester);
      expect(router.state.uri.path, '/favorites', reason: '返回必须回到收藏页');
    });

    /// live / voice / game 三类逐条跑（各自独立的 widget 树）。
    ///
    /// [cardType] 用来把点击**限定在卡片内**的文本上 —— 收藏页页签筛选条里也有
    /// 「语音房 / 桌游房」同名文本（web `FavoritesPage.tsx:19–26` 的六个分类），
    /// 点它会走 `_onFilterChange` 而不是 `openTarget`。
    Future<void> runCard(
      WidgetTester tester, {
      required AylaFavoriteTargetType type,
      required String path,
      required String label,
      required Type cardType,
    }) async {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      final GoRouter router = await mount(tester, container, <AylaFavoriteEntry>[
        _entry(type: type, targetId: path.split('/').last),
      ]);
      // ⚠️ 必须点**卡片内**的那一个「语音房/桌游房」：页签筛选条里也有同名文本
      // （web FavoritesPage.tsx:19–26 的六个分类），点它会走 `_onFilterChange`
      // ⇒ URL 变成 `/favorites?type=...`，测试就测不到 openTarget 了。
      final Finder cardText = find.descendant(
        of: find.byType(cardType),
        matching: find.text(label),
      );
      expect(cardText, findsOneWidget, reason: '收藏卡必须渲染出「$label」');
      await tester.tap(cardText);
      await _settle(tester);
      expect(router.state.uri.path, path,
          reason: 'web openTarget 的 ${type.name} 分支');
      expect(router.canPop(), isTrue, reason: 'push 语义（web navigate）');
    }

    testWidgets('live 卡 ⇒ /live/<id> 且 push', (WidgetTester tester) async {
      await runCard(tester,
          type: AylaFavoriteTargetType.live,
          path: '/live/live-1',
          label: '直播间',
          cardType: AylaLiveChannelCard);
    });

    testWidgets('voice 卡 ⇒ /voice/<id> 且 push', (WidgetTester tester) async {
      await runCard(tester,
          type: AylaFavoriteTargetType.voice,
          path: '/voice/v-1',
          label: '语音房',
          cardType: AylaVoiceChannelCard);
    });

    testWidgets('game 卡 ⇒ /games/<id> 且 push', (WidgetTester tester) async {
      await runCard(tester,
          type: AylaFavoriteTargetType.game,
          path: '/games/g-1',
          label: '桌游房',
          cardType: AylaGameRoomCard);
    });

    testWidgets('消息卡 ⇒ /chat/<conv>?msg=&seq=&subgroup= 且 push', (WidgetTester tester) async {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      final GoRouter router = await mount(tester, container, <AylaFavoriteEntry>[
        _entry(
          type: AylaFavoriteTargetType.message,
          targetId: 'm1',
          message: _msg(id: 'm1', conversationId: 'c1', seq: 7, subgroupId: 'sg-a'),
        ),
      ]);
      await tester.tap(find.text('被收藏的正文'));
      await _settle(tester);

      expect(router.state.uri.path, '/chat/c1');
      expect(router.state.uri.queryParameters, <String, String>{
        'msg': 'm1',
        'seq': '7',
        'subgroup': 'sg-a',
      });
      expect(router.canPop(), isTrue, reason: 'push 语义');
    });
  });

  // ==========================================================================
  // ③ 消息 query 拼装规则（web tsx:53–64）
  // ==========================================================================
  group('③ 消息 query 拼装（msg / seq>0 / subgroup 非空）', () {
    Future<Uri> tapMessage(
      WidgetTester tester, {
      required String id,
      required int seq,
      String? subgroupId,
      String conversationId = 'c1',
    }) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(authNotifierProvider.notifier).setUser(_me);
      aylaFavoritesPageLoader = (String? cursor) async =>
          AylaDirectoryPage<AylaFavoriteEntry>(
            results: <AylaFavoriteEntry>[
              _entry(
                type: AylaFavoriteTargetType.message,
                targetId: id,
                message: _msg(
                  id: id,
                  conversationId: conversationId,
                  seq: seq,
                  subgroupId: subgroupId,
                ),
              ),
            ],
            total: 1,
          );
      final GoRouter router = GoRouter(
        initialLocation: '/favorites',
        routes: <RouteBase>[
          GoRoute(
            path: '/favorites',
            builder: (BuildContext c, GoRouterState s) =>
                FavoritesPage(initialType: s.uri.queryParameters['type']),
          ),
          GoRoute(
            path: '/chat/:conversationId',
            builder: (BuildContext c, GoRouterState s) => const Scaffold(
              body: Center(child: Text('CHAT-TARGET')),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(theme: buildAylaTheme(), routerConfig: router),
      ));
      await _settle(tester);
      await tester.tap(find.text('被收藏的正文'));
      await _settle(tester);
      return router.state.uri;
    }

    testWidgets('三参数齐全 ⇒ msg & seq & subgroup 全带', (WidgetTester tester) async {
      final Uri uri = await tapMessage(tester, id: 'm1', seq: 7, subgroupId: 'sg-a');
      expect(uri.path, '/chat/c1');
      expect(uri.queryParameters['msg'], 'm1'); // tsx 59
      expect(uri.queryParameters['seq'], '7'); // tsx 60
      expect(uri.queryParameters['subgroup'], 'sg-a'); // tsx 61
    });

    testWidgets('seq = 0 ⇒ 不带 seq；subgroup 为 null ⇒ 不带', (WidgetTester tester) async {
      final Uri uri = await tapMessage(tester, id: 'm1', seq: 0, subgroupId: null);
      expect(uri.queryParameters.containsKey('seq'), isFalse,
          reason: 'web tsx:60 「typeof target.seq === number && target.seq > 0」才带');
      expect(uri.queryParameters.containsKey('subgroup'), isFalse,
          reason: 'web tsx:61 非空才带');
      expect(uri.queryParameters['msg'], 'm1');
    });

    testWidgets('subgroup 为空串 ⇒ 不带（web 非空判定）', (WidgetTester tester) async {
      final Uri uri = await tapMessage(tester, id: 'm1', seq: 3, subgroupId: '');
      expect(uri.queryParameters.containsKey('subgroup'), isFalse);
      expect(uri.queryParameters['seq'], '3');
    });

    testWidgets('msg id 为空 ⇒ 不带 msg（web tsx:59 的非空判定）', (WidgetTester tester) async {
      final Uri uri = await tapMessage(tester, id: '', seq: 3, subgroupId: 'sg-a');
      expect(uri.queryParameters.containsKey('msg'), isFalse,
          reason: 'web tsx:59 「typeof target.id === string && target.id」才带');
      expect(uri.queryParameters['seq'], '3');
      expect(uri.queryParameters['subgroup'], 'sg-a');
    });

    testWidgets('conversation_id 为空 ⇒ 不跳转（web tsx:54 break）', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(authNotifierProvider.notifier).setUser(_me);
      aylaFavoritesPageLoader = (String? cursor) async =>
          AylaDirectoryPage<AylaFavoriteEntry>(
            results: <AylaFavoriteEntry>[
              _entry(
                type: AylaFavoriteTargetType.message,
                targetId: 'm1',
                message: _msg(conversationId: ''),
              ),
            ],
            total: 1,
          );
      final GoRouter router = GoRouter(
        initialLocation: '/favorites',
        routes: <RouteBase>[
          GoRoute(
            path: '/favorites',
            builder: (BuildContext c, GoRouterState s) =>
                FavoritesPage(initialType: s.uri.queryParameters['type']),
          ),
          GoRoute(
            path: '/chat/:conversationId',
            builder: (BuildContext c, GoRouterState s) => const Scaffold(
              body: Center(child: Text('CHAT-TARGET')),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(theme: buildAylaTheme(), routerConfig: router),
      ));
      await _settle(tester);
      await tester.tap(find.text('被收藏的正文'));
      await _settle(tester);
      expect(router.state.uri.path, '/favorites', reason: '无会话 id ⇒ 不跳（web break）');
    });
  });

  // ==========================================================================
  // ④ 作者头像点击（web PostCard.tsx:70–79 + utils/navigation.ts:24–35）
  // ==========================================================================
  group('④ 收藏帖卡作者头像 → onAuthorTap', () {
    testWidgets('组件层：onAuthorTap 被调用且不触发 onOpen', (WidgetTester tester) async {
      int authorTaps = 0;
      int opens = 0;
      await tester.pumpWidget(_cardHost(AylaFavoriteResultCard(
        favorite: AylaFavoriteResultData(
          id: 1,
          targetType: AylaFavoriteTargetType.post,
          post: _post(),
        ),
        onOpen: () => opens++,
        onAuthorTap: () => authorTaps++,
      )));
      await tester.pump();
      expect(find.byType(AylaAvatarHalo), findsOneWidget);
      await tester.tap(find.byType(AylaAvatarHalo));
      await tester.pump();
      expect(authorTaps, 1, reason: 'web PostCard.tsx:75–78 头像 onClick');
      expect(opens, 0, reason: 'web 头像 onClick 里 stopPropagation ⇒ 不触发整卡 onOpen');
    });

    testWidgets('页面层：他人作者 ⇒ /user/<id>（push）', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(authNotifierProvider.notifier).setUser(_me);
      aylaFavoritesPageLoader = (String? cursor) async =>
          AylaDirectoryPage<AylaFavoriteEntry>(
            results: <AylaFavoriteEntry>[
              _entry(
                type: AylaFavoriteTargetType.post,
                targetId: '106',
                post: _post(authorId: 'u-2'),
              ),
            ],
            total: 1,
          );
      final GoRouter router = GoRouter(
        initialLocation: '/favorites',
        routes: <RouteBase>[
          GoRoute(
            path: '/favorites',
            builder: (BuildContext c, GoRouterState s) =>
                FavoritesPage(initialType: s.uri.queryParameters['type']),
          ),
          GoRoute(
            path: '/user/:userId',
            builder: (BuildContext c, GoRouterState s) =>
                _TargetProbe(name: 'USER', id: s.pathParameters['userId'] ?? ''),
          ),
          GoRoute(
            path: '/profile',
            builder: (BuildContext c, GoRouterState s) =>
                const Scaffold(body: Center(child: Text('PROFILE-TARGET'))),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(theme: buildAylaTheme(), routerConfig: router),
      ));
      await _settle(tester);
      await tester.tap(find.byType(AylaAvatarHalo));
      await _settle(tester);
      expect(router.state.uri.path, '/user/u-2',
          reason: 'web goUserProfile：他人 → /user/<encodeURIComponent(id)>');
      expect(router.canPop(), isTrue, reason: 'navigateTo = push');
    });

    testWidgets('页面层：作者就是自己 ⇒ /profile', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(authNotifierProvider.notifier).setUser(_me);
      aylaFavoritesPageLoader = (String? cursor) async =>
          AylaDirectoryPage<AylaFavoriteEntry>(
            results: <AylaFavoriteEntry>[
              _entry(
                type: AylaFavoriteTargetType.post,
                targetId: '106',
                post: _post(authorId: 'me'), // = 当前登录用户
              ),
            ],
            total: 1,
          );
      final GoRouter router = GoRouter(
        initialLocation: '/favorites',
        routes: <RouteBase>[
          GoRoute(
            path: '/favorites',
            builder: (BuildContext c, GoRouterState s) =>
                FavoritesPage(initialType: s.uri.queryParameters['type']),
          ),
          GoRoute(
            path: '/user/:userId',
            builder: (BuildContext c, GoRouterState s) =>
                const Scaffold(body: Center(child: Text('USER-TARGET'))),
          ),
          GoRoute(
            path: '/profile',
            builder: (BuildContext c, GoRouterState s) =>
                const Scaffold(body: Center(child: Text('PROFILE-TARGET'))),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(theme: buildAylaTheme(), routerConfig: router),
      ));
      await _settle(tester);
      await tester.tap(find.byType(AylaAvatarHalo));
      await _settle(tester);
      expect(router.state.uri.path, '/profile',
          reason: 'web goUserProfile：currentUserId === targetUserId ⇒ /profile');
    });
  });

  // ==========================================================================
  // ⑤ 消息定位链路（web MessageList.tsx:785–818）
  // ==========================================================================
  group('⑤ 外部跳转：目标不在首屏 + 带 seq ⇒ 补页后命中', () {
    List<AylaChatMessage> page({int count = 20, int start = 1}) => <AylaChatMessage>[
          for (int i = start; i < start + count; i++)
            AylaChatMessage(
              id: 'm$i',
              conversationId: 'c1',
              senderId: 'u1',
              type: AylaMessageType.text,
              status: AylaMessageStatus.sent,
              content: '第 $i 条 占位内容占位内容占位内容占位内容',
              seq: i,
              createdAt: '2026-10-21T12:00:00Z',
            ),
        ];

    Widget host(AylaMessageList list) => MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 500, height: 600, child: list),
          ),
        );

    testWidgets('S1 目标 id 不在列表但 seq 命中 ⇒ 按 seq 找到并滚动（web tsx:797 findBySeq 兜底）',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(500, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // 收藏投影记的是旧 id（'old-id'），消息面里同一 seq 的消息 id 已变 ⇒ 只能按 seq 命中
      await tester.pumpWidget(host(AylaMessageList(
        messages: page(),
        currentUserId: 'me',
        externalJump: (messageId: 'old-id', seq: 5),
        onMarkRead: (AylaChatMessage m, bool exact) async {},
      )));
      await _settle(tester, frames: 10);
      // 命中判据：目标行必须被滚进视口（未命中时列表停在初始位置、首屏只有尾部若干条）
      expect(find.textContaining('第 5 条'), findsOneWidget,
          reason: 'web tsx:797 「?? findBySeq(seq)」：按 seq 命中后滚到目标');
    });

    testWidgets('S2 目标不在首屏 + seq>0 ⇒ onLoadUntilSeq 被调用一次（web tsx:803–817）',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(500, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final List<int> asked = <int>[];
      await tester.pumpWidget(host(AylaMessageList(
        messages: page(),
        currentUserId: 'me',
        externalJump: (messageId: 'm40', seq: 40),
        onLoadUntilSeq: (int seq) async {
          asked.add(seq);
          return true;
        },
        onMarkRead: (AylaChatMessage m, bool exact) async {},
      )));
      await _settle(tester, frames: 12);
      expect(asked, <int>[40],
          reason: 'web tsx:803「externalJump.seq > 0 && onLoadUntilSeq」⇒ 按 seq 补页（jumpLoadRef 只发一次）');
    });

    testWidgets('S3 补页成功 + 父级用新数据重建 ⇒ 命中并定位到目标（web tsx:809–813）',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(500, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      List<AylaChatMessage> current = page();
      late StateSetter setHost;
      int handled = 0;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              setHost = setState;
              return SizedBox(
                width: 500,
                height: 600,
                child: AylaMessageList(
                  messages: current,
                  currentUserId: 'me',
                  externalJump: (messageId: 'm40', seq: 40),
                  onLoadUntilSeq: (int seq) async {
                    // 让出一个异步周期：生产里 onLoadUntilSeq 是 await 网络请求
                    // （`AylaConversationRuntime.loadUntilSeq` → `loadMore`），
                    // 天然不在首帧构建期回调；这里模拟同一时序，让父级 setState 落在
                    // 构建之外（本件在帧后触发外部跳转，见 message_list.dart 的 initState）。
                    await Future<void>.delayed(const Duration(milliseconds: 1));
                    // 父级补页后把新数据传给子件（等价生产里 runtime 写 store ⇒ 页面 rebuild）
                    current = page(count: 40);
                    setHost(() {});
                    return true;
                  },
                  onExternalJumpHandled: () => handled++,
                  onMarkRead: (AylaChatMessage m, bool exact) async {},
                ),
              );
            },
          ),
        ),
      ));
      await _settle(tester, frames: 24);

      expect(handled, 1, reason: 'web tsx:799 handledJumpRef.current = key（命中后置位）');
      expect(find.textContaining('第 40 条'), findsOneWidget,
          reason: '补页后必须定位到目标消息（web tsx:809–813 findBySeq + jumpToMessage）');
    });

    testWidgets('S4 seq = 0 且目标不在列表 ⇒ 不调用 onLoadUntilSeq（web tsx:803 门槛）',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(500, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      int calls = 0;
      await tester.pumpWidget(host(AylaMessageList(
        messages: page(),
        currentUserId: 'me',
        externalJump: (messageId: 'ghost', seq: 0),
        onLoadUntilSeq: (int seq) async {
          calls++;
          return true;
        },
        onMarkRead: (AylaChatMessage m, bool exact) async {},
      )));
      await _settle(tester, frames: 10);
      expect(calls, 0, reason: 'web tsx:803「externalJump.seq > 0」才补页');
    });
  });
}
