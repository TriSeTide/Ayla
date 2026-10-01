/// 主页（HomePage）首帧与状态定向测试 —— 对照 web `pages/HomePage.tsx`。
///
/// 与第二批同类页同一口径（hub_pages_test）：**无网络**下不崩、错误静默，
/// 只断言页面「骨架 / 空态 / 宽屏分支」三档与布局开关的行为，
/// 数据正确性由同批的纯函数测试 `home_activity_test.dart` 覆盖。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/directory_page.dart';
import '../lib/core/models/chat_message.dart' show AylaMessageType;
import '../lib/core/models/conversation.dart';
import '../lib/core/models/game_room.dart';
import '../lib/core/models/post.dart';
import '../lib/core/models/user_public.dart';
import '../lib/pages/home_page.dart';
import '../lib/pages/home_support.dart' show aylaWideHomeTarget;
import '../lib/state/boardgame_store.dart' show aylaBoardgameStore;
import '../lib/state/chat_providers.dart' show chatStateProvider;
import '../lib/state/chat_state.dart' show AylaChatState;
import '../lib/state/directory_store.dart' show aylaDirectoryStore;
import '../lib/state/posts_store.dart' show aylaPostsStore;
import '../lib/state/social_store.dart' show aylaSocialStore;
import '../lib/state/home_prefs.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';

import '../lib/widgets/base/loading.dart' show AylaSkeleton;
import '../lib/widgets/base/layout_switch.dart' show AylaLayoutSwitch;
import '../lib/widgets/group/group_card.dart'
    show AylaGroupCard, AylaGroupListItem;

Widget _host(Widget child, {Size viewport = const Size(420, 900)}) {
  return ProviderScope(
    child: MaterialApp(
      home: Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: viewport),
          child: previewScope(child),
        ),
      ),
    ),
  );
}

Future<void> _pump(WidgetTester tester, {Size viewport = const Size(420, 900)}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  // ⚠️ 注入已登录身份（2026-10-01）：`AylaSocialStore.isLoading` 在 `userId == null` 时
  // **恒返回 false**（`social_store.dart:250` 的有意设计 —— 未登录时 `load` 直返，
  // 若照 web 字面表达 loading 会让页面永远转圈）。而本用例要验的正是 web 的
  // 「已登录 + 群会话请求在途 + 无数据 ⇒ **SkeletonCards**」（`HomePage.tsx:155/168`）
  // ⇒ 必须给出真实用户，否则骨架分支结构性不可达（此前依赖旧 `AylaPagedList` 的
  // 首帧 `loading=true`，换成共享 store 后判定口径变了）。
  aylaSocialStore.userId = 'u1';
  addTearDown(() => aylaSocialStore.userId = null);
  // ⚠️ 只 pump 首帧：无网络时请求在**下一个** microtask 就失败，
  // 多 pump 一次就会把首屏骨架推过去（对照 hub_pages_test 同口径）。
  await tester.pumpWidget(_host(const HomePage(), viewport: viewport));
}

/// 让在途请求（无网络 ⇒ 立即失败）走完，页面进入「空态」。
Future<void> _settleFailure(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  // ⚠️ 宽屏重定向目标的**表格锁**：这段 web 语义（HomePage.tsx:128）被翻译错过两次
  //（「跳两次侧栏」= 没等 prefs ready；「没有跳到首个群」= 把 JS 空值合并写成三元），
  // 所以它必须有独立于 Widget 的表格测试 —— 逐行对照见 aylaWideHomeTarget 的文档。
  group('宽屏重定向目标（tsx 128 表格）', () {
    String? pick({
      bool prefsReady = true,
      bool recentValid = false,
      String? recent,
      bool recentResolved = true,
      String? resolvedRecent,
      List<String> ids = const <String>['a', 'b'],
    }) =>
        aylaWideHomeTarget(
          prefsReady: prefsReady,
          recentValid: recentValid,
          recent: recent,
          recentResolved: recentResolved,
          resolvedRecent: resolvedRecent,
          groupIds: ids,
        );

    test('R 非空 ⇒ R（最近群有效时优先它）', () {
      expect(pick(resolvedRecent: 'b', recent: 'z'), 'b');
    });

    test('R 已校验但不可用（null）⇒ 回落 groups[0]（此前错成 null = 停在空态）', () {
      expect(pick(recentResolved: true, resolvedRecent: null, recent: 'xyz'), 'a');
      expect(pick(recentResolved: true, resolvedRecent: null, recent: null), 'a');
    });

    test('R 未校验且 recent 有值 ⇒ null（继续等，避免跳两次）', () {
      expect(pick(recentResolved: false, recent: 'xyz'), isNull);
    });

    test('R 未校验且 recent 为空 ⇒ groups[0]', () {
      expect(pick(recentResolved: false, recent: null), 'a');
    });

    test('prefs 未读完 ⇒ 一律 null（绝不按 groups[0] 先跳）', () {
      expect(pick(prefsReady: false), isNull);
      expect(pick(prefsReady: false, recent: null, recentResolved: false), isNull);
    });

    test('无群 ⇒ null（落到空态）', () {
      expect(pick(ids: const <String>[]), isNull);
      expect(pick(recentResolved: true, resolvedRecent: null, ids: const <String>[]), isNull);
    });

    test('recentValid 优先于已校验的 R（与 web 三元顺序一致）', () {
      expect(pick(recentValid: true, recent: 'b', resolvedRecent: 'x'), 'b');
    });
  });

  group('窄屏首帧（tsx 157–166）', () {
    testWidgets('页头 .home-toolbar：群聊 28/600 + 布局开关', (WidgetTester tester) async {
      await _pump(tester);

      final Text title = tester.widget<Text>(find.text('群聊'));
      expect(title.style?.fontSize, 28);
      expect(title.style?.fontWeight, FontWeight.w600);
      expect(find.byType(AylaLayoutSwitch), findsOneWidget);
      // .home-toolbar padding sp3 sp4
      expect(
        find.ancestor(
          of: find.text('群聊'),
          matching: find.byWidgetPredicate(
            (Widget w) =>
                w is Padding &&
                w.padding ==
                    const EdgeInsets.symmetric(
                      horizontal: AylaSpacing.sp4,
                      vertical: AylaSpacing.sp3,
                    ),
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('加载中 → SkeletonCards：6 张骨架群卡（tsx 35–47）', (WidgetTester tester) async {
      await _pump(tester);
      // 6 张卡 × 2 根骨架 = 12
      expect(find.byType(AylaSkeleton), findsNWidgets(12));
      expect(find.byType(AylaGroupCard), findsNothing);
      await tester.pump(const Duration(milliseconds: 50));
    });

    testWidgets('列表 / 卡片双形态由 AylaLayoutSwitch 驱动（默认卡片档）', (WidgetTester tester) async {
      await _pump(tester);
      final AylaLayoutSwitch before =
          tester.widget<AylaLayoutSwitch>(find.byType(AylaLayoutSwitch));
      expect(before.isCard, isTrue, reason: 'web stores/home.ts:20 默认 card');

      // 两个键的可访问名 = web 的 aria-label（"卡片布局" / "列表布局"）
      for (final String label in <String>['卡片布局', '列表布局']) {
        expect(
          find.byWidgetPredicate(
            (Widget w) => w is Semantics && w.properties.label == label,
          ),
          findsWidgets,
          reason: label,
        );
      }

      // 本用例的范围是**页面接线**：onChanged(false) → prefs.setLayout(list)
      // → 开关回落到列表档（开关自身的按钮行为由它自己的测试覆盖）。
      final AylaLayoutSwitch sw =
          tester.widget<AylaLayoutSwitch>(find.byType(AylaLayoutSwitch));
      sw.onChanged(false);
      await tester.pump();
      final AylaLayoutSwitch after =
          tester.widget<AylaLayoutSwitch>(find.byType(AylaLayoutSwitch));
      expect(after.isCard, isFalse);
      await tester.pump(const Duration(milliseconds: 50));
    });
  });

  group('窄屏空态（tsx 170–180）', () {
    testWidgets('两行文案 + 两键（创建群聊 / 搜索发现群）', (WidgetTester tester) async {
      await _pump(tester);
      await _settleFailure(tester);

      expect(find.text('创建你的第一个群'), findsOneWidget);
      expect(find.text('和朋友们聚在一起，从这里开始'), findsOneWidget);
      expect(find.text('创建群聊'), findsOneWidget);
      expect(find.text('搜索发现群'), findsOneWidget);
      // .home-state padding：sp12 sp6（home.css 622–629）
      expect(
        find.ancestor(
          of: find.text('创建你的第一个群'),
          matching: find.byWidgetPredicate(
            (Widget w) =>
                w is Padding &&
                w.padding ==
                    const EdgeInsets.symmetric(
                      horizontal: AylaSpacing.sp6,
                      vertical: AylaSpacing.sp12,
                    ),
          ),
        ),
        findsOneWidget,
      );
      // 请求失败后不再显示骨架，也不伪造群卡
      expect(find.byType(AylaSkeleton), findsNothing);
      expect(find.byType(AylaGroupCard), findsNothing);
      expect(find.byType(AylaGroupListItem), findsNothing);
    });
  });

  /// 切到**列表布局**：默认档是 card（`.home-grid` 两列网格，两张卡 dy 相同）⇒
  /// 量不出顺序；列表档是单列 Column，`getTopLeft().dy` 才是顺序判据。
  Future<void> useListLayout(WidgetTester tester) async {
    final AylaLayoutSwitch sw =
        tester.widget<AylaLayoutSwitch>(find.byType(AylaLayoutSwitch));
    sw.onChanged(false);
    await tester.pump();
  }
  group('窄屏群列表随实时源重排（tsx 73–80 + groupActivity.ts:159–169）', () {
    /// 一条群会话（带最后一条消息，用于「新消息」事件）。
    AylaConversationSummary group(String id, {AylaLastMessagePreview? last}) =>
        AylaConversationSummary(
          id: id,
          type: AylaConversationType.group,
          title: '群 $id',
          lastMessage: last,
        );

    AylaLastMessagePreview msg(String at) => AylaLastMessagePreview(
          type: AylaMessageType.text,
          content: 'x',
          senderName: '小樱',
          createdAt: at,
        );

    String isoAgo(int ms) => DateTime.now()
        .subtract(Duration(milliseconds: ms))
        .toUtc()
        .toIso8601String();

    setUp(() {
      aylaPostsStore.reset();
      aylaBoardgameStore.reset();
      aylaSocialStore.reset();
      aylaSocialStore.userId = 'u1';
      aylaDirectoryStore.reset();
      aylaDirectoryStore.userId = 'u1';
    });
    tearDown(() {
      aylaSocialStore.requestOverride = null;
      aylaSocialStore.reset();
      aylaSocialStore.userId = null;
      aylaDirectoryStore.reset();
      aylaDirectoryStore.requestOverride = null;
      aylaDirectoryStore.userId = null;
      aylaPostsStore.reset();
      aylaBoardgameStore.reset();
    });

    testWidgets('posts store 变化 ⇒ 窄屏列表重排（新帖把该群往前排）', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      aylaSocialStore.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
            results: <Object>[group('g1'), group('g2')],
            total: 2,
          );
      aylaDirectoryStore.requestOverride = (kind, options, cursor) async =>
          const AylaDirectoryPage<Object>();

      await tester.pumpWidget(_host(const HomePage()));
      await tester.pump(const Duration(milliseconds: 100));
      await useListLayout(tester);
      // 初始：两群都无新内容 ⇒ 保持传入顺序（g1 在前）。
      expect(
        tester.getTopLeft(find.text('群 g1')).dy <
            tester.getTopLeft(find.text('群 g2')).dy,
        isTrue,
      );

      // 新帖落到 g2（白名单含 g2）⇒ 排序应把 g2 提前。
      aylaPostsStore.setPage(
        <AylaPost>[
          AylaPost(
            id: 1,
            title: '新帖',
            body: '正文',
            allowedGroupIds: const <String>['g2'],
            createdAt: isoAgo(60000),
          ),
        ],
        null,
        false,
      );
      await tester.pump();
      expect(
        tester.getTopLeft(find.text('群 g2')).dy <
            tester.getTopLeft(find.text('群 g1')).dy,
        isTrue,
        reason: '窄屏群列表必须随 posts store 变化重排（web groupActivity.ts:206–215）',
      );
      await tester.pumpAndSettle();
    });

    testWidgets('boardgame store 变化 ⇒ 窄屏列表重排（新桌游房把该群往前排）', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      aylaSocialStore.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
            results: <Object>[group('g1'), group('g2')],
            total: 2,
          );
      aylaDirectoryStore.requestOverride = (kind, options, cursor) async =>
          const AylaDirectoryPage<Object>();

      await tester.pumpWidget(_host(const HomePage()));
      await tester.pump(const Duration(milliseconds: 100));
      await useListLayout(tester);
      aylaBoardgameStore.upsertRoom(
        AylaGameRoom(
          id: 1,
          name: '桌游房',
          owner: const AylaUserPublic(id: 'u1', nickname: '小樱'),
          ownerId: 'u1',
          status: AylaGameRoomStatus.playing,
          allowedGroupIds: const <String>['g2'],
          createdAt: isoAgo(60000),
        ),
      );
      await tester.pump();
      expect(
        tester.getTopLeft(find.text('群 g2')).dy <
            tester.getTopLeft(find.text('群 g1')).dy,
        isTrue,
        reason: '窄屏群列表必须随 boardgame store 变化重排',
      );
      await tester.pumpAndSettle();
    });

    testWidgets('chatState.bumpGroupActivity ⇒ 窄屏列表重排（无任何目录事件的群也排前）', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      aylaSocialStore.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
            results: <Object>[group('g1'), group('g2')],
            total: 2,
          );
      aylaDirectoryStore.requestOverride = (kind, options, cursor) async =>
          const AylaDirectoryPage<Object>();

      await tester.pumpWidget(_host(const HomePage()));
      await tester.pump(const Duration(milliseconds: 100));
      await useListLayout(tester);
      // web `stores/chat.ts:85–91` 的 WS bump（`chat_ws` 收到 message.new 时写）。
      final AylaChatState chat =
          ProviderScope.containerOf(
            tester.element(find.byType(HomePage)),
            listen: false,
          ).read(chatStateProvider);
      chat.bumpGroupActivity('g2');
      await tester.pump();
      expect(
        tester.getTopLeft(find.text('群 g2')).dy <
            tester.getTopLeft(find.text('群 g1')).dy,
        isTrue,
        reason: '`groupActivityAt` bump 必须驱动重排（web groupActivity.ts:169/224）',
      );
      await tester.pumpAndSettle();
    });
  });
  group('宽屏（tsx 124–151）', () {
    testWidgets('无群 → .home-wide-empty（还没有加入群聊 + 创建你的第一个群）', (
      WidgetTester tester,
    ) async {
      await _pump(tester, viewport: const Size(1440, 900));
      await _settleFailure(tester);

      expect(find.text('还没有加入群聊'), findsOneWidget);
      expect(find.text('创建或加入一个群聊，这里是你的「家」'), findsOneWidget);
      expect(find.text('创建你的第一个群'), findsOneWidget);
      // 宽屏不出现窄屏页头与布局开关
      expect(find.text('群聊'), findsNothing);
      expect(find.byType(AylaLayoutSwitch), findsNothing);
    });
  });

  group('AylaHomePrefsController（web stores/home.ts）', () {
    test('layout 只认 list，其余（null/未知/空）回落 card', () {
      expect(AylaHomeLayout.parse('list'), AylaHomeLayout.list);
      expect(AylaHomeLayout.parse('card'), AylaHomeLayout.card);
      expect(AylaHomeLayout.parse(null), AylaHomeLayout.card);
      expect(AylaHomeLayout.parse('nope'), AylaHomeLayout.card);
    });

    test('读盘：缺键回落默认；存储异常静默回落默认', () async {
      final AylaHomePrefsController c1 = AylaHomePrefsController(
        reader: () async => <String, Object?>{
          'ayla.home.layout': 'list',
          'ayla.home.recent_group': 'g9',
        },
      );
      await c1.load();
      expect(c1.layout, AylaHomeLayout.list);
      expect(c1.recentGroupId, 'g9');

      final AylaHomePrefsController c2 = AylaHomePrefsController(
        reader: () async => throw StateError('存储不可用'),
      );
      await c2.load();
      expect(c2.layout, AylaHomeLayout.card);
      expect(c2.recentGroupId, isNull);
    });

    test('写盘：setLayout/setRecentGroup 落盘键名与 web 一致；null 清除最近群', () async {
      Map<String, Object?>? written;
      final AylaHomePrefsController c = AylaHomePrefsController(
        reader: () async => <String, Object?>{},
        writer: (Map<String, Object?> prefs) async => written = prefs,
      );
      await c.load();
      c.setLayout(AylaHomeLayout.list);
      expect(written?['ayla.home.layout'], 'list');
      c.setRecentGroup('g1');
      expect(written?['ayla.home.recent_group'], 'g1');
      c.setRecentGroup(null);
      expect(written?.containsKey('ayla.home.recent_group'), isFalse);
    });
  });
}
