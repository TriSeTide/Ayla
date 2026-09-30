/// 目录 / 信息流共享 store 定向测试 —— web `stores/directory.ts` 的缓存与合并语义
/// （`vitest/directory-store.test.tsx:57–271` 同口径），并锁住用户 2026-09-30 实报的
/// 「每个页面切换都要反复加载」。
///
/// ## 事实源
/// | web | 行 | 断言 |
/// |---|---|---|
/// | `stores/directory.ts` | 274 | `initial` 在 `fetchedAt` 60 秒内**短路、不发请求** |
/// | 同上 | 273 | 同 key 在途请求合并（只发一次） |
/// | 同上 | 275 | `more` 在 `!hasMore` / 无游标时不请求 |
/// | 同上 | 321–322 | `more` 追加按条目主键去重 |
/// | 同上 | 331–334 | 失败保留 items、只写 error |
/// | `hooks/useDirectoryPage.ts` | 23 | `loading = enabled && (!record \|\| record.loading)` |
/// | `stores/posts.ts` | 146–151 | `isPostsStale` 60 秒窗口 |
///
/// 请求实现经 `AylaDirectoryStore.requestOverride` 注入（不 mock HTTP，与仓内既有约定一致）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/directory_page.dart';
import '../lib/core/api/voice_api.dart' show AylaDirectoryVoiceEntry;
import '../lib/core/models/post.dart' show AylaPost;
import '../lib/core/net/dio_client.dart' show ApiException;
import '../lib/pages/posts_hub_page.dart';
import '../lib/pages/voice_hub_page.dart';
import '../lib/state/directory_events.dart' show AylaDirectoryKind;
import '../lib/state/directory_store.dart';
import '../lib/state/posts_store.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/loading.dart' show AylaSkeleton;
import '../lib/widgets/voice/voice_channels.dart' show AylaVoiceCardData;

void main() {
  const AylaDirectoryOptions options = AylaDirectoryOptions();

  group('目录 store 缓存与合并（stores/directory.ts 273–275）', () {
    test('首次加载后续 60 秒内的 load 命中缓存、不发请求（切页面不反复加载）', () async {
      final AylaDirectoryStore store = AylaDirectoryStore();
      final List<String?> cursors = <String?>[];
      store.requestOverride = (kind, options, cursor) async {
        cursors.add(cursor);
        return AylaDirectoryPage<Object>(
          results: <Object>['a', 'b'],
          total: 2,
        );
      };

      await store.load(AylaDirectoryKind.voice, options);
      expect(cursors.length, 1);
      expect(
        store.itemsAs<String>(AylaDirectoryKind.voice, options),
        <String>['a', 'b'],
      );
      expect(store.isLoading(AylaDirectoryKind.voice, options), isFalse);

      await store.load(AylaDirectoryKind.voice, options);
      expect(cursors.length, 1, reason: '60 秒窗口内不得重复请求');
    });

    test('并发合并：同一 key 的两条在途请求只发一次（web 273）', () async {
      final AylaDirectoryStore store = AylaDirectoryStore();
      int calls = 0;
      store.requestOverride = (kind, options, cursor) async {
        calls += 1;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return AylaDirectoryPage<Object>(results: <Object>['a']);
      };

      await Future.wait(<Future<void>>[
        store.load(AylaDirectoryKind.live, options),
        store.load(AylaDirectoryKind.live, options),
      ]);
      expect(calls, 1);
    });

    test('超过 60 秒窗口后重取（kAylaDirectoryFreshWindowMs）', () async {
      final AylaDirectoryStore store = AylaDirectoryStore();
      int clock = 1000;
      store.nowMillis = () => clock;
      int calls = 0;
      store.requestOverride = (kind, options, cursor) async {
        calls += 1;
        return AylaDirectoryPage<Object>(results: <Object>['a']);
      };

      await store.load(AylaDirectoryKind.game, options);
      await store.load(AylaDirectoryKind.game, options);
      expect(calls, 1);

      clock += kAylaDirectoryFreshWindowMs + 1;
      await store.load(AylaDirectoryKind.game, options);
      expect(calls, 2);
    });

    test('refresh 绕过 60 秒缓存（下拉刷新 / 刷新键）', () async {
      final AylaDirectoryStore store = AylaDirectoryStore();
      int calls = 0;
      store.requestOverride = (kind, options, cursor) async {
        calls += 1;
        return AylaDirectoryPage<Object>(results: <Object>['a']);
      };

      await store.load(AylaDirectoryKind.voice, options);
      await store.refresh(AylaDirectoryKind.voice, options);
      expect(calls, 2);
    });
  });

  group('分页（stores/directory.ts 275 · 321–322）', () {
    test('more：游标推进 + 追加去重；无下一页时不请求', () async {
      final AylaDirectoryStore store = AylaDirectoryStore();
      final List<String?> cursors = <String?>[];
      store.requestOverride = (kind, options, cursor) async {
        cursors.add(cursor);
        if (cursor == null) {
          return AylaDirectoryPage<Object>(
            results: <Object>['a', 'b'],
            nextCursor: 'c1',
            hasMore: true,
            total: 3,
          );
        }
        return AylaDirectoryPage<Object>(results: <Object>['b', 'c'], total: 3);
      };

      await store.load(AylaDirectoryKind.voice, options);
      await store.loadMore(AylaDirectoryKind.voice, options);
      expect(cursors, <String?>[null, 'c1']);
      expect(
        store.itemsAs<String>(AylaDirectoryKind.voice, options),
        <String>['a', 'b', 'c'],
      );

      // 首页 hasMore=false ⇒ 追加短路（web 275）。
      await store.loadMore(AylaDirectoryKind.voice, options);
      expect(cursors.length, 2);
    });
  });

  group('失败与登出（stores/directory.ts 331–334 · 86）', () {
    test('请求失败：保留已加载 items，只写 error（footer 展示，不清列表）', () async {
      final AylaDirectoryStore store = AylaDirectoryStore();
      bool fail = false;
      store.requestOverride = (kind, options, cursor) async {
        if (fail) throw const ApiException(500, 'boom');
        return AylaDirectoryPage<Object>(results: <Object>['a']);
      };

      await store.load(AylaDirectoryKind.voice, options);
      fail = true;
      await store.refresh(AylaDirectoryKind.voice, options);
      expect(
        store.itemsAs<String>(AylaDirectoryKind.voice, options),
        <String>['a'],
      );
      expect(store.recordOf(AylaDirectoryKind.voice, options)?.error, 'boom');
      expect(store.isLoading(AylaDirectoryKind.voice, options), isFalse);
    });

    test('reset 清空全部记录（登出 / 会话过期）', () async {
      final AylaDirectoryStore store = AylaDirectoryStore();
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(results: <Object>['a']);
      await store.load(AylaDirectoryKind.voice, options);
      expect(store.records, isNotEmpty);
      store.reset();
      expect(store.records, isEmpty);
    });

    test('切换 userId 清空记录（数据按用户隔离）', () async {
      final AylaDirectoryStore store = AylaDirectoryStore();
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(results: <Object>['a']);
      store.userId = 'u1';
      await store.load(AylaDirectoryKind.voice, options);
      expect(store.records, isNotEmpty);
      store.userId = 'u2';
      expect(store.records, isEmpty);
    });
  });

  group('页面适配器（hooks/useDirectoryPage.ts 21–30）', () {
    test('无 record ⇒ loading；取到后 ⇒ 不 loading（切页面不闪骨架）', () async {
      final AylaDirectoryStore store = AylaDirectoryStore();
      final AylaDirectoryController<String> controller =
          AylaDirectoryController<String>(
        store: store,
        kind: AylaDirectoryKind.voice,
        options: options,
      );
      expect(controller.loading, isTrue);
      expect(controller.loaded, isFalse);

      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(results: <Object>['a']);
      await controller.load();
      expect(controller.loading, isFalse);
      expect(controller.loaded, isTrue);
      expect(controller.items, <String>['a']);
      controller.dispose();
    });

    test('两个 controller 共享同一条 record（同页多实例 / 切页复用）', () async {
      final AylaDirectoryStore store = AylaDirectoryStore();
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(results: <Object>['a']);
      final AylaDirectoryController<String> first =
          AylaDirectoryController<String>(
        store: store,
        kind: AylaDirectoryKind.game,
        options: options,
      );
      await first.load();
      final AylaDirectoryController<String> second =
          AylaDirectoryController<String>(
        store: store,
        kind: AylaDirectoryKind.game,
        options: options,
      );
      // 第二个实例进入时直接读到已有数据，不 loading、不发请求。
      expect(second.items, <String>['a']);
      expect(second.loading, isFalse);
      first.dispose();
      second.dispose();
    });
  });

  group('帖子信息流 store（stores/posts.ts 59–71 · 146–151）', () {
    test('setPage 落地后 60 秒内不过期；从未取到 / 超窗口则过期', () {
      final AylaPostsStore store = AylaPostsStore();
      expect(store.isStale(), isTrue);
      expect(store.loaded, isFalse);

      store.setPage(const <AylaPost>[], 'c1', true);
      expect(store.isStale(), isFalse);
      expect(store.loaded, isTrue);
      expect(store.nextCursor, 'c1');
      expect(store.hasMore, isTrue);
      expect(store.isStale(maxAgeMs: -1), isTrue);
    });

    test('setScope 换作用域清空列表与游标（web 71）', () {
      final AylaPostsStore store = AylaPostsStore();
      store.setPage(const <AylaPost>[], 'c1', true);
      store.setScope('mine');
      expect(store.scope, 'mine');
      expect(store.posts, isEmpty);
      expect(store.nextCursor, isNull);
      expect(store.hasMore, isFalse);
    });

    test('reset 清空（登出）', () {
      final AylaPostsStore store = AylaPostsStore();
      store.setPage(const <AylaPost>[], 'c1', true);
      store.reset();
      expect(store.loaded, isFalse);
      expect(store.scope, 'feed');
    });
  });

  group('页面级：切换页面复用缓存（用户实报「每个页面切换都要反复加载」）', () {
    setUp(() {
      aylaDirectoryStore.reset();
      aylaDirectoryStore.userId = null;
      aylaDirectoryStore.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
        results: <Object>[
          AylaDirectoryVoiceEntry(
            card: const AylaVoiceCardData(id: 'v1', name: '语音房 1'),
          ),
        ],
        total: 1,
      );
    });
    tearDown(() {
      aylaDirectoryStore.requestOverride = null;
      aylaDirectoryStore.reset();
      aylaDirectoryStore.userId = null;
    });

    Widget host(Widget child) => ProviderScope(
          child: MaterialApp(
            home: Builder(
              builder: (BuildContext context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  size: const Size(1440, 900),
                ),
                child: previewScope(child),
              ),
            ),
          ),
        );

    testWidgets('VoiceHubPage 二次进入：不发请求、不闪骨架（60 秒缓存命中）', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      int calls = 0;
      final Future<AylaDirectoryPage<Object>> Function(
        AylaDirectoryKind,
        AylaDirectoryOptions,
        String?,
      ) inner = aylaDirectoryStore.requestOverride!;
      aylaDirectoryStore.requestOverride = (kind, options, cursor) {
        calls += 1;
        return inner(kind, options, cursor);
      };

      Future<void> enter() async {
        await tester.pumpWidget(host(const VoiceHubPage()));
        await tester.pump(const Duration(milliseconds: 100));
      }

      await enter();
      expect(calls, 1, reason: '首次进入取一次');
      expect(find.byType(AylaSkeleton), findsNothing, reason: '数据已到 ⇒ 无骨架');

      // 离开页面（卸载）后再回来 —— 等价用户切走再切回。
      await tester.pumpWidget(host(const SizedBox.shrink()));
      await enter();
      expect(calls, 1, reason: '60 秒窗口内再次进入不得重复请求');
      expect(find.byType(AylaSkeleton), findsNothing, reason: '不闪骨架');
      await tester.pumpAndSettle();
    });

    testWidgets('PostsHubPage 二次进入：不发请求、不闪骨架（60 秒 tab 缓存）', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      aylaPostTabCache.clear();
      int calls = 0;
      aylaPostTabCache.requestOverride = (String? cursor) async {
        calls += 1;
        return AylaDirectoryPage<AylaPost>(
          results: <AylaPost>[AylaPost(id: 1, title: '帖子 1', body: '正文')],
          total: 1,
        );
      };
      addTearDown(() {
        aylaPostTabCache.requestOverride = null;
        aylaPostTabCache.clear();
      });

      Future<void> enter() async {
        await tester.pumpWidget(host(const PostsHubPage()));
        await tester.pump(const Duration(milliseconds: 100));
      }

      await enter();
      expect(calls, 1, reason: '首次进入取一次');
      expect(find.byType(AylaSkeleton), findsNothing, reason: '数据已到 ⇒ 无骨架');

      await tester.pumpWidget(host(const SizedBox.shrink()));
      await enter();
      expect(calls, 1, reason: 'web PostsHubPage.tsx:224 的 60 秒窗口内不得重拉');
      expect(find.byType(AylaSkeleton), findsNothing, reason: '复用 tab 缓存 ⇒ 不闪骨架');
      await tester.pumpAndSettle();
    });
  });
}
