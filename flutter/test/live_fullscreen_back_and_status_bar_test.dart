/// 手机端全屏直播的返回键与状态栏回归锁（2026-11-01 用户实报）。
///
/// ## 需求原文（两条）
/// 1. 「手机端全屏看直播的时候顶部状态栏要隐藏」
/// 2. 「手机端进入全屏直播时返回键不是返回到主页，而是返回没全屏的状态的直播间」
///
/// ## 修复前的真实行为
/// - **返回键**：全屏层只是插进 root Overlay 的浮层，路由仍在 `/live/:channelId`
///   ⇒ 系统返回走 `context.pop()`（进房是 push）⇒ **直接退出直播间**。
/// - **状态栏**：全屏只做了「插 Overlay + 锁横屏」，从头到尾没有调过任何
///   `SystemChrome` / 原生通道 ⇒ 状态栏一直压在画面上。
///
/// ## 本文件锁什么
/// ① 纯函数分档：全屏时返回键的档位是 `liveFullscreen`（且**优先于**所有其它档）；
/// ② 真播放器里：进全屏 ⇒ 登记处理器；调它 ⇒ **只退全屏、路由不动**；退出后注销；
/// ③ 真播放器里：dispose（全屏中离开页面）也必须注销，不能留悬空处理器；
/// ④ 进/退全屏分别向系统栏控制器下发 `setImmersive(true/false)`；
/// ⑤ 桌面端（窗口级全屏）**不**下发沉浸式。
///
/// ## 为什么用注入的系统栏替身而不是 mock 平台通道
/// `aylaSetImmersive` 内部按 `defaultTargetPlatform` 分派，测试里改那个标志会被
/// binding 的 `debugAssertAllFoundationVarsUnset` 判为失败（`The value of a
/// foundation debug variable was changed by the test`）。注入替身既避开这个坑，
/// 又直接锁住「组件向控制器发了什么」（原生通道本身由 MainActivity 编译保证）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/layout/app_back.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/live/live_player.dart';

/// 系统栏替身：只记录「进入/退出沉浸式」的调用序列。
class _FakeSystemUi extends AylaSystemUiController {
  _FakeSystemUi();

  final List<bool> calls = <bool>[];

  @override
  Future<void> setImmersive(bool enabled) async {
    calls.add(enabled);
  }
}

void main() {
  Finder byLabel(String label) => find.byWidgetPredicate(
    (Widget w) => w is Semantics && w.properties.label == label,
  );

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Widget host(Widget child, {Size viewport = const Size(400, 800)}) {
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox.fromSize(size: viewport, child: child),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> enterFullscreen(WidgetTester tester) async {
    await tester.tap(find.byType(AylaLivePlayer), warnIfMissed: false);
    await tester.pump();
    await tester.tap(byLabel('全屏').first);
    await settle(tester);
  }

  group('① 返回键分档（纯函数契约）', () {
    test('全屏在档 ⇒ liveFullscreen，且优先于「能 pop」与「群场景」', () {
      expect(
        aylaBackActionFor(
          canPop: true,
          pathname: '/live/7',
          hasLiveFullscreen: true,
        ),
        AylaBackAction.liveFullscreen,
        reason: '全屏时按返回只退全屏，绝不能 pop 掉直播间',
      );
      expect(
        aylaBackActionFor(
          canPop: true,
          pathname: '/group/g1/live/3',
          hasLiveFullscreen: true,
        ),
        AylaBackAction.liveFullscreen,
        reason: '群内直播全屏同样先退全屏（群场景档排在它后面）',
      );
      expect(
        aylaBackActionFor(
          canPop: true,
          pathname: '/live/7',
          hasLiveFullscreen: false,
        ),
        AylaBackAction.popRoute,
        reason: '没全屏时语义不变：正常 pop',
      );
      expect(
        aylaBackActionFor(
          canPop: false,
          pathname: '/group',
          hasLiveFullscreen: false,
        ),
        AylaBackAction.homeExit,
        reason: '主页语义不能被这一档改坏（连按两次退出）',
      );
    });
  });

  group('② 全屏期间的返回键（真播放器）', () {
    testWidgets('进全屏 ⇒ 登记处理器；调用后只退全屏、不 pop；退出后注销', (
      WidgetTester tester,
    ) async {
      addTearDown(() => aylaLiveFullscreenBackHandler = null);
      final List<bool> events = <bool>[];
      await tester.pumpWidget(
        host(
          AylaLivePlayer(
            srsStatus: AylaLiveSrsStatus.live,
            onFullscreenChanged: events.add,
            videoView: const ColoredBox(color: Color(0xFF223344)),
          ),
        ),
      );
      await settle(tester);
      expect(aylaLiveFullscreenBackHandler, isNull, reason: '未全屏时不该有处理器');

      await enterFullscreen(tester);
      expect(byLabel('退出全屏'), findsOneWidget);
      final AylaLiveFullscreenBackHandler? handler =
          aylaLiveFullscreenBackHandler;
      expect(handler, isNotNull, reason: '进全屏必须登记返回键处理器');

      // 模拟系统返回键：处理器返回 true（本次已处理），全屏层消失。
      expect(
        handler!.call(),
        isTrue,
        reason: '必须自报「已处理」，否则框架会 pop 掉直播间',
      );
      await settle(tester);
      expect(byLabel('退出全屏'), findsNothing, reason: '退出全屏后浮层必须收起');
      expect(events, <bool>[true, false]);
      expect(
        aylaLiveFullscreenBackHandler,
        isNull,
        reason: '退出全屏后必须注销，否则返回键会一直被它吞掉',
      );

      // 页面本身还在（没有 pop）——用播放器仍在树上证明。
      expect(find.byType(AylaLivePlayer), findsOneWidget);
    });

    testWidgets('全屏中直接离开页面（dispose）⇒ 处理器注销', (
      WidgetTester tester,
    ) async {
      addTearDown(() => aylaLiveFullscreenBackHandler = null);
      await tester.pumpWidget(
        host(
          const AylaLivePlayer(
            srsStatus: AylaLiveSrsStatus.live,
            videoView: ColoredBox(color: Color(0xFF223344)),
          ),
        ),
      );
      await settle(tester);
      await enterFullscreen(tester);
      expect(aylaLiveFullscreenBackHandler, isNotNull);

      // 整棵树换掉 ⇒ AylaLivePlayer 被 dispose
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
      expect(
        aylaLiveFullscreenBackHandler,
        isNull,
        reason: '留下悬空处理器 ⇒ 下一次按返回会打到已销毁的 State',
      );
    });
  });

  group('④⑤ 状态栏：进全屏隐藏、退出恢复', () {
    testWidgets('进全屏 ⇒ setImmersive(true)；退出 ⇒ setImmersive(false)', (
      WidgetTester tester,
    ) async {
      final _FakeSystemUi ui = _FakeSystemUi();
      await tester.pumpWidget(
        host(
          AylaLivePlayer(
            srsStatus: AylaLiveSrsStatus.live,
            systemUi: ui,
            videoView: const ColoredBox(color: Color(0xFF223344)),
          ),
        ),
      );
      await settle(tester);
      expect(ui.calls, isEmpty, reason: '未全屏时不得动系统栏');

      await enterFullscreen(tester);
      await settle(tester);
      expect(
        ui.calls,
        <bool>[true],
        reason: '全屏必须隐藏状态栏/导航栏（targetSdk 36 下只能走原生通道）',
      );

      await tester.tap(byLabel('退出全屏'));
      await settle(tester);
      expect(
        ui.calls,
        <bool>[true, false],
        reason: '退出全屏必须把系统栏还回来（否则整个 App 都没有状态栏）',
      );
    });

    testWidgets('全屏中离开页面（dispose）也会恢复系统栏', (WidgetTester tester) async {
      final _FakeSystemUi ui = _FakeSystemUi();
      await tester.pumpWidget(
        host(
          AylaLivePlayer(
            srsStatus: AylaLiveSrsStatus.live,
            systemUi: ui,
            videoView: const ColoredBox(color: Color(0xFF223344)),
          ),
        ),
      );
      await settle(tester);
      await enterFullscreen(tester);
      expect(ui.calls, <bool>[true]);

      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
      expect(ui.calls, <bool>[true, false]);
    });

    testWidgets('桌面端（窗口级全屏）不下发沉浸式', (WidgetTester tester) async {
      // 桌面走 window_manager.setFullScreen，系统栏本来就不存在。
      final _FakeSystemUi ui = _FakeSystemUi();
      await tester.pumpWidget(
        host(
          AylaLivePlayer(
            srsStatus: AylaLiveSrsStatus.live,
            systemUi: ui,
            desktopFullscreen: true,
            videoView: const ColoredBox(color: Color(0xFF223344)),
          ),
        ),
      );
      await settle(tester);
      await enterFullscreen(tester);
      await settle(tester);
      expect(ui.calls, isEmpty);
    });
  });

  group('③ 真实返回键链路（BackButtonListener → 分档 → 退全屏）', () {
    testWidgets('按系统返回键：全屏退出，路由原地不动（不离开直播间）', (
      WidgetTester tester,
    ) async {
      addTearDown(() => aylaLiveFullscreenBackHandler = null);
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // 真实 GoRouter + 真实 AylaBackButtonHost（AppShell 里挂的就是这一件）。
      final GoRouter router = GoRouter(
        initialLocation: '/live/7',
        routes: <RouteBase>[
          GoRoute(
            path: '/live/:id',
            builder: (BuildContext c, GoRouterState s) => AylaBackButtonHost(
              pathname: s.uri.path,
              canPop: true,
              onGoHome: () {},
              onGroupBack: () async => true,
              child: const AylaLivePlayer(
                srsStatus: AylaLiveSrsStatus.live,
                videoView: ColoredBox(color: Color(0xFF223344)),
              ),
            ),
          ),
          GoRoute(
            path: '/group',
            builder: (BuildContext c, GoRouterState s) =>
                const Scaffold(body: Text('主页')),
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          builder: (BuildContext context, Widget? child) =>
              previewScope(child ?? const SizedBox.shrink()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await enterFullscreen(tester);
      expect(byLabel('退出全屏'), findsOneWidget);

      // 真实系统返回键
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        byLabel('退出全屏'),
        findsNothing,
        reason: '返回键必须退出全屏（修复前这里是直接离开直播间）',
      );
      expect(
        router.routerDelegate.currentConfiguration.uri.toString(),
        '/live/7',
        reason: '返回键在全屏里不得 pop 掉直播间 —— 用户要的是「回到没全屏的直播间」',
      );
      expect(find.text('主页'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
