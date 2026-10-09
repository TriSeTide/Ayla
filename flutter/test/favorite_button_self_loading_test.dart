/// 收藏键**自给自足**回归锁（2026-10-08 结构性修复）。
///
/// ## 被锁住的缺陷（用户实报）
/// 「部分收藏键仍然无法点击，显示正在加载收藏状态，且样式与分享键不统一，
/// 点刷新键又能点了」。
///
/// ## 根因（web 为准）
/// web 的收藏键**自己加载自己**：
/// - `components/FavoriteButton.tsx:22` `const state = useFavoriteStatuses(targetType, [key])[key]`；
/// - `hooks/useFavoriteStatuses.ts:12–16` 的 `useEffect` = **retain + load + 卸载 release**；
/// - 调用方只给 `targetType`/`targetId`（`LiveRoomBody.tsx:260/328`）⇒ 页面无需接线。
///
/// Flutter 侧此前把 state/busy/error/toggle 全部外提给页面（`required state`），
/// 页面漏调一次 `load` 就永久停在 unknown —— 本次让收藏键也能自持。
///
/// ## 覆盖
/// ① 挂载即自动加载（无需页面接线）；② 点击能 toggle；③ 失败/未登录路径；
/// ④ 注入档零回归；⑤ retain 引用计数；⑥ 对外状态自动刷新。
library;

import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/favorites_api.dart';
import '../lib/state/favorite_status.dart';
import '../lib/theme/app_icons.dart' show AylaIcon;
import '../lib/theme/buttons.dart' show AylaPressScale;
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/favorite_button.dart'
    show AylaFavoriteButton, AylaFavoriteState;
import '../lib/widgets/base/share.dart' show AylaShareButton;

/// 可编程的假后端（与 `favorite_status_test.dart` 的注入契约一致）。
class _FakeApi {
  _FakeApi({this.statuses = const <String, int?>{}});

  Map<String, int?> statuses;
  Object? fetchError;
  Object? addError;
  Object? removeError;

  int fetchCalls = 0;
  int addCalls = 0;
  int removeCalls = 0;
  final List<String> addedIds = <String>[];

  AylaFavoriteStatusController controller() => AylaFavoriteStatusController(
        fetcher: (String type, List<String> ids) async {
          fetchCalls += 1;
          if (fetchError != null) throw fetchError!;
          return AylaFavoriteStatuses(
            targetType: type,
            // 缺 id ⇒ 控制器按 web `favoriteStatus.ts:93` 判为「响应不完整」⇒ error 态。
            statuses: <String, int?>{
              for (final String id in ids)
                if (statuses.containsKey(id)) id: statuses[id],
            },
          );
        },
        add: (String type, String id) async {
          addCalls += 1;
          if (addError != null) throw addError!;
          addedIds.add(id);
          statuses = <String, int?>{...statuses, id: 900 + addCalls};
          return 900 + addCalls;
        },
        remove: (int favoriteId) async {
          removeCalls += 1;
          if (removeError != null) throw removeError!;
          statuses = <String, int?>{
            for (final MapEntry<String, int?> e in statuses.entries)
              e.key: e.value == favoriteId ? null : e.value,
          };
        },
      );
}

void main() {
  Widget host(Widget child) => MaterialApp(
        home: previewTheme(
          Builder(
            builder: (BuildContext context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(size: const Size(600, 400)),
              child: Center(child: child),
            ),
          ),
        ),
      );

  /// 让 initState 里发出的 load 落地（假后端是同步完成的 async，microtask 即可）。
  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  String labelOf(WidgetTester tester, String label) =>
      find.text(label).evaluate().isEmpty ? '' : label;

  group('① 挂载即自动加载（web useFavoriteStatuses.ts:12–16）', () {
    testWidgets('自给自足：未接线也能从 unknown → notFavorited（页面零接线）', (
      WidgetTester tester,
    ) async {
      final _FakeApi api = _FakeApi(statuses: <String, int?>{'x': null});
      final AylaFavoriteStatusController controller = api.controller();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        host(AylaFavoriteButton(
          targetType: 'live',
          targetId: 'x',
          controller: controller,
          // ⚠️ 刻意**不传** state/busy/error/onToggle/onRetryStatus —— 页面零接线。
        )),
      );
      // 挂载首帧：状态尚为 unknown（请求已发出但未返回）→ 禁用 + 「加载中…」
      expect(find.text('加载中…'), findsOneWidget);
      expect(labelOf(tester, '收藏'), '', reason: 'unknown 档不得显示「收藏」');

      await flush(tester);
      expect(api.fetchCalls, 1, reason: '挂载即自动 load（这是「页面漏接线也不坏」的根）');
      expect(find.text('收藏'), findsOneWidget, reason: 'unknown → notFavorited 自动完成');
    });

    testWidgets('已收藏目标 → 直接落在「已收藏」（含实心图标）', (WidgetTester tester) async {
      final _FakeApi api = _FakeApi(statuses: <String, int?>{'x': 7});
      final AylaFavoriteStatusController controller = api.controller();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        host(AylaFavoriteButton(
          targetType: 'post',
          targetId: 'x',
          controller: controller,
        )),
      );
      await flush(tester);
      expect(find.text('已收藏'), findsOneWidget);
    });

    testWidgets('不传 controller ⇒ 组件自建私有实例，照样自动加载', (
      WidgetTester tester,
    ) async {
      // 私有控制器走真实 AylaFavoritesApi ⇒ 网络必然失败（测试环境无服务器），
      // 但**必须看到它发起过加载**：失败档显示「重试收藏状态」而不是永远「加载中…」。
      await tester.pumpWidget(
        host(const AylaFavoriteButton(targetType: 'live', targetId: 'x')),
      );
      await flush(tester);
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is AylaFavoriteButton && w.controller == null,
        ),
        findsOneWidget,
      );
      // 真实网络失败 ⇒ error 档（可点重试），不是 unknown 死锁
      expect(find.text('加载中…'), findsNothing, reason: '不得永久停在加载中');
    });
  });

  group('② 点击能 toggle（web FavoriteButton.tsx:32–60）', () {
    testWidgets('未收藏 → 点「收藏」→ 已收藏；再点 → 未收藏', (WidgetTester tester) async {
      final _FakeApi api = _FakeApi(statuses: <String, int?>{'x': null});
      final AylaFavoriteStatusController controller = api.controller();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        host(AylaFavoriteButton(
          targetType: 'live',
          targetId: 'x',
          controller: controller,
        )),
      );
      await flush(tester);
      expect(find.text('收藏'), findsOneWidget);

      await tester.tap(find.text('收藏'));
      await flush(tester);
      expect(api.addCalls, 1);
      expect(api.addedIds, <String>['x']);
      expect(find.text('已收藏'), findsOneWidget);

      await tester.tap(find.text('已收藏'));
      await flush(tester);
      expect(api.removeCalls, 1);
      expect(find.text('收藏'), findsOneWidget);
    });

    testWidgets('unknown 档（在途）可点：点击只重拉状态，**不会误发收藏请求**', (
      WidgetTester tester,
    ) async {
      // fetch 永不完成 ⇒ 永远停在 loading/unknown。
      // 2026-10-09 用户裁决：unknown 档不再禁用（点击 = 拉取状态）——
      // 关键是**不能误判成「未收藏」而发 add**（那会伪造收藏）。
      final _FakeApi api = _FakeApi();
      final Completer<AylaFavoriteStatuses> pending =
          Completer<AylaFavoriteStatuses>();
      final AylaFavoriteStatusController controller =
          AylaFavoriteStatusController(
        fetcher: (String type, List<String> ids) => pending.future,
        add: (String type, String id) async => 1,
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        host(AylaFavoriteButton(
          targetType: 'live',
          targetId: 'x',
          controller: controller,
        )),
      );
      await tester.pump();
      expect(find.text('加载中…'), findsOneWidget);
      await tester.tap(find.text('加载中…'), warnIfMissed: false);
      await tester.pump();
      expect(api.addCalls, 0, reason: 'unknown 档点击 ≠ 收藏（不得伪造已收藏）');
      expect(controller.favoriteIdOf('live', 'x'), isNull);
      pending.complete(
        const AylaFavoriteStatuses(
          targetType: 'live',
          statuses: <String, int?>{'x': null},
        ),
      );
      await flush(tester);
      expect(find.text('收藏'), findsOneWidget);
    });
  });

  group('③ 失败路径（web tsx:35–38 / :69）', () {
    testWidgets('加载失败 → error 档可点，点击 = 重新拉取（不是收藏）', (
      WidgetTester tester,
    ) async {
      final _FakeApi api = _FakeApi(statuses: <String, int?>{'x': null});
      api.fetchError = StateError('boom');
      final AylaFavoriteStatusController controller = api.controller();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        host(AylaFavoriteButton(
          targetType: 'live',
          targetId: 'x',
          controller: controller,
        )),
      );
      await flush(tester);
      expect(find.text('重试收藏状态'), findsOneWidget);
      expect(api.fetchCalls, 1);

      // error 档**可点**（唯一不禁用的非正常档）⇒ 点击 = force 重拉
      api.fetchError = null;
      await tester.tap(find.text('重试收藏状态'));
      await flush(tester);
      expect(api.fetchCalls, 2, reason: '点击重试必须重新拉取');
      expect(api.addCalls, 0, reason: '重试不是收藏');
      expect(find.text('收藏'), findsOneWidget);
    });

    testWidgets('收藏动作失败 → role=alert 文案 + 状态不变（tsx:55–56）', (
      WidgetTester tester,
    ) async {
      final _FakeApi api = _FakeApi(statuses: <String, int?>{'x': null});
      api.addError = StateError('网络开小差');
      final AylaFavoriteStatusController controller = api.controller();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        host(AylaFavoriteButton(
          targetType: 'live',
          targetId: 'x',
          controller: controller,
        )),
      );
      await flush(tester);
      await tester.tap(find.text('收藏'));
      await flush(tester);
      expect(api.addCalls, 1);
      expect(find.text('收藏'), findsOneWidget, reason: '动作失败 ⇒ 状态不变（不伪造成已收藏）');
      expect(controller.actionErrorOf('live', 'x'), isNotNull);
    });
  });

  group('④ 注入档零回归（既有调用点逐像素不变）', () {
    testWidgets('传 state 且不传 targetType ⇒ 完全由 widget 驱动，绝不自动请求', (
      WidgetTester tester,
    ) async {
      // 注入档没有 controller ⇒ 结构上不可能发请求；这里锁行为面：
      int retried = 0;
      bool? toggled;
      await tester.pumpWidget(
        host(AylaFavoriteButton(
          state: AylaFavoriteState.notFavorited,
          onRetryStatus: () => retried += 1,
          onToggle: (bool v) => toggled = v,
        )),
      );
      await tester.pump();
      expect(find.text('收藏'), findsOneWidget);
      await tester.tap(find.text('收藏'));
      await tester.pump();
      expect(toggled, isTrue, reason: '注入档仍走 onToggle（web 契约不变）');
      expect(retried, 0);
    });

    testWidgets('注入档 unknown → **可点**（2026-10-09 用户裁决：删掉禁用态）', (
      WidgetTester tester,
    ) async {
      // 裁决：「收藏键非得要有个禁用态？删掉得了」⇒ unknown 档点击 = 拉取状态。
      int retried = 0;
      await tester.pumpWidget(
        host(AylaFavoriteButton(
          state: AylaFavoriteState.unknown,
          onRetryStatus: () => retried += 1,
        )),
      );
      await tester.pump();
      await tester.tap(find.text('加载中…'));
      await tester.pump();
      expect(retried, 1, reason: 'unknown 档点击 = 重新拉取状态');
    });

    testWidgets('注入档 error → 可点重试（既有语义不变）', (WidgetTester tester) async {
      int retried = 0;
      await tester.pumpWidget(
        host(AylaFavoriteButton(
          state: AylaFavoriteState.error,
          onRetryStatus: () => retried += 1,
        )),
      );
      await tester.pump();
      await tester.tap(find.text('重试收藏状态'));
      await tester.pump();
      expect(retried, 1);
    });
  });

  group('⑤ retain 引用计数（web favoriteStatus.ts:63–73）', () {
    test('两个持有者 ⇒ release 一个不清状态', () {
      final AylaFavoriteStatusController controller =
          AylaFavoriteStatusController();
      addTearDown(controller.dispose);

      final void Function() releaseA =
          controller.retain('live', <String>['x']);
      final void Function() releaseB =
          controller.retain('live', <String>['x']);
      expect(controller.retainCountOf('live', 'x'), 2);

      releaseA();
      expect(controller.retainCountOf('live', 'x'), 1, reason: '计数递减而非清零');
      releaseB();
      expect(controller.retainCountOf('live', 'x'), 0);
    });

    test('release 幂等：多调一次不出现负数', () {
      final AylaFavoriteStatusController controller =
          AylaFavoriteStatusController();
      addTearDown(controller.dispose);
      final void Function() release = controller.retain('live', <String>['x']);
      release();
      release();
      release();
      expect(controller.retainCountOf('live', 'x'), 0);
    });

    test('批量 retain 一次登记全部 id；同 id 去重', () {
      final AylaFavoriteStatusController controller =
          AylaFavoriteStatusController();
      addTearDown(controller.dispose);
      final void Function() release =
          controller.retain('post', <String>['a', 'b', 'a']);
      expect(controller.retainCountOf('post', 'a'), 1);
      expect(controller.retainCountOf('post', 'b'), 1);
      release();
      expect(controller.retainCountOf('post', 'a'), 0);
      expect(controller.retainCountOf('post', 'b'), 0);
    });

    test('被 retain 的键不被 1024 淘汰，且状态保留（web favoriteStatus.ts:57）', () async {
      final AylaFavoriteStatusController controller =
          AylaFavoriteStatusController(
        fetcher: (String type, List<String> ids) async =>
            AylaFavoriteStatuses(
          targetType: type,
          statuses: <String, int?>{for (final String id in ids) id: null},
        ),
      );
      addTearDown(controller.dispose);
      final void Function() release =
          controller.retain('live', <String>['keep']);
      await controller.load('live', <String>['keep']);
      expect(controller.stateOf('live', 'keep'), AylaFavoriteState.notFavorited);
      release();
      expect(controller.retainCountOf('live', 'keep'), 0);
      expect(
        controller.stateOf('live', 'keep'),
        AylaFavoriteState.notFavorited,
        reason: 'release 只减计数，不清状态（web 同语义）',
      );
    });
  });

  group('⑥ 状态变化自动刷新（controller → 按钮）', () {
    testWidgets('外部 apply（WS favorite.changed）⇒ 按钮立即改档', (
      WidgetTester tester,
    ) async {
      final _FakeApi api = _FakeApi(statuses: <String, int?>{'x': null});
      final AylaFavoriteStatusController controller = api.controller();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        host(AylaFavoriteButton(
          targetType: 'live',
          targetId: 'x',
          controller: controller,
        )),
      );
      await flush(tester);
      expect(find.text('收藏'), findsOneWidget);

      // web `applyFavoriteStatus`（favoriteStatus.ts:76–79）由 WS 帧驱动
      controller.apply('live', 'x', 42);
      await tester.pump();
      expect(find.text('已收藏'), findsOneWidget);
    });

    testWidgets('卸载 → release（不留引用计数）', (WidgetTester tester) async {
      final _FakeApi api = _FakeApi(statuses: <String, int?>{'x': null});
      final AylaFavoriteStatusController controller = api.controller();
      addTearDown(controller.dispose);

      // ⚠️ 不能靠「第二次 pumpWidget 换个根」来卸载：`previewTheme` 的 Overlay
      //    `initialEntries` 只在首次创建生效（既有测试已登记的坑）⇒ 旧子树不会被卸载。
      //    改用**树内** StatefulBuilder 真正把按钮移出树。
      bool mounted = true;
      late StateSetter rebuild;
      await tester.pumpWidget(
        host(StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            rebuild = setState;
            return mounted
                ? AylaFavoriteButton(
                    targetType: 'live',
                    targetId: 'x',
                    controller: controller,
                  )
                : const SizedBox.shrink();
          },
        )),
      );
      await flush(tester);
      expect(controller.retainCountOf('live', 'x'), 1);

      rebuild(() => mounted = false);
      await tester.pump();
      expect(controller.retainCountOf('live', 'x'), 0, reason: '卸载即 release');
      expect(
        find.byType(AylaFavoriteButton),
        findsNothing,
        reason: '自证子树真的被移除了（而不是 finder 没区分度）',
      );
    });

    testWidgets('自给自足 → 注入档切换：私有控制器被销毁（不泄漏、不解绑失败）', (
      WidgetTester tester,
    ) async {
      // 锁住 2026-10-08 实测到的一个真实泄漏：`_unbind` 曾用「**新的** widget.selfLoading」
      // 做提前 return 的判据 —— 而从「自给自足 + 私有控制器」切到「注入档」时它已是 false
      // ⇒ 私有控制器与监听器都留在树上。判别条件必须只看本实例自己的 _owned/_release。
      bool selfMode = true;
      late StateSetter rebuild;
      await tester.pumpWidget(
        host(StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            rebuild = setState;
            return selfMode
                ? AylaFavoriteButton(targetType: 'live', targetId: 'x')
                : AylaFavoriteButton(
                    state: AylaFavoriteState.notFavorited,
                    onToggle: (_) {},
                  );
          },
        )),
      );
      await flush(tester);
      await tester.pump(const Duration(milliseconds: 50));

      rebuild(() => selfMode = false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // 切换后仍是可用的注入档（自证切换真的发生了）
      expect(find.text('收藏'), findsOneWidget);
      expect(
        tester
            .widget<AylaFavoriteButton>(find.byType(AylaFavoriteButton))
            .controller,
        isNull,
      );
      expect(tester.takeException(), isNull, reason: '切换过程不得抛异常');
    });

    testWidgets('切 targetId ⇒ 重新绑定：新目标自动加载', (WidgetTester tester) async {
      final _FakeApi api = _FakeApi(
        statuses: <String, int?>{'x': null, 'y': 5},
      );
      final AylaFavoriteStatusController controller = api.controller();
      addTearDown(controller.dispose);

      String id = 'x';
      late StateSetter rebuild;
      await tester.pumpWidget(
        host(StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            rebuild = setState;
            return AylaFavoriteButton(
              targetType: 'live',
              targetId: id,
              controller: controller,
            );
          },
        )),
      );
      await flush(tester);
      expect(find.text('收藏'), findsOneWidget);

      rebuild(() => id = 'y');
      await flush(tester);
      expect(controller.retainCountOf('live', 'x'), 0, reason: '旧目标 release');
      expect(controller.retainCountOf('live', 'y'), 1, reason: '新目标 retain');
    });
  });

  group('⑦ 样式统一（与分享键同组，auroraqua.css:54–94）', () {
    /// 两键并排（与 `post_card.dart` 底排同构：收藏 compact + 8px 间隙 + 分享 32）。
    Widget pair() => Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AylaFavoriteButton(
                state: AylaFavoriteState.notFavorited,
                compact: true,
                onToggle: (_) {},
              ),
              // 与 web 底排同构的间隔（`post_card.dart:508` 用 sp4）
              SizedBox(width: 8),
              AylaShareButton(label: '分享帖子', onPressed: () {}),
            ],
          ),
        );

    testWidgets('尺寸同为 32×32、图标同为 16；两件共用同一交互壳（hover 1.02）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(pair()));
      await tester.pump();

      expect(
        tester.getSize(find.byType(AylaFavoriteButton)),
        const Size(32, 32),
        reason: '.favorite-toggle.is-compact（app.css:3334–3338）',
      );
      expect(
        tester.getSize(find.byType(AylaShareButton)),
        const Size(32, 32),
        reason: '用户 2026-09-22 裁决：同排统一取 32（web 原为 icon-btn-40 的 40）',
      );
      // 两键的交互反馈同源（web 把它们写在同一个 :is() 组 ⇒ hover 1.02 / active .98 一致）
      expect(find.byType(AylaPressScale), findsNWidgets(2));
    });

    testWidgets('实测：hover 到哪一键，哪一键的图标被放大到 1.02（另一键保持 1.00）', (
      WidgetTester tester,
    ) async {
      // 判定口径：量**渲染尺寸**（getRect 会应用 paint transform），不看 widget 属性——
      // 本项目 2026-09-19 的教训：布局矩形正确 ≠ 真的画成了那个样子。
      await tester.pumpWidget(host(pair()));
      await tester.pump();

      final Finder fav = find.byType(AylaFavoriteButton);
      final Finder share = find.byType(AylaShareButton);
      double favIcon() => tester
          .getRect(find.descendant(of: fav, matching: find.byType(AylaIcon)))
          .width;
      double shareIcon() => tester
          .getRect(find.descendant(of: share, matching: find.byType(AylaIcon)))
          .width;

      expect(favIcon(), 16, reason: 'compact 图标 16（FavoriteButton.tsx:74）');
      expect(shareIcon(), 16, reason: '32 档图标 16（share.dart:893）');

      final TestGesture mouse =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await tester.pump();

      // ① hover 收藏键 ⇒ 只有它放大
      await mouse.moveTo(tester.getCenter(fav));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(favIcon(), closeTo(16 * 1.02, 0.05), reason: '收藏键必须 hover 放大（修前恒 1.00）');
      expect(shareIcon(), 16, reason: '未 hover 的分享键不动');

      // ② hover 分享键 ⇒ 只有它放大（证明两键行为一致，不是「收藏键也不能动」）
      await mouse.moveTo(tester.getCenter(share));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(shareIcon(), closeTo(16 * 1.02, 0.05));
      expect(favIcon(), 16);

      // ③ 移开 ⇒ 双双回 1.00
      await mouse.moveTo(const Offset(1, 1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(favIcon(), 16);
      expect(shareIcon(), 16);
    });

    testWidgets('reduced-motion ⇒ 两键都不放大（auroraqua.css:655–674）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(MaterialApp(
        home: previewTheme(
          Builder(
            builder: (BuildContext c) => MediaQuery(
              data: MediaQuery.of(c).copyWith(
                size: const Size(400, 300),
                disableAnimations: true,
              ),
              child: pair(),
            ),
          ),
        ),
      ));
      await tester.pump();
      final Finder fav = find.byType(AylaFavoriteButton);
      double favIcon() => tester
          .getRect(find.descendant(of: fav, matching: find.byType(AylaIcon)))
          .width;
      final TestGesture mouse =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await tester.pump();
      await mouse.moveTo(tester.getCenter(fav));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(favIcon(), 16, reason: 'reduced-motion ⇒ 取消缩放');
    });
  });
}
