/// Android 系统叠加层的**几何与通道契约**回归锁（2026-11-01 用户四条实报）。
///
/// ## 用户原话（逐字）
/// > 「手机端悬浮球创建成功，但**背景不穿透**，导致**一大片点不了了**，
/// >   要改成**只有悬浮球本身可点击**」
/// > 「手机端**无法正常点开展开收起**，也**无法上下挪动位置**，
/// >   也没能做到 **Ayla 在后台时点击悬浮球打开唤起 Ayla**」
/// > 「手机端直播小窗重做，打开的小窗**仍然不是原来的小窗口**……
/// >   **新的删掉，用我原来的窗口**」
///
/// ## 本文件锁什么
/// 1. **组建树没被重画**：Android 叠加层里 build 的仍是同一份
///    `AylaSessionActivityIndicator` / `AylaLiveMiniPlayer`；
/// 2. **坐标系约定**：`MediaQuery` 报的是**屏幕**（宽度走宽屏档、高度是屏幕可用高），
///    组件的拖动 clamp 才不会饱和（「拖不动」的根因）；
/// 3. **几何回推**：拖动 top / 卡片矩形经内层通道回推原生（原生据此贴合窗口）；
/// 4. **会话投影**：`ballPayload` 通道能更新球组（第二引擎没有 store）。
///
/// ⚠️ 真机行为（窗口是否真的贴合、点球是否真的把 App 拉到前台）**本文件测不到** ——
/// 那需要设备 + 「显示在其他应用上层」权限，已在交付报告中如实登记为「未在设备验证」。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/widgets/live/live_mini_player.dart' show AylaLiveMiniPlayer;
import '../lib/widgets/shell/overlay_android_host.dart';
import '../lib/widgets/shell/session_activity.dart'
    show AylaSessionActivityIndicator;

/// 记录第二引擎 → 原生的所有内层通道调用。
class _CallLog {
  final List<MethodCall> calls = <MethodCall>[];

  void install(WidgetTester tester, MethodChannel channel) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (MethodCall call) async {
        calls.add(call);
        return true;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
  }

  Iterable<MethodCall> named(String method) =>
      calls.where((MethodCall c) => c.method == method);
}

/// 与 `main.dart` 的 `_aylaAndroidOverlayRoot` 同构的根
/// （Directionality / MediaQuery / Overlay / Navigator 四样缺一不可）。
Widget _root(Widget home) => MaterialApp(
      debugShowCheckedModeBanner: false,
      color: Colors.transparent,
      home: home,
    );

const String kPayloadJson =
    '{"voiceSessionId":"54","voiceTitle":"深夜电台","voiceRoute":"/voice/54",'
    '"liveSessionId":"","liveTitle":"","liveRoute":""}';

void main() {
  group('球窗（悬浮球叠加层）', () {
    testWidgets('起得来，且 build 的仍是**同一份** AylaSessionActivityIndicator', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _root(
          const AylaAndroidOverlayBallApp(
            initialPayload: kPayloadJson,
            initialViewportWidth: 412,
            initialViewportHeight: 780,
            initialWindowRect: AylaOverlayWindowRect(
              left: 0,
              top: 74,
              width: 160,
              height: 60,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      // 用户要求「不要造轮子，用现有的悬浮球」⇒ 必须是那个组件本身。
      expect(find.byType(AylaSessionActivityIndicator), findsOneWidget);
      expect(find.text('›'), findsOneWidget);
    });

    testWidgets('无会话 ⇒ 零渲染（不在桌面上留一个空窗）', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _root(const AylaAndroidOverlayBallApp(initialPayload: '{}')),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(AylaSessionActivityIndicator), findsNothing);
    });

    testWidgets('视口报的是**屏幕**（宽 + 高），不是那个 160×60 的小窗口', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _root(
          const AylaAndroidOverlayBallApp(
            initialPayload: kPayloadJson,
            initialViewportWidth: 412,
            initialViewportHeight: 780,
            initialWindowRect: AylaOverlayWindowRect(
              left: 0,
              top: 74,
              width: 160,
              height: 60,
            ),
          ),
        ),
      );
      await tester.pump();

      final BuildContext ctx = tester.element(
        find.byType(AylaSessionActivityIndicator),
      );
      final Size viewport = MediaQuery.sizeOf(ctx);
      // 视口必须 = **屏幕**：组件的 `Positioned` 相对画卷解析，画卷也必须是屏幕尺寸，
      // 否则球/卡片会落到屏幕外（第一版把画卷写成 1280 ⇒ 卡片 left 算成 585）。
      expect(viewport.width, 412);
      // 高度必须是屏幕高度：组件的拖动 clamp 是
      // `[8, 视口高 - 44 - 8]`，报小了就会被夹死（「拖不动」的根因）。
      expect(viewport.height, 780);
    });

    testWidgets('ballPayload 通道 ⇒ 球组跟着换（第二引擎没有 store）', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _root(const AylaAndroidOverlayBallApp(initialViewportHeight: 780)),
      );
      await tester.pump();
      // 初始无会话 ⇒ 零渲染。
      expect(find.byType(AylaSessionActivityIndicator), findsNothing);

      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        kAylaAndroidOverlayChannel,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('ballPayload', <String, Object?>{
            'payload': kPayloadJson,
          }),
        ),
        (ByteData? _) {},
      );
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(AylaSessionActivityIndicator), findsOneWidget);
    });
  });

  group('直播小窗叠加层', () {
    testWidgets('build 的仍是**同一份** AylaLiveMiniPlayer（168×94 那张卡本身）', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _root(
          const AylaAndroidLiveOverlayApp(
            initialTitle: '深夜电台',
            initialViewportWidth: 412,
            initialViewportHeight: 780,
            initialWindowRect: AylaOverlayWindowRect(
              left: 0,
              top: 0,
              width: 188,
              height: 114,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(AylaLiveMiniPlayer), findsOneWidget);
    });

    testWidgets('卡片矩形经 setCardRect 回推原生（窗口据此贴合）', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final _CallLog log = _CallLog();
      log.install(tester, const MethodChannel(kAylaAndroidLiveWindowChannel));

      await tester.pumpWidget(
        _root(
          const AylaAndroidLiveOverlayApp(
            initialViewportWidth: 412,
            initialViewportHeight: 780,
            initialWindowRect: AylaOverlayWindowRect(
              left: 0,
              top: 0,
              width: 188,
              height: 114,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      final Iterable<MethodCall> rects = log.named('setCardRect');
      expect(
        rects,
        isNotEmpty,
        reason: '原生必须知道卡片在哪，才能让窗口只包住它（背景才穿透）',
      );
      final Map<Object?, Object?> args =
          rects.first.arguments as Map<Object?, Object?>;
      // 卡片默认落点 = 右下角 16（live.css:1021–1039）；屏幕坐标。
      expect((args['width'] as num).toDouble(), 168);
      expect((args['height'] as num).toDouble(), 94);
      // 默认落点 = 屏幕右下角 16（`live.css:1021–1039` 的 `right/bottom: 16`）。
      expect((args['left'] as num).toDouble(), 412 - 168 - 16);
      expect((args['top'] as num).toDouble(), 780 - 94 - 16);
    });

    testWidgets('窗口矩形未知时也能起（不平移，按窗口内坐标渲染）', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _root(
          const AylaAndroidLiveOverlayApp(
            initialViewportWidth: 412,
            initialViewportHeight: 780,
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(AylaLiveMiniPlayer), findsOneWidget);
    });
  });

  group('坐标换算（纯函数）', () {
    testWidgets('屏幕矩形 = 本地矩形 + 窗口原点', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final GlobalKey key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              key: key,
              width: 100,
              height: 50,
            ),
          ),
        ),
      );
      await tester.pump();
      final RenderBox box = key.currentContext!.findRenderObject()! as RenderBox;

      const AylaOverlayWindowRect rect = AylaOverlayWindowRect(
        left: 120,
        top: 300,
        width: 160,
        height: 60,
      );
      // 本地坐标（窗口内）→ 屏幕坐标：加上窗口原点。
      final Rect local = box.localToGlobal(Offset.zero) & box.size;
      final Rect screen = aylaAndroidScreenRectOf(box, rect);
      expect(screen.left, local.left + 120);
      expect(screen.top, local.top + 300);
      expect(screen.width, box.size.width);
      expect(screen.height, box.size.height);
    });
  });
}