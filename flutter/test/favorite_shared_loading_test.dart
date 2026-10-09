/// 收藏键**全链路收尾**回归锁（2026-10-09）。
///
/// ## 被锁住的缺陷（用户实报）
/// 「收藏键无法点击，显示正在加载收藏状态」。
///
/// 上一轮（2026-10-08）已让 `AylaFavoriteButton` 具备自给自足档，但仍有调用点
/// 停在注入档且页面没接线 ⇒ 永久 `unknown`。本文件锁定本轮补的三处根因：
/// - **根因 1（消息气泡，最大面积）**：web `MessageBubble.tsx:246` 恒渲染
///   `<FavoriteButton targetType="message" targetId={message.id} compact />`，
///   而 `message_list.dart` 从未传 `favoriteState` ⇒ 每个气泡都禁用。现在**默认自给自足**。
/// - **根因 2（桌游房）**：`game_support.dart` 的 `_favorites.load` 写在 `_ensureMembers()`
///   里，后者**只有房主**可达（web `GameRoomPlaceholder.tsx:143` 是键自己加载）。
/// - **根因 3（收藏页对账）**：`applyFavoriteStatus` 写的是**模块级 store**
///   （`favoriteStatus.ts:76–79`），页面私有实例写进没人读的缓存 ⇒ 别处的心形键不跟着变。
///
/// ## 另锁两条 web 语义
/// - **共享 store**：`favoriteStatus.ts:17` 的 `useFavoriteStatusStore` 是模块级单例
///   ⇒ `AylaFavoriteButton` 不传 `controller` 时用库内共享单例；
/// - **drain 队列**：`favoriteStatus.ts:81–125` 的入队 + 合并 + **并发 2** + 每批 100。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/favorites_api.dart';
import '../lib/core/models/chat_message.dart';
import '../lib/core/models/game_room.dart' show AylaGameCardData;
import '../lib/state/favorite_status.dart';
import '../lib/theme/buttons.dart' show AylaPressScale;
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/favorite_button.dart'
    show AylaFavoriteButton, AylaFavoriteState;
import '../lib/widgets/chat/message_bubble.dart' show AylaMessageBubble;
import '../lib/widgets/game/game_room_card.dart' show AylaGameRoomCard;

/// 可编程假后端（与既有收藏用例同契约）。
class _FakeApi {
  _FakeApi({this.statuses = const <String, int?>{}});

  Map<String, int?> statuses;
  Object? fetchError;

  int fetchCalls = 0;
  final List<List<String>> batches = <List<String>>[];

  AylaFavoriteStatusController controller() => AylaFavoriteStatusController(
        fetcher: (String type, List<String> ids) async {
          fetchCalls += 1;
          batches.add(ids);
          if (fetchError != null) throw fetchError!;
          return AylaFavoriteStatuses(
            targetType: type,
            statuses: <String, int?>{
              for (final String id in ids)
                if (statuses.containsKey(id)) id: statuses[id],
            },
          );
        },
      );
}

AylaChatMessage _msg({String id = 'm1'}) => AylaChatMessage(
      id: id,
      conversationId: 'conv-1',
      senderId: 'user-2',
      type: AylaMessageType.text,
      content: '晚上一起看直播吗？',
      status: AylaMessageStatus.sent,
      seq: 1,
      createdAt: DateTime.now().toUtc().toIso8601String(),
    );

Widget _host(Widget child) => MaterialApp(
      home: previewTheme(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: const Size(600, 400)),
            child: Center(child: child),
          ),
        ),
      ),
    );

void main() {
  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  group('根因 1 · 消息气泡（web MessageBubble.tsx:246 恒自给自足）', () {
    testWidgets('不传任何收藏参数 ⇒ 收藏键挂载即加载，unknown → known（不再永久加载中）', (
      WidgetTester tester,
    ) async {
      final _FakeApi api = _FakeApi(statuses: <String, int?>{'m1': null});
      final AylaFavoriteStatusController controller = api.controller();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_host(AylaMessageBubble(
        msg: _msg(),
        isSelf: false,
        actionsOpen: true, // 展开操作栏（触屏档等价）
        favoriteController: controller,
      )));
      // ⚠️ 刻意**不传** favoriteState / onToggleFavorite —— message_list.dart 就是这么调的
      expect(find.byType(AylaFavoriteButton), findsOneWidget, reason: '收藏键恒在（tsx:246）');

      await flush(tester);
      expect(api.fetchCalls, 1, reason: '收藏键必须自己加载（web useFavoriteStatuses.ts:12–16）');
      expect(api.batches.single, <String>['m1'], reason: 'targetId = message.id（tsx:246）');
      expect(
        controller.stateOf('message', 'm1'),
        AylaFavoriteState.notFavorited,
        reason: 'unknown → known 自动收敛（不再永久「正在加载收藏状态」）',
      );
      // **用户实报的可见语义**：收藏键不再禁用（unknown 档 `onTap == null`）。
      expect(
        tester
            .widget<AylaPressScale>(
              find.descendant(
                of: find.byType(AylaFavoriteButton),
                matching: find.byType(AylaPressScale),
              ),
            )
            .enabled,
        isTrue,
        reason: '收敛到 known 后必须可点击（用户实报「收藏键无法点击」）',
      );
    });

    testWidgets('已收藏消息 ⇒ 收敛到「已收藏」（实心图标）', (WidgetTester tester) async {
      final _FakeApi api = _FakeApi(statuses: <String, int?>{'m1': 77});
      final AylaFavoriteStatusController controller = api.controller();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_host(AylaMessageBubble(
        msg: _msg(),
        isSelf: false,
        actionsOpen: true,
        favoriteController: controller,
      )));
      await flush(tester);
      expect(
        controller.stateOf('message', 'm1'),
        AylaFavoriteState.favorited,
      );
    });

    testWidgets('注入档零回归：传了 favoriteState ⇒ 完全由调用方驱动，绝不自动请求', (
      WidgetTester tester,
    ) async {
      final _FakeApi api = _FakeApi(statuses: <String, int?>{'m1': null});
      final AylaFavoriteStatusController controller = api.controller();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_host(AylaMessageBubble(
        msg: _msg(),
        isSelf: false,
        actionsOpen: true,
        favoriteState: AylaFavoriteState.notFavorited,
        onToggleFavorite: (_) {},
        favoriteController: controller,
      )));
      await flush(tester);
      expect(api.fetchCalls, 0, reason: '注入档不发请求（画布样张与既有测试不变）');
    });

    testWidgets('系统消息 / 已撤回 ⇒ 不渲染操作栏（tsx 244）', (WidgetTester tester) async {
      final _FakeApi api = _FakeApi();
      final AylaFavoriteStatusController controller = api.controller();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_host(AylaMessageBubble(
        msg: AylaChatMessage(
          id: 'm9',
          conversationId: 'conv-1',
          senderId: 'sys',
          type: AylaMessageType.system,
          content: '小樱 加入了群聊',
          status: AylaMessageStatus.sent,
          seq: 2,
          createdAt: DateTime.now().toUtc().toIso8601String(),
        ),
        isSelf: false,
        actionsOpen: true,
        favoriteController: controller,
      )));
      await flush(tester);
      expect(find.byType(AylaFavoriteButton), findsNothing);
      expect(api.fetchCalls, 0);
    });
  });

  group('共享 store（web favoriteStatus.ts:17 模块级单例）', () {
    testWidgets('不传 controller ⇒ 用库内共享单例（不是每键私有实例）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_host(const AylaFavoriteButton(
        targetType: 'post',
        targetId: 'shared-1',
        compact: true,
      )));
      await flush(tester);
      final AylaFavoriteButton button =
          tester.widget<AylaFavoriteButton>(find.byType(AylaFavoriteButton));
      expect(button.controller, isNull, reason: '调用方不传 ⇒ 组件自取共享单例');
      // 共享单例确实被 retain（引用计数 +1），且卸载后归零
      expect(
        aylaSharedFavoriteStatusController.retainCountOf('post', 'shared-1'),
        1,
      );
    });

    testWidgets('同一目标两个键共享状态：一处 apply ⇒ 两处同时改档', (
      WidgetTester tester,
    ) async {
      final _FakeApi api = _FakeApi(statuses: <String, int?>{'p1': null});
      final AylaFavoriteStatusController controller = api.controller();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_host(Row(
        children: <Widget>[
          AylaFavoriteButton(
            targetType: 'post',
            targetId: 'p1',
            controller: controller,
          ),
          AylaFavoriteButton(
            targetType: 'post',
            targetId: 'p1',
            controller: controller,
          ),
        ],
      )));
      await flush(tester);
      expect(find.text('收藏'), findsNWidgets(2));
      expect(api.fetchCalls, 1, reason: '同键合并成一次请求');

      // web `applyFavoriteStatus`（favoriteStatus.ts:76–79）由 WS / 收藏页对账驱动
      controller.apply('post', 'p1', 5);
      await tester.pump();
      expect(find.text('已收藏'), findsNWidgets(2));
    });

    test('收藏页取消收藏的对账走共享单例 ⇒ 广播到所有挂载键（根因 3）', () {
      final AylaFavoriteStatusController shared =
          aylaSharedFavoriteStatusController;
      shared.apply('post', 'recon-1', 3);
      expect(shared.stateOf('post', 'recon-1'), AylaFavoriteState.favorited);
      shared.apply('post', 'recon-1', null);
      expect(shared.stateOf('post', 'recon-1'), AylaFavoriteState.notFavorited);
    });
  });

  group('drain 队列（web favoriteStatus.ts:81–125）', () {
    test('同类型多 id 合并成一批（不是一键一请求）', () async {
      int calls = 0;
      final List<List<String>> batches = <List<String>>[];
      final AylaFavoriteStatusController controller =
          AylaFavoriteStatusController(
        fetcher: (String type, List<String> ids) async {
          calls += 1;
          batches.add(ids);
          return AylaFavoriteStatuses(
            targetType: type,
            statuses: <String, int?>{for (final String id in ids) id: null},
          );
        },
      );
      addTearDown(controller.dispose);

      // 五个收藏键同时挂载（web：五个 useEffect 同时入队）
      await Future.wait(<Future<void>>[
        for (final String id in <String>['a', 'b', 'c', 'd', 'e'])
          controller.load('post', <String>[id]),
      ]);
      expect(calls, 1, reason: 'web drain 把同类型 pending 合并成一批（favoriteStatus.ts:83–87）');
      expect(batches.single..sort(), <String>['a', 'b', 'c', 'd', 'e']);
      expect(controller.stateOf('post', 'a'), AylaFavoriteState.notFavorited);
    });

    test('并发上限 2（web favoriteStatus.ts:83 的 `active < 2`）', () async {
      int active = 0;
      int maxActive = 0;
      final AylaFavoriteStatusController controller =
          AylaFavoriteStatusController(
        fetcher: (String type, List<String> ids) async {
          active += 1;
          maxActive = active > maxActive ? active : maxActive;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          active -= 1;
          return AylaFavoriteStatuses(
            targetType: type,
            statuses: <String, int?>{for (final String id in ids) id: null},
          );
        },
      );
      addTearDown(controller.dispose);

      // 四种不同类型同时到达 ⇒ 必须排队（不是 4 个并发）
      await Future.wait(<Future<void>>[
        controller.load('post', <String>['1']),
        controller.load('live', <String>['1']),
        controller.load('voice', <String>['1']),
        controller.load('game', <String>['1']),
      ]);
      expect(maxActive, lessThanOrEqualTo(2), reason: '并发上限 2');
      expect(
        AylaFavoriteStatusController.concurrency,
        2,
        reason: '常量与 web 的 `active < 2` 同值',
      );
      expect(AylaFavoriteStatusController.batchLimit, 100);
    });

    test('超过 100 个 id ⇒ 分批（web `slice(0, 100)`，api/favorites.ts:25 硬上限）', () async {
      final List<int> sizes = <int>[];
      final AylaFavoriteStatusController controller =
          AylaFavoriteStatusController(
        fetcher: (String type, List<String> ids) async {
          sizes.add(ids.length);
          return AylaFavoriteStatuses(
            targetType: type,
            statuses: <String, int?>{for (final String id in ids) id: null},
          );
        },
      );
      addTearDown(controller.dispose);

      await controller.load(
        'post',
        <String>[for (int i = 0; i < 250; i++) 'p$i'],
      );
      expect(sizes.length, 3, reason: '250 个 id ⇒ 100 + 100 + 50');
      expect(sizes.reduce((int a, int b) => a > b ? a : b), 100);
    });
  });

  group('惰性补加载（2026-10-09 二次修复：用户实报「切回页面又禁用」）', () {
    // 用户复现三特征：① 刷新该页面后能点；② 从其他页面切回来又变禁用；
    // ③ 群内消息界面没问题（消息气泡已走自给自足档，不依赖页面接线）。
    // 根因：注入档调用点的加载挂在页面目录回调上，而
    // `directory_store.dart:682–688` 的 60 秒缓存短路 / `posts_store.dart:321–327`
    // 的 `shouldLoad` false 都会让该回调**根本不触发** ⇒ 页面渲染了卡片却从不查询。
    // web 的加载点是**渲染即加载**（`FavoriteButton.tsx:22`）⇒ 本组锁住同一语义。
    test('页面只读 stateOf（从不调 load）⇒ 也会自动查询并收敛（不再永久 unknown）', () async {
      final _FakeApi api = _FakeApi(statuses: <String, int?>{'p1': null});
      final AylaFavoriteStatusController controller = api.controller();
      addTearDown(controller.dispose);

      // ⚠️ 刻意**只读不 load** —— 模拟「目录缓存短路 ⇒ 页面回调未触发」的切回场景
      expect(controller.stateOf('post', 'p1'), AylaFavoriteState.unknown);
      await Future<void>.delayed(Duration.zero); // 让 microtask 跑完
      await Future<void>.delayed(Duration.zero);

      expect(api.fetchCalls, 1, reason: '读状态即补加载（web 渲染即加载）');
      expect(controller.stateOf('post', 'p1'), AylaFavoriteState.notFavorited);
    });

    test('一屏 N 张卡首次同帧读状态 ⇒ 合并成一批（与 drain 同批）', () async {
      final _FakeApi api = _FakeApi(
        statuses: <String, int?>{'a': null, 'b': null, 'c': null},
      );
      final AylaFavoriteStatusController controller = api.controller();
      addTearDown(controller.dispose);

      // 页面 build 里逐卡读状态（注入档的真实调用形态）
      for (final String id in <String>['a', 'b', 'c']) {
        controller.stateOf('post', id);
      }
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(api.fetchCalls, 1, reason: '同类型同帧合并（web queue + drain）');
      expect(api.batches.single..sort(), <String>['a', 'b', 'c']);
    });

    test('重复读同一键 ⇒ 幂等，不追加请求', () async {
      final _FakeApi api = _FakeApi(statuses: <String, int?>{'x': null});
      final AylaFavoriteStatusController controller = api.controller();
      addTearDown(controller.dispose);

      controller.stateOf('post', 'x');
      controller.stateOf('post', 'x');
      controller.stateOf('post', 'x');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      controller.stateOf('post', 'x'); // 已 known ⇒ 不排队
      await Future<void>.delayed(Duration.zero);

      expect(api.fetchCalls, 1, reason: '幂等：一屏重复 build 不放大请求数');
    });

    test('查询失败（error 档）⇒ 不无限自动重试（重试由用户点击触发）', () async {
      final _FakeApi api = _FakeApi(statuses: <String, int?>{'x': null});
      api.fetchError = StateError('boom');
      final AylaFavoriteStatusController controller = api.controller();
      addTearDown(controller.dispose);

      expect(controller.stateOf('live', 'x'), AylaFavoriteState.unknown);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(api.fetchCalls, 1);

      // 页面继续重绘（错误态）：仍显示 error、且**不再自动发请求**
      // （web：error 档点击 = 重新拉取，`FavoriteButton.tsx:35–38`）
      for (int i = 0; i < 3; i++) {
        expect(controller.stateOf('live', 'x'), AylaFavoriteState.error);
      }
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(api.fetchCalls, 1, reason: '失败后不得自动重试成环');
    });

    testWidgets('注入档页面「漏接线」场景：卡片不再永久显示「加载中…」', (
      WidgetTester tester,
    ) async {
      final _FakeApi api = _FakeApi(statuses: <String, int?>{'m': 9});
      final AylaFavoriteStatusController controller = api.controller();
      addTearDown(controller.dispose);

      // 注入档：页面**没有**调 load，只把 stateOf 的结果传给键（切回页面的真实形态）
      late StateSetter rebuild;
      await tester.pumpWidget(_host(StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) {
          rebuild = setState;
          controller.addListener(() => setState(() {}));
          return AylaFavoriteButton(
            controller: controller,
            state: controller.stateOf('live', 'm'),
            compact: false,
          );
        },
      )));
      await flush(tester);
      rebuild(() {});
      await flush(tester);
      await flush(tester);

      expect(api.fetchCalls, 1, reason: '读状态即补加载');
      expect(find.text('已收藏'), findsOneWidget, reason: '收敛后不再是「加载中…」禁用态');
    });
  });

  group('禁用态已删除（2026-10-09 用户裁决：「收藏键非得要有个禁用态？删掉得了」）', () {
    testWidgets('unknown（注入档）⇒ 可点：点击 = 拉取状态，不误发收藏', (
      WidgetTester tester,
    ) async {
      int retried = 0;
      bool? toggled;
      await tester.pumpWidget(_host(AylaFavoriteButton(
        state: AylaFavoriteState.unknown,
        onRetryStatus: () => retried += 1,
        onToggle: (bool v) => toggled = v,
      )));
      await tester.pump();
      final Semantics semantics = tester.widget<Semantics>(
        find.descendant(
          of: find.byType(AylaFavoriteButton),
          matching: find.byWidgetPredicate(
            (Widget w) =>
                w is Semantics && w.properties.label == '正在加载收藏状态',
          ),
        ),
      );
      expect(semantics.properties.enabled, isTrue, reason: 'unknown 不再禁用（裁决）');

      await tester.tap(find.text('加载中…'));
      await tester.pump();
      expect(retried, 1, reason: '点击 = 拉取状态（tsx 35–38 的语义真正生效）');
      expect(toggled, isNull, reason: '拉取 ≠ 收藏');
    });

    testWidgets('busy（切换进行中）仍禁用 —— 唯一保留的禁用是「已能点、正在执行」', (
      WidgetTester tester,
    ) async {
      int toggles = 0;
      await tester.pumpWidget(_host(AylaFavoriteButton(
        state: AylaFavoriteState.notFavorited,
        busy: true,
        onToggle: (_) => toggles += 1,
      )));
      await tester.pump();
      await tester.tap(find.text('收藏'), warnIfMissed: false);
      await tester.pump();
      expect(toggles, 0, reason: 'busy 档挡点击（避免重复请求）');
    });

    testWidgets('群内桌游卡片（无任何收藏接线）⇒ 收藏键仍自动加载并收敛', (
      WidgetTester tester,
    ) async {
      // 用户实报：/group/:id/game 的卡片心形键禁用 + 「正在加载收藏状态」。
      // 根因：AylaGameRoomCard 此前是**纯注入档**且 favoriteState 默认 unknown，
      // 而 group_games_page.dart 什么都没传 ⇒ 永久禁用。
      // web 的 GameRoomCard.tsx:50 是**恒自渲染**
      // `<FavoriteButton targetType="game" targetId={room.id} compact />`
      // （自给自足）⇒ 本件默认档也改为自给自足。
      final _FakeApi api = _FakeApi(statuses: <String, int?>{'r1': 88});
      final AylaFavoriteStatusController controller = api.controller();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_host(SizedBox(
        width: 320,
        child: AylaGameRoomCard(
          room: const AylaGameCardData(id: 'r1', name: '群内桌游房'),
          onEnter: () {},
          favoriteController: controller,
        ),
      )));
      await flush(tester);
      expect(api.fetchCalls, 1, reason: '默认档 = 自给自足（web GameRoomCard.tsx:50）');
      expect(api.batches.single, <String>['r1']);
      expect(
        controller.stateOf('game', 'r1'),
        AylaFavoriteState.favorited,
        reason: '不再永久停在 unknown 禁用',
      );
    });

    testWidgets('群内桌游卡片：缺 controller 时也自动加载（页面零接线，走共享单例）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_host(SizedBox(
        width: 320,
        child: AylaGameRoomCard(
          room: const AylaGameCardData(id: 'zero-wire-1', name: '零接线房'),
          onEnter: () {},
        ),
      )));
      await tester.pump();
      expect(
        aylaSharedFavoriteStatusController.retainCountOf('game', 'zero-wire-1'),
        1,
        reason: '零接线调用点必须落到共享单例（web favoriteStatus.ts:17）',
      );
    });
  });

  group('账号作用域（web ensureFavoriteScope，favoriteStatus.ts:28–48）', () {
    test('aylaFavoriteResetScope ⇒ 控制器清空已查状态（不残留旧账号）', () async {
      final AylaFavoriteStatusController controller =
          AylaFavoriteStatusController(
        fetcher: (String type, List<String> ids) async =>
            AylaFavoriteStatuses(
          targetType: type,
          statuses: <String, int?>{for (final String id in ids) id: 42},
        ),
      );
      addTearDown(controller.dispose);
      await controller.load('live', <String>['x']);
      expect(controller.stateOf('live', 'x'), AylaFavoriteState.favorited);

      aylaFavoriteResetScope(); // = web `epoch += 1` + entries 清空
      expect(
        controller.stateOf('live', 'x'),
        AylaFavoriteState.unknown,
        reason: '账号切换后不得残留旧账号的收藏状态（favoriteStatus.ts:36–42）',
      );
    });

    testWidgets('作用域变化 ⇒ 挂载中的收藏键重新加载（web tsx:31 的 account 依赖）', (
      WidgetTester tester,
    ) async {
      final _FakeApi api = _FakeApi(statuses: <String, int?>{'x': null});
      final AylaFavoriteStatusController controller = api.controller();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_host(AylaFavoriteButton(
        targetType: 'live',
        targetId: 'x',
        controller: controller,
      )));
      await flush(tester);
      expect(api.fetchCalls, 1);

      aylaFavoriteResetScope(); // 登录/登出
      await flush(tester);
      await flush(tester);
      expect(api.fetchCalls, 2, reason: '作用域变了必须重新查一次（否则键停在 unknown）');
      expect(find.text('收藏'), findsOneWidget);
    });
  });
}
