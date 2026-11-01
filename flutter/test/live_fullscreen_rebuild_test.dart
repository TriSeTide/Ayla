/// B1 全屏层动态刷新回归锁（开发文档 §3 B1；需求 §3.1 B1 / §5.1 S1）。
///
/// ## 用户实报与根因
/// 「全屏中黑屏，点刷新/重试都无效，**必须退出全屏再进**」。
///
/// overlay 子树插在 root Overlay 里，是**独立于本 State 的一棵子树**：播放器所在的
/// inline 侧 `setState` 不会重建它。而旧写法把 `_buildFullscreen()` 的**结果**
/// （一个已构建的 Widget 实例）捕获进 builder 闭包：
/// ```dart
/// final Widget fullscreen = _buildFullscreen();
/// aylaOverlayEntry(builder: (ctx) => fullscreen)
/// ```
/// ⇒ 播放器自愈重建、`videoView` 换成新视图后，全屏层仍渲染**旧 videoView**
/// （旧纹理早已随 `rebuild()` 的 `dispose()` 释放）⇒ 全屏永久黑屏，
/// 而 inline 侧正常 ⇒ 用户唯一出路是「退出全屏再进」。
///
/// ## 本测试锁住什么
/// 1. **默认宿主**（`aylaOverlayEntry`）：全屏中换 videoView ⇒ 全屏层渲染新视图，
///    且旧视图**不残留**（两棵并存 = 旧纹理继续被绘制）；
/// 2. **自定义宿主**（`overlayHostBuilder`）：同上 —— 这条路径此前交出去的是
///    已构建实例，宿主再包一层闭包就冻结了（测试/画布走的就是这条）；
/// 3. 反向：全屏中 `playerError` 出现 ⇒ 全屏层也要切到「播放失败」。
///
/// ## 为什么宿主用 ValueListenableBuilder 而不是连调两次 pumpWidget
/// 连调两次 `pumpWidget` 换的是**整棵树的根 widget 实例**，`AylaLivePlayer` 的
/// State 会被重建（全屏态一并丢失，全屏层随之被移除）⇒ 那样根本测不到「全屏期间
/// 换视图」这条路径。必须是「同一个 State 里 widget.videoView 换值」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/overlays.dart';
import '../lib/widgets/live/live_player.dart';

/// 带 key 的假画面：换一个新 key 的实例 ⇒ 可精确断言「全屏层现在渲染的是哪一个」。
Widget fakeVideo(String tag) => ColoredBox(
  key: ValueKey<String>('video-$tag'),
  color: const Color(0xFF102030),
);

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

  testWidgets('B1 默认宿主：全屏中播放器自愈重建（videoView 换新）⇒ 全屏层立刻渲染新视图', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<Widget> view = ValueNotifier<Widget>(fakeVideo('old'));
    addTearDown(view.dispose);
    await tester.pumpWidget(
      host(
        tester,
        ValueListenableBuilder<Widget>(
          valueListenable: view,
          builder: (BuildContext c, Widget v, Widget? _) => AylaLivePlayer(
            srsStatus: AylaLiveSrsStatus.live,
            videoView: v,
          ),
        ),
      ),
    );
    await settle(tester);
    await enterFullscreen(tester);
    expect(
      find.byKey(const ValueKey<String>('video-old')),
      findsOneWidget,
      reason: '进全屏后画面在 overlay 层（inline 侧全屏期间不挂视频）',
    );

    // 播放器自愈重建：会话层把新的 videoView 喂进来（等价 attach 出新的 Video widget）。
    view.value = fakeVideo('new');
    await settle(tester);

    expect(
      find.byKey(const ValueKey<String>('video-new')),
      findsOneWidget,
      reason: 'B1：全屏层必须跟着换成新 videoView，否则旧纹理（已释放）永久黑屏',
    );
    expect(
      find.byKey(const ValueKey<String>('video-old')),
      findsNothing,
      reason: '旧视图不得残留（两棵并存 = 旧纹理继续被绘制）',
    );
    expect(byLabel('退出全屏'), findsOneWidget, reason: '仍应在全屏态');
  });

  testWidgets('B1 自定义宿主：同样必须拿到活的全屏层（不是捕获时刻的快照）', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<Widget> view = ValueNotifier<Widget>(fakeVideo('old'));
    addTearDown(view.dispose);
    // 测试/画布常用的宿主替换形态：把 child 塞进自己的 builder 闭包 ——
    // 旧实现正是因为这里交出去的是「已构建实例」而被冻结。
    OverlayEntry customHost(Widget child) =>
        aylaOverlayEntry(builder: (BuildContext ctx) => child);

    await tester.pumpWidget(
      host(
        tester,
        ValueListenableBuilder<Widget>(
          valueListenable: view,
          builder: (BuildContext c, Widget v, Widget? _) => AylaLivePlayer(
            srsStatus: AylaLiveSrsStatus.live,
            videoView: v,
            overlayHostBuilder: customHost,
          ),
        ),
      ),
    );
    await settle(tester);
    await enterFullscreen(tester);
    expect(find.byKey(const ValueKey<String>('video-old')), findsOneWidget);

    view.value = fakeVideo('new');
    await settle(tester);

    expect(
      find.byKey(const ValueKey<String>('video-new')),
      findsOneWidget,
      reason: 'B1：自定义宿主路径也必须动态求值（这正是「点刷新/重试都无效」那条路径）',
    );
    expect(find.byKey(const ValueKey<String>('video-old')), findsNothing);
  });

  testWidgets('B1 反向：全屏中 playerError 出现 ⇒ 全屏层也要切到「播放失败」', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<Widget> view = ValueNotifier<Widget>(fakeVideo('old'));
    final ValueNotifier<String?> error = ValueNotifier<String?>(null);
    addTearDown(view.dispose);
    addTearDown(error.dispose);

    await tester.pumpWidget(
      host(
        tester,
        ValueListenableBuilder<String?>(
          valueListenable: error,
          builder: (BuildContext c, String? e, Widget? _) =>
              ValueListenableBuilder<Widget>(
            valueListenable: view,
            builder: (BuildContext c2, Widget v, Widget? __) => AylaLivePlayer(
              srsStatus: AylaLiveSrsStatus.live,
              videoView: v,
              playerError: e,
              onRetry: () {},
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    await enterFullscreen(tester);
    expect(find.byKey(const ValueKey<String>('video-old')), findsOneWidget);

    error.value = 'boom';
    await settle(tester);

    expect(find.byKey(const ValueKey<String>('video-old')), findsNothing);
    // 两处都渲染错误态是**正确**的：inline 侧在全屏期间不挂视频，但三态占位层
    // 依然在树里（进全屏前也能看到）；本用例要锁的是「全屏层也拿到了 playerError」。
    // 若全屏层冻结在旧快照，这里就只会有一个（inline 那个），全屏里一片黑。
    expect(
      find.text('播放失败'),
      findsNWidgets(2),
      reason: '三态渲染必须同步到全屏层，否则全屏里连错误提示都看不到（只剩一片黑）',
    );
  });
}
