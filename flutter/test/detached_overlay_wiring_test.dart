/// 「应用内不再有浮层」的平台分流回归锁（2026-10-31 用户定稿）。
///
/// ## 用户原话（逐字）
/// > 「**不要造轮子！用现有的悬浮球和直播小窗**」
/// > 「悬浮球不应该重新做一个出来，而是直接原来的浮层悬浮球直接扔出应用窗口外」
/// > 「**应用内不会再存在任何浮层**……取而代之的是创建时就脱离应用的、显示在其他应用之上的
/// >   悬浮窗，外观和交互完全没有区别」
///
/// ## 本文件锁什么
/// 1. **Android / Windows**：`AppShell` 里**不得**再出现 `AylaSessionActivityIndicator`
///    （应用内零浮层），且必须把会话投影推给系统层浮层（`showBall` 通道调用，
///    参数是 `AylaOverlayPayload.encode()` 的 JSON 串）。
/// 2. **iOS**：仍走应用内渲染（iOS 没有任何跨应用悬浮窗口 API —— 能力边界，不伪装）。
/// 3. **无会话**：不推 `showBall`（浮层没有存在意义，别在桌面上留一个空窗）。
///
/// ⚠️ 为什么必须单独一条文件：这两条都是「接线」而不是「组件」，
/// 组件自己的测试永远发现不了（它们的调用方就是测试自己）——
/// 与 `session_activity_host_test.dart` 文件头记录的「组件写完但从未接线」是同一类缺口。
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/layout/app_shell.dart' show AppShell;
import '../lib/state/auth_state.dart' show AuthUser, authNotifierProvider;
import '../lib/state/room_providers.dart' show sessionActivityProvider;
import '../lib/state/session_activity_state.dart';
import '../lib/theme/app_theme.dart' show buildAylaTheme;
import '../lib/widgets/shell/session_activity.dart'
    show AylaSessionActivityIndicator;

/// 与 `main.dart` 的 `detached_live.dart` 逐字一致的通道名。
const MethodChannel _pipChannel = MethodChannel('ayla/live_pip');
const MethodChannel _desktopChannel = MethodChannel('ayla/desktop_window');

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

void main() {
  setUp(aylaSessionActivity.reset);
  tearDown(aylaSessionActivity.reset);

  /// 装上假的平台通道：把「主引擎 → 原生」的调用全部记下来。
  ///
  /// `showBall` 必须回 `"shown"`，否则 `_syncDetachedBall` 会走降级分支
  /// （弹权限引导 / toast），那不是本文件要断言的东西。
  List<MethodCall> installChannels(WidgetTester tester) {
    final List<MethodCall> calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _pipChannel,
      (MethodCall call) async {
        calls.add(call);
        return call.method == 'showBall' ? 'shown' : null;
      },
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _desktopChannel,
      (MethodCall call) async {
        calls.add(call);
        if (call.method == 'showBall') return 'shown';
        if (call.method == 'updateBall') return 'shown';
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(_pipChannel, null);
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(_desktopChannel, null);
    });
    return calls;
  }

  Future<ProviderContainer> pumpShell(
    WidgetTester tester, {
    AuthUser? user,
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
    if (user?.voiceRoomId != null) {
      container.read(sessionActivityProvider).upsert(
            AylaActivityRecord(
              kind: AylaActivityKind.voice,
              sessionId: user!.voiceRoomId!,
              sourceRoute: '/voice/${user.voiceRoomId}',
              title: '深夜电台',
            ),
          );
    }
    final GoRouter router = GoRouter(
      initialLocation: '/voice',
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
    await tester.pump(const Duration(milliseconds: 120));
    return container;
  }

  /// 在指定平台上跑一段测试体，**体内复位**（否则污染后续用例）。
  Future<void> onPlatform(
    TargetPlatform platform,
    Future<void> Function() body,
  ) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  group('应用内零浮层（Android / Windows）', () {
    testWidgets('Android：有会话 ⇒ 应用内不渲染球组，且推 showBall 到 ayla/live_pip', (
      WidgetTester tester,
    ) async {
      await onPlatform(TargetPlatform.android, () async {
        final List<MethodCall> calls = installChannels(tester);
        await pumpShell(
          tester,
          user: _user(isInVoice: true, voiceRoomId: '54'),
        );

        // ① 应用内**不得**再有球组（用户：「应用内不会再存在任何浮层」）。
        expect(
          find.byType(AylaSessionActivityIndicator),
          findsNothing,
          reason: 'Android 上球组只应出现在系统叠加层的第二引擎里',
        );
        // ② 必须把投影推给原生（否则「浮层」根本不会出现）。
        final Iterable<MethodCall> shows =
            calls.where((MethodCall c) => c.method == 'showBall');
        expect(shows, isNotEmpty, reason: '有会话 ⇒ 必须调 showBall 开叠加层');
        final Map<Object?, Object?> args =
            shows.first.arguments as Map<Object?, Object?>;
        expect(
          args['payload'],
          isA<String>(),
          reason: '载荷是 AylaOverlayPayload.encode() 的 JSON 串（原生只透传）',
        );
        expect('${args['payload']}', contains('"voiceSessionId":"54"'));
      });
    });

    testWidgets('Windows：有会话 ⇒ 应用内不渲染球组，且推 showBall 到 ayla/desktop_window', (
      WidgetTester tester,
    ) async {
      await onPlatform(TargetPlatform.windows, () async {
        final List<MethodCall> calls = installChannels(tester);
        await pumpShell(
          tester,
          user: _user(isInVoice: true, voiceRoomId: '54'),
        );

        expect(find.byType(AylaSessionActivityIndicator), findsNothing);
        expect(
          calls.where((MethodCall c) => c.method == 'showBall'),
          isNotEmpty,
        );
      });
    });

    testWidgets('无会话 ⇒ **不**推 showBall（别在桌面上留一个空浮层）', (
      WidgetTester tester,
    ) async {
      await onPlatform(TargetPlatform.android, () async {
        final List<MethodCall> calls = installChannels(tester);
        await pumpShell(tester, user: _user());

        expect(find.byType(AylaSessionActivityIndicator), findsNothing);
        expect(
          calls.where((MethodCall c) => c.method == 'showBall'),
          isEmpty,
          reason: '没有任何会话 ⇒ 浮层没有存在意义',
        );
      });
    });
  });

  group('iOS 仍在应用内渲染（能力边界，不伪装）', () {
    testWidgets('iOS：有会话 ⇒ 应用内照旧渲染球组，且**不**碰浮层通道', (
      WidgetTester tester,
    ) async {
      await onPlatform(TargetPlatform.iOS, () async {
        final List<MethodCall> calls = installChannels(tester);
        await pumpShell(
          tester,
          user: _user(isInVoice: true, voiceRoomId: '54'),
        );

        // iOS 没有任何跨应用悬浮窗口 API ⇒ 只能留在应用内。
        expect(
          find.byType(AylaSessionActivityIndicator),
          findsOneWidget,
          reason: 'iOS 无跨应用浮窗 API ⇒ 必须保持应用内渲染',
        );
        expect(
          calls.where((MethodCall c) => c.method == 'showBall'),
          isEmpty,
          reason: 'aylaDetachedBallPlatformSupported 对 iOS 为 false',
        );
      });
    });
  });
}
