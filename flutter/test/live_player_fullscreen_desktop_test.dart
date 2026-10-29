/// 桌面端**真·全屏**的回归锁（2026-10-30）。
///
/// ## 用户实报与根因
/// 「电脑端直播点全屏，只在 App 窗口里黑一下，不是全屏」—— `live_player.dart` 的
/// `_toggleFullscreen` 此前只做「把内容插进 root Overlay + 移动端锁横屏」，
/// **从未让窗口本身进入全屏**。web 对应的是 `requestFullscreen()`（浏览器让元素进
/// top layer 并让窗口全屏），Flutter 侧必须补一层 `window_manager.setFullScreen`。
///
/// ## 本测试锁住什么
/// 1. 平台判定：只有 window_manager 真支持的桌面平台走窗口级全屏（移动端行为不许变）；
/// 2. 进全屏 ⇒ `setFullScreen(true)`；
/// 3. **退出全屏（含 ESC）⇒ `setFullScreen(false)` 之后追加 `restoreTitleBar()`**
///    —— window_manager 0.5.2 在「最大化状态下进全屏」时会永久留在 frameless，
///    `setTitleBarStyle(normal)` 是唯一能把 `is_frameless_` / `title_bar_style_`
///    同时复位的入口（详见 `AylaDesktopWindowController.restoreTitleBar` 注释）；
/// 4. 全屏中直接离开页面（dispose）也必须还原窗口，否则整个 App 卡在无边框全屏。
///
/// ## 为什么不碰真插件
/// 组件测试跑在 Windows 本机，`defaultTargetPlatform` 天然是 windows ⇒ 若直接调真实
/// `windowManager`，每次进/退全屏都会打进 `window_manager` MethodChannel
/// （flutter_test 下无 handler ⇒ `MissingPluginException`）。本文件全部注入
/// [AylaDesktopWindowController] 替身。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/preview_theme.dart';
import '../lib/widgets/live/live_player.dart';
import '../lib/widgets/base/overlays.dart';

/// 可注入的窗口控制替身：只记录调用，不做任何 HWND 操作。
class _FakeDesktopWindow extends AylaDesktopWindowController {
  _FakeDesktopWindow({this.maximized = false});

  /// 初始是否最大化（用于验证「进全屏前必须先解除最大化」）。
  final bool maximized;

  final List<String> calls = <String>[];

  @override
  Future<bool> isMaximized() async => maximized;

  @override
  Future<void> unmaximize() async {
    calls.add('unmaximize');
  }

  @override
  Future<void> setFullScreen(bool fullscreen) async {
    calls.add('setFullScreen($fullscreen)');
  }

  @override
  Future<void> restoreTitleBar() async {
    calls.add('restoreTitleBar');
  }
}

void main() {
  Widget host(WidgetTester tester, Widget child) {
    tester.view.physicalSize = const Size(640, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: const Size(640, 480)),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 640, height: 480, child: child),
            ),
          ),
        ),
      ),
    );
  }

  Finder byLabel(String label) => find.byWidgetPredicate(
    (Widget w) => w is Semantics && w.properties.label == label,
  );

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> enterFullscreen(WidgetTester tester) async {
    await tester.tap(find.byType(AylaLivePlayer));
    await tester.pump();
    await tester.tap(byLabel('全屏'));
    await settle(tester);
  }

  group('平台判定 aylaUsesDesktopFullscreen', () {
    test('桌面三平台走窗口级全屏；移动端 / Web 不走', () {
      expect(
        aylaUsesDesktopFullscreen(platform: TargetPlatform.windows),
        isTrue,
      );
      expect(aylaUsesDesktopFullscreen(platform: TargetPlatform.macOS), isTrue);
      expect(aylaUsesDesktopFullscreen(platform: TargetPlatform.linux), isTrue);

      expect(
        aylaUsesDesktopFullscreen(platform: TargetPlatform.android),
        isFalse,
      );
      expect(aylaUsesDesktopFullscreen(platform: TargetPlatform.iOS), isFalse);
      expect(
        aylaUsesDesktopFullscreen(platform: TargetPlatform.fuchsia),
        isFalse,
      );
      expect(
        aylaUsesDesktopFullscreen(
          platform: TargetPlatform.windows,
          isWeb: true,
        ),
        isFalse,
        reason: 'Web 没有窗口概念，window_manager 的通道在那里不存在',
      );
    });
  });

  group('桌面真·全屏（注入窗口控制替身）', () {
    testWidgets('点全屏 ⇒ setFullScreen(true)，且 Overlay 内容层仍然插上', (
      WidgetTester tester,
    ) async {
      final _FakeDesktopWindow window = _FakeDesktopWindow();
      final List<bool> events = <bool>[];
      OverlayEntry? captured;
      await tester.pumpWidget(
        host(
          tester,
          AylaLivePlayer(
            srsStatus: AylaLiveSrsStatus.live,
            desktopWindow: window,
            desktopFullscreen: true,
            onFullscreenChanged: events.add,
            overlayHostBuilder: (Widget child) => captured = aylaOverlayEntry(
              builder: (BuildContext ctx) => child,
            ),
          ),
        ),
      );
      await settle(tester);

      await enterFullscreen(tester);

      expect(window.calls, <String>['setFullScreen(true)']);
      expect(events, <bool>[true]);
      expect(byLabel('退出全屏'), findsOneWidget, reason: '内容层与窗口层必须叠加');
      expect(captured, isNotNull);
      expect(window.calls.contains('restoreTitleBar'), isFalse);
    });

    testWidgets('点「退出全屏」⇒ setFullScreen(false) 之后追加 restoreTitleBar()', (
      WidgetTester tester,
    ) async {
      final _FakeDesktopWindow window = _FakeDesktopWindow();
      final List<bool> events = <bool>[];
      await tester.pumpWidget(
        host(
          tester,
          AylaLivePlayer(
            srsStatus: AylaLiveSrsStatus.live,
            desktopWindow: window,
            desktopFullscreen: true,
            onFullscreenChanged: events.add,
            overlayHostBuilder: (Widget child) =>
                aylaOverlayEntry(builder: (BuildContext ctx) => child),
          ),
        ),
      );
      await settle(tester);
      await enterFullscreen(tester);

      await tester.tap(byLabel('退出全屏'));
      await settle(tester);

      expect(window.calls, <String>[
        'setFullScreen(true)',
        'setFullScreen(false)',
        // ⚠️ 顺序固定：先退全屏，再复位 title bar / frameless。
        'restoreTitleBar',
      ]);
      expect(events, <bool>[true, false]);
      expect(byLabel('退出全屏'), findsNothing);
    });

    testWidgets('窗口最大化时进全屏：必须**先解除最大化**（2026-10-31 实报根因）', (
      WidgetTester tester,
    ) async {
      // window_manager 0.5.2 只在「进全屏前不是最大化」时才调 SetAsFrameless()
      // （真正剥掉非客户区的那一步）；从最大化进全屏会跳过它 ⇒ 窗口拉满显示器
      // 但仍带标题栏 ⇒ 用户看到「完全没全屏成功」。故必须先 unmaximize。
      final _FakeDesktopWindow window = _FakeDesktopWindow(maximized: true);
      await tester.pumpWidget(
        host(
          tester,
          AylaLivePlayer(
            srsStatus: AylaLiveSrsStatus.live,
            desktopWindow: window,
            desktopFullscreen: true,
            overlayHostBuilder: (Widget child) =>
                aylaOverlayEntry(builder: (BuildContext ctx) => child),
          ),
        ),
      );
      await settle(tester);
      await enterFullscreen(tester);

      expect(
        window.calls,
        <String>['unmaximize', 'setFullScreen(true)'],
        reason: '最大化状态进全屏必须先 unmaximize，否则 window_manager 跳过 SetAsFrameless'
            ' ⇒ 窗口带标题栏、看起来完全没全屏',
      );
    });

    testWidgets('窗口非最大化时进全屏：**不要**多调 unmaximize（避免无谓的窗口抖动）', (
      WidgetTester tester,
    ) async {
      final _FakeDesktopWindow window = _FakeDesktopWindow(maximized: false);
      await tester.pumpWidget(
        host(
          tester,
          AylaLivePlayer(
            srsStatus: AylaLiveSrsStatus.live,
            desktopWindow: window,
            desktopFullscreen: true,
            overlayHostBuilder: (Widget child) =>
                aylaOverlayEntry(builder: (BuildContext ctx) => child),
          ),
        ),
      );
      await settle(tester);
      await enterFullscreen(tester);

      expect(window.calls, <String>['setFullScreen(true)']);
    });
    testWidgets('ESC 退出同样走完整还原链（用户最常见的退出方式）', (WidgetTester tester) async {
      final _FakeDesktopWindow window = _FakeDesktopWindow();
      await tester.pumpWidget(
        host(
          tester,
          AylaLivePlayer(
            srsStatus: AylaLiveSrsStatus.live,
            desktopWindow: window,
            desktopFullscreen: true,
            overlayHostBuilder: (Widget child) =>
                aylaOverlayEntry(builder: (BuildContext ctx) => child),
          ),
        ),
      );
      await settle(tester);
      await enterFullscreen(tester);
      expect(window.calls, <String>['setFullScreen(true)']);

      // 全屏宿主的 Shortcuts 把 Escape 映射为 DismissIntent → onExit
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);

      expect(window.calls, <String>[
        'setFullScreen(true)',
        'setFullScreen(false)',
        'restoreTitleBar',
      ], reason: 'ESC 退出**必须**还原窗口，否则用户被锁在无边框全屏里');
      expect(byLabel('退出全屏'), findsNothing);
    });

    testWidgets('全屏中直接离开页面（dispose）也会还原窗口', (WidgetTester tester) async {
      final _FakeDesktopWindow window = _FakeDesktopWindow();
      await tester.pumpWidget(
        host(
          tester,
          AylaLivePlayer(
            srsStatus: AylaLiveSrsStatus.live,
            desktopWindow: window,
            desktopFullscreen: true,
            overlayHostBuilder: (Widget child) =>
                aylaOverlayEntry(builder: (BuildContext ctx) => child),
          ),
        ),
      );
      await settle(tester);
      await enterFullscreen(tester);
      expect(window.calls, <String>['setFullScreen(true)']);

      // 卸载整棵树 ⇒ AylaLivePlayer 被 dispose（等同用户在全屏中退出直播间）。
      // 根类型整体换掉（MaterialApp → SizedBox）才能保证 unmount（不是 deactivate），
      // 从而真的跑到 AylaLivePlayer 的 dispose。
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);

      expect(window.calls, <String>[
        'setFullScreen(true)',
        'setFullScreen(false)',
        'restoreTitleBar',
      ]);
    });

    testWidgets('窗口控制抛异常时不打断播放器状态机（仍能退出全屏）', (WidgetTester tester) async {
      final _ThrowingDesktopWindow window = _ThrowingDesktopWindow();
      await tester.pumpWidget(
        host(
          tester,
          AylaLivePlayer(
            srsStatus: AylaLiveSrsStatus.live,
            desktopWindow: window,
            desktopFullscreen: true,
            overlayHostBuilder: (Widget child) =>
                aylaOverlayEntry(builder: (BuildContext ctx) => child),
          ),
        ),
      );
      await settle(tester);

      await enterFullscreen(tester);
      expect(byLabel('退出全屏'), findsOneWidget);

      await tester.tap(byLabel('退出全屏'));
      await settle(tester);
      // 内容层照常收起；异常只被记日志（不得把 _fullscreen 卡在 true）
      expect(byLabel('退出全屏'), findsNothing);
    });
  });

  group('移动端路径不变（不碰窗口控制）', () {
    testWidgets('desktopFullscreen: false ⇒ 只插 Overlay，窗口控制零调用', (
      WidgetTester tester,
    ) async {
      final _FakeDesktopWindow window = _FakeDesktopWindow();
      final List<bool> events = <bool>[];
      await tester.pumpWidget(
        host(
          tester,
          AylaLivePlayer(
            srsStatus: AylaLiveSrsStatus.live,
            desktopWindow: window,
            desktopFullscreen: false,
            onFullscreenChanged: events.add,
            overlayHostBuilder: (Widget child) =>
                aylaOverlayEntry(builder: (BuildContext ctx) => child),
          ),
        ),
      );
      await settle(tester);

      await enterFullscreen(tester);
      expect(byLabel('退出全屏'), findsOneWidget);
      expect(window.calls, isEmpty, reason: '移动端没有窗口级全屏');

      await tester.tap(byLabel('退出全屏'));
      await settle(tester);
      expect(window.calls, isEmpty);
      expect(events, <bool>[true, false]);
    });
  });
}

/// 每次窗口调用都抛异常的替身（验证异常路径不会把播放器锁死在全屏）。
class _ThrowingDesktopWindow extends AylaDesktopWindowController {
  @override
  Future<bool> isMaximized() async => false;

  @override
  Future<void> unmaximize() async {
    throw StateError('boom');
  }

  @override
  Future<void> setFullScreen(bool fullscreen) async {
    throw StateError('boom');
  }

  @override
  Future<void> restoreTitleBar() async {
    throw StateError('boom');
  }
}
