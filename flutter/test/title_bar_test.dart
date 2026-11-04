/// 自绘标题栏（Windows 去原生标题栏）回归锁。
///
/// ## 需求（用户原话）
/// 「把 windows 窗口原生顶部标题栏去掉，改成 Ayla 专属的美观的融入的标题栏。
///   Ayla 启动默认最大化，标题栏要有最小化、窗口化、关闭」
///
/// ## 本文件锁什么（原生部分编译期不可测，故只锁 Dart 侧的可判定契约）
/// 1. **三键齐全且动作对**：最小化 / 窗口化（最大化↔还原）/ 关闭 —— 每个键点一次
///    必须调到注入控制器的对应方法（`AylaWindowChromeController` 可注入，
///    否则每个用例都会打进 window_manager 的 MethodChannel）；
/// 2. **最大化状态来自窗口事件，不来自自己的记账**：外部 `onWindowMaximize` /
///    `onWindowUnmaximize` 后，窗口化键的行为必须跟着翻面（第二次点击走
///    `unmaximize`），否则会出现「系统最大化过、App 以为没最大化」的死锁；
/// 3. **首帧同步**：启动时窗口已经是最大化（`isMaximized() == true`）⇒ 第一帧
///    之后窗口化键的语义也必须已经是「还原」；
/// 4. **平台判定**：只有 Windows / Linux 挂这条；Android / iOS / macOS / Web 不挂
///    （没有可去掉的系统标题栏，且已有窄屏 / 宽屏顶栏）；
/// 5. **条高 = 40 且窗口键 40×40**：design.md §10「≥40px 触达目标」的数值锁；
/// 6. **标题区可拖拽 + 双击最大化**：拖拽必须调 `startDragging`（`SC_MOVE`），
///    双击必须走最大化/还原；
/// 7. **窗口级全屏让位**：`onWindowEnterFullScreen` 后条高归零（直播全屏时窗口
///    覆盖整块显示器，留着这条会压在画面上）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart'
    show ResizeEdge, WindowListener;

import '../lib/theme/app_theme.dart' show buildAylaTheme;
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/shell/title_bar.dart';
import '../lib/widgets/shell/top_nav.dart' show AylaTopNav;

/// 记录调用并可控返回的控制器替身。
class FakeChrome extends AylaWindowChromeController {
  FakeChrome({this.maximized = false});

  bool maximized;
  final List<String> calls = <String>[];

  @override
  Future<void> minimize() async => calls.add('minimize');

  @override
  Future<void> maximize() async {
    calls.add('maximize');
    maximized = true;
  }

  @override
  Future<void> unmaximize() async {
    calls.add('unmaximize');
    maximized = false;
  }

  @override
  Future<void> close() async => calls.add('close');

  @override
  Future<void> startDragging() async => calls.add('startDragging');

  @override
  Future<bool> isMaximized() async => maximized;
}

/// 事件源替身：保存订阅者，测试直接派发（等价原生 `onEvent` 派发）。
///
/// 为什么不直接用 `windowManager`：那会真的调进 MethodChannel（测试环境无
/// handler ⇒ MissingPluginException），事件也永远到不了。
class FakeWindowSource extends AylaWindowEvents {
  FakeWindowSource();

  final List<WindowListener> _listeners = <WindowListener>[];

  @override
  void addListener(WindowListener listener) => _listeners.add(listener);

  @override
  void removeListener(WindowListener listener) => _listeners.remove(listener);

  /// 当前订阅者数量（用于锁「卸载时成对移除」）。
  int get listenerCount => _listeners.length;

  void onWindowMaximize() {
    for (final WindowListener l in List<WindowListener>.of(_listeners)) {
      l.onWindowMaximize();
    }
  }

  void onWindowUnmaximize() {
    for (final WindowListener l in List<WindowListener>.of(_listeners)) {
      l.onWindowUnmaximize();
    }
  }

  void onWindowEnterFullScreen() {
    for (final WindowListener l in List<WindowListener>.of(_listeners)) {
      l.onWindowEnterFullScreen();
    }
  }

  void onWindowLeaveFullScreen() {
    for (final WindowListener l in List<WindowListener>.of(_listeners)) {
      l.onWindowLeaveFullScreen();
    }
  }
}

/// 与生产一致的最小宿主：主题 + 方向性（本件不依赖 Material 之外的东西）。
Widget host(Widget child) => previewTheme(Column(children: <Widget>[child]));


/// 标题条里那条「上边缘」缩放带。
///
/// 判定而非 key：带子是**透明**的（不画任何东西），没有可见标识可断言，而
/// `MouseRegion(cursor: resizeUpDown)` + `opaque` + `SizedBox` 子件正是它的契约
/// （见 [AylaResizeEdges] 的类文档）。
Finder _topResizeBand() => find.byWidgetPredicate((Widget w) {
  if (w is! MouseRegion) return false;
  if (w.cursor != SystemMouseCursors.resizeUpDown) return false;
  final Widget? inner = w.child;
  return inner is GestureDetector &&
      inner.behavior == HitTestBehavior.opaque &&
      inner.child is SizedBox;
});
void main() {
  test('平台判定：只有 Windows / Linux 挂自绘标题栏', () {
    expect(aylaUsesCustomTitleBar(platform: TargetPlatform.windows), isTrue);
    expect(aylaUsesCustomTitleBar(platform: TargetPlatform.linux), isTrue);
    for (final TargetPlatform p in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.fuchsia,
    ]) {
      expect(aylaUsesCustomTitleBar(platform: p), isFalse, reason: '$p 不该挂');
    }
    expect(aylaUsesCustomTitleBar(isWeb: true), isFalse);
  });

  test('条高 32 = 品牌行高（条内不留空白带），窗口键命中 40×40', () {
    expect(AylaTitleBarMetrics.height, 32);
    expect(AylaTitleBarMetrics.brandRowHeight, 32);
    expect(
      AylaTitleBarMetrics.height,
      AylaTitleBarMetrics.brandRowHeight,
      reason: '条内不得再留空白带（用户实报红框要求删掉那段留空）',
    );
    // 顶栏玻璃卡在桌面端不再自带上外边距：那一段已被标题条接管。
    expect(AylaTopNav.wideMarginUnderTitleBar.top, 0);
    expect(
      AylaTopNav.wideMargin.top,
      greaterThan(0),
      reason: 'web/移动端仍保留 12px，只有桌面端被标题条接管',
    );
    // design.md §10 的硬下限：命中目标 ≥ 40，键**可以溢出条高**（这正是 32 条高的前提）。
    expect(AylaTitleBarMetrics.hitSize, greaterThanOrEqualTo(40));
    // 命中区 ≥ 40（可达性），且**不得**小于品牌行高（否则键会溢出到下方极光带里）。
    expect(
      AylaTitleBarMetrics.hitSize,
      greaterThanOrEqualTo(AylaTitleBarMetrics.brandRowHeight),
      reason: '窗口键必须能落在品牌行内，不许溢出到条下方的极光带',
    );
    // 悬停胶囊必须收在命中区之内，否则悬停底会越过命中边界。
    expect(
      AylaTitleBarMetrics.chipSize,
      lessThan(AylaTitleBarMetrics.hitSize),
    );
  });

  testWidgets('三键各按一次 ⇒ 分别调到最小化 / 最大化 / 关闭', (
    WidgetTester tester,
  ) async {
    final FakeChrome chrome = FakeChrome();
    await tester.pumpWidget(host(AylaTitleBar(controller: chrome)));
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('最小化'));
    await tester.pump();
    expect(chrome.calls, <String>['minimize']);

    await tester.tap(find.bySemanticsLabel('最大化'));
    await tester.pump();
    expect(chrome.calls, <String>['minimize', 'maximize']);

    await tester.tap(find.bySemanticsLabel('关闭'));
    await tester.pump();
    expect(chrome.calls, <String>['minimize', 'maximize', 'close']);
  });

  testWidgets('最大化状态来自窗口事件：外部最大化后，窗口化键改走还原', (
    WidgetTester tester,
  ) async {
    final FakeChrome chrome = FakeChrome();
    // 生产是把 windowManager 传进来；这里传一个替身，事件由测试直接派发。
    final FakeWindowSource source = FakeWindowSource();
    await tester.pumpWidget(host(AylaTitleBar(controller: chrome, events: source)));
    await tester.pump();

    // 外部（系统）最大化：window_manager 会把它派发给所有 listener。
    source.onWindowMaximize();
    await tester.pump();
    expect(find.bySemanticsLabel('还原'), findsOneWidget);
    expect(find.bySemanticsLabel('最大化'), findsNothing);

    await tester.tap(find.bySemanticsLabel('还原'));
    await tester.pump();
    expect(chrome.calls, <String>['unmaximize']);

    // 外部还原 ⇒ 键翻回「最大化」。
    source.onWindowUnmaximize();
    await tester.pump();
    expect(find.bySemanticsLabel('最大化'), findsOneWidget);
  });

  testWidgets('首帧同步：启动时已最大化 ⇒ 第一帧后窗口化键就是「还原」', (
    WidgetTester tester,
  ) async {
    final FakeChrome chrome = FakeChrome(maximized: true);
    await tester.pumpWidget(host(AylaTitleBar(controller: chrome)));
    // `isMaximized()` 是 async：先让 Future 完成，再稳定一帧。
    await tester.pump();
    await tester.pump();
    expect(find.bySemanticsLabel('还原'), findsOneWidget);
  });

  testWidgets('标题区拖拽 ⇒ startDragging；双击 ⇒ 最大化（窗口 chrome 语义）', (
    WidgetTester tester,
  ) async {
    final FakeChrome chrome = FakeChrome();
    await tester.pumpWidget(host(AylaTitleBar(controller: chrome)));
    await tester.pump();

    // 拖拽标题区（避开右侧三键）：`startDragging` 是系统级 SC_MOVE。
    await tester.drag(find.text('Ayla'), const Offset(60, 40));
    await tester.pump();
    expect(chrome.calls, contains('startDragging'));

    chrome.calls.clear();
    // 双击 = 两次 tap（DoubleTapGestureRecognizer 的 300ms 窗口内）。
    await tester.tap(find.text('Ayla'));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.text('Ayla'));
    // 收掉双击识别器残留的计时器（否则 test 框架报 pending timer）。
    await tester.pump(const Duration(milliseconds: 400));
    expect(chrome.calls, contains('maximize'));
  });

  testWidgets('直播窗口级全屏时标题栏让位：条高归零（fullscreenActive 驱动）', (
    WidgetTester tester,
  ) async {
    // ⚠️ 这条**不能**用 `onWindowEnterFullScreen` 去驱动：window_manager 只在
    // `wParam == SIZE_MAXIMIZED` 时才发该事件，而本 app 进全屏走 SetWindowPos
    // 铺满显示器 ⇒ 事件永不发出（2026-11-04 实报「直播全屏画面时不用这个标题栏」
    // 就是第一版监听了这个从不触发的信号）。
    // 现在的契约：调用方把播放器广播的 aylaLiveWindowFullscreen 传进
    // `fullscreenActive`，标题条据此让位。
    //
    // 宿主必须用 **MaterialApp + Align**：
    // · `host()` 是 `Column` 宿主 —— 让位后组件返回的 `SizedBox(width: infinity)`
    //   没有高度约束，会被 Column 撑回 32，量到的永远是旧高度；
    // · 每次断言前都要 `pump()` 两次（pumpWidget 一帧 + 布局稳定一帧），
    //   否则 `getSize` 读到的是上一帧的布局结果。
    // 与 `test/tmp_iso` 里已验证可行的宿主一致（MaterialApp + Scaffold + Align）。
    Widget hosted(Widget child) => MaterialApp(
      theme: buildAylaTheme(),
      home: Scaffold(
        body: Align(alignment: Alignment.topLeft, child: child),
      ),
    );

    await tester.pumpWidget(hosted(const AylaTitleBar()));
    await tester.pump();
    await tester.pump();
    expect(
      tester.getSize(find.byType(AylaTitleBar)).height,
      AylaTitleBarMetrics.height,
    );

    await tester.pumpWidget(hosted(const AylaTitleBar(fullscreenActive: true)));
    await tester.pump();
    await tester.pump();
    expect(
      tester.getSize(find.byType(AylaTitleBar)).height,
      0,
      reason: '直播全屏时标题条必须整条让位，否则压在视频画面上',
    );

    await tester.pumpWidget(hosted(const AylaTitleBar()));
    await tester.pump();
    await tester.pump();
    expect(
      tester.getSize(find.byType(AylaTitleBar)).height,
      AylaTitleBarMetrics.height,
      reason: '退出全屏后标题条要回来',
    );
  });

  testWidgets('窗口化时上边缘可缩放；最大化后整组缩放带消失', (WidgetTester tester) async {
    final FakeChrome chrome = FakeChrome();
    final FakeWindowSource source = FakeWindowSource();
    await tester.pumpWidget(host(AylaTitleBar(controller: chrome, events: source)));
    await tester.pump();

    // 窗口化：上边带存在（贴条顶、宽 = 条宽 − 两侧角）。
    final double band = AylaResizeEdges.grabBand;
    final Finder topBand = _topResizeBand();
    expect(topBand, findsOneWidget, reason: '窗口化时上边缘必须能缩放');
    expect(tester.getSize(topBand).height, band);

    // 最大化：没有任何缩放带（最大化窗口没有可拖的边）。
    source.onWindowMaximize();
    await tester.pump();
    expect(find.byType(AylaResizeEdges), findsNothing, reason: '标题条内不嵌 AylaResizeEdges');
    expect(_topResizeBand(), findsNothing, reason: '最大化后不得保留缩放带');
  });

  testWidgets('窗口键压在缩放带之上：右上角的关闭键仍然点得到', (WidgetTester tester) async {
    final FakeChrome chrome = FakeChrome();
    await tester.pumpWidget(host(AylaTitleBar(controller: chrome)));
    await tester.pump();

    // 关闭键的命中中心（条最右、垂直居中）。
    final Offset closeCenter = tester.getCenter(find.bySemanticsLabel('关闭'));
    await tester.tapAt(closeCenter);
    await tester.pump();
    expect(
      chrome.calls,
      <String>['close'],
      reason: '关闭键在右上角附近，缩放带不得抢走它的点击',
    );
  });

  testWidgets('AylaResizeEdgeSet.content 不含上边（上边归标题条）', (WidgetTester tester) async {
    expect(AylaResizeEdgeSet.content.top, isFalse);
    expect(AylaResizeEdgeSet.content.bottom, isTrue);
    expect(AylaResizeEdgeSet.content.left, isTrue);
    expect(AylaResizeEdgeSet.content.right, isTrue);
    expect(AylaResizeEdgeSet.all.top, isTrue);
    expect(AylaResizeEdgeSet.none.top, isFalse);

    // 关掉时完全透传：不叠任何命中带。
    await tester.pumpWidget(
      host(
        AylaResizeEdges(
          enabled: false,
          child: const ColoredBox(color: Color(0xFFFFFFFF)),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(GestureDetector), findsNothing);
  });

  testWidgets('边缘缩放走注入回调（默认实现是 windowManager.startResizing）', (
    WidgetTester tester,
  ) async {
    final List<ResizeEdge> started = <ResizeEdge>[];
    // ⚠️ 必须给**有界**高度：本件内部是 `Stack(fit: expand)` —— 生产里它由
    // `AylaAuroraBackground` 的 `Column` 带 `Expanded` 给定高度，测试宿主是
    // 无界 `Column`，不套 `SizedBox` 会撞 `BoxConstraints forces an infinite height`。
    await tester.pumpWidget(
      host(
        SizedBox(
          height: 300,
          child: AylaResizeEdges(
            enabled: true,
            edges: AylaResizeEdgeSet.content,
            onResizeStart: (ResizeEdge e) async => started.add(e),
            child: const ColoredBox(color: Color(0xFFFFFFFF)),
          ),
        ),
      ),
    );
    await tester.pump();

    // `AylaResizeEdges` 自身是 Stack（没有固有尺寸），几何取它包住的 child。
    final Rect box = tester.getRect(find.byType(ColoredBox));
    // 下边中点：命中下边带。
    await tester.dragFrom(
      Offset(box.center.dx, box.bottom - 2),
      const Offset(0, -30),
    );
    await tester.pump();
    expect(started, <ResizeEdge>[ResizeEdge.bottom]);
  });

  test('源码契约：全仓不得再把标题栏复位成 TitleBarStyle.normal', () {
    // 原生 caption 由 runner 去掉（WM_NCCALCSIZE 恒返回 0）后，`normal` 会让
    // window_manager 的 `title_bar_style_` 与真实窗口不一致 —— 之后任何走它内部逻辑的
    // 操作（ForceRefresh / SetFullScreen 的恢复分支）都会按「有标题栏」算客户区。
    // 唯一负责复位的是 `live_player.dart` 的 restoreTitleBar（应为 hidden）。
    final Directory lib = Directory('lib');
    expect(lib.existsSync(), isTrue, reason: '测试工作目录必须是 flutter 工程根');
    final List<String> offenders = <String>[];
    for (final FileSystemEntity f in lib.listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final String src = f.readAsStringSync();
      if (src.contains('TitleBarStyle.normal')) offenders.add(f.path);
    }
    expect(
      offenders,
      isEmpty,
      reason: '这些文件仍把标题栏复位成系统档：$offenders',
    );
  });

  testWidgets('整条高度内任意一点都能起拖拽（贴顶 / 中线 / 底部 1px）', (
    WidgetTester tester,
  ) async {
    final FakeChrome chrome = FakeChrome();
    await tester.pumpWidget(host(AylaTitleBar(controller: chrome)));
    await tester.pump();

    final Rect bar = tester.getRect(find.byType(AylaTitleBar));
    expect(bar.height, AylaTitleBarMetrics.height);

    // 三个纵向采样点：贴顶 10px 处、品牌行中线、**条最底 1px**。
    // 任意一点都要能起拖拽 —— 这是「看得到却拖不动」的回归锁。
    final List<double> ys = <double>[
      bar.top + 10,
      bar.top + AylaTitleBarMetrics.brandRowHeight / 2,
      bar.bottom - 1,
    ];
    final double x = bar.left + bar.width * 0.35; // 避开右侧三键
    for (final double y in ys) {
      chrome.calls.clear();
      final TestGesture g = await tester.startGesture(Offset(x, y));
      // 3px 阈值 + 1px 余量：必须**一步**就起拖（旧实现要 18px slop）。
      await g.moveBy(const Offset(4, 0));
      await tester.pump();
      expect(
        chrome.calls,
        contains('startDragging'),
        reason: 'y=$y（条内 ${y - bar.top}px）拖不动 —— 命中区没覆盖整条',
      );
      await g.up();
      await tester.pump();
    }
  });

  testWidgets('拖拽无需大位移：3px 阈值内即起拖（旧实现 18px slop 的回归锁）', (
    WidgetTester tester,
  ) async {
    final FakeChrome chrome = FakeChrome();
    await tester.pumpWidget(host(AylaTitleBar(controller: chrome)));
    await tester.pump();

    final Rect bar = tester.getRect(find.byType(AylaTitleBar));
    final TestGesture g = await tester.startGesture(
      Offset(bar.left + bar.width * 0.3, bar.center.dy),
    );
    // 1px：不该起拖（区分手抖与点击）；4px：必须起拖。
    await g.moveBy(const Offset(1, 0));
    await tester.pump();
    expect(chrome.calls, isNot(contains('startDragging')));
    await g.moveBy(const Offset(3, 0));
    await tester.pump();
    expect(chrome.calls, contains('startDragging'));
    await g.up();
    await tester.pump();
  });

  testWidgets('拖拽后不再触发双击最大化（拖过 ≠ 点过）', (WidgetTester tester) async {
    final FakeChrome chrome = FakeChrome();
    await tester.pumpWidget(host(AylaTitleBar(controller: chrome)));
    await tester.pump();

    final Rect bar = tester.getRect(find.byType(AylaTitleBar));
    final Offset p = Offset(bar.left + bar.width * 0.3, bar.center.dy);
    // 第一次：拖动（应只起拖，不该被记成一次点击）
    final TestGesture g1 = await tester.startGesture(p);
    await g1.moveBy(const Offset(20, 0));
    await g1.up();
    await tester.pump();
    chrome.calls.clear();
    // 第二次：单击 —— 若上一步被误记成点击，这里就会被判成「双击」而最大化。
    await tester.tapAt(p);
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      chrome.calls,
      isNot(contains('maximize')),
      reason: '拖拽结束后紧接着的一次单击不得被判成双击',
    );
  });
}