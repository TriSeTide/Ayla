/// 语音悬浮球在**语音列表页**（`/voice`）必须显示 —— 用户实报（2026-10-17）。
///
/// ## 现象
/// 人在语音房（列表首卡显示「我在其中」），回到语音列表页 `/voice` 却看不到语音悬浮球
/// （web 有这个球，点它回语音房）。
///
/// ## 事实源（web `layout/SessionActivityIndicator.tsx`）
/// | 环节 | 行 | 判据 |
/// |---|---|---|
/// | 显示 | :81 | `showVoice = currentUser.is_in_voice && voice && !onVoiceRoom` |
/// | 隐藏集合 | :71–74 | `onVoiceRoom = pathname === "/voice/:id" \|\| pathname === sourceRoute` |
/// | | | ⇒ **`/voice`（列表页）不在隐藏集合里** ⇒ 球必须显示 |
/// | 回房目标 | :148 | `navigate(voice.sourceRoute \|\| "/voice/:id")` |
/// | 活动索引 upsert | useVoiceChannel.ts:256–262 | `sourceRoute = pathname.startsWith("/group/") ? pathname : "/voice/:id"` |
///
/// ## 本文件锁什么
/// ① `/voice` 列表页 + `is_in_voice` ⇒ 语音球显示；
/// ② `/voice/:id` 房内页 ⇒ 语音球隐藏（防回归）；
/// ③ 群内语音的 `sourceRoute`（`/group/:id/voice`）不影响列表页显示；
/// ④ **语音 + 直播同时进行**（用户账号真实状态：`is_in_voice=true` 且 `is_live=true`）
///    ⇒ **两个球都要渲染**（此前无任何测试覆盖这个组合）。
///
/// ## ⚠️ 2026-10-31 平台分流（用户改需求）
/// 用户要求「应用内不再存在任何浮层，取而代之的是**创建时就脱离应用**的悬浮窗」。
/// ⇒ Windows / Android 上 `AppShell` 不再渲染应用内球，改为推给窗口外浮层。
/// 本文件的「应用内渲染」断言因此只对 iOS / Web 成立；Windows/Android 上这些用例
/// 由 `skip` 跳过（窗口外浮层的正确性见 `test/overlay_window_root_test.dart`）。
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/layout/app_shell.dart' show AppShell;
import '../lib/state/auth_state.dart' show AuthUser, authNotifierProvider;
import '../lib/state/room_providers.dart' show sessionActivityProvider;
import '../lib/state/session_activity_state.dart';
import '../lib/theme/app_theme.dart' show buildAylaTheme;
import '../lib/theme/app_icons.dart' show AylaIcon;
import '../lib/widgets/shell/session_activity.dart';

/// 一条最小用户（四个媒体字段是主角，其余按序列化契约给空值）。
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

/// 当前平台是否走「窗口外浮层」（Windows / Android）⇒ 应用内不再渲染球。
///
/// 与 `AppShell._SessionActivityHostState.build` 的 `detachedBall` 判据同源：
/// 这两个平台有跨应用浮窗 API，应用内那一份被移出窗口；iOS / Web 没有 ⇒ 仍在应用内渲染。
bool get _detachedPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.android);

/// 把一条「应用内渲染」用例钉在 **iOS 平台**上跑。
///
/// ## 为什么不能 `skip: _detachedPlatform`
/// 那会把 6 条断言**直接丢掉**（本机跑测试的宿主平台是 Windows ⇒ 全跳）。
/// 但「应用内球组的显示/隐藏判定」（tsx 71–82 那套）是**跨平台共用**的逻辑，
/// 只是宿主不同 —— 丢掉它等于放弃对 `_activitySession` / `showVoice` / `showLive`
/// 的回归保护。
///
/// iOS 是**没有**跨应用浮窗 API 的平台（见 `detached_live.dart` 文件头），
/// 那里仍然走应用内渲染 ⇒ 用它当宿主，断言口径与旧版**完全一致**；
/// Windows / Android 的「应用内零浮层 + 推 showBall」由
/// `test/detached_overlay_wiring_test.dart` 单独锁住。
Future<void> _onInAppPlatform(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  // `aylaSessionActivity` 是模块级单例（web zustand store 同款），跨用例存活 ⇒ 前后复位。
  setUp(aylaSessionActivity.reset);
  tearDown(aylaSessionActivity.reset);

  Future<ProviderContainer> pumpShell(
    WidgetTester tester,
    String location, {
    AuthUser? user,
    String? voiceSourceRoute,
  }) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(authNotifierProvider.notifier).setTokens('a', 'r');
    if (user != null) {
      container.read(authNotifierProvider.notifier).setUser(user);
    }
    if (voiceSourceRoute != null) {
      container.read(sessionActivityProvider).upsert(
            AylaActivityRecord(
              kind: AylaActivityKind.voice,
              sessionId: user!.voiceRoomId!,
              sourceRoute: voiceSourceRoute,
              title: '13244',
            ),
          );
    }
    final GoRouter router = GoRouter(
      initialLocation: location,
      routes: <RouteBase>[
        ShellRoute(
          builder: (BuildContext c, GoRouterState s, Widget child) =>
              AppShell(child: child),
          routes: <RouteBase>[
            GoRoute(
              path: '/voice',
              builder: (BuildContext c, GoRouterState s) =>
                  const SizedBox.shrink(),
            ),
            GoRoute(
              path: '/voice/:channelId',
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
    await tester.pump(const Duration(milliseconds: 120));
    return container;
  }

  AylaSessionActivityIndicator indicator(WidgetTester tester) =>
      tester.widget<AylaSessionActivityIndicator>(
        find.byType(AylaSessionActivityIndicator),
      );

  /// 球图标在树上的数量（语音球 = iconMic，直播球 = iconVideo，把手不是图标）。
  ///
  /// 组件内只有「两个球 + 一个把手」，把手是文本字形不是 [AylaIcon]
  /// ⇒ 直接数 `AylaIcon` 就是球数（2026-10-31：脱离键已随用户否决被删除，
  /// 此处恢复成原来的简单计数）。
  int iconCount(WidgetTester tester) => find
      .descendant(
        of: find.byType(AylaSessionActivityIndicator),
        matching: find.byType(AylaIcon),
      )
      .evaluate()
      .length;

  // ⚠️ 2026-10-31 语义变更：用户要求「应用内不再存在任何浮层，取而代之的是**创建时就脱离应用**的
  // 悬浮窗」⇒ Windows / Android 上 `AppShell` **不再渲染** `AylaSessionActivityIndicator`，
  // 改为把会话投影推给窗口外浮层（`aylaShowDetachedBall` / `aylaUpdateDetachedBall`）。
  //
  // 本组用例断言的是「应用内渲染球」的**显示/隐藏判定**（tsx 71–82），
  // 那是跨平台共用的逻辑，只是宿主不同 ⇒ 一律钉在 **iOS 平台**跑
  // （`_onInAppPlatform`，见文件头）：iOS 无跨应用浮窗 API，仍走应用内渲染，
  // 断言口径与旧版完全一致。**不能**用 `skip:` —— 那会把 6 条断言直接丢掉。
  // Windows / Android 的「应用内零浮层 + 推 showBall」由
  // `test/detached_overlay_wiring_test.dart` 单独锁住。
  // 窗口外浮层本身的正确性由 `test/overlay_window_root_test.dart` 覆盖（第二引擎里 build
  // 同一份 `AylaSessionActivityIndicator`，含「无会话零渲染」「点球不抛」）。
  group('语音列表页 /voice 的悬浮球（用户实报）', () {
    testWidgets('★ 在语音 + 停在列表页 ⇒ 语音球必须显示', (WidgetTester tester) async {
      await _onInAppPlatform(() async {
      await pumpShell(
        tester,
        '/voice',
        user: _user(isInVoice: true, voiceRoomId: '54'),
        voiceSourceRoute: '/voice/54',
      );

      expect(
        indicator(tester).voice,
        isNotNull,
        reason: '★ web SessionActivityIndicator.tsx:71–74 的隐藏集合只有 '
            '"/voice/:id" 与 sourceRoute；列表页 "/voice" 两者都不等于 ⇒ showVoice 为真',
      );
      expect(iconCount(tester), 1, reason: '一个语音球图标');
      });
    });

    testWidgets('房内页 /voice/54 ⇒ 语音球隐藏（tsx 71–74 正例，防回归）', (WidgetTester tester) async {
      await _onInAppPlatform(() async {
      await pumpShell(
        tester,
        '/voice/54',
        user: _user(isInVoice: true, voiceRoomId: '54'),
        voiceSourceRoute: '/voice/54',
      );

      expect(indicator(tester).voice, isNull);
      expect(iconCount(tester), 0);
      });
    });

    testWidgets('群内语音的 sourceRoute 不影响列表页显示', (WidgetTester tester) async {
      await _onInAppPlatform(() async {
      await pumpShell(
        tester,
        '/voice',
        user: _user(isInVoice: true, voiceRoomId: '54'),
        voiceSourceRoute: '/group/g1/voice',
      );

      final AylaActivitySession? voice = indicator(tester).voice;
      expect(voice, isNotNull);
      expect(voice!.sourceRoute, '/group/g1/voice', reason: '回房目标是群场景');
      });
    });

    testWidgets('★ 语音 + 直播同时进行 ⇒ **两个球都渲染**（用户账号真实状态）', (WidgetTester tester) async {
      await _onInAppPlatform(() async {
      // 真实数据：xixi 账号 is_in_voice=true room=54 且 is_live=true live=76。
      await pumpShell(
        tester,
        '/voice',
        user: _user(
          isInVoice: true,
          voiceRoomId: '54',
          isLive: true,
          liveRoomId: '76',
        ),
        voiceSourceRoute: '/voice/54',
      );

      expect(indicator(tester).voice, isNotNull, reason: '语音球');
      expect(indicator(tester).live, isNotNull, reason: '直播球');
      expect(
        iconCount(tester),
        2,
        reason: '★ 两个球各有一个图标（此前无任何用例覆盖这个组合）',
      );
      });
    });

    testWidgets('★ 回房路由必须是 /voice/:id —— 不是列表页 /voice（用户点球回不到房间）', (WidgetTester tester) async {
      await _onInAppPlatform(() async {
      // 索引未写入时走兜底投影（tsx 49）；房内宿主 upsert 时写入的是带 id 的那条。
      await pumpShell(
        tester,
        '/voice',
        user: _user(isInVoice: true, voiceRoomId: '54'),
        voiceSourceRoute: '/voice/54',
      );

      final AylaActivitySession voice = indicator(tester).voice!;
      expect(
        voice.sourceRoute,
        '/voice/54',
        reason: '★ web useVoiceChannel.ts:258–259：一级语音的 sourceRoute = /voice/:channelId；'
            '若误用退出落点 backPath（/voice）⇒ 点球回到列表页而不是房间',
      );
      });
    });

    testWidgets('索引缺该 id ⇒ 兜底路由同样带 id（tsx 49）', (WidgetTester tester) async {
      await _onInAppPlatform(() async {
      await pumpShell(
        tester,
        '/voice',
        user: _user(isInVoice: true, voiceRoomId: '54'),
        // 不 seed 索引 ⇒ 走 fallbackRoute。
      );

      expect(indicator(tester).voice!.sourceRoute, '/voice/54');
      });
    });
  });
}
