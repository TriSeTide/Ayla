/// 跨页面媒体会话悬浮球（`layout/SessionActivityIndicator.tsx` 181 行）的**接线回归锁**。
///
/// ## 为什么单独一条文件
/// 2026-10 实测发现：本件在 Flutter 侧**组件写完了但从未接线** ——
/// `app_shell.dart` 挂的是 `const AylaSessionActivityIndicator()`，两个会话参数恒为 null，
/// 而组件在「两个都 null」时返回 `SizedBox.shrink()`（等价 tsx 135 的 `return null`）
/// ⇒ 真实运行时**永远不会出现**，且 `dart analyze` 与既有组件测试**都发现不了**
/// （它们的调用方就是样张/测试自己）。
///
/// 这与 `GroupCreateDialog`（`home_page.dart:745–760` 记录的"裸接线"静默无反应）、
/// `QuickMessagesSheet`（标志位有、渲染点无）是**同一类**接线缺口。
/// 本文件的职责 = 把「壳层必须把真实数据喂给悬浮球」这件事锁住。
///
/// ## 覆盖（逐条对齐 web）
/// 壳层接线：
/// ① 不在任何会话 ⇒ 两个参数都 null（等价 tsx 135 零渲染）；
/// ② 在语音且不在语音房路由 ⇒ 语音球带**索引里的** title / sourceRoute（tsx 41–54）；
/// ③ 索引缺该 id ⇒ **兜底投影**：title 字面量「语音房」、路由 `/voice/:id`（tsx 49）；
/// ④ 直播同理，兜底路由是 `/live/start/:id`、title「直播间」（tsx 63）；
/// ⑤ 在语音房自己的路由上 ⇒ 语音球隐藏（tsx 71–74）；
/// ⑥ 群内语音：`pathname == sourceRoute`（`/group/:id/voice`）⇒ 同样隐藏；
/// ⑦ 直播球只在 `/live/start/:id` 上隐藏；进**普通直播间** `/live/:id` 时**仍显示**
///    （tsx 76–79 的注释就是这么写的）；
/// ⑧ 点球的回调走 `sourceRoute` 导航。
///
/// 索引状态机（web `stores/sessionActivity.ts`）：
/// ⑨ `upsert` 整体替换 + 补 `updatedAt`；⑩ `setStatus` 无记录静默返回、`lastError` 覆盖写；
/// ⑪ `clear(kind, idle)` 置空 vs `clear(kind, ended)` 留痕；⑫ `reset` 两条一起清。
///
/// 登录态投影（web `stores/auth.ts:80–91` `setMediaActivity`）：
/// ⑬ 置真写入 roomId；⑭ 置假**连 roomId 一并清 null**；⑮ 未登录时静默返回。
library;

import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/layout/app_shell.dart';
import '../lib/state/auth_state.dart';
import '../lib/state/room_providers.dart' show sessionActivityProvider;
import '../lib/state/session_activity_state.dart';
import '../lib/theme/app_theme.dart';
import '../lib/widgets/shell/session_activity.dart';

/// 一条最小用户（四个媒体字段是本节的主角，其余按序列化契约给空值）。
AuthUser _user({
  bool isInVoice = false,
  String? voiceRoomId,
  bool isLive = false,
  String? liveRoomId,
}) =>
    AuthUser(
      id: 'me',
      username: 'me',
      nickname: '我',
      avatar: '',
      signature: '',
      status: 'online',
      online: true,
      displayStatus: '',
      dateJoined: '',
      isInVoice: isInVoice,
      voiceRoomId: voiceRoomId,
      isLive: isLive,
      liveRoomId: liveRoomId,
      showContent: true,
      email: '',
    );

void main() {
  // ⚠️ `aylaSessionActivity` 是**模块级单例**（web 的 zustand store 同款），
  // 它跨用例存活 ⇒ 每个用例前后都必须显式复位，否则「索引缺该 id ⇒ 兜底投影」
  // 这类用例会读到上一个用例留下的记录（实测踩过：兜底 title 读成了别人的频道名）。
  setUp(aylaSessionActivity.reset);
  tearDown(aylaSessionActivity.reset);

  group('会话活动索引（web stores/sessionActivity.ts）', () {
    late AylaSessionActivityStore store;

    setUp(() => store = AylaSessionActivityStore());
    tearDown(() => store.dispose());

    AylaActivityRecord voiceRecord({
      String sessionId = '5',
      String title = '深夜电台',
      AylaActivityStatus status = AylaActivityStatus.connecting,
    }) =>
        AylaActivityRecord(
          kind: AylaActivityKind.voice,
          sessionId: sessionId,
          sourceRoute: '/voice/$sessionId',
          title: title,
          status: status,
        );

    test('⑨ upsert 整体替换该 kind（不合并旧值）并补 updatedAt', () {
      store.upsert(voiceRecord(title: '第一个'));
      final DateTime? firstAt = store.voiceSession!.updatedAt;
      expect(firstAt, isNotNull, reason: 'upsert 未给 updatedAt ⇒ 由 store 补当前时间');

      store.upsert(voiceRecord(title: '第二个'));
      expect(store.voiceSession!.title, '第二个');
      expect(store.voiceSession!.updatedAt, isNotNull);

      // 另一条 kind 不受影响（web 用 kind 选 key）。
      store.upsert(const AylaActivityRecord(
        kind: AylaActivityKind.live,
        sessionId: '9',
        sourceRoute: '/live/start/9',
        title: '直播间',
      ));
      expect(store.voiceSession!.title, '第二个');
      expect(store.liveSession!.sessionId, '9');
    });

    test('⑩ setStatus：无该 kind 记录时静默返回；lastError 缺省即清空（覆盖写）', () {
      store.setStatus(AylaActivityKind.voice, AylaActivityStatus.connected);
      expect(store.voiceSession, isNull, reason: 'web: if (!current) return state');

      store.upsert(voiceRecord());
      store.setStatus(
        AylaActivityKind.voice,
        AylaActivityStatus.failed,
        lastError: '进房失败',
      );
      expect(store.voiceSession!.status, AylaActivityStatus.failed);
      expect(store.voiceSession!.lastError, '进房失败');

      // 再调一次不传 lastError ⇒ 上一轮的错误被清掉（web 的覆盖写语义）。
      store.setStatus(AylaActivityKind.voice, AylaActivityStatus.connected);
      expect(store.voiceSession!.lastError, isNull);
    });

    test('⑪ clear：默认 ended 留痕；idle 把记录整条置空', () {
      store.upsert(voiceRecord());
      store.clear(AylaActivityKind.voice);
      expect(store.voiceSession, isNotNull, reason: '默认 status = "ended" ⇒ 保留记录');
      expect(store.voiceSession!.status, AylaActivityStatus.ended);

      store.clear(AylaActivityKind.voice, AylaActivityStatus.idle);
      expect(store.voiceSession, isNull, reason: 'status === "idle" ⇒ 置 null');

      // 无记录时静默返回（不抛）。
      store.clear(AylaActivityKind.live, AylaActivityStatus.idle);
      expect(store.liveSession, isNull);
    });

    test('⑫ reset 两条一起清空', () {
      store.upsert(voiceRecord());
      store.upsert(const AylaActivityRecord(
        kind: AylaActivityKind.live,
        sessionId: '9',
        sourceRoute: '/live/start/9',
        title: '直播间',
      ));
      store.reset();
      expect(store.voiceSession, isNull);
      expect(store.liveSession, isNull);
    });
  });

  group('登录态媒体活动投影（web stores/auth.ts:80–91）', () {
    test('⑬⑭ setMediaActivity：置真写 roomId，置假连 roomId 一并清空', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      final AuthNotifier auth = container.read(authNotifierProvider.notifier);
      auth.setUser(_user());

      auth.setMediaActivity(
        kind: AylaMediaActivityKind.voice,
        active: true,
        roomId: '5',
      );
      expect(container.read(authNotifierProvider).user!.isInVoice, isTrue);
      expect(container.read(authNotifierProvider).user!.voiceRoomId, '5');
      // 另一条 kind 不受影响（web 的三元只改自己那一支）。
      expect(container.read(authNotifierProvider).user!.isLive, isFalse);

      auth.setMediaActivity(kind: AylaMediaActivityKind.voice, active: false);
      expect(container.read(authNotifierProvider).user!.isInVoice, isFalse);
      expect(
        container.read(authNotifierProvider).user!.voiceRoomId,
        isNull,
        reason: 'web: active ? roomId : null —— 退出时 roomId 一并置 null',
      );
    });

    test('⑮ 未登录（无 user）时静默返回，不凭空造一个用户', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      final AuthNotifier auth = container.read(authNotifierProvider.notifier);

      auth.setMediaActivity(
        kind: AylaMediaActivityKind.live,
        active: true,
        roomId: '9',
      );
      expect(container.read(authNotifierProvider).user, isNull);
    });
  });

  group('壳层接线（AppShell.tsx:130 + SessionActivityIndicator.tsx:34–82）', () {
    /// 在「iOS 平台」下跑一段测试体，**并在体内复位** `debugDefaultTargetPlatformOverride`。
    ///
    /// 为什么必须体内复位：flutter_test 在**测试体结束后、tearDown 之前**就断言
    /// 「foundation 调试变量已复位」（`_verifyInvariants`）⇒ 用 `tearDown` / `addTearDown`
    /// 复位都会晚一步、被判成「测试改了调试变量」。
    ///
    /// 为什么要伪装平台：Windows / Android 上悬浮球**不再在应用内渲染**
    /// （用户要求「应用内不再存在任何浮层」，渲染宿主搬到了窗口外第二引擎的透明叠加层）。
    /// 本组用例锁的是**壳层投影逻辑**（取哪条记录 / 兜底 title+route / 在哪些路由上隐藏），
    /// 那份逻辑与平台无关，只是渲染点不同；iOS 是「无跨应用悬浮能力 ⇒ 保留应用内渲染」
    /// 的档位，正好用它验证投影本身。窗口外那条链路由 `live_mini_player_host_test.dart`
    /// 与原生侧覆盖。
    Future<void> onIosPlatform(Future<void> Function() body) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    /// 壳层宿主：自建最小 GoRouter（不 import 整张路由表，同 `app_shell_fabs_test.dart`）。
    ///
    /// 返回 [ProviderContainer] 以便用例直接改写 auth / 索引（等价 web 的
    /// `useAuthStore.getState().setMediaActivity(...)` 与 `useSessionActivityStore.upsert`）。
    Future<ProviderContainer> pumpShell(
      WidgetTester tester,
      String location, {
      AuthUser? user,
      void Function(ProviderContainer c)? seed,
    }) async {
      // ⚠️ **必须把平台伪装成 iOS**（2026-10-31）：
      // Windows / Android 上悬浮球**不再在应用内渲染**（用户要求「应用内不再存在任何浮层」，
      // 渲染宿主搬到了窗口外第二引擎的透明叠加层，见 `app_shell.dart` 的 `_SessionActivityHost`）。
      // 而本组用例锁的是**壳层投影逻辑**（voice/live 取哪条记录、兜底 title/route、
      // 在哪些路由上隐藏）—— 那份逻辑与平台无关，只是渲染点不同。
      // iOS 是「无跨应用悬浮能力 ⇒ 保留应用内渲染」的档位，正好用它验证投影本身。
      // 窗口外那条链路由 `live_mini_player_host_test.dart` / `session_activity_detach_test.dart`
      // 与原生侧覆盖。
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(authNotifierProvider.notifier).setTokens('access', 'r');
      if (user != null) container.read(authNotifierProvider.notifier).setUser(user);
      seed?.call(container);
      final GoRouter router = GoRouter(
        initialLocation: location,
        routes: <RouteBase>[
          ShellRoute(
            builder: (BuildContext c, GoRouterState s, Widget child) =>
                AppShell(child: child),
            routes: <RouteBase>[
              // 覆盖本文件用到的全部路由（含参数段的两种形状）。
              GoRoute(
                path: '/group',
                builder: (BuildContext c, GoRouterState s) =>
                    const SizedBox.shrink(),
              ),
              GoRoute(
                path: '/voice/:channelId',
                builder: (BuildContext c, GoRouterState s) =>
                    const SizedBox.shrink(),
              ),
              GoRoute(
                path: '/live/start/:channelId',
                builder: (BuildContext c, GoRouterState s) =>
                    const SizedBox.shrink(),
              ),
              GoRoute(
                path: '/live/:channelId',
                builder: (BuildContext c, GoRouterState s) =>
                    const SizedBox.shrink(),
              ),
              GoRoute(
                path: '/group/:groupId/voice',
                builder: (BuildContext c, GoRouterState s) =>
                    const SizedBox.shrink(),
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            theme: buildAylaTheme(),
            builder: (BuildContext context, Widget? child) => Scaffold(
              backgroundColor: Colors.transparent,
              body: child,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      return container;
    }


    AylaSessionActivityIndicator indicator(WidgetTester tester) =>
        tester.widget<AylaSessionActivityIndicator>(
          find.byType(AylaSessionActivityIndicator),
        );

    testWidgets('① 不在任何会话 ⇒ 两个参数都为 null（零渲染）', (WidgetTester tester) async => onIosPlatform(() async {
      await pumpShell(tester, '/group', user: _user());

      expect(indicator(tester).voice, isNull);
      expect(indicator(tester).live, isNull);
      expect(
        tester.getSize(find.byType(AylaSessionActivityIndicator)),
        Size.zero,
        reason: 'tsx 135：两球都无 ⇒ return null（Flutter 用 0×0 表达）',
      );
    }));

    testWidgets('② 在语音且不在房内路由 ⇒ 语音球取**索引里的** title / sourceRoute',
        (WidgetTester tester) async => onIosPlatform(() async {
      await pumpShell(
        tester,
        '/group',
        user: _user(isInVoice: true, voiceRoomId: '5'),
        seed: (ProviderContainer c) =>
            c.read(sessionActivityProvider).upsert(const AylaActivityRecord(
              kind: AylaActivityKind.voice,
              sessionId: '5',
              sourceRoute: '/group/g1/voice',
              title: '深夜电台',
            )),
      );

      final AylaActivitySession? voice = indicator(tester).voice;
      expect(voice, isNotNull);
      expect(voice!.sessionId, '5');
      expect(voice.title, '深夜电台', reason: 'tsx 42–53：id 命中 ⇒ 整条沿用索引记录');
      expect(voice.sourceRoute, '/group/g1/voice');
      expect(indicator(tester).live, isNull);
    }));

    testWidgets('③ 索引缺该 id ⇒ 兜底投影（title「语音房」+ /voice/:id）',
        (WidgetTester tester) async => onIosPlatform(() async {
      await pumpShell(
        tester,
        '/group',
        user: _user(isInVoice: true, voiceRoomId: '5'),
      );

      final AylaActivitySession? voice = indicator(tester).voice;
      expect(voice, isNotNull, reason: '索引还没写入时也必须显示球（tsx 44–53 的兜底分支）');
      expect(voice!.title, '语音房', reason: 'tsx 49 的字面量');
      expect(voice.sourceRoute, '/voice/5');
    }));

    testWidgets('④ 直播兜底投影：title「直播间」+ /live/start/:id', (WidgetTester tester) async => onIosPlatform(() async {
      await pumpShell(
        tester,
        '/group',
        user: _user(isLive: true, liveRoomId: '9'),
      );

      final AylaActivitySession? live = indicator(tester).live;
      expect(live, isNotNull);
      expect(live!.title, '直播间', reason: 'tsx 63 的字面量');
      expect(live.sourceRoute, '/live/start/9');
    }));

    testWidgets('⑤ 在语音房自己的路由上 ⇒ 语音球隐藏（tsx 71–74）',
        (WidgetTester tester) async => onIosPlatform(() async {
      await pumpShell(
        tester,
        '/voice/5',
        user: _user(isInVoice: true, voiceRoomId: '5'),
      );

      expect(indicator(tester).voice, isNull);
    }));

    testWidgets('⑥ 群内语音：pathname == sourceRoute ⇒ 同样隐藏', (WidgetTester tester) async => onIosPlatform(() async {
      await pumpShell(
        tester,
        '/group/g1/voice',
        user: _user(isInVoice: true, voiceRoomId: '5'),
        seed: (ProviderContainer c) =>
            c.read(sessionActivityProvider).upsert(const AylaActivityRecord(
              kind: AylaActivityKind.voice,
              sessionId: '5',
              sourceRoute: '/group/g1/voice',
              title: '群语音',
            )),
      );

      expect(indicator(tester).voice, isNull);
    }));

    testWidgets('⑦ 直播球只在开播控制台隐藏；普通直播间里仍显示（tsx 76–79）',
        (WidgetTester tester) async => onIosPlatform(() async {
      await pumpShell(
        tester,
        '/live/start/9',
        user: _user(isLive: true, liveRoomId: '9'),
      );
      expect(indicator(tester).live, isNull, reason: 'tsx 76–79：onLiveConsole 判据');

      await pumpShell(
        tester,
        '/live/9',
        user: _user(isLive: true, liveRoomId: '9'),
      );
      expect(
        indicator(tester).live,
        isNotNull,
        reason: 'web 原话：进入任何普通直播间都必须显示',
      );
    }));

    testWidgets('⑧ 点球的回调按 sourceRoute 导航', (WidgetTester tester) async => onIosPlatform(() async {
      final ProviderContainer container = await pumpShell(
        tester,
        '/group',
        user: _user(isInVoice: true, voiceRoomId: '5'),
        seed: (ProviderContainer c) =>
            c.read(sessionActivityProvider).upsert(const AylaActivityRecord(
              kind: AylaActivityKind.voice,
              sessionId: '5',
              sourceRoute: '/voice/5',
              title: '深夜电台',
            )),
      );
      final GoRouter router = GoRouter.of(
        tester.element(find.byType(AppShell)),
      );

      indicator(tester).onOpenSession!(indicator(tester).voice!);
      await tester.pump(const Duration(milliseconds: 100));

      expect(router.state.uri.path, '/voice/5');
      // 导航后已进房 ⇒ 球按 ⑤ 的判据自行隐藏，闭环。
      expect(container.read(authNotifierProvider).user!.voiceRoomId, '5');
      expect(indicator(tester).voice, isNull);
    }));
  });
}