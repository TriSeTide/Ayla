/// 社交共享 store 定向测试 —— web `stores/social.ts` 的缓存 / 合并 / 直返语义
/// （`loadSocial` 144–195），并锁住主页「不再每次进入都重新加载」。
///
/// ## 事实源
/// | web | 行 | 断言 |
/// |---|---|---|
/// | `stores/social.ts` | 148 | 未登录（无 `currentUser.id`）**不发请求、不建 record** |
/// | 同上 | 149 | 同 key 在途请求合并 |
/// | 同上 | 150 | `initial` 在 `fetchedAt` 60 秒内**短路** |
/// | 同上 | 151 | `more` 在 `!hasMore` / 无游标时不请求 |
/// | 同上 | 160–161 | 游标未推进 ⇒ **抛错**（与 directory 的静默降级不同） |
/// | 同上 | 129 | 页大小 30 |
/// | `hooks/useSocialPage.ts` | 23–24 | `loading = enabled && (!record \|\| record.loading)`；`invalidated` 恒 false |
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/directory_page.dart';
import '../lib/core/models/conversation.dart';
import '../lib/core/net/dio_client.dart' show ApiException;
import '../lib/pages/home_page.dart';
import '../lib/state/directory_store.dart';
import '../lib/state/social_store.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/loading.dart' show AylaSkeleton;

void main() {
  const AylaSocialOptions options = AylaSocialOptions(type: 'group');

  group('social store 缓存与合并（stores/social.ts 148–151）', () {
    test('未登录：不发请求、不建 record（web 148）', () async {
      final AylaSocialStore store = AylaSocialStore();
      int calls = 0;
      store.requestOverride = (kind, options, cursor) async {
        calls += 1;
        return AylaDirectoryPage<Object>(results: <Object>['a']);
      };
      await store.load(AylaSocialKind.conversations, options);
      expect(calls, 0);
      expect(store.records, isEmpty);
    });

    test('60 秒内二次 load 命中缓存、不发请求（切页面不反复加载）', () async {
      final AylaSocialStore store = AylaSocialStore();
      store.userId = 'u1';
      final List<String?> cursors = <String?>[];
      store.requestOverride = (kind, options, cursor) async {
        cursors.add(cursor);
        return AylaDirectoryPage<Object>(results: <Object>['a', 'b'], total: 2);
      };

      await store.load(AylaSocialKind.conversations, options);
      expect(cursors.length, 1);
      expect(
        store.itemsAs<String>(AylaSocialKind.conversations, options),
        <String>['a', 'b'],
      );
      expect(store.isLoading(AylaSocialKind.conversations, options), isFalse);

      await store.load(AylaSocialKind.conversations, options);
      expect(cursors.length, 1, reason: '60 秒窗口内不得重复请求');
    });

    test('超过 60 秒窗口后重取（kAylaSocialFreshWindowMs）', () async {
      final AylaSocialStore store = AylaSocialStore();
      store.userId = 'u1';
      int clock = 1000;
      store.nowMillis = () => clock;
      int calls = 0;
      store.requestOverride = (kind, options, cursor) async {
        calls += 1;
        return AylaDirectoryPage<Object>(results: <Object>['a']);
      };
      await store.load(AylaSocialKind.friends, const AylaSocialOptions());
      await store.load(AylaSocialKind.friends, const AylaSocialOptions());
      expect(calls, 1);
      clock += kAylaSocialFreshWindowMs + 1;
      await store.load(AylaSocialKind.friends, const AylaSocialOptions());
      expect(calls, 2);
    });

    test('并发合并：同一 key 的两条在途请求只发一次（web 149）', () async {
      final AylaSocialStore store = AylaSocialStore();
      store.userId = 'u1';
      int calls = 0;
      store.requestOverride = (kind, options, cursor) async {
        calls += 1;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return AylaDirectoryPage<Object>(results: <Object>['a']);
      };
      await Future.wait(<Future<void>>[
        store.load(AylaSocialKind.conversations, options),
        store.load(AylaSocialKind.conversations, options),
      ]);
      expect(calls, 1);
    });

    test('refresh 绕过 60 秒缓存', () async {
      final AylaSocialStore store = AylaSocialStore();
      store.userId = 'u1';
      int calls = 0;
      store.requestOverride = (kind, options, cursor) async {
        calls += 1;
        return AylaDirectoryPage<Object>(results: <Object>['a']);
      };
      await store.load(AylaSocialKind.conversations, options);
      await store.refresh(AylaSocialKind.conversations, options);
      expect(calls, 2);
    });

    test('切换 userId 清空记录（数据按用户隔离）', () async {
      final AylaSocialStore store = AylaSocialStore();
      store.userId = 'u1';
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(results: <Object>['a']);
      await store.load(AylaSocialKind.conversations, options);
      expect(store.records, isNotEmpty);
      store.userId = 'u2';
      expect(store.records, isEmpty);
    });
  });

  group('分页与响应校验（stores/social.ts 151 · 160–161）', () {
    test('more：游标推进 + 追加去重；无下一页时不请求', () async {
      final AylaSocialStore store = AylaSocialStore();
      store.userId = 'u1';
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
      await store.load(AylaSocialKind.friends, const AylaSocialOptions());
      await store.loadMore(AylaSocialKind.friends, const AylaSocialOptions());
      expect(cursors, <String?>[null, 'c1']);
      expect(
        store.itemsAs<String>(AylaSocialKind.friends, const AylaSocialOptions()),
        <String>['a', 'b', 'c'],
      );
      await store.loadMore(AylaSocialKind.friends, const AylaSocialOptions());
      expect(cursors.length, 2, reason: 'hasMore=false ⇒ 追加短路');
    });

    test('游标未推进 ⇒ 抛错写 error（web 160–161，与 directory 的静默降级不同）', () async {
      final AylaSocialStore store = AylaSocialStore();
      store.userId = 'u1';
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
        results: <Object>['a'],
        nextCursor: 'same',
        hasMore: true,
      );
      await store.load(AylaSocialKind.conversations, options);
      await store.loadMore(AylaSocialKind.conversations, options);
      expect(
        store.recordOf(AylaSocialKind.conversations, options)?.error,
        isNotNull,
      );
    });

    test('未接线的 kind 显式抛 UnsupportedError（不静默返回空列表）', () async {
      final AylaSocialStore store = AylaSocialStore();
      store.userId = 'u1';
      await store.load(AylaSocialKind.invites, const AylaSocialOptions());
      final AylaSocialRecord? record =
          store.recordOf(AylaSocialKind.invites, const AylaSocialOptions());
      expect(record?.error, isNotNull);
      expect(record?.loading, isFalse);
    });

    test('失败：保留已加载 items，只写 error', () async {
      final AylaSocialStore store = AylaSocialStore();
      store.userId = 'u1';
      bool fail = false;
      store.requestOverride = (kind, options, cursor) async {
        if (fail) throw const ApiException(500, 'boom');
        return AylaDirectoryPage<Object>(results: <Object>['a']);
      };
      await store.load(AylaSocialKind.conversations, options);
      fail = true;
      await store.refresh(AylaSocialKind.conversations, options);
      expect(
        store.itemsAs<String>(AylaSocialKind.conversations, options),
        <String>['a'],
      );
      expect(store.recordOf(AylaSocialKind.conversations, options)?.error, 'boom');
    });
  });

  group('页面适配器（hooks/useSocialPage.ts 22–24）', () {
    test('无 record ⇒ loading；取到后 ⇒ 不 loading（主页不闪骨架）', () async {
      final AylaSocialStore store = AylaSocialStore();
      store.userId = 'u1';
      final AylaSocialController<String> controller = AylaSocialController<String>(
        store: store,
        kind: AylaSocialKind.conversations,
        options: options,
      );
      expect(controller.loading, isTrue);
      expect(controller.loaded, isFalse);
      expect(controller.invalidated, isFalse); // web 恒 false（:24）

      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(results: <Object>['a']);
      await controller.load();
      expect(controller.loading, isFalse);
      expect(controller.loaded, isTrue);
      expect(controller.items, <String>['a']);
      controller.dispose();
    });

    test('reset 清空（登出 / 会话过期）', () async {
      final AylaSocialStore store = AylaSocialStore();
      store.userId = 'u1';
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(results: <Object>['a']);
      await store.load(AylaSocialKind.conversations, options);
      expect(store.records, isNotEmpty);
      store.reset();
      expect(store.records, isEmpty);
    });
  });

  group('页面级：主页不再每次进入都重新加载（用户实报「主页也没有单独的加载动画」）', () {
    setUp(() {
      aylaSocialStore.reset();
      aylaSocialStore.userId = 'u1';
    });
    tearDown(() {
      aylaSocialStore.requestOverride = null;
      aylaSocialStore.reset();
      aylaSocialStore.userId = null;
      aylaDirectoryStore.reset();
      aylaDirectoryStore.requestOverride = null;
    });

    Widget host(Widget child) => ProviderScope(
          child: MaterialApp(
            home: Builder(
              builder: (BuildContext context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  size: const Size(375, 720),
                ),
                child: previewScope(child),
              ),
            ),
          ),
        );

    testWidgets('HomePage 二次进入：不发请求、不闪骨架（60 秒缓存命中）', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(375, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      int calls = 0;
      aylaSocialStore.requestOverride = (kind, options, cursor) async {
        calls += 1;
        return AylaDirectoryPage<Object>(
          results: <Object>[
            AylaConversationSummary(
              id: 'g1',
              type: AylaConversationType.group,
              title: '群 1',
            ),
          ],
          total: 1,
        );
      };
      // 四份目录快照走共享 store：注入空页，避免测试环境发真实请求。
      aylaDirectoryStore.requestOverride = (kind, options, cursor) async =>
          const AylaDirectoryPage<Object>();

      Future<void> enter() async {
        await tester.pumpWidget(host(const HomePage()));
        await tester.pump(const Duration(milliseconds: 100));
      }

      await enter();
      expect(calls, 1, reason: '首次进入取一次');
      expect(find.byType(AylaSkeleton), findsNothing, reason: '数据已到 ⇒ 无骨架');
      expect(find.text('群 1'), findsOneWidget);

      await tester.pumpWidget(host(const SizedBox.shrink()));
      await enter();
      expect(calls, 1, reason: '60 秒窗口内再次进入不得重复请求');
      expect(find.byType(AylaSkeleton), findsNothing, reason: '不闪骨架');
      await tester.pumpAndSettle();
    });

    testWidgets('HomePage：预取命中 ⇒ 首帧即无骨架、不发请求（preload 的价值）', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(375, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      int calls = 0;
      aylaSocialStore.requestOverride = (kind, options, cursor) async {
        calls += 1;
        return AylaDirectoryPage<Object>(
          results: <Object>[
            AylaConversationSummary(
              id: 'g1',
              type: AylaConversationType.group,
              title: '群 1',
            ),
          ],
          total: 1,
        );
      };
      aylaDirectoryStore.requestOverride = (kind, options, cursor) async =>
          const AylaDirectoryPage<Object>();
      // 模拟 `AppInit.run()` 的预取（web `appInit.ts:35` 的 conversations{group}）。
      await aylaSocialStore.load(
        AylaSocialKind.conversations,
        const AylaSocialOptions(type: 'group'),
      );
      expect(calls, 1);

      await tester.pumpWidget(host(const HomePage()));
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls, 1, reason: '预取命中 ⇒ 页面不再请求');
      expect(find.byType(AylaSkeleton), findsNothing, reason: '首帧即无骨架');
      expect(find.text('群 1'), findsOneWidget);
      await tester.pumpAndSettle();
    });
  });
}
