/// **帖子列表页**（一级 /posts）WS 热更新回归锁 —— 用户实报的「帖子列表页没有 ws 热更新」。
///
/// ## 事实源
/// web `pages/PostsHubPage.tsx:232–262` 在页面内 `chatWS.onFrame(...)`：
/// - `post.deleted`（`:234–243`）：从**本账号全部 tab 的缓存**里过滤该条 + 当前 tab；
/// - `post.created`（`:245–261`）：拉 REST 详情后 upsert（帧只带简化字段）。
///
/// ⚠️ **帖子域与目录域不同**：一级帖子页读的是**页面私有的** `postTabPages`
/// （`PostsHubPage.tsx:77 / 98–101`），不是 `usePostsStore` ⇒ web **自己也必须**在
/// 本页订阅帧。这是 web 的原样结构，不是偏离。
///
/// ## 本文件锁什么
/// 1. `AylaPostTabCache.removeFromAllTabs`（web :237–241 的等价物）；
/// 2. 页面 `_onFrame` 的删除分支经**真实 chat WS 分发**到达页面 ⇒ 当前 tab 立即摘除。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/directory_page.dart';
import '../lib/core/models/post.dart';
import '../lib/core/ws/chat_ws.dart';
import '../lib/pages/posts_hub_page.dart';
import '../lib/state/chat_providers.dart' show chatWsProvider;
import '../lib/state/posts_store.dart';
import '../lib/state/paged_list.dart';
import '../lib/theme/preview_theme.dart';

AylaPost _post(int id) => AylaPost(id: id, title: '帖子 $id', body: '正文');

Widget _host(Widget child, {Size viewport = const Size(1440, 900)}) =>
    ProviderScope(
      child: MaterialApp(
        home: Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: previewScope(child),
          ),
        ),
      ),
    );

void main() {
  setUp(() {
    aylaPostTabCache.clear();
    aylaPostsStore.reset();
    aylaPostTabCache.requestOverride = (String? cursor) async =>
        AylaDirectoryPage<AylaPost>(
      results: <AylaPost>[_post(1), _post(2)],
      total: 2,
    );
  });

  tearDown(() {
    aylaPostTabCache.requestOverride = null;
    aylaPostTabCache.clear();
    aylaPostsStore.reset();
  });

  group('AylaPostTabCache.removeFromAllTabs（web PostsHubPage.tsx:237–241）', () {
    test('从**全部 tab** 的已加载投影里摘掉该条（避免切回旧 tab 时复活）', () async {
      final AylaPagedList<AylaPost> a = aylaPostTabCache.acquire(
        'posts:u1:all',
        create: () => AylaPagedList<AylaPost>(
          request: (String? c) async =>
              AylaDirectoryPage<AylaPost>(results: <AylaPost>[_post(1), _post(2)]),
          keyOf: (AylaPost p) => p.id.toString(),
        ),
      );
      await a.load();
      final AylaPagedList<AylaPost> b = aylaPostTabCache.acquire(
        'posts:u1:mine',
        create: () => AylaPagedList<AylaPost>(
          request: (String? c) async =>
              AylaDirectoryPage<AylaPost>(results: <AylaPost>[_post(1), _post(3)]),
          keyOf: (AylaPost p) => p.id.toString(),
        ),
      );
      await b.load();
      expect(a.items.length, 2);
      expect(b.items.length, 2);

      aylaPostTabCache.removeFromAllTabs(1);
      expect(a.items.map((AylaPost p) => p.id), <int>[2]);
      expect(b.items.map((AylaPost p) => p.id), <int>[3],
          reason: '非当前 tab 也要摘（web 的 for 循环遍历全部 posts:{account}: 键）');
    });

    test('未命中的 id ⇒ 不动（不整表重建、不误删）', () async {
      final AylaPagedList<AylaPost> a = aylaPostTabCache.acquire(
        'posts:u1:all',
        create: () => AylaPagedList<AylaPost>(
          request: (String? c) async =>
              AylaDirectoryPage<AylaPost>(results: <AylaPost>[_post(1)]),
          keyOf: (AylaPost p) => p.id.toString(),
        ),
      );
      await a.load();
      final AylaPost before = a.items.first;
      aylaPostTabCache.removeFromAllTabs(99);
      expect(identical(a.items.first, before), isTrue);
    });
  });

  group('PostsHubPage：帧到达后列表立即反映（零手动刷新）', () {
    testWidgets('post.deleted 经真实 chat WS 分发 ⇒ 列表立即摘掉该条',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Builder(
              builder: (BuildContext context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(size: const Size(1440, 900)),
                child: previewScope(const PostsHubPage()),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('帖子 1'), findsOneWidget);
      expect(find.text('帖子 2'), findsOneWidget);

      // ★ 帧：真实 chat WS 分发路径（页面在 initState 里挂了 `chat.onFrame`）。
      container.read(chatWsProvider).debugHandleFrame(<String, dynamic>{
        'type': 'post.deleted',
        'post_id': 1,
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('帖子 1'), findsNothing,
          reason: '删除帧 ⇒ 列表**立即**摘除（这是「帖子列表页没有热更新」的修复判据）');
      expect(find.text('帖子 2'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('post.deleted ⇒ 缓存也同步摘除（切 tab 回来不复活）',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Builder(
              builder: (BuildContext context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(size: const Size(1440, 900)),
                child: previewScope(const PostsHubPage()),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      container.read(chatWsProvider).debugHandleFrame(<String, dynamic>{
        'type': 'post.deleted',
        'post_id': 2,
      });
      await tester.pump();
      final AylaPagedList<AylaPost>? cached = aylaPostTabCache
          .pagerOf(AylaPostTabCache.keyFor(account: 'anonymous', filter: 'all'));
      expect(cached, isNotNull);
      expect(cached!.items.map((AylaPost p) => p.id), isNot(contains(2)),
          reason: 'web :238–241 —— 全部 tab 缓存都要摘（含当前 tab）');
      await tester.pumpAndSettle();
    });
  });
}
