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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/directory_page.dart';
import '../lib/core/models/chat_message.dart';
import '../lib/core/models/conversation.dart';
import '../lib/core/models/subgroup.dart' show AylaSubGroup;
import '../lib/core/net/dio_client.dart' show ApiException;
import '../lib/core/ws/chat_ws.dart' show AylaChatWsClient;
import '../lib/pages/group_support.dart'
    show AylaGroupActivity, aylaSortGroupsByActivity;
import '../lib/pages/home_page.dart';
import '../lib/core/models/user_public.dart' show AylaUserPublic;
import '../lib/state/badges_state.dart' show AylaBadgesController;
import '../lib/state/chat_state.dart' show AylaChatState;
import '../lib/state/directory_store.dart';
import '../lib/state/message_state.dart' show AylaMessageState;
import '../lib/state/notices_state.dart' show AylaNoticesController;
import '../lib/state/realtime_state.dart' show AylaRealtimeState;
import '../lib/state/social_store.dart';
import '../lib/state/subgroup_state.dart'
    show AylaSubGroupState, aylaSortSubgroupsByActivity;
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

  group('reconcileCached（web stores/social.ts:87–106）+ ensureSocialTracking（:108–120）', () {
    /// 一条群会话（对账的输入）。
    AylaConversationSummary conv(
      String id, {
      String title = '',
      int unread = 0,
    }) =>
        AylaConversationSummary(
          id: id,
          type: AylaConversationType.group,
          title: title.isEmpty ? id : title,
          unreadCount: unread,
        );

    AylaSocialOptions groupOptions() => const AylaSocialOptions(type: 'group');

    test('就地替换已有项 + total / mutationRevision 前进（web 103–104）', () async {
      final AylaSocialStore store = AylaSocialStore();
      store.userId = 'u1';
      final List<AylaConversationSummary> first = <AylaConversationSummary>[
        conv('g1', title: '旧名'),
        conv('g2'),
      ];
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(results: first, total: 2);
      await store.load(AylaSocialKind.conversations, groupOptions());
      final int before =
          store.recordOf(AylaSocialKind.conversations, groupOptions())!.mutationRevision;

      // 同一 id 的新实例（标题变了）—— 对账应就地替换并递增 revision。
      final AylaConversationSummary fresh = conv('g1', title: '新名');
      store.reconcileCached(
        AylaSocialKind.conversations,
        <Object>[fresh, conv('g2')],
        <Object>[...first],
      );
      final AylaSocialRecord after =
          store.recordOf(AylaSocialKind.conversations, groupOptions())!;
      expect(after.items.length, 2);
      expect((after.items.first as AylaConversationSummary).title, '新名');
      expect(after.mutationRevision, before + 1, reason: '变化 ⇒ mutationRevision + 1');
      expect(after.total, 2);
    });

    test('新增项**前插**；total + 1（web 99 / 104 的 added.length）', () async {
      final AylaSocialStore store = AylaSocialStore();
      store.userId = 'u1';
      final List<AylaConversationSummary> first = <AylaConversationSummary>[conv('g1')];
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(results: first, total: 1);
      await store.load(AylaSocialKind.conversations, groupOptions());

      store.reconcileCached(
        AylaSocialKind.conversations,
        <Object>[first.first, conv('g9')],
        <Object>[...first],
      );
      final AylaSocialRecord after =
          store.recordOf(AylaSocialKind.conversations, groupOptions())!;
      expect(
        <String>[
          for (final Object item in after.items)
            (item as AylaConversationSummary).id,
        ],
        <String>['g9', 'g1'],
        reason: 'web :103 是 [...added, ...items] —— 新增前插',
      );
      expect(after.total, 2);
    });

    test('被移除项从投影剔除；total − 1（web 93–96 / 104）', () async {
      final AylaSocialStore store = AylaSocialStore();
      store.userId = 'u1';
      final List<AylaConversationSummary> first = <AylaConversationSummary>[
        conv('g1'),
        conv('g2'),
      ];
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(results: first, total: 2);
      await store.load(AylaSocialKind.conversations, groupOptions());

      store.reconcileCached(
        AylaSocialKind.conversations,
        <Object>[first.first],
        <Object>[...first],
      );
      final AylaSocialRecord after =
          store.recordOf(AylaSocialKind.conversations, groupOptions())!;
      expect(after.items.length, 1);
      expect(after.total, 1);
    });

    test('无变化 ⇒ 短路：不递增 revision、不发通知（web 100–102）', () async {
      final AylaSocialStore store = AylaSocialStore();
      store.userId = 'u1';
      final List<AylaConversationSummary> first = <AylaConversationSummary>[conv('g1')];
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(results: first, total: 1);
      await store.load(AylaSocialKind.conversations, groupOptions());
      final int before =
          store.recordOf(AylaSocialKind.conversations, groupOptions())!.mutationRevision;
      int notifications = 0;
      store.addListener(() => notifications += 1);

      store.reconcileCached(
        AylaSocialKind.conversations,
        <Object>[first.first],
        <Object>[...first],
      );
      expect(notifications, 0, reason: 'changed === false ⇒ continue');
      expect(
        store.recordOf(AylaSocialKind.conversations, groupOptions())!.mutationRevision,
        before,
      );
    });

    test('kind 过滤：只动同 kind 的 record（web 92）', () async {
      final AylaSocialStore store = AylaSocialStore();
      store.userId = 'u1';
      store.requestOverride = (kind, options, cursor) async {
        if (kind == AylaSocialKind.friends) {
          return AylaDirectoryPage<Object>(
            results: <Object>[const AylaUserPublic(id: 'u1')],
            total: 1,
          );
        }
        return AylaDirectoryPage<Object>(results: <Object>[conv('g1')], total: 1);
      };
      await store.load(AylaSocialKind.conversations, groupOptions());
      await store.load(AylaSocialKind.friends, const AylaSocialOptions());
      final int friendRevision = store
          .recordOf(AylaSocialKind.friends, const AylaSocialOptions())!
          .mutationRevision;

      store.reconcileCached(
        AylaSocialKind.conversations,
        <Object>[conv('g1'), conv('g2')],
        <Object>[conv('g1')],
      );
      expect(
        store
            .recordOf(AylaSocialKind.friends, const AylaSocialOptions())!
            .mutationRevision,
        friendRevision,
        reason: 'friends record 不得被动',
      );
    });

    test('tracking：chatState 变化 ⇒ 一条通知内完成对账（web :114–116）', () {
      final AylaSocialStore store = AylaSocialStore();
      store.userId = 'u1';
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
            results: <Object>[conv('g1', title: '旧名')],
            total: 1,
          );
      final AylaChatState chat = AylaChatState();
      final AylaSubGroupState subgroups = AylaSubGroupState();
      final AylaSocialTracking tracking = AylaSocialTracking(store: store);
      tracking.bind(chatState: chat, subgroupState: subgroups);
      addTearDown(tracking.dispose);

      // 先落一条 record（对账的 before/after 都基于 chatState 的列表）。
      return store
          .load(AylaSocialKind.conversations, groupOptions())
          .then((_) {
        chat.setConversations(<AylaConversationSummary>[conv('g1', title: '新名')]);
        final AylaSocialRecord after =
            store.recordOf(AylaSocialKind.conversations, groupOptions())!;
        expect((after.items.first as AylaConversationSummary).title, '新名');
        expect(after.mutationRevision, 1);
      });
    });

    test('tracking：同列表内容再通知一次 ⇒ 不重复对账（幂等）', () {
      final AylaSocialStore store = AylaSocialStore();
      store.userId = 'u1';
      final AylaChatState chat = AylaChatState();
      final AylaSubGroupState subgroups = AylaSubGroupState();
      final AylaSocialTracking tracking = AylaSocialTracking(store: store);
      tracking.bind(chatState: chat, subgroupState: subgroups);
      addTearDown(tracking.dispose);
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(results: <Object>[conv('g1')], total: 1);

      return store.load(AylaSocialKind.conversations, groupOptions()).then((_) {
        chat.setConversations(<AylaConversationSummary>[conv('g1', title: 'A')]);
        expect(
          store.recordOf(AylaSocialKind.conversations, groupOptions())!.mutationRevision,
          1,
        );
        // 同样的值再写一次（`AylaChatState.setConversations` 的 `same && isNotEmpty` 短路
        // 会直接 return；这里用 bump 触发一次 notify 但**内容不变**的路径）。
        chat.bumpGroupActivity('不存在的群', 123);
        expect(
          store.recordOf(AylaSocialKind.conversations, groupOptions())!.mutationRevision,
          1,
          reason: '逐项身份比较命中 ⇒ 不重复对账',
        );
      });
    });
  });

  group('tombstone：本地删除不被在途响应灌回（web :79–81 / 154 / 163）', () {
    AylaConversationSummary row(String id) => AylaConversationSummary(
          id: id,
          type: AylaConversationType.group,
          title: id,
        );

    test('setItems 移除的条目不会被同 key 的在途分页重新写入', () async {
      const AylaSocialOptions options = AylaSocialOptions(type: 'group');
      final AylaSocialStore store = AylaSocialStore();
      store.userId = 'u1';
      // ① 先落一页（record 里有 g1）。
      store.requestOverride = (kind, opt, cursor) async =>
          AylaDirectoryPage<Object>(results: <Object>[row('g1')], total: 1);
      await store.load(AylaSocialKind.conversations, options);
      expect(store.recordOf(AylaSocialKind.conversations, options)!.items.length, 1);

      // ② 再起一次 refresh，把它卡在在途。
      final Completer<AylaDirectoryPage<Object>> gate =
          Completer<AylaDirectoryPage<Object>>();
      store.requestOverride = (kind, opt, cursor) => gate.future;
      final Future<void> loading =
          store.refresh(AylaSocialKind.conversations, options);

      // ③ 在途期间本地显式移除 g1（web `updateSocialItems` ⇒ 写 tombstone，:79–81）。
      store.setItems(
        AylaSocialKind.conversations,
        options,
        <Object>[],
      );

      // ④ 在途响应仍然带着 g1 —— tombstone 必须把它滤掉（web :163）。
      gate.complete(
        AylaDirectoryPage<Object>(results: <Object>[row('g1')], total: 1),
      );
      await loading;
      expect(
        store.recordOf(AylaSocialKind.conversations, options)!.items,
        isEmpty,
        reason: '被本地删掉的 id 不得由在途响应灌回（web :154/163 的 deleted 过滤）',
      );
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

  // ==========================================================================
  // 端到端回归锁：**生产装配顺序**灌数据，断言真实链路结果
  // ==========================================================================
  //
  // ⚠️ 为什么不能只测纯函数（上一轮的实际事故）：aylaSortGroupsByActivity 上一轮
  // 已被证明是对的，但真实链路是**断的** —— social.load() 不回写 chatState ⇒
  // chat_ws 的 if (conv != null) 恒假 ⇒ 发消息不 bump ⇒ 排序不动。
  // 因此本组严格按生产装配顺序：
  //   AylaSocialTracking.bind() + bindRehydration()（= chat_providers.dart 的装配）
  //   → socialStore.load()（= app_preload.dart 的预取）
  //   → AylaChatWsClient.debugHandleFrame(message.new)（= 真实 WS 帧）
  //   → 断言 chatState.byId(id) != null 且**排序结果真的变了**。
  group('端到端：social.load 回流 → WS 帧 → 排序（web stores/social.ts:170-181）', () {
    late AylaSocialStore store;
    late AylaChatState chat;
    late AylaSubGroupState subgroups;
    late AylaSocialTracking tracking;
    late AylaChatWsClient ws;

    AylaConversationSummary group(String id) => AylaConversationSummary(
          id: id,
          type: AylaConversationType.group,
          title: '群$id',
          isPinned: false,
        );

    /// web groupActivity.ts:171-177 的 at 取值（消息时间 vs groupActivityAt 取大，
    /// 与 home_support.dart:249-266 的生产合并口径同源）。
    int activityOf(AylaConversationSummary c) {
      final int fromMessage = c.lastMessage == null
          ? 0
          : (DateTime.tryParse(c.lastMessage!.createdAt ?? '')
                  ?.millisecondsSinceEpoch ??
              0);
      final int bumped = chat.groupActivityAt[c.id] ?? 0;
      return fromMessage > bumped ? fromMessage : bumped;
    }

    /// 生产口径的排序（web GroupPage.tsx:205-209）—— 置顶判据由
    /// aylaSortGroupsByActivity 内部读会话行的 isPinned（group_support.dart:298）。
    List<String> order() => aylaSortGroupsByActivity(
          chat.conversations,
          (AylaConversationSummary c) =>
              AylaGroupActivity(lastNewAt: activityOf(c)),
        ).map((AylaConversationSummary c) => c.id).toList();

    setUp(() {
      store = AylaSocialStore()..userId = 'u1';
      chat = AylaChatState();
      subgroups = AylaSubGroupState();
      // 生产装配：chat_providers.dart 的 socialTrackingProvider 同时做这两件事。
      tracking = AylaSocialTracking(store: store)
        ..bind(chatState: chat, subgroupState: subgroups)
        ..bindRehydration(chatState: chat, subgroupState: subgroups);
      ws = AylaChatWsClient(
        chatState: chat,
        messageState: AylaMessageState(),
        notices: AylaNoticesController(),
        badges: AylaBadgesController(),
        realtime: AylaRealtimeState(),
        subgroupState: subgroups,
        currentUserId: () => 'u1',
        autoReconcile: false,
      );
    });

    tearDown(() {
      ws.disconnect();
      tracking.dispose();
      store.dispose();
      chat.dispose();
      subgroups.dispose();
    });

    test('load(conversations) 后 chatState 就有该会话（根因 A 的直接锁）', () async {
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
            results: <Object>[group('g1'), group('g2')],
            total: 2,
          );

      await store.load(AylaSocialKind.conversations,
          const AylaSocialOptions(type: 'group'));

      expect(chat.byId('g1'), isNotNull,
          reason: 'web :172 的 upsertConversation 回流 —— 没有它 chat_ws 门控恒假');
      expect(chat.byId('g2'), isNotNull);
      expect(chat.conversations.length, 2);
    });

    test('第 2 页新群：load(more) 之后新群也进 chatState（不是只有第 1 页）', () async {
      int call = 0;
      store.requestOverride = (kind, options, cursor) async {
        call += 1;
        if (call == 1) {
          return AylaDirectoryPage<Object>(
            results: <Object>[group('g1')],
            total: 2,
            hasMore: true,
            nextCursor: 'c1',
          );
        }
        return AylaDirectoryPage<Object>(results: <Object>[group('g2')], total: 2);
      };
      await store.load(AylaSocialKind.conversations,
          const AylaSocialOptions(type: 'group'));
      expect(chat.byId('g2'), isNull);

      await store.load(AylaSocialKind.conversations,
          const AylaSocialOptions(type: 'group'), mode: AylaSocialMode.more);

      expect(chat.byId('g2'), isNotNull,
          reason: '第 2 页 / 新群 / 别处刷新 —— 正是「social 有、chatState 没有」');
    });

    test('端到端：回流缺失 ⇒ 帧不排上去；回流接上 ⇒ 排上去（用户验收口径）', () async {
      // 对照组：**不接回流**的 store（等价于 A 未修时的生产状态）。
      final AylaSocialStore legacy = AylaSocialStore()..userId = 'u1';
      legacy.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
            results: <Object>[group('g1'), group('g2')],
            total: 2,
          );
      await legacy.load(AylaSocialKind.conversations,
          const AylaSocialOptions(type: 'group'));
      expect(chat.byId('g1'), isNull,
          reason: '未接回流 ⇒ chatState 空（上一轮的断裂点）');

      // 生产路径：接回流的 store（= chat_providers.dart 的装配）。
      store.requestOverride = legacy.requestOverride;
      await store.load(AylaSocialKind.conversations,
          const AylaSocialOptions(type: 'group'));
      expect(chat.byId('g1'), isNotNull, reason: 'web :172 回流生效');

      // g2 先有活动 ⇒ 排序基线上 g2 在前。
      chat.bumpGroupActivity('g2', 1000);
      expect(order().first, 'g2');

      // 真实 WS 帧：**在 g1 里发一条消息**（用户实报的场景）。
      ws.debugHandleFrame(<String, dynamic>{
        'type': 'message.new',
        'data': <String, dynamic>{
          'conversation_id': 'g1',
          'message_id': 'm1',
          'sender_id': 'u2',
          'content': '发一条',
          'type': 'text',
          'media': null,
          'reply_to': null,
          'seq': 900,
          'ts': '2026-10-01T00:00:01Z',
        },
      });

      expect(chat.byId('g1')!.lastMessage?.content, '发一条',
          reason: 'chat_ws.dart:657 setLastMessage（门控命中才会有）');
      expect(chat.groupActivityAt['g1'], isNotNull,
          reason: 'chat_ws.dart:671 bumpGroupActivity（门控命中才会有）');
      expect(order().first, 'g1',
          reason: '★ 验收口径：发消息后 g1 必须排到最前，不是纯函数返回值');

      legacy.dispose();
    });

    test('未接回流回调时 load 不报错（纯 state 单测 / 离线路径）', () async {
      final AylaSocialStore bare = AylaSocialStore()..userId = 'u1';
      bare.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(results: <Object>[group('g1')], total: 1);
      await bare.load(AylaSocialKind.conversations,
          const AylaSocialOptions(type: 'group'));
      expect(
        bare.itemsAs<AylaConversationSummary>(
            AylaSocialKind.conversations, const AylaSocialOptions(type: 'group')),
        hasLength(1),
      );
      bare.dispose();
    });
  });

  // ==========================================================================
  // 端到端回归锁：subgroups 的 default 并入 + 子群活跃度（web social.ts:173-184）
  // ==========================================================================
  group('端到端：subgroups 落库含 default 且按默认组/活跃度排序', () {
    late AylaSocialStore store;
    late AylaChatState chat;
    late AylaSubGroupState subgroups;
    late AylaSocialTracking tracking;

    AylaSubGroup sg(String id, {bool isDefault = false, int? seq}) => AylaSubGroup(
          id: id,
          conversationId: 'g1',
          name: '组$id',
          isDefault: isDefault,
          unreadCount: 0,
          lastMessageSeq: seq,
        );

    setUp(() {
      store = AylaSocialStore()..userId = 'u1';
      chat = AylaChatState();
      subgroups = AylaSubGroupState();
      tracking = AylaSocialTracking(store: store)
        ..bind(chatState: chat, subgroupState: subgroups)
        ..bindRehydration(chatState: chat, subgroupState: subgroups);
    });

    tearDown(() {
      tracking.dispose();
      store.dispose();
      chat.dispose();
      subgroups.dispose();
    });

    test('取页响应里的 default（不在 results 内）必须被并入 subgroupState', () async {
      // 后端 views.py:238-247：游标页 rows 不含 default，default 在响应外层另给。
      store.subgroupRequestOverride = (kind, options, cursor) async =>
          AylaSocialPage(
            page: AylaDirectoryPage<Object>(
              results: <Object>[sg('b', seq: 30)],
              total: 2,
            ),
            defaultSubgroup: sg('a', isDefault: true, seq: 0),
          );

      await store.load(AylaSocialKind.subgroups,
          const AylaSocialOptions(groupId: 'g1'));

      expect(subgroups.subgroupsOf('g1').map((AylaSubGroup s) => s.id).toList(),
          <String>['a', 'b'],
          reason: 'web :175-177 的 default 并入 + 落地排序（默认组在前）');
      expect(subgroups.activeSubgroupOf('g1'), isNull,
          reason: 'active 由页面按 GroupPage.tsx:267-269 确立，store 不替它决定');
    });

    test('端到端：子群消息（带 subgroup_id）推进子群活跃度，不是记到主群', () async {
      store.subgroupRequestOverride = (kind, options, cursor) async =>
          AylaSocialPage(
            page: AylaDirectoryPage<Object>(
              results: <Object>[sg('a', isDefault: true), sg('b')],
              total: 2,
            ),
            defaultSubgroup: sg('a', isDefault: true),
          );
      await store.load(AylaSocialKind.subgroups,
          const AylaSocialOptions(groupId: 'g1'));

      // 真实链路：消息进 messageState（挂生产钩子）→ recordMessageActivity。
      final AylaMessageState message = AylaMessageState()
        ..onSubgroupActivity = (String convId, String? sgId, int seq) =>
            subgroups.recordMessageActivity(convId, sgId, seq);
      message.upsertMessage(
        'g1',
        AylaChatMessage(
          id: 'm1',
          conversationId: 'g1',
          senderId: 'u2',
          type: AylaMessageType.text,
          content: '子群消息',
          status: AylaMessageStatus.sent,
          seq: 42,
          createdAt: '2026-10-01T00:00:00Z',
          subgroupId: 'b',
        ),
      );

      expect(
        subgroups
            .subgroupsOf('g1')
            .firstWhere((AylaSubGroup s) => s.id == 'b')
            .lastMessageSeq,
        42,
        reason: '★ 子群活跃度必须推进到该子群 key —— 不是主群/默认组',
      );
      expect(subgroups.unreadOf('g1', 'b'), 0,
          reason: '活跃度与未读无关（web subgroup.ts:38 注释）');
      message.dispose();
    });

    test('无 subgroup 归属的旧消息不进任何子群 key（web subgroup.ts:145-148）', () async {
      subgroups.setSubgroups('g1', <AylaSubGroup>[sg('a', isDefault: true)]);
      final AylaMessageState message = AylaMessageState()
        ..onSubgroupActivity = (String convId, String? sgId, int seq) =>
            subgroups.recordMessageActivity(convId, sgId, seq);
      message.upsertMessage(
        'g1',
        AylaChatMessage(
          id: 'm1',
          conversationId: 'g1',
          senderId: 'u2',
          type: AylaMessageType.text,
          content: '旧消息',
          status: AylaMessageStatus.sent,
          seq: 7,
          createdAt: '2026-10-01T00:00:00Z',
        ),
      );
      // setSubgroups 会把 lastMessageSeq 规整成 0（web subgroup.ts:81 的 max(…, 0)）
      // ⇒ 真正的判据是「**没有被 seq=7 推进**」，而不是 null。
      expect(subgroups.subgroupsOf('g1').first.lastMessageSeq, 0,
          reason: 'subgroupId == null ⇒ recordMessageActivity 直接返回（不猜归属）');
      message.dispose();
    });
  });
}
