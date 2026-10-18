/// P1-4 路由层定向测试：五条 `/group/*` 路由把 `?msg=&seq=&subgroup=` 解析进
/// `GroupPage` 的构造参数。
///
/// 事实源：web `App.tsx:86–90` 的五条 Route `element` 全是同一个 `GroupPage`，
/// 页面内部用 `useSearchParams()` 读三维参数（`GroupChat.tsx:72–86`）。
/// Flutter 的 `pageBuilder` 拿不到子页面自身 query ⇒ 在路由层解析后作为构造参数下传。
///
/// 断言方式：挂真实 `GroupPage`（与 `group_pages_test` 同一 harness 形态），
/// 从 widget 树里取出 `GroupPage` 实例，逐字段对比三个构造参数。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/directory_page.dart' show AylaDirectoryPage;
import '../lib/core/models/subgroup.dart'
    show AylaSubGroup, AylaSubgroupPage;
import '../lib/pages/group_page.dart' show GroupPage, aylaGroupPageSubgroupsLoader;
import '../lib/state/group_providers.dart' show subgroupStateProvider;
import '../lib/state/social_store.dart' show aylaSocialStore;

AylaSubGroup _sg(String id, {bool isDefault = false, int? lastSeq}) =>
    AylaSubGroup(
      id: id,
      conversationId: 'g1',
      name: '子群$id',
      isDefault: isDefault,
      unreadCount: 0,
      lastMessageSeq: lastSeq,
    );

/// 从 widget 树里取 `GroupPage` 实例（只有一个）。
GroupPage groupPageOf(WidgetTester tester) =>
    tester.widget<GroupPage>(find.byType(GroupPage));

void main() {
  setUp(() {
    aylaSocialStore.reset();
    aylaSocialStore.userId = 'u1';
    aylaSocialStore.requestOverride =
        (kind, options, cursor) async => const AylaDirectoryPage<Object>();
    aylaGroupPageSubgroupsLoader = (String groupId, String? cursor) async =>
        AylaSubgroupPage(
          results: <AylaSubGroup>[_sg('sg-a', lastSeq: 10)],
          total: 2,
          defaultSubgroup: _sg('sg-default', isDefault: true),
        );
  });

  tearDown(() {
    aylaGroupPageSubgroupsLoader = null;
    aylaSocialStore.requestOverride = null;
    aylaSocialStore.reset();
    aylaSocialStore.userId = null;
  });

  Widget host(ProviderContainer container, Widget page) =>
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  size: const Size(1440, 900),
                ),
                child: page,
              ),
            ),
          ),
        ),
      );

  group('GroupPage 深链构造参数（web GroupChat.tsx:72–86）', () {
    testWidgets('三个参数都传 ⇒ 原样落到字段', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(host(
        container,
        const GroupPage(
          groupId: 'g1',
          jumpMessageId: 'm-42',
          jumpSeq: 42,
          jumpSubgroupId: 'sg-a',
        ),
      ));
      await tester.pump(const Duration(milliseconds: 200));

      final GroupPage page = groupPageOf(tester);
      expect(page.jumpMessageId, 'm-42');
      expect(page.jumpSeq, 42);
      expect(page.jumpSubgroupId, 'sg-a');
      await tester.pumpAndSettle();
    });

    testWidgets('无深链（三个参数全 null）⇒ 与旧行为一致、不切子群',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(host(
        container,
        const GroupPage(groupId: 'g1'),
      ));
      await tester.pump(const Duration(milliseconds: 200));

      final GroupPage page = groupPageOf(tester);
      expect(page.jumpMessageId, isNull);
      expect(page.jumpSeq, isNull);
      expect(page.jumpSubgroupId, isNull);
      // 无深链时首个 active 仍是服务端默认组（既有语义不变）。
      expect(container.read(subgroupStateProvider).activeSubgroupOf('g1'),
          'sg-default');
      await tester.pumpAndSettle();
    });

    testWidgets('带 subgroup 的深链 ⇒ 页面把 active 切到该子群',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(host(
        container,
        const GroupPage(
          groupId: 'g1',
          jumpMessageId: 'm-42',
          jumpSeq: 42,
          jumpSubgroupId: 'sg-a',
        ),
      ));
      // 深链处理链：initState 帧后 → _bootstrap → _applyExternalJump（要等子群列表落库）。
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        container.read(subgroupStateProvider).activeSubgroupOf('g1'),
        'sg-a',
        reason: 'web GroupChat.tsx:91–94：带 subgroup 且存在 ⇒ 切过去',
      );
      await tester.pumpAndSettle();
    });

    testWidgets('不带 subgroup 的深链 ⇒ 页面把 active 切到默认组',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      // 预置 active 为非默认子群（模拟「从别的子群点收藏消息」）。
      container.read(subgroupStateProvider).setActiveSubgroup('g1', 'sg-a');

      await tester.pumpWidget(host(
        container,
        const GroupPage(
          groupId: 'g1',
          jumpMessageId: 'm-7',
          jumpSeq: 7,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        container.read(subgroupStateProvider).activeSubgroupOf('g1'),
        'sg-default',
        reason: 'web GroupChat.tsx:96–99：不带 subgroup ⇒ 切默认组',
      );
      await tester.pumpAndSettle();
    });
  });
}
